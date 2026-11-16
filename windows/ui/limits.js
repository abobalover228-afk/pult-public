import { call, on, h } from './core.js';
import { button } from './render.js';
import roadmap from './roadmap.js';
const root = document.querySelector('#limits-app');
const label = window.__TAURI__.window.getCurrentWindow().label;
let state = {}, error = '';
window.addEventListener('pult-error', e => { error = e.detail; render(); });
window.addEventListener('unhandledrejection', e => { e.preventDefault(); error = String(e.reason); render(); });
const action = (name, args = {}) => call('limits', name, args);
const reset = ts => ts ? `Сброс ${new Date(ts * 1000).toLocaleString('ru', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })}` : 'Время сброса неизвестно';
function quota(name, remaining, ts) {
  const known = Number.isFinite(remaining), value = known ? Math.min(100, Math.max(0, remaining)) : 0, low = value < 15;
  const bar = h('span', { class: low ? 'low' : '' }); bar.style.width = `${value}%`;
  return h('div.quota-row', {}, h('div.quota-top', {}, h('span', {}, name), h(`strong${low ? '.low' : ''}`, {}, known ? `${Math.round(value)}%` : '—')),
    h('div.quota-bar', { role: 'meter', 'aria-label': name, 'aria-valuemin': 0, 'aria-valuemax': 100, ...(known && { 'aria-valuenow': value }) }, bar), h('div.quota-reset', {}, reset(ts)));
}
function account(a) {
  const card = h('section.limit-card', {}, h('h3', {}, a.name), h('span.plan', {}, a.plan || 'Codex'));
  if (!a.available) card.append(h('p.limit-error', {}, a.error || 'Остаток неизвестен'));
  for (const l of a.limits || []) for (const w of l.windows || []) card.append(quota(`${l.name} · ${w.minutes >= 10000 ? 'неделя' : w.minutes ? `${w.minutes / 60}ч` : w.kind}`, w.remaining_percent, w.resets_at));
  if (label === 'accounts') card.append(h('div.limits-actions', {}, button('Открыть Codex', () => action('open', { home: a.home })), button('Войти', () => action('login', { home: a.home }))));
  return card;
}
function render() {
  if (label === 'map') return renderMap();
  const head = h('header', {}, h('strong', {}, label === 'accounts' ? 'Аккаунты' : '◫ Лимиты'), button(state.loading ? '…' : '↻', () => action('refresh')));
  if (label === 'limits') head.ondblclick = () => action('pult');
  if (label === 'limits') head.onpointerdown = e => { if (!e.target.closest('button')) action('drag'); };
  root.replaceChildren(head);
  if (error) root.append(h('p.limit-error', { role: 'alert' }, error));
  const rows = state.codex?.accounts || [];
  root.append(...(rows.length ? rows : (state.names || []).map(a => ({ ...a, error: state.loading ? 'Получаем лимиты…' : 'Нет данных' }))).map(account));
  let claude;
  try { claude = typeof state.claude === 'string' ? JSON.parse(state.claude) : state.claude; } catch {}
  const card = h('section.limit-card', {}, h('h3', {}, 'Claude'), h('span.plan', {}, 'Локальная квота Claude Code'));
  if (claude?.rate_limits && Object.keys(claude.rate_limits).length) {
    for (const [key, row] of Object.entries(claude.rate_limits)) card.append(quota(key === 'five_hour' ? '5 часов' : 'Неделя', typeof row.used_percentage === 'number' ? 100 - row.used_percentage : null, row.resets_at));
    const age = Math.round((Date.now() / 1000 - claude.saved_at) / 60); card.append(h('small', {}, age > 15 ? `Данные устарели: ${age} мин назад` : 'Из статусной строки'));
  } else card.append(h('p.limit-error', {}, 'Нет данных. Подключи статусную строку Claude Code: pult --statusline.'));
  root.append(card, h('div.limits-footer', {}, button('Пульт', () => action('pult')), button('Аккаунты', () => action('accounts')), button('Команды', () => action('map'))));
  if (label === 'accounts') root.append(h('div.limits-actions', {}, button('+ Аккаунт', () => action('add')), button('Codex авто', () => action('auto'))));
  if (state.codex?.updated) root.append(h('small', {}, `Обновлено ${new Date(state.codex.updated).toLocaleTimeString('ru')}`));
}
function renderMap() {
  const list = h('div'), input = h('input', { placeholder: 'Поиск по командам', 'aria-label': 'Поиск команд' });
  function filter() {
    const q = input.value.toLowerCase();
    list.replaceChildren(...roadmap.filter(r => `${r.name} ${r.meaning} ${r.provider} ${r.detail}`.toLowerCase().includes(q)).map(r => h('article.limit-card', {},
      h('code', {}, r.syntax || r.name), h('strong', {}, `${r.provider} · ${r.meaning}`), h('small', {}, r.detail), h('small', {}, `Статус оригинальной macOS-версии: ${r.status}`))));
  }
  input.oninput = filter; root.className = 'command-map'; root.replaceChildren(h('h2', {}, 'Карта команд'), h('p.limit-error', {}, 'Справочник оригинала. Наличие команды здесь не означает, что она уже перенесена в Windows.'), input, list); filter();
}
async function update() { state = await action('state'); render(); }
await on('limits', update); await update(); await call('app', 'ready', { label });
