import { call, on, h } from './core.js';
import { button, rings, tone } from './render.js';
import roadmap from './roadmap.js';
const root = document.querySelector('#limits-app');
const label = window.__TAURI__.window.getCurrentWindow().label;
let state = {}, error = '';
window.addEventListener('pult-error', e => { error = e.detail; render(); });
window.addEventListener('unhandledrejection', e => { e.preventDefault(); error = String(e.reason); render(); });
const action = (name, args = {}) => call('limits', name, args);
// Сколько до сброса — по-человечески: «через 2 ч 14 мин», «завтра 09:40».
function until(ts) {
  if (!ts) return 'сброс неизвестен';
  const left = ts * 1000 - Date.now();
  if (left <= 0) return 'уже сброшен';
  const m = Math.round(left / 60000);
  if (m < 60) return `сброс через ${m} мин`;
  if (m < 24 * 60) return `сброс через ${Math.floor(m / 60)} ч ${m % 60 ? (m % 60) + ' мин' : ''}`.trim();
  return 'сброс ' + new Date(ts * 1000).toLocaleString('ru', { weekday: 'short', hour: '2-digit', minute: '2-digit' });
}
const windowName = w => w.minutes >= 10000 ? 'Неделя' : w.minutes ? `${Math.round(w.minutes / 60)} ч` : w.kind;
function bar(label, remaining, ts) {
  const known = Number.isFinite(remaining), value = known ? Math.min(100, Math.max(0, remaining)) : 0;
  const fill = h('i'); requestAnimationFrame(() => { fill.style.width = `${value}%`; });
  return h('div.lw-bar.' + tone(remaining), { title: until(ts) },
    h('div.lw-bar-top', {}, h('span', {}, label), h('b', {}, known ? `${Math.round(value)}%` : '—')),
    h('div.lw-track', { role: 'meter', 'aria-label': label, 'aria-valuemin': 0, 'aria-valuemax': 100, ...(known && { 'aria-valuenow': value }) }, fill),
    h('small', {}, until(ts)));
}
// Кольцо с минимальным остатком — главное число аккаунта.
function ring(remaining) {
  const known = Number.isFinite(remaining), value = known ? Math.min(100, Math.max(0, remaining)) : 0, r = 15, c = 2 * Math.PI * r;
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg'); svg.setAttribute('viewBox', '0 0 36 36'); svg.classList.add('lw-ring', tone(remaining));
  svg.innerHTML = `<circle cx="18" cy="18" r="${r}" class="bg"/><circle cx="18" cy="18" r="${r}" class="fg" stroke-dasharray="${c}" stroke-dashoffset="${c}"/><text x="18" y="21.5">${known ? Math.round(value) : '—'}</text>`;
  requestAnimationFrame(() => svg.querySelector('.fg').style.strokeDashoffset = String(c * (1 - value / 100)));
  return svg;
}
const lowest = a => { const v = (a.limits || []).flatMap(l => (l.windows || []).map(w => w.remaining_percent)).filter(Number.isFinite); return v.length ? Math.min(...v) : NaN; };
function account(a, best) {
  const left = lowest(a), reached = (a.limits || []).some(l => (l.windows || []).some(w => w.remaining_percent === 0));
  const card = h('section.lw-card' + (a.name === best ? '.best' : '') + (reached ? '.out' : ''), {},
    h('div.lw-head', {}, ring(left), h('div.lw-title', {}, h('h3', {}, a.name), h('span', {}, [(a.plan || 'Codex').replace(/^./, c => c.toUpperCase()), a.name === best ? 'лучший сейчас' : reached ? 'лимит исчерпан' : ''].filter(Boolean).join(' · ')))));
  if (!a.available) card.append(h('p.lw-error', {}, a.error || 'Остаток неизвестен'));
  for (const l of a.limits || []) {
    const extra = l.name && l.name !== 'codex';
    for (const w of l.windows || []) card.append(bar((extra ? l.name + ' · ' : '') + windowName(w), w.remaining_percent, w.resets_at));
    if (l.credits?.hasCredits || l.credits?.unlimited) card.append(h('small.lw-credits', {}, l.credits.unlimited ? 'Кредиты: без ограничений' : `Кредиты: ${l.credits.balance}`));
  }
  if (label === 'accounts') card.append(h('div.lw-actions', {}, button('Открыть Codex', () => action('open', { home: a.home })), button('Войти', () => action('login', { home: a.home }))));
  return card;
}
// ───────── док: кольца как у виджета «Аккумуляторы» ─────────
const pick = (a, long) => ((a.limits || []).find(l => !l.name || l.name.toLowerCase() === 'codex') || a.limits?.[0])?.windows?.find(w => long ? w.minutes >= 10000 : w.minutes < 10000);
function tile(name, five, week, sub, extra = '') {
  const vals = [five?.remaining_percent, week?.remaining_percent];
  const low = Math.min(...vals.filter(Number.isFinite));
  const t = h('button.dk-tile' + extra, { type: 'button' }, rings(vals[0], vals[1], Number.isFinite(low) ? Math.round(low) : '—'), h('span.dk-name', {}, name));
  t.title = `${name}${sub ? ' · ' + sub : ''}\n5 часов: ${Number.isFinite(vals[0]) ? Math.round(vals[0]) + '%' : '—'} · ${until(five?.resets_at)}\nНеделя: ${Number.isFinite(vals[1]) ? Math.round(vals[1]) + '%' : '—'} · ${until(week?.resets_at)}\nВнешнее кольцо — 5 часов, внутреннее — неделя`;
  t.onclick = () => action('pult');
  return t;
}
const withMenu = (t, a) => { t.oncontextmenu = e => { e.preventDefault(); e.stopPropagation(); action('tileMenu', { home: a.home, name: a.name, signedIn: a.available !== false }).catch(() => {}); }; return t; };
function renderDock() {
  document.documentElement.classList.add('dk-page'); document.body.className = 'dk-body';
  const rows = state.codex?.accounts || [];
  const list = rows.length ? rows : (state.names || []).map(a => ({ ...a, limits: [] }));
  const best = rows.filter(a => Number.isFinite(lowest(a))).sort((x, y) => lowest(y) - lowest(x))[0]?.name;
  let claude; try { claude = typeof state.claude === 'string' ? JSON.parse(state.claude) : state.claude; } catch {}
  const cl = k => { const r = claude?.rate_limits?.[k]; return r && { remaining_percent: typeof r.used_percentage === 'number' ? 100 - r.used_percentage : NaN, resets_at: r.resets_at }; };
  const glass = h('div.dk-glass' + (state.loading ? '.loading' : ''), {},
    ...list.map(a => withMenu(tile(a.name, pick(a, false), pick(a, true), a.plan, (a.name === best ? '.best' : '') + (lowest(a) === 0 ? '.out' : '')), { ...a, home: a.home || (state.names || []).find(n => n.name === a.name)?.home })),
    claude?.rate_limits ? tile('Claude', cl('five_hour'), cl('seven_day'), 'Claude Code', '.claude') : null);
  glass.append(h('button.dk-hide', { type: 'button', title: 'Скрыть виджет', onclick: () => action('toggle') }, '×'));
  glass.onpointerdown = e => { if (e.button === 0 && !e.target.closest('button')) action('drag'); };
  glass.ondblclick = e => { if (!e.target.closest('.dk-tile')) action('dock'); };
  glass.oncontextmenu = e => { e.preventDefault(); action('menu'); };
  glass.title = 'Перетащи, чтобы сдвинуть. Двойной щелчок — вернуть вниз по центру. Правый щелчок по кольцу — действия с аккаунтом';
  root.replaceChildren(glass);
  if (error) glass.append(h('span.dk-error', { title: error }, '!'));
  requestAnimationFrame(() => action('fit', { width: Math.ceil(glass.getBoundingClientRect().width), height: Math.ceil(glass.getBoundingClientRect().height) }).catch(() => {}));
}

// ───────── окно «Аккаунты»: список и вход по коду ─────────
let profiles = [], login = null, renaming = null, browsers = { selected: "auto", items: [] };
async function loadProfiles() { const rows = await call('accounts', 'list').catch(() => null); profiles = Array.isArray(rows) ? rows : []; browsers = (await call('accounts', 'browsers').catch(() => null)) || browsers; }
const copyText = text => navigator.clipboard.writeText(text).catch(() => { const a = h('textarea', { value: text }); document.body.append(a); a.select(); document.execCommand('copy'); a.remove(); });
async function startLogin(home) {
  login = { stage: 'start', home }; render();
  try { const r = await call('accounts', 'login', home ? { home } : {}); login = { ...login, id: r.id }; }
  catch (e) { login = { stage: 'error', message: String(e) }; }
  render();
}
on('accounts', async e => {
  if (!login || e.id !== login.id) return;
  if (e.stage === 'code') {
    // Самое удобное: код сразу в буфере, страница входа сразу открыта — остаётся вставить.
    login = { ...login, ...e }; await copyText(e.code);
    const opened = await call('accounts', 'openPrivate', { url: e.url }).catch(e => { login.browserError = String(e); return null; }); login.browser = opened?.browser; login.private = opened?.private;
  } else if (e.stage === 'done') { login = { ...login, ...e }; await loadProfiles(); action('refresh').catch(() => {}); }
  else if (e.stage === 'error') login = { ...login, ...e };
  render();
});
function loginSheet() {
  const close = () => { if (login?.id && !['done', 'error'].includes(login.stage)) call('accounts', 'cancel', { id: login.id }); login = null; render(); };
  const body = [];
  if (login.stage === 'start') body.push(h('div.ac-wait', {}, h('span.ac-spin'), 'Запрашиваю код входа…'));
  if (login.stage === 'code') body.push(
    h('div.ac-step', {}, h('span.ac-num', {}, '1'), h('div', {}, h('strong', {}, 'Страница входа'), h('small', {}, login.browser ? `Открыта ${login.private ? "в приватном окне" : "в обычном окне"} ${login.browser}. Войди нужным аккаунтом ChatGPT.` : (login.browserError || 'Скопируй ссылку в приватное окно браузера.')),
      h('div.ac-link', {}, h('code', {}, login.url.replace(/^https:\/\//, '')), button('Открыть снова', async () => { const r = await call('accounts', 'openPrivate', { url: login.url }); login.browser = r?.browser; login.private = r?.private; render(); }), button('Обычно', () => action('url', { url: login.url })), button('Копировать', () => copyText(login.url))))),
    h('div.ac-step', {}, h('span.ac-num', {}, '2'), h('div', {}, h('strong', {}, 'Код'), h('small', {}, 'Уже в буфере обмена — просто вставь на странице. Действует 15 минут.'),
      h('div.ac-code', {}, ...[...login.code].map(c => h(c === '-' ? 'i' : 'b', {}, c === '-' ? '' : c)), button('Копировать', () => copyText(login.code))))),
    h('div.ac-wait', {}, h('span.ac-spin'), 'Жду, пока подтвердишь в браузере — аккаунт добавится сам'));
  if (login.stage === 'done') body.push(h('div.ac-done', {}, h('span.ac-check', {}, '✓'), h('div', {}, h('strong', {}, login.duplicate ? 'Этот вход уже есть' : 'Готово'),
    h('small', {}, login.duplicate ? `${login.email} уже подключён как «${login.duplicate}». Два одинаковых аккаунта делят один лимит, второй не добавлен.` : [login.name, login.email, login.plan && String(login.plan).replace(/^./, c => c.toUpperCase())].filter(Boolean).join(' · ')))));
  if (login.stage === 'error') body.push(h('div.ac-done.bad', {}, h('span.ac-check', {}, '!'), h('div', {}, h('strong', {}, 'Не получилось'), h('small', {}, login.message || 'Вход не завершён'))), button('Ещё раз', () => startLogin(login.home), 'primary'));
  return h('div.ac-sheet', {}, h('div.ac-card', {}, h('header', {}, h('strong', {}, login.home ? 'Вход в аккаунт' : 'Новый аккаунт'), button(['done', 'error'].includes(login.stage) ? 'Готово' : 'Отмена', close)), ...body));
}
async function takeUi() {
  const job = await action('takeUi').catch(() => null); if (!job) return;
  if (job.action === 'add') return startLogin(null);
  if (job.action === 'login') return startLogin(job.home);
  if (job.action === 'rename') { renaming = job.home; render(); }
}
if (label === 'accounts') { on('accounts-ui', () => takeUi()); setTimeout(takeUi, 300); }
function renderAccounts() {
  document.body.className = 'ac-body';
  const rows = state.codex?.accounts || [];
  const list = h('div.ac-list', {}, ...profiles.map((p, i) => {
    const a = rows.find(r => r.home === p.home || r.name === p.name) || { limits: [] };
    const five = pick(a, false), week = pick(a, true);
    const name = renaming === p.home ? h('input.ac-rename', { value: p.name, maxLength: 40, onkeydown: async e => {
      if (e.key === 'Escape') { renaming = null; render(); }
      if (e.key === 'Enter') { try { await call('accounts', 'rename', { home: p.home, name: e.target.value }); renaming = null; await loadProfiles(); render(); } catch (err) { error = String(err); render(); } } } }) : h('strong', { ondblclick: () => { renaming = p.home; render(); } }, p.name);
    const menu = h('select.ac-more', { title: 'Ещё', onchange: async e => {
      const v = e.target.value; e.target.value = '';
      try {
        if (v === 'rename') { renaming = p.home; return render(); }
        if (v === 'login') return startLogin(p.home);
        if (v === 'up' || v === 'down') await call('accounts', 'move', { home: p.home, step: v === 'up' ? -1 : 1 });
        if (v === 'remove' && confirm(`Убрать «${p.name}» из списка? Папка аккаунта и вход останутся на диске.`)) await call('accounts', 'remove', { home: p.home });
        if (v === 'open') await action('open', { home: p.home });
        await loadProfiles(); render();
      } catch (err) { error = String(err); render(); }
    } }, h('option', { value: '' }, '⋯'), h('option', { value: 'rename' }, 'Переименовать'), h('option', { value: 'login' }, 'Войти заново'), h('option', { value: 'open' }, 'Открыть Codex в Терминале'),
      i > 0 ? h('option', { value: 'up' }, 'Выше') : null, i < profiles.length - 1 ? h('option', { value: 'down' }, 'Ниже') : null, profiles.length > 1 ? h('option', { value: 'remove' }, 'Убрать из списка…') : null);
    const twin = p.email && profiles.slice(0, i).find(x => x.email === p.email);
    return h('article.ac-row' + (p.signedIn ? '' : '.off'), {},
      rings(five?.remaining_percent, week?.remaining_percent, p.signedIn ? (Number.isFinite(lowest(a)) ? Math.round(lowest(a)) : '…') : '—'),
      h('div.ac-info', {}, name,
        h('small', {}, p.signedIn ? [p.email || 'вход выполнен', p.plan && String(p.plan).replace(/^./, c => c.toUpperCase())].filter(Boolean).join(' · ') : 'Нет входа'),
        twin ? h('small.ac-warn', {}, `Тот же вход, что «${twin.name}» — лимит общий`) : null,
        p.signedIn ? h('small.ac-reset', {}, `5 ч: ${until(five?.resets_at)} · неделя: ${until(week?.resets_at)}`) : null),
      p.signedIn ? null : button('Войти', () => startLogin(p.home), 'primary'), menu);
  }));
  root.replaceChildren(...[h('header.ac-head', {}, h('div', {}, h('strong', {}, 'Аккаунты Codex'), h('small', {}, `${profiles.length} · кольца: снаружи 5 часов, внутри неделя`)),
    button('↻', async () => { await loadProfiles(); action('refresh'); }, 'lw-icon'), button('+ Добавить аккаунт', () => startLogin(null), 'primary')),
    h('label.ac-hint', {}, 'Браузер для входа: ', h('select', { 'aria-label': 'Браузер для входа', onchange: async e => { try { await call('accounts', 'browser', { name: e.target.value }); browsers.selected = e.target.value; } catch (err) { error = String(err); render(); } } }, ...[{ name: 'auto', label: 'Авто — Chrome инкогнито, иначе по умолчанию' }, { name: 'default', label: 'По умолчанию — обычное окно' }, ...browsers.items.map(b => ({ name: b.name, label: b.name + (b.private ? ' — приватное окно' : ' — обычное окно') }))].map(b => h('option', { value: b.name, selected: b.name === (browsers.selected || 'auto') }, b.label)))),
    error ? h('p.lw-error', {}, error) : null, list,
    h('p.ac-hint', {}, 'Двойной щелчок по имени — переименовать. Вход идёт через официальный codex login: Пульт сам откроет страницу и положит код в буфер.'),
    login ? loginSheet() : null].filter(Boolean));
}
function render() {
  if (label === 'map') return renderMap();
  if (label === 'limits') return renderDock();
  return renderAccounts();
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
async function update() { state = await action('state'); if (label === 'accounts') await loadProfiles(); render(); }
setInterval(() => { if (label !== 'map') render(); }, 60000);   // «через N мин» не стоит на месте
await on('limits', update); await update(); await call('app', 'ready', { label });
