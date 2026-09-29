const DAY = 86400000;
export function estimate(item, history, now = Date.now()) {
  const times = history.filter(x => x.item_id === item.id).map(x => Date.parse(x.restocked_at)).filter(Number.isFinite).sort((a,b) => a-b);
  // 同一天多次購買不應把平均週期壓成零天；原始歷史仍完整保存。
  const days = [...new Set(times.map(t => Math.floor(t / DAY)))];
  const average = days.length >= 2 ? (days.at(-1) - days[0]) / (days.length - 1) : null;
  const last = times.at(-1) ?? null;
  const possible = average !== null && now - last >= average * DAY * 0.8;
  return { average, last, samples: Math.max(0, days.length-1), status: item.status === 'low' ? 'low' : possible ? 'possible' : 'normal' };
}
