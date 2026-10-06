-- 006 成功後才執行。所有測試資料／刪除／版本變更最後 ROLLBACK。
begin;
set local statement_timeout='30s';
do $$
declare a uuid; b uuid; h uuid; h2 uuid; s uuid; s2 uuid; empty_source uuid; it uuid; archived uuid;
  foreign_source uuid; outsider uuid:=gen_random_uuid(); tag text:='__SOURCE_DELETE_TEST_'||gen_random_uuid()::text;
  before_item jsonb; before_archive jsonb; before_history jsonb; snap jsonb; v bigint;
begin
  select ma.user_id,mb.user_id,ma.household_id into a,b,h from public.life_household_members ma
    join public.life_household_members mb on ma.household_id=mb.household_id and ma.user_id<mb.user_id limit 1;
  if a is null then raise exception '需要兩位同家庭成員'; end if;
  perform set_config('request.jwt.claim.sub',a::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  set local role authenticated;
  empty_source:=public.restock_save_source(h,null,null,tag||'_empty');
  begin perform public.restock_delete_source(h,empty_source,1,null); raise exception 'FAIL missing confirmation'; exception when invalid_parameter_value then null; end;
  perform public.restock_delete_source(h,empty_source,1,'{}'::uuid[]);
  if exists(select 1 from public.restock_sources where id=empty_source) then raise exception 'FAIL empty delete'; end if;
  s:=public.restock_save_source(h,null,null,tag||'_used');
  s2:=public.restock_save_source(h,null,null,tag||'_keep');
  it:=public.restock_add_item_with_sources(h,tag,'冷凍',true,array[s,s2]);
  archived:=public.restock_add_item_with_sources(h,tag||'_archived','食品常溫',false,array[s]);
  perform public.restock_change_item(it,1,'restock');
  perform public.restock_delete_item(archived,1);
  -- 來源改名、使用品項集合及 null version 都需拒絕；拒絕後保留來源。
  begin perform public.restock_delete_source(h,s,null,array[it]); raise exception 'FAIL null version'; exception when serialization_failure then null; end;
  begin perform public.restock_delete_source(h,s,0,array[it]); raise exception 'FAIL stale source'; exception when serialization_failure then null; end;
  begin perform public.restock_delete_source(h,s,1,'{}'::uuid[]); raise exception 'FAIL changed count'; exception when serialization_failure then null; end;
  begin perform public.restock_delete_source(h,s,1,array[archived]); raise exception 'FAIL same count different items'; exception when serialization_failure then null; end;
  reset role;
  select to_jsonb(i),i.version into before_item,v from public.restock_items i where id=it;
  select to_jsonb(i) into before_archive from public.restock_items i where id=archived;
  select jsonb_agg(r order by r.id) into before_history from public.restock_history r where item_id=it;
  set local role authenticated;
  perform public.restock_delete_source(h,s,1,array[it]);
  if exists(select 1 from public.restock_item_sources where source_id=s) or exists(select 1 from public.restock_sources where id=s) then raise exception 'FAIL cascade'; end if;
  if not exists(select 1 from public.restock_item_sources where item_id=it and source_id=s2) then raise exception 'FAIL other source association'; end if;
  begin perform public.restock_update_item_with_sources(it,v,tag,'冷凍',array[s2]); raise exception 'FAIL stale item after unlink'; exception when serialization_failure then null; end;
  reset role;
  if (before_item-'version') is distinct from (select to_jsonb(i)-'version' from public.restock_items i where id=it)
    or (before_archive-'version') is distinct from (select to_jsonb(i)-'version' from public.restock_items i where id=archived)
    or not exists(select 1 from public.restock_items where id=it and version=v+1)
    or not exists(select 1 from public.restock_items where id=archived and version=(before_archive->>'version')::bigint+1)
    or before_history is distinct from (select jsonb_agg(r order by r.id) from public.restock_history r where item_id=it) then raise exception 'FAIL item/history preserved'; end if;
  perform set_config('request.jwt.claim.sub',b::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
  set local role authenticated;
  snap:=public.restock_snapshot();
  if exists(select 1 from jsonb_array_elements(snap->'sources') x where x->>'id'=s::text)
    or exists(select 1 from jsonb_array_elements(snap->'item_sources') x where x->>'source_id'=s::text)
    or not exists(select 1 from jsonb_array_elements(snap->'items') x where x->>'id'=it::text) then raise exception 'FAIL B snapshot'; end if;
  -- B 的另一個家庭，A 未加入。
  h2:=public.life_create_household(tag||'_other_household');
  foreign_source:=public.restock_save_source(h2,null,null,tag||'_other_source');
  reset role;
  perform set_config('request.jwt.claim.sub',a::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  set local role authenticated;
  begin perform public.restock_delete_source(h,foreign_source,1,'{}'::uuid[]); raise exception 'FAIL foreign source id'; exception when insufficient_privilege then null; end;
  begin perform public.restock_delete_source(h2,foreign_source,1,'{}'::uuid[]); raise exception 'FAIL foreign household'; exception when insufficient_privilege then null; end;
  begin delete from public.restock_sources where id=s2; raise exception 'FAIL direct source delete'; exception when insufficient_privilege then null; end;
  begin delete from public.restock_item_sources where source_id=s2; raise exception 'FAIL direct association delete'; exception when insufficient_privilege then null; end;
  reset role;
  perform set_config('request.jwt.claim.sub',outsider::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',outsider,'role','authenticated')::text,true);
  set local role authenticated;
  begin perform public.restock_delete_source(h,s2,1,array[it]); raise exception 'FAIL outsider'; exception when insufficient_privilege then null; end;
  reset role;
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  set local role anon;
  begin perform public.restock_delete_source(h,s2,1,array[it]); raise exception 'FAIL anon'; exception when insufficient_privilege then null; end;
  reset role;
  if not exists(select 1 from public.restock_sources where id=foreign_source and household_id=h2)
    or not exists(select 1 from public.restock_sources where id=s2 and household_id=h) then raise exception 'FAIL unrelated sources preserved'; end if;
  raise notice 'PASS empty/used source delete, preserved items/history, B snapshot, version, household isolation';
end;
$$;
rollback;
