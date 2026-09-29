import { config } from './config.js';
import { Backend } from './api.mjs';
import { estimate } from './cycle.mjs';

const $ = id => document.getElementById(id);
const api = new Backend(config);
let snapshot = { households: [], items: [], history: [] };
let selected = '', loading = false, busy = false, generation = 0;
let refreshTask = null;
const date = value => new Intl.DateTimeFormat('zh-TW', { month: 'numeric', day: 'numeric', year: 'numeric' }).format(new Date(value));
function notice(message) {
  $('notice').textContent = message; $('notice').hidden = !message;
  document.querySelectorAll('.dialog-error').forEach(n => n.remove());
  const dialog = document.querySelector('dialog[open]');
  if (message && dialog) { const error = el('p', 'notice dialog-error', message); error.setAttribute('role','alert'); dialog.prepend(error); }
}
function message(e) {
  if (e.message.includes('STALE_ITEM')) return '家人已更新這個品項，已重新讀取；請確認最新狀態。';
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
}
function render() {
  const previous = selected;
  if (!snapshot.households.some(h => h.id === selected)) selected = snapshot.households[0]?.id || '';
  $('household').replaceChildren(...snapshot.households.map(h => { const opt = el('option', '', h.name); opt.value = h.id; return opt; }));
  $('household').value = selected;
  $('house-id').value = selected;
  $('house-title').textContent = snapshot.households.find(h => h.id === selected)?.name || '家裡的常用品';
  $('no-house').hidden = !!selected; $('lists').hidden = !selected; $('add-open').hidden = !selected;
  if (previous !== selected && $('add-dialog').open) $('add-dialog').close();
  const groups = { low: [], possible: [], normal: [] };
  for (const item of snapshot.items.filter(i => i.household_id === selected)) groups[estimate(item, snapshot.history).status].push(item);
  for (const [status, items] of Object.entries(groups)) {
    $(''+status+'-count').textContent = items.length;
    const container = $(status+'-list'); container.replaceChildren();
    items.sort((a,b) => a.name.localeCompare(b.name, 'zh-Hant'));
    for (const item of items) container.append(card(item));
    if (!items.length) container.append(el('p', 'empty', {low:'目前沒有待購品項，家裡都準備好了。',possible:'有足夠補貨紀錄後，會在這裡提醒你。',normal:'把經常買的用品加進來，下次一鍵記下。'}[status]));
  }
}
function action(label, style, handler) { const b = el('button', style, label); b.type = 'button'; b.addEventListener('click', handler); b.disabled = busy; return b; }
function card(item) {
  const cycle = estimate(item, snapshot.history);
  const node = el('article', 'item');
  const info = el('div'); info.append(el('span', 'category', item.category), el('h3', '', item.name));
  info.append(el('p', 'meta', cycle.last ? `上次補貨 ${date(cycle.last)}` : '尚未記錄補貨'));
  if (cycle.average !== null) info.append(el('p', 'meta', `約 ${Math.round(cycle.average)} 天補一次${cycle.samples === 1 ? ' · 初步估計' : ''}`));
  const actions = el('div', 'item-actions');
  actions.append(action('紀錄', 'quiet', () => showHistory(item)));
  if (item.status === 'low') {
    actions.append(action('取消待購', 'quiet', () => mutate(item, 'normal')));
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
  finally { busy = false; document.querySelectorAll('button').forEach(b => b.disabled = false); }
}
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
