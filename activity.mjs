const verbs = {add:'新增了',edit:'修改了',low:'將',restock:'補貨了',snooze:'確認',archive:'刪除了',normal:'取消了'};
export function activityText(event, userId) {
  const actor = event.actor_id === userId ? '你' : event.actor_id ? '另一位成員' : '先前成員';
  const name = `「${event.item_name}」`;
  if (event.event === 'low') return `${actor}將${name}標記為快沒了`;
  if (event.event === 'snooze') return `${actor}確認${name}還很多，7 天後再評估`;
  if (event.event === 'normal') return `${actor}取消了${name}的待購`;
  return `${actor}${verbs[event.event] || '更新了'}${name}${event.event === 'restock' && event.quantity ? ` × ${event.quantity}` : ''}`;
}
export function activityTime(value, now = new Date()) {
  const time = new Date(value);
  if (!Number.isFinite(time.getTime())) return '';
  const key = d => `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
  const yesterday = new Date(now); yesterday.setDate(yesterday.getDate()-1);
  const clock = time.toLocaleTimeString('zh-TW',{hour:'2-digit',minute:'2-digit',hour12:false});
  if (key(time) === key(now)) return `今天 ${clock}`;
  if (key(time) === key(yesterday)) return `昨天 ${clock}`;
  return `${time.getMonth()+1}/${time.getDate()} ${clock}`;
}
export function recentActivity(snapshot, householdId) {
  return (snapshot.activity || []).filter(event => event.household_id === householdId)
    .slice().sort((a,b) => b.created_at.localeCompare(a.created_at) || b.id.localeCompare(a.id)).slice(0,20);
}
