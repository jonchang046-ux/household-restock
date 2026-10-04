const DAY = 86400000;
export function median(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a,b) => a-b), mid = Math.floor(sorted.length/2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid-1]+sorted[mid])/2;
}
export function estimate(item, history, now = Date.now()) {
  const times = history.filter(x => x.item_id === item.id).map(x => Date.parse(x.restocked_at)).filter(Number.isFinite).sort((a,b) => a-b);
  // 同一天多次購買不應把平均週期壓成零天；原始歷史仍完整保存。
  const days = [...new Set(times.map(t => Math.floor(t / DAY)))];
  const intervals = days.slice(1).map((day,i) => day-days[i]);
  const average = intervals.length ? intervals.reduce((sum,n) => sum+n,0)/intervals.length : null;
  const period = median(intervals);
  const last = times.at(-1) ?? null;
  const reminderAt = period === null ? null : last + period*DAY*0.8;
  const snoozedUntil = Date.parse(item.snoozed_until), snoozed = Number.isFinite(snoozedUntil) && now < snoozedUntil;
  const possible = reminderAt !== null && now >= reminderAt && !snoozed;
  const soon = reminderAt !== null && now < reminderAt && now + 7*DAY >= reminderAt && !snoozed;
  return { average, period, last, reminderAt, soon, snoozed, snoozedUntil, samples: intervals.length, status: item.status === 'low' ? 'low' : possible ? 'possible' : 'normal' };
}
