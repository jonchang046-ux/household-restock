-- 家裡補一下：待購數量、7 天再評估、輕量動態。
-- 先完成 001/002/003。在 SQL Editor 以 postgres 一次執行整份。
-- 無 DROP/TRUNCATE，不改 Auth、life_ 共用結構或其他 App；既有歷史不回填數量。
-- CLI 未安裝，採現有 SQL Editor migration 流程，無需安裝套件。
-- 非重複 migration：若已執行，會失敗並回滾，勿選取片段重跑。
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
alter table public.restock_items
  add column purchase_quantity integer not null default 1 check(purchase_quantity between 1 and 999),
  add column snoozed_until timestamptz;
alter table public.restock_history add column purchased_quantity integer check(purchased_quantity between 1 and 999);
comment on column public.restock_items.purchase_quantity is '本次待購數量，不是剩餘庫存；補貨或取消待購後重設為 1。';
comment on column public.restock_items.snoozed_until is '還很多：延後預測提醒，與補貨歷史無關。';
comment on column public.restock_history.purchased_quantity is '本次補貨數量；舊歷史 NULL 代表未記錄，不推測為 1。';
create table public.restock_activity (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.life_households(id) on delete cascade,
  item_id uuid not null,
  item_name text not null,
  actor_id uuid references auth.users(id) on delete set null,
  event text not null check(event in ('add','edit','low','restock','snooze','archive','normal')),
  quantity integer check(quantity between 1 and 999),
  created_at timestamptz not null default clock_timestamp(),
  foreign key(item_id,household_id) references public.restock_items(id,household_id) on delete cascade
);
create index restock_activity_household_recent_idx on public.restock_activity(household_id,created_at desc,id desc);
alter table public.restock_activity enable row level security;
create policy restock_activity_read_member on public.restock_activity for select to authenticated using(exists(
  select 1 from public.life_household_members m where m.household_id=restock_activity.household_id and m.user_id=(select auth.uid())
));
revoke all on public.restock_activity from public,anon,authenticated;
grant select on public.restock_activity to authenticated;

create or replace function public.restock_add_item(p_household_id uuid,p_name text,p_category text default '其他',p_low boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
  -- 鎖定 membership，與同時移除家庭成員的交易依序處理。
  perform 1 from public.life_household_members where household_id=p_household_id and user_id=auth.uid() for share;
  if not found then raise exception 'NOT_MEMBER' using errcode = '42501'; end if;
  insert into public.restock_items(household_id,name,category,status)
    values(p_household_id,btrim(p_name),p_category,case when p_low then 'low' else 'normal' end) returning id into v_id;
  insert into public.restock_activity(household_id,item_id,item_name,actor_id,event,quantity) values(p_household_id,v_id,btrim(p_name),auth.uid(),'add',case when p_low then 1 else null end);
  return v_id;
end;
$$;

create or replace function public.restock_update_item(
  p_item_id uuid, p_version bigint, p_name text, p_category text
) returns void
language plpgsql security definer set search_path = '' as $$
declare v_item public.restock_items%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
  select i.* into v_item from public.restock_items i
    where i.id = p_item_id and exists (
      select 1 from public.life_household_members m
      where m.household_id = i.household_id and m.user_id = auth.uid()
    ) for update;
  if not found then raise exception 'NOT_MEMBER' using errcode = '42501'; end if;
  perform 1 from public.life_household_members
    where household_id = v_item.household_id and user_id = auth.uid() for share;
  if not found then raise exception 'NOT_MEMBER' using errcode = '42501'; end if;
  if v_item.archived_at is not null then raise exception 'ITEM_ARCHIVED' using errcode = '40001'; end if;
  if p_version is distinct from v_item.version then raise exception 'STALE_ITEM' using errcode = '40001'; end if;
  if p_name is null or char_length(btrim(p_name)) not between 1 and 80 then
    raise exception 'INVALID_NAME' using errcode = '22023';
  end if;
  if p_category is null or p_category not in ('浴廁','清潔','廚房','食品','個人用品','其他') then
    raise exception 'INVALID_CATEGORY' using errcode = '22023';
  end if;
  update public.restock_items set name = btrim(p_name), category = p_category, version = version + 1
    where id = v_item.id;
  insert into public.restock_activity(household_id,item_id,item_name,actor_id,event,quantity) values(v_item.household_id,v_item.id,btrim(p_name),auth.uid(),'edit',null);
end;
$$;

create or replace function public.restock_delete_item(p_item_id uuid, p_version bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare v_item public.restock_items%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
  select i.* into v_item from public.restock_items i
    where i.id = p_item_id and exists (
      select 1 from public.life_household_members m
      where m.household_id = i.household_id and m.user_id = auth.uid()
    ) for update;
  if not found then raise exception 'NOT_MEMBER' using errcode = '42501'; end if;
  perform 1 from public.life_household_members
    where household_id = v_item.household_id and user_id = auth.uid() for share;
  if not found then raise exception 'NOT_MEMBER' using errcode = '42501'; end if;
  if v_item.archived_at is not null then raise exception 'ITEM_ARCHIVED' using errcode = '40001'; end if;
  if p_version is distinct from v_item.version then raise exception 'STALE_ITEM' using errcode = '40001'; end if;
  update public.restock_items set archived_at = clock_timestamp(), version = version + 1
    where id = v_item.id;
  insert into public.restock_activity(household_id,item_id,item_name,actor_id,event,quantity) values(v_item.household_id,v_item.id,v_item.name,auth.uid(),'archive',null);
end;
$$;

create or replace function public.restock_change_item(p_item_id uuid,p_version bigint,p_operation text) returns void
language plpgsql security definer set search_path='' as $$
declare v_item public.restock_items%rowtype; v_now timestamptz;
begin

  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
  select i.* into v_item from public.restock_items i where i.id=p_item_id and exists(
    select 1 from public.life_household_members m where m.household_id=i.household_id and m.user_id=auth.uid()) for update;
  if not found then raise exception 'NOT_MEMBER' using errcode='42501'; end if;
  perform 1 from public.life_household_members where household_id=v_item.household_id and user_id=auth.uid() for share;
  if not found then raise exception 'NOT_MEMBER' using errcode='42501'; end if;
  if v_item.archived_at is not null then raise exception 'ITEM_ARCHIVED' using errcode='40001'; end if;
  if p_version is distinct from v_item.version then raise exception 'STALE_ITEM' using errcode='40001'; end if;
  if p_operation is null or p_operation not in ('low','normal','restock') then raise exception 'INVALID_OPERATION' using errcode='22023'; end if;
  v_now:=clock_timestamp();
  if p_operation='restock' then
    insert into public.restock_history(household_id,item_id,restocked_at,created_by,purchased_quantity)
      values(v_item.household_id,v_item.id,v_now,auth.uid(),v_item.purchase_quantity);
    update public.restock_items set status='normal',last_restocked_at=v_now,purchase_quantity=1,snoozed_until=null,version=version+1 where id=v_item.id;
    insert into public.restock_activity(household_id,item_id,item_name,actor_id,event,quantity) values(v_item.household_id,v_item.id,v_item.name,auth.uid(),'restock',v_item.purchase_quantity);
  else
    update public.restock_items set status=p_operation,snoozed_until=null,
      purchase_quantity=case when p_operation='low' and v_item.status='low' then purchase_quantity else 1 end,
      version=version+1 where id=v_item.id;
    if p_operation is distinct from v_item.status then
      insert into public.restock_activity(household_id,item_id,item_name,actor_id,event,quantity)
        values(v_item.household_id,v_item.id,v_item.name,auth.uid(),p_operation,case when p_operation='low' then 1 else null end);
    end if;
  end if;
end;
$$;

create function public.restock_set_purchase_quantity(p_item_id uuid,p_version bigint,p_quantity integer) returns void
language plpgsql security definer set search_path='' as $$
declare v_item public.restock_items%rowtype;
begin

  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
  select i.* into v_item from public.restock_items i where i.id=p_item_id and exists(
    select 1 from public.life_household_members m where m.household_id=i.household_id and m.user_id=auth.uid()) for update;
  if not found then raise exception 'NOT_MEMBER' using errcode='42501'; end if;
  perform 1 from public.life_household_members where household_id=v_item.household_id and user_id=auth.uid() for share;
  if not found then raise exception 'NOT_MEMBER' using errcode='42501'; end if;
  if v_item.archived_at is not null then raise exception 'ITEM_ARCHIVED' using errcode='40001'; end if;
  if p_version is distinct from v_item.version then raise exception 'STALE_ITEM' using errcode='40001'; end if;
  if p_quantity is null or p_quantity not between 1 and 999 then raise exception 'INVALID_QUANTITY' using errcode='22023'; end if;
  if v_item.status<>'low' then raise exception 'NOT_SHOPPING' using errcode='22023'; end if;
  if p_quantity=v_item.purchase_quantity then return; end if;
  update public.restock_items set purchase_quantity=p_quantity,version=version+1 where id=v_item.id;
end;
$$;

create function public.restock_snooze_item(p_item_id uuid,p_version bigint) returns void
language plpgsql security definer set search_path='' as $$
declare v_item public.restock_items%rowtype;
begin

  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
  select i.* into v_item from public.restock_items i where i.id=p_item_id and exists(
    select 1 from public.life_household_members m where m.household_id=i.household_id and m.user_id=auth.uid()) for update;
  if not found then raise exception 'NOT_MEMBER' using errcode='42501'; end if;
  perform 1 from public.life_household_members where household_id=v_item.household_id and user_id=auth.uid() for share;
  if not found then raise exception 'NOT_MEMBER' using errcode='42501'; end if;
  if v_item.archived_at is not null then raise exception 'ITEM_ARCHIVED' using errcode='40001'; end if;
  if p_version is distinct from v_item.version then raise exception 'STALE_ITEM' using errcode='40001'; end if;
  if v_item.status<>'normal' then raise exception 'NOT_NORMAL' using errcode='22023'; end if;
  update public.restock_items set snoozed_until=clock_timestamp()+interval '7 days',version=version+1 where id=v_item.id;
  insert into public.restock_activity(household_id,item_id,item_name,actor_id,event,quantity) values(v_item.household_id,v_item.id,v_item.name,auth.uid(),'snooze',null);
end;
$$;

create or replace function public.restock_snapshot() returns jsonb
language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'schema_version',4,
    'activity',coalesce((select jsonb_agg(a order by a.created_at desc,a.id desc) from public.life_households h
      cross join lateral (select r.* from public.restock_activity r where r.household_id=h.id order by r.created_at desc,r.id desc limit 20) a),'[]'::jsonb),
    'households',coalesce((select jsonb_agg(h order by h.created_at,h.id) from public.life_households h),'[]'::jsonb),
    'items',coalesce((select jsonb_agg(i order by i.id) from public.restock_items i where i.archived_at is null),'[]'::jsonb),
    'history',coalesce((select jsonb_agg(r order by r.restocked_at,r.id) from public.restock_history r
      where exists(select 1 from public.restock_items i where i.id=r.item_id and i.household_id=r.household_id and i.archived_at is null)),'[]'::jsonb),
    'sources',coalesce((select jsonb_agg(s order by s.name,s.id) from public.restock_sources s),'[]'::jsonb),
    'item_sources',coalesce((select jsonb_agg(l order by l.item_id,l.source_id) from public.restock_item_sources l
      where exists(select 1 from public.restock_items i where i.id=l.item_id and i.household_id=l.household_id and i.archived_at is null)),'[]'::jsonb)
  );
$$;

revoke all on function public.restock_add_item(uuid,text,text,boolean),public.restock_update_item(uuid,bigint,text,text),public.restock_delete_item(uuid,bigint),public.restock_change_item(uuid,bigint,text),public.restock_set_purchase_quantity(uuid,bigint,integer),public.restock_snooze_item(uuid,bigint),public.restock_snapshot() from public,anon,authenticated;
grant execute on function public.restock_add_item(uuid,text,text,boolean),public.restock_update_item(uuid,bigint,text,text),public.restock_delete_item(uuid,bigint),public.restock_change_item(uuid,bigint,text),public.restock_set_purchase_quantity(uuid,bigint,integer),public.restock_snooze_item(uuid,bigint),public.restock_snapshot() to authenticated;
notify pgrst,'reload schema';
commit;
