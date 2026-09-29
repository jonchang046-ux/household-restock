-- life-tools / household restock MVP
-- 在 Supabase SQL Editor 以 postgres 執行一次。所有變更在同一交易內。
-- 不修改既有其他 App 的表、權限、Auth 設定或預設 grants。
begin;

create table public.life_households (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 80),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create table public.life_household_members (
  household_id uuid not null references public.life_households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','member')),
  joined_at timestamptz not null default now(),
  primary key (household_id,user_id)
);
create index life_members_user_idx on public.life_household_members(user_id, household_id);

create table public.restock_items (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.life_households(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  category text not null default '其他' check (category in ('浴廁','清潔','廚房','食品','個人用品','其他')),
  status text not null default 'normal' check (status in ('normal','low')),
  last_restocked_at timestamptz,
  version bigint not null default 1,
  created_at timestamptz not null default now(),
  unique(id, household_id)
);
create index restock_items_household_idx on public.restock_items(household_id);
create table public.restock_history (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.life_households(id) on delete cascade,
  item_id uuid not null,
  restocked_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  foreign key (item_id, household_id) references public.restock_items(id, household_id) on delete cascade
);
create index restock_history_item_date_idx on public.restock_history(item_id, restocked_at);
create index restock_history_household_idx on public.restock_history(household_id);

alter table public.life_households enable row level security;
alter table public.life_household_members enable row level security;
alter table public.restock_items enable row level security;
alter table public.restock_history enable row level security;

-- 成員只讀自己的 membership，避免遞迴 RLS，也不公開其他帳號資料。
create policy life_members_read_self on public.life_household_members
  for select to authenticated using (user_id = (select auth.uid()));
create policy life_households_read_member on public.life_households
  for select to authenticated using (exists (
    select 1 from public.life_household_members m where m.household_id = id and m.user_id = (select auth.uid())
  ));
create policy restock_items_read_member on public.restock_items
  for select to authenticated using (exists (
    select 1 from public.life_household_members m where m.household_id = restock_items.household_id and m.user_id = (select auth.uid())
  ));
create policy restock_history_read_member on public.restock_history
  for select to authenticated using (exists (
    select 1 from public.life_household_members m where m.household_id = restock_history.household_id and m.user_id = (select auth.uid())
  ));

-- 不允許前端直接新增成員、改家庭、覆寫歷史或自行寫入 last_restocked_at。
revoke all on public.life_households, public.life_household_members, public.restock_items, public.restock_history from public, anon, authenticated;
grant select on public.life_households, public.life_household_members, public.restock_items, public.restock_history to authenticated;

create function public.life_create_household(p_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
  insert into public.life_households(name,created_by) values(btrim(p_name),v_uid) returning id into v_id;
  insert into public.life_household_members(household_id,user_id,role) values(v_id,v_uid,'owner');
  return v_id;
end;
$$;

create function public.restock_add_item(p_household_id uuid,p_name text,p_category text default '其他',p_low boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  -- 鎖定 membership，與同時移除家庭成員的交易依序處理。
  perform 1 from public.life_household_members where household_id=p_household_id and user_id=auth.uid() for share;
  if not found then raise exception 'NOT_MEMBER' using errcode = '42501'; end if;
  insert into public.restock_items(household_id,name,category,status)
    values(p_household_id,btrim(p_name),p_category,case when p_low then 'low' else 'normal' end) returning id into v_id;
  return v_id;
end;
$$;

create function public.restock_change_item(p_item_id uuid,p_version bigint,p_operation text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_item public.restock_items%rowtype; v_now timestamptz := clock_timestamp();
begin
  if p_operation is null or p_operation not in ('low','normal','restock') then raise exception 'INVALID_OPERATION'; end if;
  select i.* into v_item from public.restock_items i
    where i.id=p_item_id and exists (select 1 from public.life_household_members m where m.household_id=i.household_id and m.user_id=auth.uid())
    for update;
  if not found then raise exception 'NOT_MEMBER' using errcode = '42501'; end if;
  perform 1 from public.life_household_members where household_id=v_item.household_id and user_id=auth.uid() for share;
  if not found then raise exception 'NOT_MEMBER' using errcode = '42501'; end if;
  if p_version is distinct from v_item.version then raise exception 'STALE_ITEM' using errcode = '40001'; end if;
  if p_operation = 'restock' then
    insert into public.restock_history(household_id,item_id,restocked_at,created_by)
      values(v_item.household_id,v_item.id,v_now,auth.uid());
    update public.restock_items set status='normal',last_restocked_at=v_now,version=version+1 where id=v_item.id;
  else
    update public.restock_items set status=p_operation,version=version+1 where id=v_item.id;
  end if;
end;
$$;

-- 一個 SQL statement 取得一致快照；security invoker 保留呼叫者的 RLS。
create function public.restock_snapshot() returns jsonb
language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'households',coalesce((select jsonb_agg(h order by h.created_at) from public.life_households h),'[]'::jsonb),
    'items',coalesce((select jsonb_agg(i) from public.restock_items i),'[]'::jsonb),
    'history',coalesce((select jsonb_agg(r) from public.restock_history r),'[]'::jsonb)
  );
$$;

revoke all on function public.life_create_household(text), public.restock_add_item(uuid,text,text,boolean), public.restock_change_item(uuid,bigint,text), public.restock_snapshot() from public, anon, authenticated;
grant execute on function public.life_create_household(text), public.restock_add_item(uuid,text,text,boolean), public.restock_change_item(uuid,bigint,text), public.restock_snapshot() to authenticated;
notify pgrst, 'reload schema';
commit;
