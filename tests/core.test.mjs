import test from 'node:test';
import assert from 'node:assert/strict';
import { estimate } from '../cycle.mjs';
import { Backend } from '../api.mjs';
const item = {id:'a', status:'normal'};
const row = date => ({item_id:'a', restocked_at:date});
test('沒有或僅一日歷史時不猜測補貨週期', () => {
  assert.equal(estimate(item, []).average, null);
  assert.equal(estimate(item, [row('2026-01-01')]).status, 'normal');
});
test('80% 邊界提醒且確定待購優先，不改原始狀態', () => {
  const history=[row('2026-01-01T00:00:00Z'),row('2026-01-11T00:00:00Z')];
  assert.equal(estimate(item,history,Date.parse('2026-01-18T23:59:59Z')).status,'normal');
  assert.equal(estimate(item,history,Date.parse('2026-01-19T00:00:00Z')).status,'possible');
  assert.equal(estimate({...item,status:'low'},history,Date.parse('2026-01-19')).status,'low');
  assert.equal(item.status,'normal');
});
test('同日補貨合併計算、歷史不變、排除其他品項', () => {
  const history=[row('2026-01-01T01:00:00Z'),row('2026-01-01T12:00:00Z'),row('2026-01-11T00:00:00Z'),{item_id:'b',restocked_at:'2026-03-01'}];
  assert.equal(estimate(item,history).average,10); assert.equal(history.length,4);
});
test('不規則與未排序日期取各間隔平均', () => {
  const s=estimate(item,[row('2026-01-31'),row('2026-01-01'),row('2026-01-11'),row('invalid')]);
  assert.equal(s.average,15); assert.equal(s.samples,2);
});
const storage = () => { const map=new Map(); return {getItem:k=>map.get(k)??null,setItem:(k,v)=>map.set(k,v),removeItem:k=>map.delete(k)}; };
test('登入不儲存密碼，RPC 使用登入者 JWT', async () => {
  const original=global.fetch; const calls=[];
  global.fetch=async (url,opts) => {calls.push({url,opts}); return new Response(JSON.stringify(url.includes('/auth/')?{access_token:'jwt',refresh_token:'refresh',expires_in:3600,user:{id:'u',email:'a@test'}}:{items:[]}));};
  try {
    const api=new Backend({supabaseUrl:'https://test.supabase.co',supabaseKey:'public'},storage());
    await api.login('a@test','never-store'); await api.rpc('restock_snapshot');
    assert.ok(!JSON.stringify(api.session()).includes('never-store'));
    assert.equal(calls[1].opts.headers.Authorization,'Bearer jwt');
  } finally {global.fetch=original;}
});
test('並行請求只更新 session 一次，登入失效時清除 session', async () => {
  const original=global.fetch; let calls=0;
  const api=new Backend({supabaseUrl:'https://test.supabase.co',supabaseKey:'public'},storage());
  api.save({access_token:'old',refresh_token:'r',expires_at:1,user:{id:'u'}});
  global.fetch=async()=>{calls++; return new Response(JSON.stringify({access_token:'new',refresh_token:'r2',expires_in:3600,user:{id:'u'}}));};
  try {
    assert.deepEqual(await Promise.all([api.token(),api.token()]),['new','new']); assert.equal(calls,1);
    api.save({access_token:'old',refresh_token:'r',expires_at:1,user:{id:'u'}});
    global.fetch=async()=>new Response(JSON.stringify({message:'Expired'}),{status:400});
    await assert.rejects(api.token()); assert.equal(api.session(),null);
  } finally {global.fetch=original;}
});
test('網路錯誤不抹除仍可重試的 session', async () => {
  const original=global.fetch;
  const api=new Backend({supabaseUrl:'https://test.supabase.co',supabaseKey:'public'},storage());
  api.save({access_token:'old',refresh_token:'r',expires_at:1,user:{id:'u'}});
  global.fetch=async()=>{throw new TypeError('Failed to fetch');};
  try {await assert.rejects(api.token()); assert.equal(api.session().refresh_token,'r');} finally {global.fetch=original;}
});
