-- 在既有 001 + 002 之後執行一次。不清空／改寫任何既有品項或歷史。
-- 若表已存在會失敗並回滾；勿只選取部分 SQL 執行。
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

create table public.restock_sources (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.life_households(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  version bigint not null default 1,
  created_at timestamptz not null default now(),
  unique(id, household_id)
);
create unique index restock_sources_household_name_idx on public.restock_sources(household_id, lower(btrim(name)));
create table public.restock_item_sources (
  household_id uuid not null,
  item_id uuid not null,
  source_id uuid not null,
  primary key(item_id, source_id),
  foreign key(item_id, household_id) references public.restock_items(id, household_id) on delete cascade,
  foreign key(source_id, household_id) references public.restock_sources(id, household_id) on delete cascade
);
create index restock_item_sources_household_idx on public.restock_item_sources(household_id);
create index restock_item_sources_source_idx on public.restock_item_sources(source_id, household_id);
alter table public.restock_sources enable row level security;
alter table public.restock_item_sources enable row level security;
create policy restock_sources_read_member on public.restock_sources for select to authenticated using (exists (
  select 1 from public.life_household_members m where m.household_id=restock_sources.household_id and m.user_id=(select auth.uid())
));
create policy restock_item_sources_read_member on public.restock_item_sources for select to authenticated using (exists (
  select 1 from public.life_household_members m where m.household_id=restock_item_sources.household_id and m.user_id=(select auth.uid())
));
revoke all on public.restock_sources, public.restock_item_sources from public, anon, authenticated;
grant select on public.restock_sources, public.restock_item_sources to authenticated;

-- NULL source_id 建立途徑；指定 source_id 改名，必須提供目前 version。
create function public.restock_save_source(p_household_id uuid, p_source_id uuid, p_version bigint, p_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_source public.restock_sources%rowtype; v_id uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
  perform 1 from public.life_household_members where household_id=p_household_id and user_id=auth.uid() for share;
  if not found then raise exception 'NOT_MEMBER' using errcode='42501'; end if;
  if p_name is null or char_length(btrim(p_name)) not between 1 and 80 then raise exception 'INVALID_NAME' using errcode='22023'; end if;
  if p_source_id is null then
    insert into public.restock_sources(household_id,name) values(p_household_id,btrim(p_name)) returning id into v_id;
  else
    select * into v_source from public.restock_sources where id=p_source_id and household_id=p_household_id for update;
    if not found then raise exception 'NOT_MEMBER' using errcode='42501'; end if;
    if p_version is distinct from v_source.version then raise exception 'STALE_SOURCE' using errcode='40001'; end if;
    update public.restock_sources set name=btrim(p_name),version=version+1 where id=v_source.id;
    v_id := v_source.id;
  end if;
  return v_id;
exception when unique_violation then raise exception 'DUPLICATE_SOURCE' using errcode='23505';
end;
$$;

-- 採新 RPC 名稱，避免 PostgREST overload 歧義。舊版 RPC 與前端繼續可用。
-- 品項及途徑在同一交易儲存；無效來源會令整筆新增回滾。
create function public.restock_add_item_with_sources(p_household_id uuid,p_name text,p_category text,p_low boolean,p_source_ids uuid[]) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
  v_id := public.restock_add_item(p_household_id,p_name,p_category,p_low);
  if p_source_ids is null or exists (
    select 1 from unnest(p_source_ids) chosen(id) where not exists (
      select 1 from public.restock_sources s where s.id=chosen.id and s.household_id=p_household_id
    )
  ) then raise exception 'INVALID_SOURCES' using errcode='22023'; end if;
  insert into public.restock_item_sources(household_id,item_id,source_id)
    select p_household_id,v_id,id from (select distinct unnest(p_source_ids) as id) chosen;
  return v_id;
end;
$$;

-- 沿用原 item 鎖、member 鎖、封存檢查和 version；只增加一次 version。
-- 名稱／分類／多選途徑要麼一起成功，要麼一起回滾，歷史不動。
create function public.restock_update_item_with_sources(p_item_id uuid,p_version bigint,p_name text,p_category text,p_source_ids uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
declare v_household uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
  perform public.restock_update_item(p_item_id,p_version,p_name,p_category);
  select household_id into v_household from public.restock_items where id=p_item_id;
  if p_source_ids is null or exists (
    select 1 from unnest(p_source_ids) chosen(id) where not exists (
      select 1 from public.restock_sources s where s.id=chosen.id and s.household_id=v_household
    )
  ) then raise exception 'INVALID_SOURCES' using errcode='22023'; end if;
  delete from public.restock_item_sources where item_id=p_item_id and household_id=v_household;
  insert into public.restock_item_sources(household_id,item_id,source_id)
    select v_household,p_item_id,id from (select distinct unnest(p_source_ids) as id) chosen;
end;
$$;

create or replace function public.restock_snapshot() returns jsonb
language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'schema_version',3,
    'households',coalesce((select jsonb_agg(h order by h.created_at,h.id) from public.life_households h),'[]'::jsonb),
    'items',coalesce((select jsonb_agg(i order by i.id) from public.restock_items i where i.archived_at is null),'[]'::jsonb),
    'history',coalesce((select jsonb_agg(r order by r.restocked_at,r.id) from public.restock_history r
      where exists(select 1 from public.restock_items i where i.id=r.item_id and i.household_id=r.household_id and i.archived_at is null)),'[]'::jsonb),
    'sources',coalesce((select jsonb_agg(s order by s.name,s.id) from public.restock_sources s),'[]'::jsonb),
    'item_sources',coalesce((select jsonb_agg(l order by l.item_id,l.source_id) from public.restock_item_sources l
      where exists(select 1 from public.restock_items i where i.id=l.item_id and i.household_id=l.household_id and i.archived_at is null)),'[]'::jsonb)
  );
$$;
revoke all on function public.restock_save_source(uuid,uuid,bigint,text),public.restock_add_item_with_sources(uuid,text,text,boolean,uuid[]),public.restock_update_item_with_sources(uuid,bigint,text,text,uuid[]),public.restock_snapshot() from public,anon,authenticated;
grant execute on function public.restock_save_source(uuid,uuid,bigint,text),public.restock_add_item_with_sources(uuid,text,text,boolean,uuid[]),public.restock_update_item_with_sources(uuid,bigint,text,text,uuid[]),public.restock_snapshot() to authenticated;
notify pgrst, 'reload schema';
commit;
