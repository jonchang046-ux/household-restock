import test from 'node:test';
import assert from 'node:assert/strict';
import {selectItems, householdSources, itemSourceIds, sourceUsageIds, resolveSourceFilter} from '../list.mjs';
const now=Date.parse('2026-10-03T12:00:00Z');
const item=(id,name,category,status='low')=>({id,household_id:'home',name,category,status});
const data={items:[item('paper','衛生紙','浴廁'),item('soap','洗衣精','清潔'),item('bags','垃圾袋','清潔'),item('dish','洗碗精','廚房'),item('unset','廚房紙巾','廚房'),item('normal','衛生紙備品','浴廁','normal')],history:[],sources:[{id:'costco',household_id:'home',name:'好市多'},{id:'px',household_id:'home',name:'全聯'},{id:'car',household_id:'home',name:'家樂福'},{id:'foreign',household_id:'other',name:'另一家庭'}],item_sources:[['paper','costco'],['paper','px'],['soap','costco'],['bags','px'],['dish','car'],['normal','costco']].map(([item_id,source_id])=>({household_id:'home',item_id,source_id}))};
const select=(q='',category='',source='')=>selectItems(data,'home',q,category,now,source);
test('好市多待購只含衛生紙與洗衣精，多途徑品項仍只顯示一次',()=>{
  assert.deepEqual(select('','','costco').groups.low.map(i=>i.id),['paper','soap']);
  assert.deepEqual(select('','','px').groups.low.map(i=>i.id),['paper','bags']);
  assert.equal(select('','','costco').groups.normal[0].id,'normal');
});
test('搜尋、分類、購買途徑取交集且保留狀態分組',()=>{
  const result=select('紙','浴廁','costco');
  assert.deepEqual(result.groups.low.map(i=>i.id),['paper']);
  assert.deepEqual(result.groups.normal.map(i=>i.id),['normal']);
  assert.equal(select('洗','浴廁','costco').shown,0);
  assert.equal(select('紙','浴廁','car').shown,0);
});
test('既有無關聯品項可選尚未設定，清除途徑篩選恢復全部',()=>{
  assert.deepEqual(select('','','unset').groups.low.map(i=>i.id),['unset']);
  assert.equal(select().shown,6);
  assert.equal(selectItems({items:data.items,history:[]},'home','','',now,'unset').shown,6);
});
test('來源清單隔離家庭；錯誤家庭關聯不影響目前品項',()=>{
  assert.equal(householdSources(data,'home').length,3);
  const extra={...data,item_sources:[...data.item_sources,{household_id:'other',item_id:'unset',source_id:'foreign'}]};
  assert.deepEqual(itemSourceIds(extra,data.items[4]),[]);
});
test('途徑改名保留 ID 和篩選；重排快照不改變顯示順序或輸入',()=>{
  const before=structuredClone(data), renamed=structuredClone(data);
  renamed.sources[0].name='好市多線上';renamed.items.reverse();renamed.item_sources.reverse();
  assert.deepEqual(selectItems(renamed,'home','','',now,'costco').groups,select('','','costco').groups);
  assert.deepEqual(data,before);
});

test('刪除確認數量依目前用品計算，排除封存、外家庭、孤立及重複關聯',()=>{
  const input=structuredClone(data);
  input.items.push({...item('archived','封存用品','其他'),archived_at:'2026-10-01'});
  input.item_sources.push({household_id:'home',item_id:'archived',source_id:'costco'},
    {household_id:'home',item_id:'missing',source_id:'costco'},
    {household_id:'other',item_id:'bags',source_id:'costco'},input.item_sources[0]);
  assert.deepEqual(sourceUsageIds(input,'home','costco'),['normal','paper','soap']);
  assert.deepEqual(sourceUsageIds(input,'home','missing'),[]);
  assert.deepEqual(sourceUsageIds({...input,items:[]},'home','costco'),[]);
});

test('來源刪除的同步快照令篩選回全部；搜尋分類仍取交集，其他途徑仍保留',()=>{
  const input=structuredClone(data);
  input.sources=input.sources.filter(s=>s.id!=='costco');
  input.item_sources=input.item_sources.filter(l=>l.source_id!=='costco');
  const filter=resolveSourceFilter(input,'home','costco');
  assert.equal(filter,'');
  assert.equal(resolveSourceFilter(input,'home','px'),'px');
  assert.equal(resolveSourceFilter(input,'home','unset'),'unset');
  assert.equal(resolveSourceFilter(input,'home','foreign'),'');
  assert.deepEqual(selectItems(input,'home','紙','浴廁',now,filter).groups.low.map(i=>i.id),['paper']);
  assert.deepEqual(itemSourceIds(input,input.items[0]),['px']);
  assert.equal(input.items.length,data.items.length);
});
