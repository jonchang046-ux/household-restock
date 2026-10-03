import test from 'node:test';
import assert from 'node:assert/strict';
import { selectItems } from '../list.mjs';
const items = [
  {id:'a',household_id:'home',name:'衛生紙',category:'浴廁',status:'low'},
  {id:'b',household_id:'home',name:'洗衣精',category:'清潔',status:'normal'},
  {id:'c',household_id:'home',name:'洗碗精',category:'廚房',status:'normal'},
  {id:'d',household_id:'home',name:'垃圾袋',category:'清潔',status:'normal'},
  {id:'e',household_id:'home',name:'洗衣粉',category:'清潔',status:'low',archived_at:'2026-01-01'},
  {id:'f',household_id:'other',name:'洗手乳',category:'清潔',status:'low'},
];
const history=[{item_id:'b',restocked_at:'2026-01-01T00:00:00Z'},{item_id:'b',restocked_at:'2026-01-11T00:00:00Z'}];
const snapshot={items,history};
const now=Date.parse('2026-01-19T00:00:00Z');
const ids = result => Object.values(result.groups).flat().map(i=>i.id);
test('名稱部分搜尋，保留三種狀態並排除其他家庭及封存品項',()=>{
  const result=selectItems(snapshot,'home','洗','',now);
  assert.deepEqual(ids(result),['b','c']); assert.equal(result.groups.possible[0].id,'b'); assert.equal(result.groups.normal[0].id,'c');
  assert.deepEqual(ids(selectItems(snapshot,'home','衛生','',now)),['a']);
});
test('分類與搜尋同時作用、空結果、全部與空白搜尋',()=>{
  assert.deepEqual(ids(selectItems(snapshot,'home','洗','清潔',now)),['b']);
  assert.equal(selectItems(snapshot,'home','','清潔',now).shown,2);
  assert.equal(selectItems(snapshot,'home','不存在','',now).shown,0);
  assert.equal(selectItems(snapshot,'home','   ','',now).shown,4);
  assert.equal(selectItems(snapshot,'home','   ','',now).filtered,false);
});
test('分類順序固定，名稱自然排序，相同名稱以 ID 決定且輸入不被修改',()=>{
  const input={items:[{id:'z',household_id:'home',name:'用品2',category:'其他',status:'normal'},{id:'b',household_id:'home',name:'用品10',category:'浴廁',status:'normal'},{id:'c',household_id:'home',name:'用品2',category:'浴廁',status:'normal'},{id:'a',household_id:'home',name:'用品2',category:'浴廁',status:'normal'}],history:[]};
  const before=JSON.stringify(input); const expected=['a','c','b','z'];
  assert.deepEqual(ids(selectItems(input,'home')),expected);
  assert.deepEqual(ids(selectItems({...input,items:[...input.items].reverse()},'home')),expected);
  assert.equal(JSON.stringify(input),before);
});
test('編輯不改歷史來源及週期，刪除不再參與清單',()=>{
  const edited={...snapshot,items:items.map(i=>i.id==='b'?{...i,name:'家庭洗衣精',category:'其他'}:i)};
  assert.equal(selectItems(edited,'home','家庭','其他',now).groups.possible[0].id,'b');
  const archived={...edited,items:edited.items.map(i=>i.id==='b'?{...i,archived_at:'2026-01-19'}:i)};
  assert.equal(selectItems(archived,'home','家庭','',now).shown,0); assert.equal(archived.history.length,2);
});
test('不分英文大小寫與全形半形，名稱不當成正規表示式',()=>{
  const input={items:[{id:'1',household_id:'home',name:'ＡＢＣ 洗劑 (大)',category:'清潔',status:'normal'}],history:[]};
  assert.equal(selectItems(input,'home','abc').shown,1); assert.equal(selectItems(input,'home','(').shown,1);
});
