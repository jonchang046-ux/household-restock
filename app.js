import { config } from './config.js';
import { Backend } from './api.mjs';
import { estimate } from './cycle.mjs';
import { categories, selectItems } from './list.mjs';

const $ = id => document.getElementById(id);
const api = new Backend(config);
let snapshot = { households: [], items: [], history: [] };
let selected = '', loading = false, busy = false, generation = 0;
let refreshTask = null;
let searchText = '', categoryFilter = '', managedItem = null, editItem = null, deleteItem = null;
const date = value => new Intl.DateTimeFormat('zh-TW', { month: 'numeric', day: 'numeric', year: 'numeric' }).format(new Date(value));
function notice(message) {
  $('notice').textContent = message; $('notice').hidden = !message;
  document.querySelectorAll('.dialog-error').forEach(n => n.remove());
  const dialog = document.querySelector('dialog[open]');
  if (message && dialog) { const error = el('p', 'notice dialog-error', message); error.setAttribute('role','alert'); dialog.prepend(error); }
}
function message(e) {
  if (e.message.includes('STALE_ITEM')) return '家人已更新這個品項，已重新讀取；請確認最新狀態。';
  if (e.message.includes('ITEM_ARCHIVED')) return '這個品項已被刪除，歷史仍保留。請關閉視窗查看最新清單。';
  if (e.message.includes('INVALID_NAME')) return '請輸入 1 到 80 個字的品項名稱。';
  if (e.message.includes('INVALID_CATEGORY')) return '請選擇有效的分類。';
  if (e.code === 'PGRST202') return '品項管理功能尚未啟用，請管理者確認 v2 migration 已成功執行。';
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
  if (previous !== selected) document.querySelectorAll('dialog[open]').forEach(d => d.close());
  const {groups, total, shown, filtered} = selectItems(snapshot, selected, searchText, categoryFilter);
  $('filter-summary').textContent = filtered ? `找到 ${shown} 項／共 ${total} 項${shown === 0 ? '，試試其他名稱或清除篩選。' : ''}` : `共 ${total} 項常用品`;
  for (const button of $('category-filters').children) button.setAttribute('aria-pressed', String(button.dataset.category === categoryFilter));
  for (const [status, items] of Object.entries(groups)) {
    $(''+status+'-count').textContent = items.length;
    const container = $(status+'-list'); container.replaceChildren();
    for (const item of items) container.append(card(item));
    if (!items.length) container.append(el('p', 'empty', filtered ? '此區沒有符合篩選的品項。' : {low:'目前沒有待購品項，家裡都準備好了。',possible:'有足夠補貨紀錄後，會在這裡提醒你。',normal:'把經常買的用品加進來，下次一鍵記下。'}[status]));
  }
  updateDialogState();
}
function action(label, style, handler) { const b = el('button', style, label); b.type = 'button'; b.addEventListener('click', handler); b.disabled = busy; return b; }
function card(item) {
  const cycle = estimate(item, snapshot.history);
  const node = el('article', 'item');
  const info = el('div', 'item-info'); info.append(el('span', 'category', item.category), el('h3', '', item.name));
  info.append(el('p', 'meta', cycle.last ? `上次補貨 ${date(cycle.last)}` : '尚未記錄補貨'));
  if (cycle.average !== null) info.append(el('p', 'meta', `約 ${Math.round(cycle.average)} 天補一次${cycle.samples === 1 ? ' · 初步估計' : ''}`));
  const actions = el('div', 'item-actions');
  const more = action('⋯', 'quiet item-more', () => openItemMenu(item));
  more.setAttribute('aria-label', `${item.name}的更多操作`);
  more.setAttribute('aria-haspopup', 'dialog');
  node.append(more);
  if (item.status === 'low') {
    actions.append(action('✓ 已補貨', 'primary', () => mutate(item, 'restock')));
  } else {
    actions.append(action('已補貨', 'secondary', () => mutate(item, 'restock')));
    actions.append(action('快沒了', 'primary', () => mutate(item, 'low')));
  }
  node.append(info, actions); return node;
}
function showHistory(item) {
  $('history-title').textContent = `${item.name}・補貨紀錄`;
  const cycle = estimate(item, snapshot.history);
  $('history-summary').textContent = cycle.average === null ? '至少需要兩個不同日期的補貨紀錄，才能估計週期。' : `平均約 ${Math.round(cycle.average)} 天，根據 ${cycle.samples} 段間隔估計。經過平均週期的 80% 時提醒，不會自動加入待購。`;
  const rows = snapshot.history.filter(h => h.item_id === item.id).sort((a,b) => b.restocked_at.localeCompare(a.restocked_at));
  $('history-list').replaceChildren(...rows.map(h => el('li', 'history-row', new Date(h.restocked_at).toLocaleString('zh-TW'))));
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
function updateDialogState() {
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
for (const category of ['', ...categories]) {
  const button = action(category || '全部', 'category-chip', () => { categoryFilter = category; render(); });
  button.dataset.category = category; button.setAttribute('aria-pressed', String(category === ''));
  $('category-filters').append(button);
}
$('search').addEventListener('input', e => { searchText = e.target.value; render(); });
$('clear-filters').addEventListener('click', () => { searchText = ''; categoryFilter = ''; $('search').value = ''; render(); $('search').focus(); });
$('edit-open').addEventListener('click', () => {
  const item = currentItem(managedItem); if (!item) return;
  $('item-dialog').close(); loadEdit(item); $('edit-dialog').showModal(); $('edit-name').focus();
});
$('edit-reload').addEventListener('click', () => { const item = currentItem(editItem); if (item) { notice(''); loadEdit(item); $('edit-name').focus(); } });
$('edit-form').addEventListener('submit', e => {
  e.preventDefault(); if (busy || $('edit-save').disabled) return;
  const name = $('edit-name').value.trim();
  if (!name) { notice('請輸入品項名稱，不能只有空白。'); $('edit-name').focus(); return; }
  manageMutation('restock_update_item', {p_item_id:editItem.id, p_version:editItem.version, p_name:name, p_category:$('edit-category').value}, $('edit-dialog'), '品項已更新，補貨紀錄保持不變。');
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
$('login-form').addEventListener('submit', e => {
  e.preventDefault(); const data = new FormData(e.target);
  run(e.submitter, async () => { await api.login(data.get('email').trim(), data.get('password')); e.target.reset(); generation++; view(); await refresh(); });
});
$('household').addEventListener('change', e => { selected = e.target.value; render(); });
$('refresh').addEventListener('click', e => run(e.target, refresh));
$('account-button').addEventListener('click', () => $('account-dialog').showModal());
$('add-open').addEventListener('click', () => { $('add-dialog').showModal(); $('add-form').elements.name.focus(); });
document.querySelectorAll('[data-close]').forEach(b => b.addEventListener('click', () => b.closest('dialog').close()));
$('add-form').addEventListener('submit', e => {
  e.preventDefault(); const data = new FormData(e.target); const name = data.get('name').trim();
  if (!name) return;
  run(e.submitter, async () => {
    await api.rpc('restock_add_item', { p_household_id:selected, p_name:name, p_category:data.get('category'), p_low:data.has('low') });
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
