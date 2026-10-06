-- 006：刪除家庭購買途徑。005 後，在 life-tools SQL Editor 以 postgres 執行整份。
-- migration 本身不刪任何資料；只有使用者確認呼叫新 RPC 才刪來源與其關聯。
-- 不改 FK、table 權限、RLS、Auth、household、其他 App。
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';

-- 若 FK 已漂移，不猜測級聯行為，整份停止。
do $$
begin
  if not exists(select 1 from pg_constraint where contype='f'
    and conrelid='public.restock_item_sources'::regclass
    and confrelid='public.restock_sources'::regclass and confdeltype='c')
    or exists(select 1 from pg_constraint where contype='f'
      and confrelid='public.restock_sources'::regclass
      and conrelid<>'public.restock_item_sources'::regclass) then
    raise exception 'UNEXPECTED_SOURCE_FOREIGN_KEYS';
  end if;
end;
$$;

-- 統一鎖順序：chosen sources（按 ID）→ item。
-- 先锁來源 key share，再由原 RPC 鎖品項，避免刪來源時 FK key share 反向等待。
create or replace function public.restock_add_item_with_sources(p_household_id uuid,p_name text,p_category text,p_low boolean,p_source_ids uuid[]) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
  perform 1 from public.life_household_members where household_id=p_household_id and user_id=auth.uid() for share;
  if not found then raise exception 'NOT_MEMBER' using errcode='42501'; end if;
  if p_source_ids is null or array_position(p_source_ids,null) is not null then raise exception 'INVALID_SOURCES' using errcode='22023'; end if;
  perform s.id from public.restock_sources s where s.household_id=p_household_id and s.id=any(p_source_ids) order by s.id for key share;
  if exists(select 1 from unnest(p_source_ids) chosen(id) where not exists(
    select 1 from public.restock_sources s where s.id=chosen.id and s.household_id=p_household_id
  )) then raise exception 'INVALID_SOURCES' using errcode='22023'; end if;
  v_id:=public.restock_add_item(p_household_id,p_name,p_category,p_low);
  insert into public.restock_item_sources(household_id,item_id,source_id)
    select p_household_id,v_id,id from (select distinct unnest(p_source_ids) as id) chosen;
  return v_id;
end;
$$;

create or replace function public.restock_update_item_with_sources(p_item_id uuid,p_version bigint,p_name text,p_category text,p_source_ids uuid[]) returns void
language plpgsql security definer set search_path='' as $$
declare v_household uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
  select i.household_id into v_household from public.restock_items i where i.id=p_item_id and exists(
    select 1 from public.life_household_members m where m.household_id=i.household_id and m.user_id=auth.uid()
  );
  if not found then raise exception 'NOT_MEMBER' using errcode='42501'; end if;
  if p_source_ids is null or array_position(p_source_ids,null) is not null then raise exception 'INVALID_SOURCES' using errcode='22023'; end if;
  perform s.id from public.restock_sources s where s.household_id=v_household and s.id=any(p_source_ids) order by s.id for key share;
  if exists(select 1 from unnest(p_source_ids) chosen(id) where not exists(
    select 1 from public.restock_sources s where s.id=chosen.id and s.household_id=v_household
  )) then raise exception 'INVALID_SOURCES' using errcode='22023'; end if;
  perform public.restock_update_item(p_item_id,p_version,p_name,p_category);
  delete from public.restock_item_sources where item_id=p_item_id and household_id=v_household;
  insert into public.restock_item_sources(household_id,item_id,source_id)
    select v_household,p_item_id,id from (select distinct unnest(p_source_ids) as id) chosen;
end;
$$;

create function public.restock_delete_source(p_household_id uuid,p_source_id uuid,p_version bigint,p_expected_item_ids uuid[]) returns void
language plpgsql security definer set search_path='' as $$
declare v_source public.restock_sources%rowtype; v_active uuid[]; v_all uuid[]; v_expected uuid[];
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
  perform 1 from public.life_household_members where household_id=p_household_id and user_id=auth.uid() for share;
  if not found then raise exception 'NOT_MEMBER' using errcode='42501'; end if;
  select * into v_source from public.restock_sources where id=p_source_id and household_id=p_household_id for update;
  if not found then raise exception 'NOT_MEMBER' using errcode='42501'; end if;
  if p_version is distinct from v_source.version then raise exception 'STALE_SOURCE' using errcode='40001'; end if;
  if p_expected_item_ids is null or array_position(p_expected_item_ids,null) is not null then raise exception 'INVALID_SOURCES' using errcode='22023'; end if;
  -- 鎖定所有仍關聯品項（含封存）；阻止品項關聯覆寫，並保護 version。
  perform i.id from public.restock_items i join public.restock_item_sources l
    on l.item_id=i.id and l.household_id=i.household_id
    where l.household_id=p_household_id and l.source_id=p_source_id order by i.id for update of i;
  select coalesce(array_agg(i.id order by i.id),'{}'::uuid[]) into v_active
    from public.restock_items i join public.restock_item_sources l on l.item_id=i.id and l.household_id=i.household_id
    where l.household_id=p_household_id and l.source_id=p_source_id and i.archived_at is null;
  select coalesce(array_agg(l.item_id order by l.item_id),'{}'::uuid[]) into v_all
    from public.restock_item_sources l where l.household_id=p_household_id and l.source_id=p_source_id;
  select coalesce(array_agg(id order by id),'{}'::uuid[]) into v_expected from (select distinct unnest(p_expected_item_ids) as id) chosen;
  if v_active is distinct from v_expected then raise exception 'SOURCE_USAGE_CHANGED' using errcode='40001'; end if;
  -- 只刪來源；經已驗證 FK 清除它的關聯，不刪用品或歷史。
  delete from public.restock_sources where id=p_source_id and household_id=p_household_id;
  update public.restock_items set version=version+1 where household_id=p_household_id and id=any(v_all);
end;
$$;

revoke all on function public.restock_delete_source(uuid,uuid,bigint,uuid[]) from public,anon,authenticated;
grant execute on function public.restock_delete_source(uuid,uuid,bigint,uuid[]) to authenticated;
-- 原兩個 function 的 CREATE OR REPLACE 保留 grants，再明確維持匿名不可執行。
revoke all on function public.restock_add_item_with_sources(uuid,text,text,boolean,uuid[]),public.restock_update_item_with_sources(uuid,bigint,text,text,uuid[]) from public,anon;
grant execute on function public.restock_add_item_with_sources(uuid,text,text,boolean,uuid[]),public.restock_update_item_with_sources(uuid,bigint,text,text,uuid[]) to authenticated;
notify pgrst,'reload schema';
commit;
