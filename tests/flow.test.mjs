import test from 'node:test';
import assert from 'node:assert/strict';
import { estimate, median } from '../cycle.mjs';
import { selectItems } from '../list.mjs';
import { activityText, activityTime, recentActivity } from '../activity.mjs';
const DAY=86400000, item={id:'i',household_id:'h',name:'紙',category:'浴廁',status:'normal'};
function history(intervals) { let day=Date.parse('2025-01-01T00:00:00Z');return [0,...intervals].map(n=>{day+=n*DAY;return {item_id:'i',restocked_at:new Date(day).toISOString()};}); }
test('中位數抵抗 80 天極端值，保留真實平均供歷史參考',()=>{
  const rows=history([35,38,80,37]), copy=structuredClone(rows), result=estimate(item,rows);
  assert.equal(result.period,37.5); assert.equal(result.average,47.5);assert.deepEqual(rows,copy);
  assert.equal(median([]),null);assert.equal(median([38,35,37]),37);
});
test('無資料不推測；一段間隔提供初估；同日多筆不壓縮週期',()=>{
  assert.equal(estimate(item,[]).period,null);assert.equal(estimate(item,history([])).period,null);
  const rows=history([35]);rows.push({...rows.at(-1),restocked_at:rows.at(-1).restocked_at.replace('00:00','12:00')});
  const result=estimate(item,rows);assert.equal(result.period,35);assert.equal(result.samples,1);
});
test('提醒使用中位數 80% 邊界，單次極端值不延後提醒',()=>{
  const rows=history([35,38,80,37]), last=Date.parse(rows.at(-1).restocked_at), threshold=last+30*DAY;
  assert.equal(estimate(item,rows,threshold-1).status,'normal');assert.equal(estimate(item,rows,threshold).status,'possible');
});
test('還很多不改歷史，7 天內不提醒或順便補，到期重新評估，待購優先',()=>{
  const rows=history([10]), now=Date.parse(rows.at(-1).restocked_at)+9*DAY, until=now+7*DAY;
  const snoozed={...item,snoozed_until:new Date(until).toISOString()};
  assert.equal(estimate(snoozed,rows,now).status,'normal');assert.equal(estimate(snoozed,rows,now).soon,false);
  assert.equal(estimate(snoozed,rows,until-1).status,'normal');assert.equal(estimate(snoozed,rows,until).status,'possible');
  assert.equal(estimate({...snoozed,status:'low'},rows,now).status,'low');assert.equal(rows.length,2);
});
test('順便補只在指定途徑、名稱分類交集內；無歷史不推薦、無重複、不寫入待購',()=>{
  const rows=history([35]), now=Date.parse(rows.at(-1).restocked_at)+22*DAY;
  const snapshot={items:[item,{...item,id:'other',name:'紙2'},{...item,id:'unknown',name:'纸'}],history:rows,
    item_sources:[{item_id:'i',household_id:'h',source_id:'costco'},{item_id:'other',household_id:'h',source_id:'px'}]};
  assert.equal(selectItems(snapshot,'h','紙','浴廁',now).groups.possible.length,0);
  const result=selectItems(snapshot,'h','紙','浴廁',now,'costco');assert.deepEqual(result.groups.possible.map(i=>i.id),['i']);
  assert.equal(result.groups.low.length,0);assert.equal(result.groups.normal.length,0);assert.equal(item.status,'normal');
  assert.equal(selectItems(snapshot,'h','紙','清潔',now,'costco').shown,0);
  assert.equal(selectItems(snapshot,'h','','',now,'unset').groups.possible.length,0);
});
test('順便補 7 天界線、snooze 排除、真正待購不重複',()=>{
  const rows=history([35]), last=Date.parse(rows.at(-1).restocked_at);
  assert.equal(estimate(item,rows,last+21*DAY-1).soon,false);assert.equal(estimate(item,rows,last+21*DAY).soon,true);
  const snapshot={items:[{...item,status:'low',purchase_quantity:3}],history:rows,item_sources:[{item_id:'i',household_id:'h',source_id:'costco'}]};
  const result=selectItems(snapshot,'h','','',last+22*DAY,'costco');assert.equal(result.groups.low[0].purchase_quantity,3);assert.equal(result.groups.possible.length,0);
  snapshot.items[0]={...item,snoozed_until:new Date(last+40*DAY).toISOString()};
  assert.equal(selectItems(snapshot,'h','','',last+22*DAY,'costco').groups.possible.length,0);
});
test('動態操作者、補貨數量、先前成員與名字保留；每家庭最近20筆',()=>{
  const event={actor_id:'a',item_name:'雞肉',event:'restock',quantity:2};
  assert.equal(activityText(event,'a'),'你補貨了「雞肉」 × 2');assert.equal(activityText(event,'b'),'另一位成員補貨了「雞肉」 × 2');
  assert.match(activityText({...event,actor_id:null},'a'),/^先前成員/);
  assert.match(activityText({...event,event:'snooze'},'a'),/7 天後再評估/);
  const events=Array.from({length:30},(_,i)=>({...event,id:String(i),household_id:'h',created_at:new Date(i*DAY).toISOString()}));
  events.push({...event,id:'other',household_id:'other',created_at:new Date(999*DAY).toISOString()});
  const result=recentActivity({activity:events},'h');assert.equal(result.length,20);assert.equal(result[0].id,'29');assert.equal(events.length,31);
});
test('動態時間以裝置當地日曆判斷今天昨天，跨月正確',()=>{
  const now=new Date(2026,9,1,12);assert.match(activityTime(new Date(2026,9,1,8).toISOString(),now),/^今天/);
  assert.match(activityTime(new Date(2026,8,30,8).toISOString(),now),/^昨天/);
  assert.match(activityTime(new Date(2026,8,29,8).toISOString(),now),/^9\/29/);
});
