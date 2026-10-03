-- 003 成功後再執行。使用現有同家庭 A/B；暫時建立來源、品項與另一測試家庭，最後全部 ROLLBACK。
-- 不修改既有品項／歷史，不建立或修改 Auth 使用者。
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
do $$
declare
  a uuid; b uuid; h uuid; other_home uuid; outsider uuid:=gen_random_uuid();
  s1 uuid; s2 uuid; other_source uuid; it uuid; snap jsonb; v bigint; history_before jsonb;
  tag text:='__SOURCES_TEST_'||gen_random_uuid()::text;
begin
  select ma.user_id,mb.user_id,ma.household_id into a,b,h
    from public.life_household_members ma join public.life_household_members mb on ma.household_id=mb.household_id and ma.user_id<mb.user_id limit 1;
  if a is null then raise exception '需要兩位同家庭成員；未寫入資料'; end if;
  perform set_config('request.jwt.claim.sub',a::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  set local role authenticated;
  s1:=public.restock_save_source(h,null,null,tag||'_A');
  s2:=public.restock_save_source(h,null,null,tag||'_B');
  begin
    perform public.restock_save_source(h,null,null,tag||'_A');raise exception 'FAIL duplicate';
  exception when unique_violation then null; end;
  begin
    perform public.restock_save_source(h,null,null,'   ');raise exception 'FAIL blank name';
  exception when invalid_parameter_value then null; end;
  it:=public.restock_add_item_with_sources(h,tag,'浴廁',true,array[s1,s2,s1]);
  if (select count(*) from public.restock_item_sources where item_id=it)<>2 then raise exception 'FAIL multi/dedup'; end if;
  perform public.restock_change_item(it,1,'restock');
  select jsonb_agg(r order by r.id) into history_before from public.restock_history r where item_id=it;
  other_home:=public.life_create_household(tag||'_other');
  other_source:=public.restock_save_source(other_home,null,null,tag||'_other_source');
  begin
    perform public.restock_update_item_with_sources(it,2,'不應儲存','清潔',array[other_source]);raise exception 'FAIL cross household';
  exception when invalid_parameter_value then null; end;
  if not exists(select 1 from public.restock_items where id=it and name=tag and version=2) then raise exception 'FAIL rollback item'; end if;
  if (select count(*) from public.restock_item_sources where item_id=it)<>2 then raise exception 'FAIL rollback links'; end if;
  begin
    perform public.restock_add_item_with_sources(h,tag||'_invalid','其他',false,array[other_source]);raise exception 'FAIL invalid add';
  exception when invalid_parameter_value then null; end;
  if exists(select 1 from public.restock_items where name=tag||'_invalid') then raise exception 'FAIL partial add'; end if;
  begin
    perform public.restock_update_item_with_sources(it,2,tag,'浴廁',array[null]::uuid[]);raise exception 'FAIL null source';
  exception when invalid_parameter_value then null; end;
  begin
    insert into public.restock_item_sources values(h,it,other_source);raise exception 'FAIL direct write';
  exception when insufficient_privilege then null; end;
  begin
    update public.restock_sources set name='直接改' where id=s1;raise exception 'FAIL direct source update';
  exception when insufficient_privilege then null; end;
  -- 即使繞過 RLS 的管理員也不能插入跨家庭關聯：複合外鍵要拒絕。
  reset role;
  begin
    insert into public.restock_item_sources values(h,it,other_source);raise exception 'FAIL composite FK';
  exception when foreign_key_violation then null; end;
  perform set_config('request.jwt.claim.sub',b::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
  set local role authenticated;
  snap:=public.restock_snapshot();
  if not exists(select 1 from jsonb_array_elements(snap->'sources') x where x->>'id'=s1::text) then raise exception 'FAIL B source read'; end if;
  if (select count(*) from jsonb_array_elements(snap->'item_sources') x where x->>'item_id'=it::text)<>2 then raise exception 'FAIL B links'; end if;
  if exists(select 1 from public.restock_sources where id=other_source) then raise exception 'FAIL B other source read'; end if;
  perform public.restock_save_source(h,s1,1,tag||'_renamed');
  begin
    perform public.restock_save_source(h,s1,1,tag||'_stale');raise exception 'FAIL stale source';
  exception when serialization_failure then null; end;
  perform public.restock_update_item_with_sources(it,2,tag||'_edited','浴廁',array[s1]);
  begin
    perform public.restock_update_item_with_sources(it,2,tag,'其他',array[s2]);raise exception 'FAIL stale item';
  exception when serialization_failure then null; end;
  -- 舊手機改名不應抹掉新途徑。
  perform public.restock_update_item(it,3,tag||'_old_client','浴廁');
  if (select count(*) from public.restock_item_sources where item_id=it and source_id=s1)<>1 then raise exception 'FAIL old client'; end if;
  if history_before is distinct from (select jsonb_agg(r order by r.id) from public.restock_history r where item_id=it) then raise exception 'FAIL history'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub',outsider::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',outsider,'role','authenticated')::text,true);
  set local role authenticated;
  if exists(select 1 from public.restock_sources where id=s1) or exists(select 1 from public.restock_item_sources where item_id=it) then raise exception 'FAIL outsider read'; end if;
  begin
    perform public.restock_save_source(h,null,null,tag);raise exception 'FAIL outsider create';
  exception when insufficient_privilege then null; end;
  begin
    perform public.restock_save_source(h,s1,2,tag);raise exception 'FAIL outsider rename';
  exception when insufficient_privilege then null; end;
  begin
    perform public.restock_update_item_with_sources(it,4,tag,'浴廁',array[s1]);raise exception 'FAIL outsider item';
  exception when insufficient_privilege then null; end;
  reset role;
  perform set_config('request.jwt.claim.sub',a::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  set local role authenticated;
  if not exists(select 1 from public.restock_sources where id=s1 and name=tag||'_renamed') then raise exception 'FAIL A sees B'; end if;
  perform public.restock_update_item_with_sources(it,4,tag,'浴廁','{}'::uuid[]);
  if exists(select 1 from public.restock_item_sources where item_id=it) then raise exception 'FAIL clear sources'; end if;
  perform public.restock_update_item_with_sources(it,5,tag,'浴廁',array[s1]);
  perform public.restock_delete_item(it,6);
  if not exists(select 1 from public.restock_item_sources where item_id=it) then raise exception 'FAIL archive links'; end if;
  snap:=public.restock_snapshot();
  if exists(select 1 from jsonb_array_elements(snap->'item_sources') x where x->>'item_id'=it::text) then raise exception 'FAIL archived snapshot'; end if;
  reset role;
  perform set_config('request.jwt.claim.sub','',true);perform set_config('request.jwt.claims','{}',true);
  set local role anon;
  begin
    perform 1 from public.restock_sources;raise exception 'FAIL anon read';
  exception when insufficient_privilege then null; end;
  begin
    perform public.restock_save_source(h,null,null,tag);raise exception 'FAIL anon save';
  exception when insufficient_privilege then null; end;
  begin
    perform public.restock_add_item_with_sources(h,tag,'其他',false,'{}'::uuid[]);raise exception 'FAIL anon add';
  exception when insufficient_privilege then null; end;
  begin
    perform public.restock_update_item_with_sources(it,7,tag,'其他','{}'::uuid[]);raise exception 'FAIL anon update';
  exception when insufficient_privilege then null; end;
  reset role;
end $$;
rollback;
select 'PASS: 購買途徑回歸測試通過，所有測試資料已回滾' as result;
