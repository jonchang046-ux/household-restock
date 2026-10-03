import { estimate } from './cycle.mjs';

export const categories = ['浴廁', '清潔', '廚房', '食品', '個人用品', '其他'];
const collator = new Intl.Collator('zh-Hant', { numeric: true, sensitivity: 'base' });
const normalize = value => String(value ?? '').normalize('NFKC').trim().toLocaleLowerCase('zh-Hant');
const rank = category => { const i = categories.indexOf(category); return i < 0 ? categories.length : i; };

export function compareItems(a, b) {
  return rank(a.category) - rank(b.category)
    || collator.compare(a.name, b.name)
    || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}

// 純函式：不修改快照，篩選前後維持狀態、分類、名稱、ID 的穩定順序。
export function selectItems(snapshot, householdId, query = '', category = '', now = Date.now()) {
  const all = snapshot.items.filter(item => item.household_id === householdId && !item.archived_at);
  const needle = normalize(query);
  const visible = all.filter(item => (!category || item.category === category) && normalize(item.name).includes(needle)).sort(compareItems);
  const groups = { low: [], possible: [], normal: [] };
  for (const item of visible) groups[estimate(item, snapshot.history, now).status].push(item);
  return { groups, total: all.length, shown: visible.length, filtered: !!needle || !!category };
}
