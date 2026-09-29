-- migration 後在 SQL Editor 執行。測試資料與 Auth 使用者最後全部 ROLLBACK。
-- 若出現錯誤，請保留訊息並執行 rollback;，不要移除驗證條件。
begin;
do $$
declare
  a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); c uuid := gen_random_uuid();
  h uuid; other_h uuid; item uuid; snapshot jsonb; count_before integer;
begin
  insert into auth.users(id,email) values (a,a||'@example.invalid'),(b,b||'@example.invalid'),(c,c||'@example.invalid');
  perform set_config('request.jwt.claim.sub',a::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  set local role authenticated;
  h := public.life_create_household('SECURITY TEST HOUSE');
  item := public.restock_add_item(h,'SECURITY TEST ITEM','其他',true);
  if (select count(*) from public.restock_items where id=item) <> 1 then raise exception 'FAIL: owner cannot read'; end if;
  reset role;
  insert into public.life_household_members(household_id,user_id) values(h,b);
  perform set_config('request.jwt.claim.sub',b::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
  set local role authenticated;
  perform public.restock_change_item(item,1,'restock');
  if (select count(*) from public.restock_history where item_id=item) <> 1 then raise exception 'FAIL: history missing'; end if;
  if not exists(select 1 from public.restock_items where id=item and status='normal' and last_restocked_at is not null and version=2) then raise exception 'FAIL: restock not atomic'; end if;
  begin
    perform public.restock_change_item(item,1,'restock');
    raise exception 'FAIL: stale write accepted';
  exception when serialization_failure then null; end;
  begin
    insert into public.life_household_members(household_id,user_id) values(h,c);
    raise exception 'FAIL: membership escalation';
  exception when insufficient_privilege then null; end;
  begin
    update public.restock_items set status='low' where id=item;
    raise exception 'FAIL: direct write allowed';
  exception when insufficient_privilege then null; end;
  begin
    delete from public.restock_history where item_id=item;
    raise exception 'FAIL: history deletion allowed';
  exception when insufficient_privilege then null; end;
  reset role;
  perform set_config('request.jwt.claim.sub',c::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',c,'role','authenticated')::text,true);
  set local role authenticated;
  if exists(select 1 from public.restock_items where id=item) then raise exception 'FAIL: outsider read'; end if;
  if exists(select 1 from public.restock_history where item_id=item) then raise exception 'FAIL: outsider history read'; end if;
  if exists(select 1 from public.life_households where id=h) then raise exception 'FAIL: outsider household read'; end if;
  begin
    perform public.restock_change_item(item,2,'low');
    raise exception 'FAIL: outsider update';
  exception when insufficient_privilege then null; end;
  begin
    perform public.restock_add_item(h,'OUTSIDER','其他',false);
    raise exception 'FAIL: outsider insert';
  exception when insufficient_privilege then null; end;
  other_h := public.life_create_household('OTHER TEST HOUSE');
  snapshot := public.restock_snapshot();
  if jsonb_array_length(snapshot->'households') <> 1 or jsonb_array_length(snapshot->'items') <> 0 then raise exception 'FAIL: snapshot isolation'; end if;
  reset role;
  delete from public.life_household_members where household_id=h and user_id=b;
  perform set_config('request.jwt.claim.sub',b::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
  set local role authenticated;
  begin
    perform public.restock_change_item(item,2,'low');
    raise exception 'FAIL: removed member update';
  exception when insufficient_privilege then null; end;
  reset role;
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  set local role anon;
  begin
    perform public.restock_snapshot();
    raise exception 'FAIL: anonymous RPC';
  exception when insufficient_privilege then null; end;
  begin
    perform 1 from public.restock_items;
    raise exception 'FAIL: anonymous read';
  exception when insufficient_privilege then null; end;
  reset role;
  raise notice 'PASS: member sharing, atomic history, stale version, direct write denial, outsider isolation, removed membership, anonymous denial';
end $$;
rollback;
