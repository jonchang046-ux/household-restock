import { config } from './config.js';
import { Backend } from './api.mjs';
import { estimate } from './cycle.mjs?v=7';
import { categories, selectItems, itemSourceIds, householdSources, sourceUsageIds, resolveSourceFilter } from './list.mjs?v=7';
import { activityText, activityTime, recentActivity } from './activity.mjs?v=7';

const $ = id => document.getElementById(id);
const api = new Backend(config);
let snapshot = { households: [], items: [], history: [] };
let selected = '', loading = false, busy = false, generation = 0;
let refreshTask = null;
let searchText = '', categoryFilter = '', managedItem = null, editItem = null, deleteItem = null;
let sourceFilter = '', sourceEditing = null, sourceCatalogKey = '';
let sourceDeleting = null;
let normalExpanded = false, normalFilterKey = '', normalFilteredOverride = null;
const date = value => new Intl.DateTimeFormat('zh-TW', { month: 'numeric', day: 'numeric', year: 'numeric' }).format(new Date(value));
function notice(message) {
  $('notice').textContent = message; $('notice').hidden = !message;
  document.querySelectorAll('.dialog-error').forEach(n => n.remove());
  const dialog = [...document.querySelectorAll('dialog[open]')].at(-1);
  if (message && dialog) { const error = el('p', 'notice dialog-error', message); error.setAttribute('role','alert'); dialog.prepend(error); }
}
function message(e) {
  if (e.message.includes('INVALID_QUANTITY')) return '待購數量必須是 1 到 999 的整數。';
  if (e.message.includes('NOT_SHOPPING')) return '此品項已離開待購清單，請確認最新狀態。';
  if (e.message.includes('NOT_NORMAL')) return '此品項已加入待購，請確認最新狀態。';
  if (e.message.includes('SOURCE_USAGE_CHANGED')) return '使用此途徑的品項已改變，請取消後重新確認數量。';
  if (e.message.includes('STALE_SOURCE')) return '家人已修改此購買途徑，請取消目前操作並重新選擇最新資料。';
  if (e.message.includes('DUPLICATE_SOURCE')) return '這個家庭已有同名購買途徑，請使用現有選項。';
  if (e.message.includes('INVALID_SOURCES')) return '購買途徑無效或不屬於這個家庭，請重新整理後再選擇。';
  if (e.message.includes('STALE_ITEM')) return '家人已更新這個品項，已重新讀取；請確認最新狀態。';
  if (e.message.includes('ITEM_ARCHIVED')) return '這個品項已被刪除，歷史仍保留。請關閉視窗查看最新清單。';
  if (e.message.includes('INVALID_NAME')) return '請輸入 1 到 80 個字的品項名稱。';
  if (e.message.includes('INVALID_CATEGORY')) return '請選擇有效的分類。';
  if (e.code === 'PGRST202') return '功能尚未啟用，請管理者確認對應的 migration 已成功執行。';
  if (e.message.includes('NOT_MEMBER')) return '你目前不是這個家庭的成員，請聯絡管理者。';
  if (e.message.includes('Invalid login credentials')) return 'Email 或密碼不正確，請再確認。';
  if (e.message.includes('Failed to fetch') || e.name === 'TimeoutError') return '目前無法連線。變更尚未確認，請重新整理後確認狀態。';
  if (e.status === 401) return '登入已失效，請登出後重新登入。';
  return e.message;
}
function el(tag, className, text) { const node = document.createElement(tag); if (className) node.className = className; if (text != null) node.textContent = text; return node; }
function view() {
  const signedIn = !!api.session();
  $('login').hidden = signedIn; $('app').hidden = !signedIn; $('account-button').hidden = !signedIn;
  if (signedIn) { $('email').textContent = api.session().user.email; $('user-id').value = api.session().user.id; }
  else document.querySelectorAll('dialog[open]').forEach(d => d.close());
}
function render() {
  const previous = selected;
  if (!snapshot.households.some(h => h.id === selected)) selected = snapshot.households[0]?.id || '';
  $('household').replaceChildren(...snapshot.households.map(h => { const opt = el('option', '', h.name); opt.value = h.id; return opt; }));
  $('household').value = selected;
  $('house-id').value = selected;
  $('house-title').textContent = snapshot.households.find(h => h.id === selected)?.name || '家裡的常用品';
  $('no-house').hidden = !!selected; $('lists').hidden = !selected; $('add-open').hidden = !selected;
  $('browse').hidden = !selected;
  $('search-tools').hidden = !selected;
  if (previous !== selected) { sourceFilter = ''; document.querySelectorAll('dialog[open]').forEach(d => d.close()); }
  renderSources();
  const {groups, total, shown, filtered} = selectItems(snapshot, selected, searchText, categoryFilter, Date.now(), sourceFilter);
  const atStore = !!sourceFilter && sourceFilter !== 'unset';
  $('possible-title').textContent = atStore ? '可能可以順便補' : '可能快沒了';
  $('possible-note').textContent = atStore ? '此途徑的近期品項，含未來 7 天內可能需要的用品；不會自動加入待購。' : '依補貨間隔提醒，確認快沒了再加入待購。';
  $('filter-summary').textContent = filtered ? `找到 ${shown} 項／共 ${total} 項${shown === 0 ? '，試試其他名稱或清除篩選。' : ''}` : `共 ${total} 項常用品`;
  for (const button of $('category-filters').children) button.setAttribute('aria-pressed', String(button.dataset.category === categoryFilter));
  $('quick-category').value = categoryFilter;
  for (const [status, items] of Object.entries(groups)) {
    $(''+status+'-count').textContent = items.length;
    const container = $(status+'-list'); container.replaceChildren();
    for (const item of items) container.append(card(item, status));
    if (!items.length) container.append(el('p', 'empty', filtered ? '此區沒有符合篩選的品項。' : {low:'目前沒有待購品項，家裡都準備好了。',possible:'有足夠補貨紀錄後，會在這裡提醒你。',normal:'把經常買的用品加進來，下次一鍵記下。'}[status]));
  }
  // 收合只影響呈現；變更篩選時自動顯示結果，同步時保留手動切換。
  const filterKey = JSON.stringify([selected, searchText.trim(), categoryFilter, sourceFilter]);
  if (filterKey !== normalFilterKey) { normalFilterKey = filterKey; normalFilteredOverride = null; }
  const expanded = filtered ? (normalFilteredOverride ?? groups.normal.length > 0) : normalExpanded;
  $('normal-list').hidden = !expanded;
  $('normal-toggle').setAttribute('aria-expanded', String(expanded));
  $('normal-chevron').textContent = expanded ? '⌃' : '⌄';
  renderActivity();
  updateDialogState();
}
function renderActivity() {
  $('recent-activity').hidden = !selected || snapshot.schema_version < 4;
  const rows = recentActivity(snapshot, selected);
  $('activity-count').textContent = rows.length;
  $('activity-list').replaceChildren(...rows.map(event => {
    const row = el('li', 'activity-row'), time = el('time','muted',activityTime(event.created_at));
    time.dateTime = event.created_at;
    row.append(time,el('span','',activityText(event,api.session()?.user.id))); return row;
  }));
  if (!rows.length) $('activity-list').append(el('li','empty','新版本啟用後的操作會記在這裡。'));
}
function action(label, style, handler) { const b = el('button', style, label); b.type = 'button'; b.addEventListener('click', handler); b.disabled = busy; return b; }
function card(item, status) {
  const cycle = estimate(item, snapshot.history);
  const compact = status === 'normal';
  const node = el('article', compact ? 'item item-compact' : 'item');
  const info = el('div', 'item-info');
  const quantity = Number.isInteger(item.purchase_quantity) ? item.purchase_quantity : 1;
  const name = item.status === 'low' ? `${item.name} × ${quantity}` : item.name;
  if (compact) info.append(el('h3', '', name), el('span', 'category', item.category));
  else info.append(el('span', 'category', item.category), el('h3', '', name));
  const sourceIds = itemSourceIds(snapshot, item);
  const sourceNames = householdSources(snapshot, item.household_id).filter(s => sourceIds.includes(s.id)).map(s => s.name);
  info.append(el('p', 'meta source-names', sourceNames.length ? `購買：${sourceNames.join('、')}` : '尚未設定購買途徑'));
  if (cycle.last) info.append(el('p', 'meta', `上次補貨 ${date(cycle.last)}`));
  if (cycle.period !== null) info.append(el('p', 'meta', `預估約 ${Math.round(cycle.period)} 天補一次${cycle.samples === 1 ? ' · 初步估計' : ''}`));
  if (cycle.snoozed && item.status !== 'low') info.append(el('p','meta',`還很多 · ${date(cycle.snoozedUntil)} 再評估`));
  if (status === 'possible' && cycle.soon) info.append(el('p','meta','預估 7 天內可能需要，可順便確認。'));
  const actions = el('div', 'item-actions');
  const more = action('⋯', 'quiet item-more', () => openItemMenu(item));
  more.setAttribute('aria-label', `${item.name}的更多操作`);
  more.setAttribute('aria-haspopup', 'dialog');
  node.append(more);
  if (item.status === 'low') {
    if (snapshot.schema_version >= 4) {
      const picker = el('div','quantity-picker'); picker.setAttribute('role','group'); picker.setAttribute('aria-label',`${item.name}的待購數量`);
      const minus = action('−','secondary quantity-step',() => adjustQuantity(item,quantity-1));
      const plus = action('＋','secondary quantity-step',() => adjustQuantity(item,quantity+1));
      minus.setAttribute('aria-label',`減少${item.name}的待購數量`); plus.setAttribute('aria-label',`增加${item.name}的待購數量`);
      minus.dataset.blocked = String(quantity <= 1); plus.dataset.blocked = String(quantity >= 999);
      picker.append(minus,el('span','quantity-value',String(quantity)),plus); actions.append(picker);
    }
    actions.append(action('✓ 已補貨', 'primary', () => mutate(item, 'restock')));
  } else if (compact) {
    actions.append(action('快沒了', 'primary', () => mutate(item, 'low')));
    actions.append(action('已補貨', 'quiet', () => mutate(item, 'restock')));
  } else {
    if (snapshot.schema_version >= 4) actions.append(action('還很多', 'secondary', () => snooze(item)));
    actions.append(action('快沒了', 'primary', () => mutate(item, 'low')));
    actions.append(action('已補貨', 'quiet', () => mutate(item, 'restock')));
  }
  node.append(info, actions); return node;
}
function showHistory(item) {
  $('history-title').textContent = `${item.name}・補貨紀錄`;
  const cycle = estimate(item, snapshot.history);
  $('history-summary').textContent = cycle.period === null ? '至少需要兩個不同日期的補貨紀錄，才能估計週期。' : `預估約 ${Math.round(cycle.period)} 天（${cycle.samples} 段補貨間隔的中位數${cycle.samples === 1 ? '，初步估計' : ''}）；原始平均約 ${Math.round(cycle.average)} 天。經過預估週期的 80% 時提醒，不會自動加入待購。`;
  const rows = snapshot.history.filter(h => h.item_id === item.id).sort((a,b) => b.restocked_at.localeCompare(a.restocked_at));
  $('history-list').replaceChildren(...rows.map(h => el('li', 'history-row', `${new Date(h.restocked_at).toLocaleString('zh-TW')}${h.purchased_quantity ? ` · 補貨 × ${h.purchased_quantity}` : ''}`)));
  if (!rows.length) $('history-list').append(el('li', 'history-row', '還沒有補貨紀錄。'));
  $('history-dialog').showModal();
}
function refresh() {
  if (refreshTask) return refreshTask;
  refreshTask = fetchSnapshot().finally(() => { refreshTask = null; });
  return refreshTask;
}
async function fetchSnapshot() {
  if (loading || !api.session()) return;
  loading = true; const current = generation;
  try {
    const data = await api.rpc('restock_snapshot');
    if (current !== generation || !api.session()) return;
    snapshot = data; render();
    $('sync').textContent = `已同步 ${new Date().toLocaleTimeString('zh-TW', {hour:'2-digit',minute:'2-digit',second:'2-digit'})} · 每 10 秒更新`;
  } catch (e) {
    $('sync').textContent = '同步失敗，畫面可能不是最新資料。';
    if (!api.session()) { generation++; snapshot = { households:[], items:[], history:[] }; render(); view(); }
    throw e;
  } finally { loading = false; }
}
async function run(button, fn) {
  if (busy) return; busy = true; notice('');
  document.querySelectorAll('button').forEach(b => b.disabled = true);
  try { if (refreshTask) await refreshTask.catch(() => {}); await fn(); } catch (e) { notice(message(e)); }
  finally { busy = false; document.querySelectorAll('button').forEach(b => b.disabled = false); updateDialogState(); }
}
function currentItem(item) { return item && snapshot.items.find(i => i.id === item.id && i.household_id === selected && !i.archived_at); }
function chosenSources(id) { return [...$(id).querySelectorAll('input:checked')].map(input => input.value); }
function renderSourcePicker(id, chosen = null) {
  const container = $(id), sources = householdSources(snapshot, selected);
  const key = JSON.stringify([selected, sources.map(s => [s.id,s.name])]);
  if (chosen === null && container.dataset.catalog === key) return;
  const checked = new Set(chosen ?? chosenSources(id));
  container.dataset.catalog = key;
  container.replaceChildren(...sources.map(source => {
    const label = el('label', 'source-option'), input = document.createElement('input');
    input.type = 'checkbox'; input.value = source.id; input.checked = checked.has(source.id);
    label.append(input, el('span', '', source.name)); return label;
  }));
  if (!sources.length) container.append(el('p','muted','尚無購買途徑，可以先新增，或留空稍後設定。'));
}
function resetSourceForm() {
  sourceEditing = null; $('source-form').reset(); $('source-name-label').textContent = '新增購買途徑';
  $('source-save').textContent = '新增途徑'; $('source-reset').hidden = true; updateDialogState();
}
function renderSources() {
  const sources = householdSources(snapshot, selected);
  sourceFilter = resolveSourceFilter(snapshot, selected, sourceFilter);
  const key = JSON.stringify([selected, sources]);
  if (sourceCatalogKey !== key) {
    sourceCatalogKey = key;
    const chips = $('source-filters'), scrollLeft = chips.scrollLeft;
    chips.replaceChildren(...[{id:'',name:'全部'},{id:'unset',name:'尚未設定'},...sources].map(source => {
      const button = action(source.name,'category-chip', () => { sourceFilter = source.id; render(); });
      button.dataset.source = source.id; return button;
    }));
    chips.scrollLeft = scrollLeft;
    $('source-list').replaceChildren(...sources.map(source => {
      const row = el('div','source-row');
      const button = action('改名','secondary', () => {
        sourceEditing = {...source}; $('source-name').value = source.name;
        $('source-name-label').textContent = `修改購買途徑：${source.name}`;
        $('source-save').textContent = '儲存名稱'; $('source-reset').hidden = false;
        notice(''); updateDialogState(); $('source-name').focus();
      });
      button.setAttribute('aria-label',`修改途徑 ${source.name}`);
      const remove = action('刪除','danger-quiet', () => {
        if (busy) return;
        sourceDeleting = {...source, itemIds:sourceUsageIds(snapshot, selected, source.id)};
        $('source-delete-title').textContent = `刪除「${source.name}」？`;
        const count = sourceDeleting.itemIds.length;
        $('source-delete-description').textContent = count
          ? `目前有 ${count} 個品項使用這個購買途徑。刪除後，這些品項將不再具有「${source.name}」標籤，但品項本身與補貨歷史不會被刪除。`
          : '目前沒有品項使用這個購買途徑。刪除不會刪除品項或補貨歷史。';
        updateDialogState(); $('source-delete-dialog').showModal();
        $('source-delete-dialog').querySelector('[data-close]').focus();
      });
      remove.setAttribute('aria-label',`刪除購買途徑 ${source.name}`);
      remove.dataset.sourceDelete = source.id;
      row.append(el('span','',source.name),button,remove); return row;
    }));
  }
  for (const button of $('source-filters').children) button.setAttribute('aria-pressed',String(button.dataset.source === sourceFilter));
  const sourceLabel = sourceFilter === 'unset' ? '尚未設定' : sources.find(s => s.id === sourceFilter)?.name;
  $('source-filter-note').textContent = sourceFilter ? `購買途徑：${sourceLabel}；與搜尋、使用分類一起篩選以下三區。` : '可與搜尋、使用分類一起篩選以下三區。';
  renderSourcePicker('add-sources'); renderSourcePicker('edit-sources');
}
function updateDialogState() {
  document.querySelectorAll('[data-source-delete]').forEach(button => button.disabled = busy);
  const latestRemoval = sourceDeleting && householdSources(snapshot, selected).find(s => s.id === sourceDeleting.id);
  const removalChanged = !!sourceDeleting && (!latestRemoval || latestRemoval.version !== sourceDeleting.version
    || JSON.stringify(sourceUsageIds(snapshot, selected, sourceDeleting.id)) !== JSON.stringify(sourceDeleting.itemIds));
  $('source-delete-confirm').disabled = busy || !sourceDeleting || removalChanged;
  $('source-delete-conflict').hidden = !removalChanged;
  $('source-delete-conflict').textContent = '購買途徑或使用它的品項已變更。請取消後重新確認，再刪除。';
  document.querySelectorAll('.quantity-step').forEach(button => button.disabled = busy || button.dataset.blocked === 'true');
  const latestSource = sourceEditing && householdSources(snapshot, selected).find(s => s.id === sourceEditing.id);
  const sourceChanged = !!sourceEditing && (!latestSource || latestSource.version !== sourceEditing.version);
  $('source-save').disabled = busy || !(snapshot.schema_version >= 3) || !selected || sourceChanged;
  $('source-conflict').hidden = !sourceChanged;
  $('source-conflict').textContent = '家人已修改此購買途徑，請取消改名並重新選擇。你的輸入尚未儲存。';
  document.querySelectorAll('[data-manage-sources]').forEach(b => b.disabled = busy || !(snapshot.schema_version >= 3));
  const latestEdit = currentItem(editItem);
  const editChanged = !!editItem && (!latestEdit || latestEdit.version !== editItem.version);
  $('edit-save').disabled = busy || !latestEdit || editChanged;
  $('edit-conflict').hidden = !editChanged;
  $('edit-conflict').textContent = latestEdit ? `家人已更新此品項（目前：${latestEdit.name}／${latestEdit.category}）。請先載入最新資料，再修改。` : '品項已被刪除，或你已無法存取這個家庭。';
  $('edit-reload').hidden = !editChanged || !latestEdit;
  $('edit-reload').disabled = busy;
  const latestDelete = currentItem(deleteItem);
  const deleteChanged = !!deleteItem && (!latestDelete || latestDelete.version !== deleteItem.version);
  $('delete-confirm').disabled = busy || !latestDelete || deleteChanged;
  $('delete-conflict').hidden = !deleteChanged;
  $('delete-conflict').textContent = latestDelete ? '此品項已更新。請取消，回清單重新確認品項後再刪除。' : '品項已被刪除，或你已無法存取這個家庭。';
  if ($('item-dialog').open && !currentItem(managedItem)) $('item-dialog').close();
}
function openItemMenu(item) {
  managedItem = item;
  $('item-dialog-title').textContent = item.name;
  $('cancel-low').hidden = item.status !== 'low';
  notice(''); $('item-dialog').showModal();
}
function loadEdit(item) {
  editItem = { ...item }; // 保留開啟時的 version；背景同步不能默默取代它。
  $('edit-name').value = item.name; $('edit-category').value = item.category;
  renderSourcePicker('edit-sources', itemSourceIds(snapshot, item));
  updateDialogState();
}
async function manageMutation(name, args, dialog, success) {
  await run(null, async () => {
    try { await api.rpc(name, args); }
    catch (e) { await refresh().catch(() => {}); throw e; }
    dialog.close();
    await refresh(); notice(success);
  });
}
// 首頁 chips、浮動篩選與新增／修改表單共用同一份使用分類。
for (const select of [$('add-form').elements.category, $('edit-category')]) {
  select.replaceChildren(...categories.map(category => {
    const option = el('option', '', category); option.value = category;
    option.defaultSelected = category === '其他'; return option;
  }));
}
$('add-form').elements.category.value = '其他';
for (const category of ['', ...categories]) {
  const button = action(category || '全部', 'category-chip', () => { categoryFilter = category; render(); });
  button.dataset.category = category; button.setAttribute('aria-pressed', String(category === ''));
  $('category-filters').append(button);
  const option = el('option', '', category || '全部分類'); option.value = category;
  $('quick-category').append(option);
}
$('quick-category').addEventListener('change', e => { categoryFilter = e.target.value; render(); });
$('normal-toggle').addEventListener('click', () => {
  const expanded = $('normal-toggle').getAttribute('aria-expanded') === 'true';
  if (searchText.trim() || categoryFilter || sourceFilter) normalFilteredOverride = !expanded;
  else normalExpanded = !expanded;
  render();
});
document.querySelectorAll('[data-manage-sources]').forEach(button => button.addEventListener('click', () => {
  resetSourceForm(); notice(''); $('sources-dialog').showModal(); $('source-name').focus();
}));
$('source-reset').addEventListener('click', resetSourceForm);
$('source-delete-confirm').addEventListener('click', () => {
  if (busy || $('source-delete-confirm').disabled) return;
  const source = sourceDeleting;
  run(null, async () => {
    try { await api.rpc('restock_delete_source', {p_household_id:source.household_id,p_source_id:source.id,p_version:source.version,p_expected_item_ids:source.itemIds}); }
    catch (e) { await refresh().catch(() => {}); throw e; }
    $('source-delete-dialog').close(); sourceDeleting = null;
    if (sourceEditing?.id === source.id) resetSourceForm();
    await refresh(); notice('購買途徑已刪除，品項與補貨歷史已保留。');
  });
});
$('source-form').addEventListener('submit', e => {
  e.preventDefault(); if (busy || $('source-save').disabled) return;
  const name = $('source-name').value.trim();
  if (!name) { notice('請輸入購買途徑名稱，不能只有空白。'); return; }
  const args = {p_household_id:selected,p_source_id:sourceEditing?.id ?? null,p_version:sourceEditing?.version ?? null,p_name:name};
  run(null, async () => {
    try { await api.rpc('restock_save_source',args); }
    catch (e) { await refresh().catch(() => {}); throw e; }
    resetSourceForm(); await refresh(); notice('購買途徑已儲存，家庭成員可共用。');
  });
});
$('search').addEventListener('input', e => { searchText = e.target.value; render(); });
$('clear-filters').addEventListener('click', () => { searchText = ''; categoryFilter = ''; sourceFilter = ''; $('search').value = ''; render(); $('search').focus(); });
$('edit-open').addEventListener('click', () => {
  const item = currentItem(managedItem); if (!item) return;
  $('item-dialog').close(); loadEdit(item); $('edit-dialog').showModal(); $('edit-name').focus();
});
$('edit-reload').addEventListener('click', () => { const item = currentItem(editItem); if (item) { notice(''); loadEdit(item); $('edit-name').focus(); } });
$('edit-form').addEventListener('submit', e => {
  e.preventDefault(); if (busy || $('edit-save').disabled) return;
  const name = $('edit-name').value.trim();
  if (!name) { notice('請輸入品項名稱，不能只有空白。'); $('edit-name').focus(); return; }
  const args = {p_item_id:editItem.id, p_version:editItem.version, p_name:name, p_category:$('edit-category').value};
  if (snapshot.schema_version >= 3) args.p_source_ids = chosenSources('edit-sources');
  manageMutation(snapshot.schema_version >= 3 ? 'restock_update_item_with_sources' : 'restock_update_item', args, $('edit-dialog'), '品項已更新，補貨紀錄保持不變。');
});
$('delete-open').addEventListener('click', () => {
  const item = currentItem(managedItem); if (!item) return;
  deleteItem = { ...item }; $('delete-name').textContent = item.name;
  $('item-dialog').close(); updateDialogState(); $('delete-dialog').showModal();
  $('delete-dialog').querySelector('[data-close]').focus();
});
$('delete-confirm').addEventListener('click', () => {
  if (busy || $('delete-confirm').disabled) return;
  manageMutation('restock_delete_item', {p_item_id:deleteItem.id,p_version:deleteItem.version}, $('delete-dialog'), '已從目前用品移除，補貨歷史已保留。');
});
$('item-history').addEventListener('click', () => { const item = currentItem(managedItem); if (item) { $('item-dialog').close(); showHistory(item); } });
$('cancel-low').addEventListener('click', () => { const item = currentItem(managedItem); if (item) { $('item-dialog').close(); mutate(item, 'normal'); } });
for (const dialog of document.querySelectorAll('dialog')) dialog.addEventListener('cancel', e => { if (busy) e.preventDefault(); });
async function mutate(item, operation) {
  await run(null, async () => {
    // 無樂觀更新：伺服器確認成功後才移動品項。
    try { await api.rpc('restock_change_item', { p_item_id:item.id, p_version:item.version, p_operation:operation }); }
    catch (e) { await refresh().catch(() => {}); throw e; }
    await refresh(); notice(operation === 'restock' ? '已補貨，也記下這次日期了。' : operation === 'low' ? '已加入待購清單。' : '已取消待購。');
  });
}
async function adjustQuantity(item, quantity) {
  if (!Number.isInteger(quantity) || quantity < 1 || quantity > 999) return;
  await itemFeedback('restock_set_purchase_quantity',item,{p_quantity:quantity},'');
}
async function snooze(item) {
  await itemFeedback('restock_snooze_item',item,{},'已記下還很多，7 天後再評估；沒有新增補貨紀錄。');
}
async function itemFeedback(rpc,item,args,success) {
  await run(null,async () => {
    try { await api.rpc(rpc,{p_item_id:item.id,p_version:item.version,...args}); }
    catch (e) { await refresh().catch(() => {}); throw e; }
    await refresh(); notice(success);
  });
}
$('login-form').addEventListener('submit', e => {
  e.preventDefault(); const data = new FormData(e.target);
  run(e.submitter, async () => { await api.login(data.get('email').trim(), data.get('password')); e.target.reset(); generation++; view(); await refresh(); });
});
$('household').addEventListener('change', e => { selected = e.target.value; sourceFilter = ''; render(); });
$('refresh').addEventListener('click', e => run(e.target, refresh));
$('account-button').addEventListener('click', () => $('account-dialog').showModal());
$('add-open').addEventListener('click', () => { renderSourcePicker('add-sources', []); $('add-dialog').showModal(); $('add-form').elements.name.focus(); });
document.querySelectorAll('[data-close]').forEach(b => b.addEventListener('click', () => b.closest('dialog').close()));
$('add-form').addEventListener('submit', e => {
  e.preventDefault(); const data = new FormData(e.target); const name = data.get('name').trim();
  if (!name) return;
  run(e.submitter, async () => {
    const args = { p_household_id:selected, p_name:name, p_category:data.get('category'), p_low:data.has('low') };
    if (snapshot.schema_version >= 3) args.p_source_ids = chosenSources('add-sources');
    await api.rpc(snapshot.schema_version >= 3 ? 'restock_add_item_with_sources' : 'restock_add_item', args);
    e.target.reset(); $('add-dialog').close(); await refresh(); notice('已新增常用品。');
  });
});
$('house-form').addEventListener('submit', e => {
  e.preventDefault(); const name = new FormData(e.target).get('name').trim(); if (!name) return;
  run(e.submitter, async () => { selected = await api.rpc('life_create_household', { p_name:name }); e.target.reset(); await refresh(); $('account-dialog').close(); notice('家庭已建立，可以開始新增常用品。'); });
});
$('logout').addEventListener('click', e => run(e.target, async () => {
  generation++;
  try { await api.logout(); } finally { snapshot = { households:[], items:[], history:[] }; selected=''; render(); view(); $('account-dialog').close(); }
}));
const backgroundRefresh = () => { if (!document.hidden && !busy && api.session()) refresh().catch(e => notice(message(e))); };
setInterval(backgroundRefresh, 10000);
document.addEventListener('visibilitychange', backgroundRefresh);
window.addEventListener('online', backgroundRefresh);
window.addEventListener('storage', e => { if (e.key === api.storageKey) { generation++; snapshot = { households:[], items:[], history:[] }; render(); view(); backgroundRefresh(); } });
const validUrl = /^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(config.supabaseUrl);
// 僅接受公開 publishable key；刻意不接受可繞過 RLS 的 secret/service-role 金鑰。
if (!validUrl || !config.supabaseKey.startsWith('sb_publishable_')) $('setup').hidden = false;
else { view(); backgroundRefresh(); }
