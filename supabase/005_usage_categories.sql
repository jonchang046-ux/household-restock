-- 005：使用分類更新。先完成 004；在 life-tools SQL Editor 以 postgres 執行整份。
-- 無刪表、刪品項、刪歷史；僅更新 restock_items 的分類／version 與兩個既有 RPC。
-- 保留 RPC signatures、會員驗證、鎖定、version、活動紀錄、既有 grants/RLS。
-- 同一交易；出錯不會部分完成。可重跑，已轉換品項不會再次加 version。
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
lock table public.restock_items in access exclusive mode;

-- 交易內驗收快照，COMMIT 後自動移除，不建立永久備份表。
create temporary table restock_category_before on commit drop as
  select id, to_jsonb(i) as row_data from public.restock_items i;

-- 先移除舊分類 CHECK，轉換，再加回嚴格九分類限制。
-- 交易與 table lock 保護中間狀態，其他連線不會看到無限制的狀態。
alter table public.restock_items drop constraint restock_items_category_check;
update public.restock_items set category = '食品常溫', version = version + 1
  where category = '食品';
alter table public.restock_items add constraint restock_items_category_check
  check (category in ('浴廁','清潔','廚房','食品常溫','飲料','冷藏','冷凍','個人用品','其他'));

create or replace function public.restock_add_item(p_household_id uuid,p_name text,p_category text default '其他',p_low boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode='42501'; end if;
  -- 鎖定 membership，與同時移除家庭成員的交易依序處理。
  perform 1 from public.life_household_members where household_id=p_household_id and user_id=auth.uid() for share;
  if not found then raise exception 'NOT_MEMBER' using errcode = '42501'; end if;
  p_category := case when p_category = '食品' then '食品常溫' else p_category end;
  if p_category is null or p_category not in ('浴廁','清潔','廚房','食品常溫','飲料','冷藏','冷凍','個人用品','其他') then
    raise exception 'INVALID_CATEGORY' using errcode = '22023';
  end if;
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
  p_category := case when p_category = '食品' then '食品常溫' else p_category end;
  if p_category is null or p_category not in ('浴廁','清潔','廚房','食品常溫','飲料','冷藏','冷凍','個人用品','其他') then
    raise exception 'INVALID_CATEGORY' using errcode = '22023';
  end if;
  update public.restock_items set name = btrim(p_name), category = p_category, version = version + 1
    where id = v_item.id;
  insert into public.restock_activity(household_id,item_id,item_name,actor_id,event,quantity) values(v_item.household_id,v_item.id,btrim(p_name),auth.uid(),'edit',null);
end;
$$;


-- CREATE OR REPLACE 保留既有權限，再次明確確保 anon / PUBLIC 不可執行。
revoke all on function public.restock_add_item(uuid,text,text,boolean) from public,anon;
revoke all on function public.restock_update_item(uuid,bigint,text,text) from public,anon;
grant execute on function public.restock_add_item(uuid,text,text,boolean) to authenticated;
grant execute on function public.restock_update_item(uuid,bigint,text,text) to authenticated;

do $$
begin
  if exists (
    select 1 from restock_category_before b full join public.restock_items i on i.id=b.id
    where b.id is null or i.id is null
      or (to_jsonb(i) - 'category' - 'version') is distinct from (b.row_data - 'category' - 'version')
      or i.category is distinct from case when b.row_data->>'category'='食品' then '食品常溫' else b.row_data->>'category' end
      or i.version is distinct from (b.row_data->>'version')::bigint + case when b.row_data->>'category'='食品' then 1 else 0 end
  ) then raise exception 'CATEGORY_MIGRATION_PRESERVATION_FAILED'; end if;
end;
$$;

select count(*) filter(where row_data->>'category'='食品') as converted_items,
       count(*) as preserved_items from restock_category_before;
commit;
