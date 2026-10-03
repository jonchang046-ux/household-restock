-- life-tools：補貨助手 v2。以 postgres 在 SQL Editor 執行。
-- 不重新執行 001；不 DROP、不清空資料、不修改 Auth 或 life_ 共用表。
-- 可重複執行；既有 archived_at 值不被覆寫。整份成功才 COMMIT。
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

alter table public.restock_items add column if not exists archived_at timestamptz;
comment on column public.restock_items.archived_at is 'v2 軟刪除：保留品項及補貨歷史；NULL 表示目前用品。';

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

-- 名稱沿用「delete」，實際只有標記封存，不執行 DELETE 或 cascade。
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

-- 保留 v1 簽章與交易，另拒絕舊手機對已封存品項的補貨／標記。
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

-- 舊版前端也不會再收到已封存品項；歷史仍在表中，可與保留的 item JOIN。
-- security invoker：快照查詢繼續套用原有 RLS，不向其他家庭洩漏資料。
create or replace function public.restock_snapshot() returns jsonb
language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'schema_version',2,
    'households',coalesce((select jsonb_agg(h order by h.created_at,h.id) from public.life_households h),'[]'::jsonb),
    'items',coalesce((select jsonb_agg(i order by i.id) from public.restock_items i where i.archived_at is null),'[]'::jsonb),
    'history',coalesce((select jsonb_agg(r order by r.restocked_at,r.id) from public.restock_history r
      where exists (select 1 from public.restock_items i where i.id=r.item_id and i.household_id=r.household_id and i.archived_at is null)),'[]'::jsonb)
  );
$$;

-- 僅調整本 App 的函式權限，不增加表格 UPDATE/DELETE grant，不更動 RLS policy。
revoke all on function public.restock_update_item(uuid,bigint,text,text), public.restock_delete_item(uuid,bigint), public.restock_change_item(uuid,bigint,text), public.restock_snapshot() from public, anon, authenticated;
grant execute on function public.restock_update_item(uuid,bigint,text,text), public.restock_delete_item(uuid,bigint), public.restock_change_item(uuid,bigint,text), public.restock_snapshot() to authenticated;
notify pgrst, 'reload schema';
commit;
