-- 005 成功後才執行。測試假資料在最後完整 ROLLBACK，不保留測試事件。
begin;
set local statement_timeout='30s';
do $$
declare
  a uuid; b uuid; h uuid; it uuid; source uuid; cat text; v bigint;
  outsider uuid:=gen_random_uuid(); tag text:='__CATEGORY_TEST_'||gen_random_uuid()::text;
  before_history jsonb; before_links jsonb; before_last timestamptz; snap jsonb;
begin
  select ma.user_id,mb.user_id,ma.household_id into a,b,h
    from public.life_household_members ma join public.life_household_members mb
    on ma.household_id=mb.household_id and ma.user_id<mb.user_id limit 1;
  if a is null then raise exception '需要兩位同家庭成員'; end if;
  if exists(select 1 from public.restock_items where category='食品') then raise exception 'FAIL migration not complete'; end if;
  perform set_config('request.jwt.claim.sub',a::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  set local role authenticated;
  source:=public.restock_save_source(h,null,null,tag||'_store');
  foreach cat in array array['食品常溫','飲料','冷藏','冷凍'] loop
    it:=public.restock_add_item_with_sources(h,tag,cat,true,array[source]);
    if not exists(select 1 from public.restock_items where id=it and category=cat and status='low' and purchase_quantity=1) then raise exception 'FAIL add category'; end if;
  end loop;
  -- 最後的冷凍品項先補貨，確認後續分類修改不污染歷史、日期、來源。
  perform public.restock_change_item(it,1,'restock');
  select jsonb_agg(r order by r.id) into before_history from public.restock_history r where item_id=it;
  select jsonb_agg(r order by r.source_id) into before_links from public.restock_item_sources r where item_id=it;
  select last_restocked_at,version into before_last,v from public.restock_items where id=it;
  perform public.restock_update_item_with_sources(it,v,tag,'冷藏',array[source]);
  begin perform public.restock_update_item(it,v,tag,'飲料'); raise exception 'FAIL stale version'; exception when serialization_failure then null; end;
  reset role;
  perform set_config('request.jwt.claim.sub',b::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
  set local role authenticated;
  snap:=public.restock_snapshot();
  if not exists(select 1 from jsonb_array_elements(snap->'items') x where x->>'id'=it::text and x->>'category'='冷藏') then raise exception 'FAIL B sees A category'; end if;
  select version into v from public.restock_items where id=it;
  perform public.restock_update_item_with_sources(it,v,tag,'飲料',array[source]);
  if before_history is distinct from (select jsonb_agg(r order by r.id) from public.restock_history r where item_id=it)
    or before_links is distinct from (select jsonb_agg(r order by r.source_id) from public.restock_item_sources r where item_id=it)
    or before_last is distinct from (select last_restocked_at from public.restock_items where id=it) then raise exception 'FAIL preserved history/source/date'; end if;
  select version into v from public.restock_items where id=it;
  begin perform public.restock_update_item(it,v,tag,'乳製品'); raise exception 'FAIL invalid category'; exception when invalid_parameter_value then null; end;
  begin perform public.restock_add_item(h,tag,'乳製品',false); raise exception 'FAIL invalid add category'; exception when invalid_parameter_value then null; end;
  -- 相容舊手機：只能寫入食品常溫，不能重新產生食品。
  perform public.restock_update_item(it,v,tag,'食品');
  if not exists(select 1 from public.restock_items where id=it and category='食品常溫') then raise exception 'FAIL legacy update'; end if;
  it:=public.restock_add_item(h,tag,'食品',false);
  if not exists(select 1 from public.restock_items where id=it and category='食品常溫') then raise exception 'FAIL legacy add'; end if;
  begin update public.restock_items set category='冷凍' where id=it; raise exception 'FAIL direct update'; exception when insufficient_privilege then null; end;
  begin delete from public.restock_items where id=it; raise exception 'FAIL direct delete'; exception when insufficient_privilege then null; end;
  reset role;
  perform set_config('request.jwt.claim.sub',outsider::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',outsider,'role','authenticated')::text,true);
  set local role authenticated;
  if exists(select 1 from public.restock_items where household_id=h) then raise exception 'FAIL outsider read'; end if;
  begin perform public.restock_add_item(h,tag,'冷凍',true); raise exception 'FAIL outsider add'; exception when insufficient_privilege then null; end;
  begin perform public.restock_update_item(it,1,tag,'冷凍'); raise exception 'FAIL outsider edit'; exception when insufficient_privilege then null; end;
  begin perform public.restock_delete_item(it,1); raise exception 'FAIL outsider delete'; exception when insufficient_privilege then null; end;
  reset role;
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  set local role anon;
  begin perform public.restock_snapshot(); raise exception 'FAIL anon snapshot'; exception when insufficient_privilege then null; end;
  begin perform public.restock_add_item(h,tag,'冷凍',false); raise exception 'FAIL anon add'; exception when insufficient_privilege then null; end;
  reset role;
  raise notice 'PASS categories, A/B snapshot, sources/history, stale version, isolation';
end;
$$;
rollback;
