-- 002 migration 成功後，於 SQL Editor 以 postgres 手動執行。
-- 使用既有兩位同家庭成員模擬 JWT；不建立／修改／刪除 Auth 使用者。
-- 僅建立一筆暫時品項與其歷史，最後 ROLLBACK。既有品項完全不動。
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
do $$
declare
  a uuid; b uuid; c uuid := gen_random_uuid(); h uuid; item uuid;
  history_before jsonb; last_before timestamptz; snap jsonb;
begin
  select ma.user_id,mb.user_id,ma.household_id into a,b,h
    from public.life_household_members ma join public.life_household_members mb
      on ma.household_id=mb.household_id and ma.user_id<mb.user_id limit 1;
  if a is null then raise exception '測試需要同家庭的兩位既有成員，未寫入任何資料。'; end if;
  perform set_config('request.jwt.claim.sub',a::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  set local role authenticated;
  item := public.restock_add_item(h,'__V2_ROLLBACK_TEST__','其他',false);
  perform public.restock_change_item(item,1,'low');
  perform public.restock_change_item(item,2,'restock');
  select jsonb_agg(r order by r.id) into history_before from public.restock_history r where item_id=item;
  select last_restocked_at into last_before from public.restock_items where id=item;
  perform public.restock_update_item(item,3,'A 修改','清潔');
  if not exists(select 1 from public.restock_items where id=item and name='A 修改' and category='清潔' and version=4) then raise exception 'FAIL A update'; end if;

  reset role;
  perform set_config('request.jwt.claim.sub',b::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
  set local role authenticated;
  snap := public.restock_snapshot();
  if not exists(select 1 from jsonb_array_elements(snap->'items') x where x->>'id'=item::text and x->>'name'='A 修改') then raise exception 'FAIL B snapshot'; end if;
  begin
    perform public.restock_update_item(item,3,'過期覆寫','其他');
    raise exception 'FAIL stale update';
  exception when serialization_failure then null; end;
  begin
    perform public.restock_delete_item(item,3);
    raise exception 'FAIL stale delete';
  exception when serialization_failure then null; end;
  begin
    perform public.restock_update_item(item,null,'空版本','其他');
    raise exception 'FAIL null version';
  exception when serialization_failure then null; end;
  begin
    perform public.restock_update_item(item,4,'   ','其他');
    raise exception 'FAIL blank name';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.restock_update_item(item,4,'名稱','不存在');
    raise exception 'FAIL category';
  exception when invalid_parameter_value then null; end;
  perform public.restock_update_item(item,4,'B 修改','廚房');
  if history_before is distinct from (select jsonb_agg(r order by r.id) from public.restock_history r where item_id=item) then raise exception 'FAIL history modified'; end if;
  if not exists(select 1 from public.restock_items where id=item and last_restocked_at=last_before and version=5) then raise exception 'FAIL original date or ID'; end if;
  begin
    update public.restock_items set name='直接改' where id=item;
    raise exception 'FAIL direct update';
  exception when insufficient_privilege then null; end;
  begin
    delete from public.restock_items where id=item;
    raise exception 'FAIL direct delete';
  exception when insufficient_privilege then null; end;

  reset role;
  perform set_config('request.jwt.claim.sub',c::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',c,'role','authenticated')::text,true);
  set local role authenticated;
  if exists(select 1 from public.restock_items where id=item) then raise exception 'FAIL outsider read'; end if;
  begin
    perform public.restock_update_item(item,5,'越權','其他');
    raise exception 'FAIL outsider update';
  exception when insufficient_privilege then null; end;
  begin
    perform public.restock_delete_item(item,5);
    raise exception 'FAIL outsider delete';
  exception when insufficient_privilege then null; end;

  reset role;
  perform set_config('request.jwt.claim.sub',a::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  set local role authenticated;
  if not exists(select 1 from public.restock_items where id=item and name='B 修改') then raise exception 'FAIL A sees B'; end if;
  perform public.restock_delete_item(item,5);
  if not exists(select 1 from public.restock_items where id=item and archived_at is not null and version=6 and last_restocked_at=last_before) then raise exception 'FAIL archive'; end if;
  if history_before is distinct from (select jsonb_agg(r order by r.id) from public.restock_history r where item_id=item) then raise exception 'FAIL archived history'; end if;
  snap := public.restock_snapshot();
  if exists(select 1 from jsonb_array_elements(snap->'items') x where x->>'id'=item::text) then raise exception 'FAIL archive in active snapshot'; end if;
  if exists(select 1 from jsonb_array_elements(snap->'history') x where x->>'item_id'=item::text) then raise exception 'FAIL archived history in active snapshot'; end if;
  begin
    perform public.restock_change_item(item,6,'restock');
    raise exception 'FAIL archived restock';
  exception when serialization_failure then null; end;
  begin
    perform public.restock_update_item(item,6,'復活','其他');
    raise exception 'FAIL archived update';
  exception when serialization_failure then null; end;
  begin
    perform public.restock_delete_item(item,6);
    raise exception 'FAIL repeated archive';
  exception when serialization_failure then null; end;

  reset role;
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  set local role anon;
  begin
    perform public.restock_update_item(item,6,'匿名','其他');
    raise exception 'FAIL anon update';
  exception when insufficient_privilege then null; end;
  begin
    perform public.restock_delete_item(item,6);
    raise exception 'FAIL anon delete';
  exception when insufficient_privilege then null; end;
  begin
    perform public.restock_snapshot();
    raise exception 'FAIL anon snapshot';
  exception when insufficient_privilege then null; end;
  reset role;
  raise notice 'PASS v2：雙向共享、版本衝突、輸入驗證、歷史保留、封存、越權與匿名拒絕。測試資料即將回滾。';
end $$;
rollback;
