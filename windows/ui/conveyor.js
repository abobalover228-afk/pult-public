// Конвейер: сильная модель раскладывает эпик на волны, дешёвые делают задачи волны параллельно
// (каждая в своём worktree), два ревьюера на разных моделях проверяют diff, волна сливается и проверяется,
// следующая стартует от слитого результата. В рабочую ветку эпик вливается только по кнопке.
import { call, ui, h, settings } from './core.js';
import { button } from './render.js';
import { sphere } from './sphere.js';

const ROLES = { planner: 'План', worker: 'Работа', review1: 'Ревью 1', review2: 'Ревью 2' };
const DEFAULT_ROLES = { planner: { target: 'claude', model: 'opus' }, worker: { target: 'codex', model: '' }, review1: { target: 'claude', model: 'sonnet' }, review2: { target: 'codex', model: '' } };
const TASK = { queued: 'В очереди', working: 'Работает', review: 'На ревью', fixing: 'Правки', done: 'Готово', needsYou: 'Нужен ты', skipped: 'Пропущена' };
const EPIC = { draft: 'Черновик', planning: 'Планирую', planned: 'План готов', running: 'Едет', paused: 'Пауза', needsYou: 'Нужен ты', review: 'Приёмка', done: 'Принят' };
const MAX_ROUNDS = 2;
let epics = [], selected = null, lessons = {}, root = null, timer = 0, saving = 0;
const expandedHistory = new Set();
const viewedWave = new Map();
const closing = new Set();   // волна закрывается одной цепочкой, даже если две задачи доделались разом

const uuid = () => crypto.randomUUID();
const now = () => Date.now();
const epicOf = id => epics.find(e => e.id === id);
const tasks = e => e.waves.flatMap(w => w.tasks);
const chatOf = id => id && ui.chats.list().find(c => c.id === id);
const modelName = r => (r.model || 'по умолчанию') + ' · ' + (r.target === 'claude' ? 'Claude' : r.target === 'codex' ? 'Codex' : 'API');
const block = (text, tag) => new RegExp('```' + tag + '\\s*([\\s\\S]*?)```').exec(text || '')?.[1]?.trim();
const turnText = c => { const i = c.messages.map(m => m.kind).lastIndexOf('user'); return c.messages.slice(i + 1).filter(m => m.kind === 'agent').map(m => m.text).join('\n'); };
const lessonsFor = e => (lessons[e.cwd] || []).slice(-15);
const lessonText = e => lessonsFor(e).length ? '\n\nУроки прошлых задач в этом проекте:\n' + lessonsFor(e).map(l => '- ' + l).join('\n') : '';

function log(e, text, kind = '') { e.log = [{ t: now(), text, kind }, ...(e.log || [])].slice(0, 60); }
function save() { clearTimeout(saving); saving = setTimeout(() => settings.set('conveyor', { epics, lessons }).catch(ui.toast), 250); redraw(); }
function notify(e, body) { call('app', 'notify', { title: 'Конвейер · ' + e.title, body }).catch(() => {}); }

// ───────── Агенты ─────────
function agent(e, role, cwd, title, extra = {}) {
  const r = e.roles[role === 'reviewer' ? extra.slot : role === 'fixer' ? 'worker' : role];
  const readOnly = role === 'planner' || role === 'reviewer';
  return ui.chats.open({ title, target: r.target, model: r.model, cwd, select: false, autoApprove: !readOnly && !!e.autoApprove,
    ...(readOnly && { sandbox: 'read-only' }), conveyor: { epic: e.id, role, task: extra.task, slot: extra.slot } });
}
const send = (chat, text) => ui.chats.send(text, { chat, literal: true });
const drop = chat => chat && setTimeout(() => ui.chats.close(chat).catch(() => {}), 50);

async function plan(e, feedback = '') {
  e.status = 'planning'; e.error = ''; log(e, feedback ? 'Перепланирую с учётом замечаний' : 'Планировщик раскладывает эпик на волны'); save();
  const chat = chatOf(e.plannerChat) || agent(e, 'planner', e.cwd, '⛭ План: ' + e.title); e.plannerChat = chat.id;
  await send(chat, feedback ? `Поправь план:\n${feedback}\n\nОтветь тем же блоком pult-waves целиком.` : `Ты планировщик конвейера Пульта. Цель эпика:\n${e.goal}\n
Изучи репозиторий (только чтение, ничего не меняй) и разбей цель на волны задач.
Правила: задачи одной волны независимы и не правят одни и те же файлы; каждая следующая волна опирается на результат предыдущей; задача — 15–60 минут работы агента, с понятным критерием готовности. Не больше 8 волн и 6 задач в волне.
Ответь блоком:
\`\`\`pult-waves
[{"tasks":[{"title":"коротко","detail":"что сделать и как проверить"}]}]
\`\`\`${lessonText(e)}`);
}
function parsePlan(text) {
  let raw = JSON.parse(block(text, 'pult-waves'));
  if (!Array.isArray(raw)) raw = raw?.waves;
  const waves = (raw || []).slice(0, 8).map(w => ({ tasks: (Array.isArray(w) ? w : w?.tasks || []).slice(0, 6)
    .filter(t => typeof t?.title === 'string' && t.title.trim()).map(t => ({ id: uuid(), title: t.title.trim().slice(0, 160), detail: String(t.detail || '').slice(0, 4000), status: 'queued', round: 0, reviews: [] })) }))
    .filter(w => w.tasks.length);
  if (!waves.length) throw Error('Планировщик не прислал задач');
  return waves;
}

async function launch(e) {
  if (!tasks(e).length) throw Error('Нет задач');
  const started = await call('conveyor', 'start', { cwd: e.cwd, epic: e.id });
  Object.assign(e, { base: started.base, branch: started.branch, epicCwd: started.cwd, status: 'running', wave: e.wave || 0, started: e.started || now() });
  log(e, `Ветка ${started.branch} от ${started.base}. Едем`, 'ok'); drop(chatOf(e.plannerChat)); save(); pump(e);
}

/** Двигает конвейер: добирает задачи текущей волны до лимита параллельности или закрывает волну. */
function pump(e) {
  if (e.status !== 'running') return;
  const wave = e.waves[e.wave]; if (!wave) return;
  if (wave.tasks.every(t => ['done', 'skipped'].includes(t.status))) { closeWave(e).catch(err => problem(e, 'Волна', String(err))); return; }
  const active = wave.tasks.filter(t => ['working', 'review', 'fixing'].includes(t.status)).length;
  for (const t of wave.tasks.filter(t => t.status === 'queued').slice(0, Math.max(0, e.parallel - active))) work(e, t).catch(err => stuck(e, t, String(err)));
}

async function work(e, t, resume = false) {
  t.status = 'working'; t.note = ''; t.startedAt = t.startedAt || now(); save();
  const wt = await call('conveyor', 'task', { cwd: e.cwd, epic: e.id, task: t.id }); t.cwd = wt.cwd;
  const old = chatOf(t.chat), chat = old && !old.busy ? old : agent(e, 'worker', wt.cwd, `▸ ${t.title}`, { task: t.id }); t.chat = chat.id;
  log(e, `Взял: ${t.title} · ${modelName(e.roles.worker)}`); save();
  await send(chat, `Задача конвейера: волна ${e.wave + 1} из ${e.waves.length}, эпик «${e.title}».
Цель эпика: ${e.goal}

Твоя задача: ${t.title}
${t.detail}
${resume ? '\nЧасть работы уже есть в этой папке — посмотри git diff и продолжи.\n' : ''}
Работай только в этой папке: это отдельная ветка задачи. Не пушь и не трогай секреты. Коммитить не обязательно — после ревью коммит сделает Пульт.
В конце кратко опиши, что сделал, и, если узнал что-то полезное для следующих задач, добавь блок \`\`\`pult-lesson одна строка\`\`\`.${lessonText(e)}`);
}

async function review(e, t) {
  t.status = 'review'; t.reviews = []; save();
  const d = await call('conveyor', 'diff', { epic: e.id, task: t.id });
  if (!d.files.length) { stuck(e, t, 'Агент ничего не изменил'); return; }
  t.files = d.files;
  log(e, `Ревью: ${t.title} · ${d.files.length} файл(ов)`);
  for (const slot of ['review1', 'review2']) {
    const chat = agent(e, 'reviewer', t.cwd, `◎ ${ROLES[slot]}: ${t.title}`, { task: t.id, slot });
    t.reviews.push({ slot, chat: chat.id, verdict: 'pending', notes: [] }); save();
    send(chat, `Ты ${ROLES[slot].toLowerCase()} в конвейере Пульта. Проверь изменения по задаче, ничего не меняй.
Цель эпика: ${e.goal}
Задача: ${t.title}
${t.detail}

Diff против ветки эпика${d.truncated ? ' (обрезан, остальное смотри в файлах папки)' : ''}:
\`\`\`diff
${d.diff}
\`\`\`
Ищи баги, недоделки и расхождения с задачей. Стиль и мелочи не в счёт. Если есть дефекты, verdict должен быть "fix", а notes — непустым списком конкретных замечаний с файлом и строкой. Если дефектов нет, ответь блоком:
\`\`\`pult-review
{"verdict":"ok","notes":[]}
\`\`\``).catch(err => reviewError(e, t, slot, 'Ревьюер не запустился: ' + err));
  }
}

function reviewError(e, t, slot, reason) {
  const r = t.reviews.find(r => r.slot === slot);
  if (!r || r.verdict !== 'pending') return;
  r.verdict = 'error'; r.notes = [reason];
  stuck(e, t, `${ROLES[slot]}: ${reason}. Повтори ревью.`);
}

async function readVerdict(e, t, chat, text, failed) {
  const slot = chat.conveyor.slot;
  const r = t.reviews.find(r => r.slot === slot && r.chat === chat.id);
  if (!r || r.verdict !== 'pending' || t.status !== 'review') return;
  if (failed) { reviewError(e, t, slot, 'Ход ревьюера прервался'); return; }
  let v; try { v = JSON.parse(block(text, 'pult-review')); } catch {}
  const notes = Array.isArray(v?.notes) ? v.notes.filter(n => typeof n === 'string' && n.trim()).map(n => n.trim()).slice(0, 12) : [];
  if (v && ['ok', 'fix'].includes(v.verdict) && Array.isArray(v.notes) && (v.verdict === 'ok' || notes.length)) {
    await verdict(e, t, slot, { verdict: v.verdict, notes }); return;
  }
  if (!r.retried) {
    r.retried = true; log(e, `${ROLES[slot]}: повторно запрашиваю вердикт`, 'warn'); save();
    await send(chat, 'Ответ не содержит корректного вердикта. Заверши ревью и ответь только блоком ```pult-review\n{"verdict":"ok","notes":[]}\n```. Если есть конкретные дефекты, укажи "fix" и непустой список notes с файлами и описанием проблемы.');
    return;
  }
  reviewError(e, t, slot, 'Не получен корректный вердикт после повторного запроса');
}

async function verdict(e, t, slot, v) {
  const r = t.reviews.find(r => r.slot === slot); if (!r || r.verdict !== 'pending') return;
  Object.assign(r, v); drop(chatOf(r.chat)); save();
  if (t.status !== 'review' || t.reviews.some(r => !['ok', 'fix'].includes(r.verdict))) return;
  const notes = t.reviews.filter(r => r.verdict !== 'ok').flatMap(r => r.notes.map(n => `${ROLES[r.slot]}: ${n}`));
  if (!notes.length) { await accept(e, t); return; }
  if (t.round >= MAX_ROUNDS) { stuck(e, t, `После ${MAX_ROUNDS} кругов ревьюеры всё ещё против`); return; }
  t.round++; t.status = 'fixing'; log(e, `Правки (круг ${t.round}/${MAX_ROUNDS}): ${t.title}`, 'warn'); save();
  const chat = chatOf(t.chat) || agent(e, 'worker', t.cwd, `▸ ${t.title}`, { task: t.id }); t.chat = chat.id;
  await send(chat, `Ревьюеры вернули задачу (круг ${t.round} из ${MAX_ROUNDS}). Исправь:\n${notes.map(n => '- ' + n).join('\n')}\n\nПотом снова кратко опиши, что сделал.`);
}

async function accept(e, t) {
  await call('conveyor', 'commit', { epic: e.id, task: t.id, title: t.title });
  Object.assign(t, { status: 'done', note: '', doneAt: now() }); drop(chatOf(t.chat));
  log(e, `Готово: ${t.title}`, 'ok'); save(); pump(e);
}

function stuck(e, t, note) { Object.assign(t, { status: 'needsYou', note }); log(e, `${t.title}: ${note}`, 'bad'); notify(e, `${t.title}: ${note}`); save(); }
function problem(e, kind, text) { Object.assign(e, { status: 'needsYou', problem: { kind, text } }); log(e, `${kind}: ${text.slice(0, 200)}`, 'bad'); notify(e, kind + ': ' + text.slice(0, 120)); save(); }

/** Волна: слить задачи в ветку эпика, прогнать проверку, перейти дальше. */
async function closeWave(e) {
  if (closing.has(e.id)) return;
  closing.add(e.id);
  try { await mergeAndCheck(e); } finally { closing.delete(e.id); }
}
async function mergeAndCheck(e) {
  const wave = e.waves[e.wave];
  for (const t of wave.tasks.filter(t => t.status === 'done' && !t.merged)) {
    try { await call('conveyor', 'merge', { epic: e.id, task: t.id, title: t.title }); t.merged = true; save(); }
    catch (err) { Object.assign(t, { status: 'needsYou', note: String(err), conflict: true }); problem(e, 'Слияние', `${t.title}: ${err}`); return; }
  }
  if (e.check && !(await checkPassed(e))) return;
  log(e, `Волна ${e.wave + 1} влита${e.check ? ' и проверена' : ''}`, 'ok');
  e.wave++; e.problem = null;
  if (e.wave < e.waves.length) { save(); pump(e); return; }
  Object.assign(e, { status: 'review', finished: now() }); log(e, 'Все волны пройдены — жду приёмки', 'ok'); notify(e, 'Все волны пройдены, жду приёмки'); save();
  if (e.autoShip) ship(e).catch(err => problem(e, 'Автоприёмка', String(err)));
}
async function checkPassed(e) {
  log(e, `Проверка: ${e.check}`); save();
  const r = await call('conveyor', 'run', { epic: e.id, command: e.check }); e.checkOutput = r.output;
  if (r.ok) return true;
  problem(e, 'Проверка', `«${e.check}» упала (код ${r.code ?? '?'})\n${r.output.slice(-3000)}`); return false;
}
async function ship(e) {
  await call('conveyor', 'finish', { cwd: e.cwd, epic: e.id, base: e.base }); log(e, `Влито в ${e.base}`, 'ok');
  if (e.deploy) { const r = await call('conveyor', 'run', { epic: e.id, command: e.deploy }); log(e, r.ok ? 'Выкачено' : `Выкатка упала: ${r.output.slice(-300)}`, r.ok ? 'ok' : 'bad'); if (!r.ok) { problem(e, 'Выкатка', r.output.slice(-3000)); return; } }
  e.status = 'done'; e.problem = null; save();
}

async function fixer(e) {
  const chat = agent(e, 'fixer', e.epicCwd, '✚ Починка: ' + e.title); e.fixerChat = chat.id; e.status = 'running'; e.problem = null; save();
  await send(chat, `Ты чинишь ветку эпика «${e.title}» после волны ${e.wave + 1}. Проверка «${e.check}» падает:\n\`\`\`\n${(e.checkOutput || '').slice(-8000)}\n\`\`\`\nПочини так, чтобы проверка прошла. Не пушь.`);
}

// ───────── События чатов ─────────
await ui.ready;
ui.chats.onEvent(ev => onChat(ev));
function onChat(ev) {
  const m = ev.chat.conveyor; if (!m) return;
  const e = epicOf(m.epic); if (!e) return;
  const t = m.task && tasks(e).find(t => t.id === m.task);
  if (ev.type === 'message' && ev.message.kind === 'approval' && !ev.message.done && !ev.message.auto && t) { t.waiting = true; redraw(); return; }
  if (ev.type === 'turnStart' && t) { t.waiting = false; redraw(); return; }
  if (ev.type !== 'turnEnd') return;
  const text = turnText(ev.chat);
  if (m.role === 'planner') {
    if (e.status !== 'planning') return;
    try { e.waves = parsePlan(text); e.status = 'planned'; log(e, `План: ${e.waves.length} волн, ${tasks(e).length} задач`, 'ok'); }
    catch (err) { e.status = 'draft'; e.error = 'Не разобрал план: ' + err.message; }
    save(); return;
  }
  if (m.role === 'fixer') {
    call('conveyor', 'commit', { epic: e.id, title: 'Починка проверки' }).then(() => closeWave(e)).catch(err => problem(e, 'Починка', String(err)));
    drop(ev.chat); return;
  }
  if (!t) return;
  if (m.role === 'worker' && ['working', 'fixing'].includes(t.status)) {
    const lesson = block(text, 'pult-lesson');
    if (lesson) { lessons[e.cwd] = [...(lessons[e.cwd] || []), lesson.split('\n')[0].slice(0, 300)].slice(-40); }
    if (ev.failed) stuck(e, t, 'Ход агента прервался'); else review(e, t).catch(err => stuck(e, t, String(err)));
  }
  if (m.role === 'reviewer') {
    readVerdict(e, t, ev.chat, text, ev.failed).catch(err => reviewError(e, t, m.slot, String(err)));
  }
}

// ───────── Интерфейс ─────────
const el = (spec, props, ...kids) => h(spec, props || {}, ...kids);
const act = (text, fn, cls = '') => button(text, async () => { try { await fn(); } catch (err) { ui.toast(String(err.message || err)); } }, 'cv-btn ' + cls);
const ago = ms => { const s = Math.max(0, Math.round(ms / 1000)); return s < 60 ? s + ' с' : s < 3600 ? Math.floor(s / 60) + ' мин' : Math.floor(s / 3600) + ' ч ' + Math.floor(s % 3600 / 60) + ' мин'; };

function ring(value, label) {
  const C = 2 * Math.PI * 34, svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 80 80'); svg.classList.add('cv-ring');
  svg.innerHTML = `<defs><linearGradient id="cvg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f0a77f"/><stop offset="1" stop-color="#7cc8ff"/></linearGradient></defs>
<circle cx="40" cy="40" r="34" class="track"/><circle cx="40" cy="40" r="34" class="arc" stroke-dasharray="${C}" stroke-dashoffset="${C * (1 - value)}"/>
<text x="40" y="38">${Math.round(value * 100)}%</text><text x="40" y="52" class="sub">${label}</text>`;
  return svg;
}

function hero(e) {
  const all = tasks(e), done = all.filter(t => ['done', 'skipped'].includes(t.status)).length;
  const reviews = all.flatMap(t => t.reviews || []), rounds = all.reduce((n, t) => n + (t.round || 0), 0);
  const tile = (k, v) => el('div.cv-stat', {}, el('b', {}, String(v)), el('span', {}, k));
  return el('header.cv-hero', {},
    ring(all.length ? done / all.length : 0, `${done}/${all.length}`),
    el('div.cv-head', {}, el('div.cv-title', {}, el('h1', {}, e.title), el('span', { className: 'cv-pill ' + e.status }, EPIC[e.status])),
      el('p.cv-goal', {}, e.goal),
      el('div.cv-route', {}, ...Object.keys(ROLES).map(k => el('span.cv-chip', { title: ROLES[k] }, el('i', { className: 'r-' + k }), ROLES[k], el('em', {}, modelName(e.roles[k])))))),
    el('div.cv-stats', {}, tile('волна', e.waves.length ? `${Math.min(e.wave + 1, e.waves.length)}/${e.waves.length}` : '—'), tile('ревью ✓/✕', `${reviews.filter(r => r.verdict === 'ok').length}/${reviews.filter(r => r.verdict === 'fix').length}`),
      tile('кругов правок', rounds), el('div.cv-stat', {}, el('b.cv-clock', {}, e.started ? ago((e.finished || now()) - e.started) : '—'), el('span', {}, 'в пути'))));
}

function card(e, t, index) {
  const chat = chatOf(t.chat);
  const pips = el('div.cv-pips', {}, ...['review1', 'review2'].map(slot => { const r = (t.reviews || []).find(r => r.slot === slot); return el('i', { className: 'pip ' + (r?.verdict || 'none'), title: `${ROLES[slot]}: ${r ? (r.verdict === 'pending' ? 'смотрит' : r.verdict === 'ok' ? 'ок' : r.notes.join('; ')) : 'ещё не было'}` }); }));
  const actions = [];
  if (chat) actions.push(act('Агент', () => ui.chats.activate(chat.id), 'ghost'));
  if (t.status === 'needsYou') {
    if (t.conflict) actions.push(act('Разрулить конфликт', async () => { t.conflict = false; t.status = 'fixing'; e.status = 'running'; e.problem = null; t.merged = false; const c = chatOf(t.chat) || agent(e, 'worker', t.cwd, `▸ ${t.title}`, { task: t.id }); t.chat = c.id; save(); await send(c, `Влей в эту ветку ветку эпика (git merge ${e.branch}), разреши конфликты, сохрани смысл обеих сторон и закоммить слияние.`); }, 'primary'));
    else if (t.reviews?.some(r => r.verdict === 'error')) actions.push(act('Повторить ревью', () => review(e, t), 'primary'));
    else actions.push(act(t.cwd ? 'Продолжить' : 'Повторить', () => { e.status = 'running'; return work(e, t, !!t.cwd); }, 'primary'));
    if (t.cwd) actions.push(act('Принять', () => accept(e, t)));
    actions.push(act('Пропустить', () => { t.status = 'skipped'; log(e, 'Пропущена: ' + t.title, 'warn'); save(); pump(e); }, 'ghost'));
  }
  if (e.status === 'planned') actions.push(act('Убрать', () => { for (const w of e.waves) w.tasks = w.tasks.filter(x => x !== t); e.waves = e.waves.filter(w => w.tasks.length); save(); }, 'ghost'));
  return el('article', { className: `cv-card ${t.status}${t.waiting ? ' waiting' : ''}`, style: `--i:${index}` },
    el('div.cv-card-top', {}, el('span.cv-glyph', {}), el('strong', { title: t.detail }, t.title)),
    t.detail && e.status === 'planned' ? el('p.cv-detail', {}, t.detail) : null,
    el('div.cv-card-meta', {}, el('span', {}, t.waiting ? 'Ждёт подтверждения' : TASK[t.status]), t.round ? el('span.cv-round', {}, `круг ${t.round}/${MAX_ROUNDS}`) : null, t.files ? el('span', {}, `${t.files.length} файл.`) : null, pips),
    t.note ? el('p.cv-note', {}, t.note) : null,
    actions.length ? el('div.cv-card-actions', {}, ...actions) : null);
}

function belt(e) {
  if (e.status === 'planned') return el('div.cv-belt', {}, ...e.waves.map((w, i) => el('section.cv-wave', {}, el('div.cv-wave-head', {}, el('b', {}, `Волна ${i + 1}`)), ...w.tasks.map((t, j) => card(e, t, j)))));
  const index = Math.min(viewedWave.get(e.id) ?? e.wave, e.waves.length - 1);
  const wave = e.waves[index];
  const positions = [[17, 30], [83, 30], [13, 57], [87, 57], [19, 83], [81, 83]];
  const graph = el('div.cv-graph', {});
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.classList.add('cv-edges'); svg.setAttribute('viewBox', '0 0 1000 620'); svg.setAttribute('preserveAspectRatio', 'none'); svg.setAttribute('aria-hidden', 'true');
  const line = (x, y) => { const l = document.createElementNS(svg.namespaceURI, 'line'); l.setAttribute('x1', '500'); l.setAttribute('y1', '310'); l.setAttribute('x2', String(x * 10)); l.setAttribute('y2', String(y * 6.2)); svg.append(l); };
  line(50, 9);
  const nodes = wave.tasks.map((t, i) => {
    const [x, y] = positions[i]; line(x, y);
    const node = card(e, t, i); node.classList.add('cv-node'); node.style.left = x + '%'; node.style.top = y + '%';
    return node;
  });
  const active = wave.tasks.filter(t => ['working', 'review', 'fixing'].includes(t.status)).length;
  const needs = wave.tasks.filter(t => t.status === 'needsYou').length;
  const status = needs ? 'НУЖЕН ТЫ' : e.status === 'paused' ? 'ПАУЗА' : e.status === 'done' ? 'ЗАВЕРШЕНО' : e.status === 'review' ? 'ЖДУ ПРИЁМКИ' : active ? 'ДЕЙСТВУЕТ' : 'НА СВЯЗИ';
  const waveButtons = e.waves.map((w, i) => act(String(i + 1), () => { viewedWave.set(e.id, i); redraw(); }, i === index ? 'selected' : ''));
  graph.append(svg,
    el('div.cv-project-node', {}, el('strong', { title: e.title }, e.title), el('div.cv-group-tabs', {}, el('span', {}, 'волны'), ...waveButtons)),
    ...nodes,
    el('div.cv-orchestrator', { 'data-state': active ? 'thinking' : 'idle' },
      el('button.cv-sphere-button', { type: 'button', title: 'Голосовой разговор', 'aria-label': 'Голосовой разговор', onclick: () => ui.openPanel('voice-sphere', 'main') }, sphere(180)),
      el('span.cv-orchestrator-state', {}, status),
      el('p.cv-orchestrator-caption', {}, needs ? `${needs} задач ждут твоего решения` : active ? `${active} задач в работе · волна ${index + 1}` : EPIC[e.status]),
      el('p.cv-orchestrator-update', { title: e.log?.[0]?.text || '' }, e.log?.[0]?.text || 'Готов к запуску')));
  return el('div.cv-map', {}, graph);
}

function controls(e) {
  const row = [];
  if (e.status === 'planned') {
    const note = el('input.cv-input.replan', { placeholder: 'Что поправить в плане? Например: «объедини 2 и 3 волну»' });
    row.push(act('Запустить конвейер', () => launch(e), 'primary big'), note, act('Перепланировать', async () => { if (!note.value.trim()) throw Error('Напиши, что поправить'); await plan(e, note.value.trim()); }));
  }
  if (e.status === 'running') row.push(act('Пауза', () => { e.status = 'paused'; log(e, 'Пауза: новые задачи не берутся'); save(); }));
  if (e.status === 'paused') row.push(act('Продолжить', () => { e.status = 'running'; save(); pump(e); }, 'primary'));
  if (e.status === 'needsYou' && e.problem) {
    if (e.problem.kind === 'Проверка') row.push(act('Починить агентом', () => fixer(e), 'primary'), act('Повторить проверку', async () => { e.status = 'running'; e.problem = null; save(); await closeWave(e); }), act('Без проверки', async () => { const c = e.check; e.check = ''; e.status = 'running'; e.problem = null; await closeWave(e); e.check = c; save(); }, 'ghost'));
    else if (e.problem.kind !== 'Слияние') row.push(act('Повторить', async () => { e.status = 'running'; e.problem = null; save(); if (e.wave >= e.waves.length) await ship(e); else await closeWave(e); }, 'primary'));
  }
  if (e.status === 'review') row.push(act(`Влить в ${e.base}${e.deploy ? ' и выкатить' : ''}`, () => ship(e), 'primary big'), act('Запушить ветку', async () => { await call('conveyor', 'push', { epic: e.id }); log(e, `Ветка ${e.branch} отправлена`, 'ok'); save(); }));
  if (['draft', 'planned', 'done', 'review', 'paused', 'needsYou'].includes(e.status)) row.push(act('Удалить эпик', async () => {
    if (!confirm(`Удалить «${e.title}»? Рабочие папки конвейера будут убраны, ветки останутся в репозитории.`)) return;
    if (e.branch) await call('conveyor', 'cleanup', { cwd: e.cwd, epic: e.id }).catch(() => {});
    epics = epics.filter(x => x !== e); selected = epics[0]?.id || null; save();
  }, 'ghost danger'));
  return el('div.cv-controls', {}, ...row);
}

function draft() {
  const roles = structuredClone(epics[0]?.roles || DEFAULT_ROLES);
  let cwd = ui.chats.current()?.cwd || '';
  const goal = el('textarea.cv-input.goal', { placeholder: 'Что должно получиться? Например: «Добавить оплату картой: форма, вебхук, письмо с чеком, тесты»' });
  const folder = act(cwd || 'Выбрать папку проекта', async () => { const p = (await call('codex', 'pick', { folder: true, dir: cwd }))?.[0]; if (p) { cwd = p; folder.textContent = p; } }, 'ghost folder');
  const providers = [['codex', 'Codex'], ['claude', 'Claude'], ...ui.providers.map(p => [p.id, p.title])];
  const roleRow = k => { const r = roles[k];
    const target = el('select.cv-input', { onchange: () => { r.target = target.value; } }, ...providers.map(([v, n]) => el('option', { value: v, selected: v === r.target }, n)));
    const model = el('input.cv-input', { value: r.model, placeholder: 'модель по умолчанию', oninput: () => { r.model = model.value.trim(); } });
    return el('label.cv-role', {}, el('i', { className: 'r-' + k }), el('span', {}, ROLES[k]), target, model); };
  const parallel = el('input', { type: 'range', min: 1, max: 6, value: 3 }), parallelLabel = el('b', {}, '3');
  parallel.oninput = () => { parallelLabel.textContent = parallel.value; };
  const check = el('input.cv-input', { placeholder: 'Проверка после каждой волны, например: npm test' });
  const deploy = el('input.cv-input', { placeholder: 'Выкатка после приёмки, например: ./deploy.sh (необязательно)' });
  const auto = el('input', { type: 'checkbox' }), ship = el('input', { type: 'checkbox' });
  return el('div.cv-draft', {},
    el('div.cv-intro', {}, el('h1', {}, 'Конвейер'), el('p', {}, 'Сильная модель режет эпик на волны → дешёвые делают задачи волны параллельно, каждая в своей ветке → два ревьюера на разных моделях → слияние и проверка → следующая волна. В твою ветку — только по кнопке.')),
    el('div.cv-flow', {}, ...['План', 'Волны', 'Ревью ×2', 'Слияние', 'Приёмка'].map((s, i) => el('span', { style: `--i:${i}` }, s))),
    goal, folder,
    el('div.cv-roles', {}, ...Object.keys(ROLES).map(roleRow)),
    el('label.cv-line', {}, 'Параллельно', parallel, parallelLabel, 'задачи'),
    check, deploy,
    el('label.cv-line', {}, auto, 'Подтверждать действия исполнителей за меня'),
    el('label.cv-line', {}, ship, 'Если всё зелёное — влить и выкатить без меня'),
    act('Разложить на волны', async () => {
      if (!goal.value.trim()) throw Error('Опиши цель эпика');
      if (!cwd) throw Error('Выбери папку проекта');
      const e = { id: uuid(), title: goal.value.trim().split('\n')[0].slice(0, 70), goal: goal.value.trim(), cwd, roles, parallel: Number(parallel.value), check: check.value.trim(), deploy: deploy.value.trim(),
        autoApprove: auto.checked, autoShip: ship.checked, status: 'draft', waves: [], wave: 0, log: [], created: now() };
      document.activeElement?.blur(); epics.unshift(e); selected = e.id; await plan(e);
    }, 'primary big'));
}

function history(e) {
  return el('details.cv-history', { open: expandedHistory.has(e.id), ontoggle: ev => { if (ev.target.open) expandedHistory.add(e.id); else expandedHistory.delete(e.id); } },
    el('summary', {}, el('b', {}, 'История'), el('span.cv-latest', {}, e.log?.[0]?.text || 'Событий пока нет'), el('small', {}, String(e.log?.length || 0))),
    el('ol.cv-log', {}, ...(e.log || []).map(l => el('li', { className: l.kind }, el('time', {}, new Date(l.t).toLocaleTimeString().slice(0, 5)), el('span', {}, l.text)))));
}

function view() {
  const e = epicOf(selected);
  const tabs = el('nav.cv-tabs', {}, ...epics.map(x => { const all = tasks(x), done = all.filter(t => t.status === 'done').length;
    return el('button', { className: 'cv-tab ' + x.status + (x.id === selected ? ' selected' : ''), onclick: () => { selected = x.id; redraw(); } }, el('i'), el('span', {}, x.title), el('small', {}, all.length ? `${done}/${all.length}` : EPIC[x.status])); }),
    el('button', { className: 'cv-tab new' + (!e ? ' selected' : ''), onclick: () => { selected = null; redraw(); } }, '＋ Новый эпик'));
  if (!e) return el('div.cv', {}, tabs, draft());
  const belted = e.waves.length ? belt(e) : el('div.cv-empty', {}, e.status === 'planning' ? el('div.cv-thinking', {}, el('i'), el('i'), el('i'), el('span', {}, 'Планировщик изучает проект и режет эпик на волны…')) : el('p', {}, e.error || 'Плана пока нет'),
    e.status === 'draft' ? act('Спланировать заново', () => plan(e), 'primary') : null, chatOf(e.plannerChat) ? act('Открыть планировщика', () => ui.chats.activate(e.plannerChat), 'ghost') : null);
  return el('div.cv', {}, tabs, hero(e), controls(e),
    e.problem ? el('div.cv-problem', {}, el('b', {}, e.problem.kind), el('pre', {}, e.problem.text)) : null,
    belted,
    history(e));
}

function redraw() {
  if (!root?.isConnected) return;
  const scroll = root.querySelector('.cv-belt, .cv-map')?.scrollLeft || 0;
  const a = document.activeElement;
  if (root.contains(a) && /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName)) return; // не сбрасываем поле, пока в нём печатают
  root.replaceChildren(view());
  const b = root.querySelector('.cv-belt, .cv-map'); if (b) b.scrollLeft = scroll;
}

ui.addPanel({ id: 'conveyor', title: 'Конвейер', slot: 'main', render(host) { root = host; root.classList.add('cv-host'); redraw(); clearInterval(timer); timer = setInterval(() => { const c = root?.querySelector('.cv-clock'); const e = epicOf(selected); if (c && e?.started && !e.finished) c.textContent = ago(now() - e.started); }, 1000); }, dispose() { clearInterval(timer); root = null; } });
ui.addSidebar({ id: 'conveyor', title: 'Конвейер', icon: '⇶', open: () => ui.openPanel('conveyor', 'main'), badge: () => epics.filter(e => e.status === 'needsYou').length });
ui.addCommand({ name: 'conveyor', hint: 'Конвейер: эпик → волны → ревью → слияние', run: () => ui.openPanel('conveyor', 'main') });

// После перезапуска чатов агентов нет: что было в работе — ждёт кнопки «Продолжить».
const saved = await settings.get('conveyor');
if (saved) {
  epics = Array.isArray(saved.epics) ? saved.epics : []; lessons = saved.lessons || {};
  for (const e of epics) {
    if (e.status === 'planning') { e.status = 'draft'; e.error = 'Пульт перезапускался во время планирования'; }
    if (e.status === 'running') e.status = 'paused';
    for (const t of tasks(e)) if (['working', 'review', 'fixing'].includes(t.status)) Object.assign(t, { status: 'needsYou', note: 'Пульт перезапускался — продолжи', waiting: false });
    for (const t of tasks(e)) {
      const invalid = (t.reviews || []).filter(r => r.notes?.some(n => /^Ревьюер не (вынес вердикт|запустился)/.test(n)));
      if (!invalid.length || ['done', 'skipped'].includes(t.status)) continue;
      for (const r of invalid) r.verdict = 'error';
      t.status = 'needsYou'; t.note = 'Прошлое ревью завершилось без вердикта — повтори проверку';
    }
  }
  selected = epics[0]?.id || null;
}
ui.conveyor = { epics: () => epics, event: onChat };
