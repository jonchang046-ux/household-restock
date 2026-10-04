-- 僅在 004 已成功、且網站已切回 91defb9 或更早版本後執行。
-- 功能回退：保留新欄位、數量、snooze、歷史及動態表，不 DROP、不清空。
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
create or replace function public.restock_add_item(p_household_id uuid,p_name text,p_category text default '其他',p_low boolean default false) returns uuid
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
end;
$$;

create or replace function public.restock_change_item(p_item_id uuid,p_version bigint,p_operation text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_item public.restock_items%rowtype; v_now timestamptz := clock_timestamp();
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
  if p_operation is null or p_operation not in ('low','normal','restock') then raise exception 'INVALID_OPERATION'; end if;
  select i.* into v_item from public.restock_items i
    where i.id=p_item_id and exists (select 1 from public.life_household_members m where m.household_id=i.household_id and m.user_id=auth.uid())
    for update;
  if not found then raise exception 'NOT_MEMBER' using errcode = '42501'; end if;
  perform 1 from public.life_household_members where household_id=v_item.household_id and user_id=auth.uid() for share;
  if not found then raise exception 'NOT_MEMBER' using errcode = '42501'; end if;
  if v_item.archived_at is not null then raise exception 'ITEM_ARCHIVED' using errcode = '40001'; end if;
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
revoke all on function public.restock_set_purchase_quantity(uuid,bigint,integer),public.restock_snooze_item(uuid,bigint) from public,anon,authenticated;
revoke all on public.restock_activity from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
