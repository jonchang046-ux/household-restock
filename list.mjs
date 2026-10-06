import { estimate } from './cycle.mjs?v=7';

export const categories = ['浴廁', '清潔', '廚房', '食品常溫', '飲料', '冷藏', '冷凍', '個人用品', '其他'];
const collator = new Intl.Collator('zh-Hant', { numeric: true, sensitivity: 'base' });
const normalize = value => String(value ?? '').normalize('NFKC').trim().toLocaleLowerCase('zh-Hant');
const rank = category => { const i = categories.indexOf(category); return i < 0 ? categories.length : i; };

export function compareItems(a, b) {
  return rank(a.category) - rank(b.category)
    || collator.compare(a.name, b.name)
    || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}

// 純函式：不修改快照，篩選前後維持狀態、分類、名稱、ID 的穩定順序。
export function itemSourceIds(snapshot, item) {
  return [...new Set((snapshot.item_sources || []).filter(link => link.item_id === item.id && link.household_id === item.household_id).map(link => link.source_id))];
}

export function householdSources(snapshot, householdId) {
  return (snapshot.sources || []).filter(source => source.household_id === householdId)
    .slice().sort((a,b) => collator.compare(a.name,b.name) || a.id.localeCompare(b.id));
}

// 確認刪除時的目前用品集合；排除其他家庭、封存及孤立／重複關聯。
export function sourceUsageIds(snapshot, householdId, sourceId) {
  const active = new Set(snapshot.items.filter(i => i.household_id === householdId && !i.archived_at).map(i => i.id));
  return [...new Set((snapshot.item_sources || []).filter(l => l.household_id === householdId && l.source_id === sourceId && active.has(l.item_id)).map(l => l.item_id))].sort();
}

export function resolveSourceFilter(snapshot, householdId, sourceId) {
  return !sourceId || sourceId === 'unset' || householdSources(snapshot, householdId).some(s => s.id === sourceId) ? sourceId : '';
}

export function selectItems(snapshot, householdId, query = '', category = '', now = Date.now(), sourceId = '') {
  const all = snapshot.items.filter(item => item.household_id === householdId && !item.archived_at);
  const needle = normalize(query);
  const visible = all.filter(item => {
    const ids = itemSourceIds(snapshot, item);
    return (!category || item.category === category) && normalize(item.name).includes(needle)
      && (!sourceId || (sourceId === 'unset' ? ids.length === 0 : ids.includes(sourceId)));
  }).sort(compareItems);
  const groups = { low: [], possible: [], normal: [] };
  for (const item of visible) {
    const cycle = estimate(item, snapshot.history, now);
    const status = cycle.status === 'normal' && sourceId && sourceId !== 'unset' && cycle.soon ? 'possible' : cycle.status;
    groups[status].push(item);
  }
  return { groups, total: all.length, shown: visible.length, filtered: !!needle || !!category || !!sourceId };
}
