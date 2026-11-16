import { call, on, ui, h, settings } from './core.js';
import { markdown, basename, button, localFileTarget, icon, iconButton, rings } from './render.js';
const chats = [], events = new EventTarget(), previews = new Map();
const isImage = path => /\.(png|jpe?g|gif|webp|bmp)$/i.test(path);
let active, accounts = [], info, prefs = {}, history = [], query = '', follow = true, showingTrash = false;
const app = document.querySelector('#app'), threadList = h('div.thread-list'), tabs = h('div.tabs'), feed = h('div.feed');
const title = h('strong', {}, 'Новый диалог'), status = h('span.status', {}, 'Готов');
// Значок цели: видно, что агент работает под /goal, её статус и расход.
const goalChip = h('button.goal-chip', { type: 'button', hidden: true, onclick: () => { composer.value = '/goal '; composer.focus(); } });
function paintGoal() {
  const g = active?.target === 'codex' ? active.goal : null; goalChip.hidden = !g; if (!g) return;
  const label = { active: 'цель', paused: 'цель на паузе', completed: 'цель выполнена', budgetLimited: 'бюджет цели исчерпан' }[g.status] || 'цель';
  goalChip.className = 'goal-chip ' + (g.status || 'active');
  goalChip.replaceChildren(h('span.goal-ring'), h('span.goal-label', {}, label), h('span.goal-text', {}, g.objective || ''));
  goalChip.title = `${g.objective}\n${g.tokensUsed ? Math.round(g.tokensUsed / 1000) + 'k токенов · ' : ''}${g.timeUsedSeconds ? Math.max(1, Math.round(g.timeUsedSeconds / 60)) + ' мин' : ''}\nНажми, чтобы изменить или снять (/goal clear)`;
}
const accountSelect = h('select', { 'aria-label': 'Аккаунт' });
const provider = h('select', { 'aria-label': 'Провайдер' }, h('option', { value: 'codex' }, 'Codex'), h('option', { value: 'claude' }, 'Claude'));
const suggestions = h('div.slash-suggestions', { hidden: true, role: 'listbox', 'aria-label': 'Команды' });
let suggestionIndex = 0;
const modelChoices = iconButton('cpu', 'Модели', () => ui.models.open(active), 'По умолчанию');
const folder = button('Папка проекта', async () => {
  const c=active;if(c.busy)return ui.toast('Сначала останови текущий ход');
  const paths=await call('codex','pick',{folder:true,dir:c.cwd});
  if(!paths?.[0] || paths[0]===c.cwd)return;
  if(c.messages.length || c.thread || c.session) open({target:c.target,cwd:paths[0],model:c.model,account:c.account});
  else {c.cwd=paths[0];if(c===active)header();}
});
const composer = h('textarea', { placeholder: 'Напиши задачу…  Enter — отправить, Shift+Enter — новая строка', rows: 3, 'aria-label': 'Сообщение' });
const files = h('div.attachments'), queue = h('div.queue'), extensions = h('div.extensions');
const leftDock = h('aside.dock.left', { hidden: true }), rightDock = h('aside.dock.right', { hidden: true }), mainDock = h('section.main-dock', { hidden: true }), statusbar = h('div.statusbar');
const stage = h('div.stage', {}, leftDock, feed, mainDock, rightDock);
const sendButton = iconButton('arrow','Отправить ↑',()=>send()), stopButton = iconButton('stop','Стоп',interrupt);
sendButton.className='send-button';stopButton.className='stop-button';
const search = h('input.search', { placeholder: 'Найти диалог', 'aria-label': 'Поиск диалогов', oninput: e => { query = e.target.value.toLowerCase(); renderHistory(); } });
const panel = h('dialog.panel'), toast = h('div.toast', { role: 'status', hidden: true }), nav = h('div.nav');
const sidebar = h('aside.sidebar'), sidebarScroll = h('div.sidebar-scroll');
const toggleSidebar = () => { app.classList.toggle('sidebar-collapsed'); };
const sectionTitle = text => h('div.section-title', {}, text);
const trashButton = iconButton('trash','Открыть корзину',async()=>{showingTrash=!showingTrash;await loadHistory();header();},'Корзина');
// Лимиты — рядом колец внизу окна, как док: щелчок — перейти на аккаунт, правый щелчок — действия с ним.
const ringBar = h('div.ring-bar', {'aria-label':'Лимиты аккаунтов'});
const settingsButton = iconButton('settings','⚙ Настройки',()=>ui.openSettings());
sidebarScroll.append(sectionTitle('Открытые чаты'),tabs,button('+ Новый диалог',()=>open(),'new-chat'),
  h('div.history-search',{},icon('search'),search),h('div.history-tools',{},trashButton,iconButton('limits','◫ Лимиты',()=>call('limits','toggle'))),threadList);
sidebar.append(h('div.sidebar-tools',{},h('span.app-name',{},'Пульт'),iconButton('search','Открыть поиск',()=>search.focus()),iconButton('new','Новый чат',()=>open()),iconButton('sidebar','Скрыть боковую панель',toggleSidebar)),sidebarScroll,nav,
  h('div.sidebar-footer',{},iconButton('cpu','↗ API-подключения',()=>ui.openPanel('api')),h('small.app-version',{},'Пульт'),settingsButton));
const controls = h('div.compose-actions',{},provider,modelChoices,iconButton('paperclip','+ Файлы',attach),extensions,
  iconButton('people','Мультиагент',()=>{active.multi=!active.multi;header();}),
  iconButton('shield','Подтверждать за меня',()=>ui.commands.get('approvals').run(active.autoApprove?'off':'on',active)),
  iconButton('rules','Правила чата',()=>ui.chats.openRules(active)),h('span.compose-spacer'),stopButton,sendButton);
const usageLabel = h('small.usage');
const activity = h('div.activity',{hidden:true});
app.append(sidebar,h('main.workspace',{},
  h('header.toolbar',{},iconButton('sidebar','Показать боковую панель',toggleSidebar),h('div.heading',{},title,status,goalChip),
    h('div.toolbar-actions',{},iconButton('people','Вместе',()=>ui.openPanel('team','right')),accountSelect,iconButton('settings','Настройки',()=>ui.openSettings()))),stage,
  h('div.compose-wrap',{},activity,queue,suggestions,h('div.composer',{},files,h('div.composer-input',{},h('span.prompt-mark',{},'>'),composer),controls),
    h('div.composer-footer',{},folder,usageLabel,h('small.hint',{},'Enter — отправить · Shift+Enter — новая строка'))),ringBar,statusbar),panel,toast);
ui.toast = text => { toast.textContent = text; toast.hidden = false; clearTimeout(ui.toast.timer); ui.toast.timer = setTimeout(() => toast.hidden = true, 5000); };
window.addEventListener('pult-error', e => ui.toast(e.detail));
window.addEventListener('unhandledrejection', e => { e.preventDefault(); ui.toast(String(e.reason)); });
document.addEventListener('click', e => {
  const a = e.target.closest('a');
  if (a && !a.hasAttribute('download')) {
    e.preventDefault(); const raw = a.getAttribute('href');
    if (!raw) return;
    if (raw.startsWith('#')) { document.getElementById(raw.slice(1))?.scrollIntoView(); return; }
    try { (/^https?:\/\//i.test(raw) ? call('limits', 'url', { url: raw }) : call('codex', 'open', { ...localFileTarget(raw), cwd: active.cwd })).catch(ui.toast); } catch (e) { ui.toast(String(e)); }
  }
});
function emit(type, chat, extra = {}) { events.dispatchEvent(new CustomEvent('event', { detail: { type, chat, origin: chat.origin ?? null, ...extra } })); }
const mounted = new Map();
let sheetOwner;
function unmount(id) {
  const item = mounted.get(id); if (!item) return;
  mounted.delete(id); item.el.remove();
  try { item.p.onClose?.(); } catch (e) { ui.toast(String(e)); }
  if (item.slot === 'sheet') sheetOwner = null;
  for (const host of [leftDock, rightDock, mainDock]) if (host.dataset.panel === id) { host.replaceChildren(); host.hidden = true; delete host.dataset.panel; }
  feed.hidden = !mainDock.hidden;
}
panel.addEventListener('close', () => { if (!panel.open && sheetOwner) unmount(sheetOwner); });
function modal(name, content) {
  if (sheetOwner) unmount(sheetOwner);
  panel.replaceChildren(h('div.panel-head', {}, h('h2', {}, name), button('Закрыть', () => panel.close())), content);
  if (!panel.open) panel.showModal();
}
ui.openPanel = (id, placement) => {
  const p = ui.panels.get(id); if (!p) throw new Error(`Панель не найдена: ${id}`);
  const slot = placement || p.slot || 'sheet';
  if (!['main', 'left', 'right', 'sheet'].includes(slot)) throw new Error('Неизвестное размещение панели');
  let item = mounted.get(id);
  if (item?.slot === slot) { if (slot === 'sheet' && !panel.open) panel.showModal(); return; }
  if (item) {
    item.el.remove();
    if (item.slot === 'sheet') { sheetOwner = null; panel.close(); }
    for (const host of [leftDock, rightDock, mainDock]) if (host.dataset.panel === id) { host.replaceChildren(); host.hidden = true; delete host.dataset.panel; }
  } else item = { p, el: h('div.panel-body'), slot };
  item.slot = slot;
  if (slot === 'sheet') { modal(p.title, item.el); sheetOwner = id; }
  else {
    const host = { main: mainDock, left: leftDock, right: rightDock }[slot];
    if (host.dataset.panel) unmount(host.dataset.panel);
    host.dataset.panel = id; host.hidden = false;
    host.replaceChildren(h('div.dock-head', {}, h('strong', {}, p.title), button('×', () => ui.closePanel(id))), item.el);
  }
  const fresh = !mounted.has(id); mounted.set(id, item); feed.hidden = !mainDock.hidden;
  if (fresh) Promise.resolve(p.render(item.el)).catch(e => ui.toast(String(e)));
};
ui.closePanel = id => { if (!id) { panel.close(); return; } const item = mounted.get(id); if (item?.slot === 'sheet') { sheetOwner = null; panel.close(); } unmount(id); };
function refreshExtensions() {
  provider.replaceChildren(...[{ id: 'codex', title: 'Codex' }, { id: 'claude', title: 'Claude' }, ...ui.providers].map(p => h('option', { value: p.id }, p.title)));
  if (active) provider.value = active.target;
  nav.replaceChildren(...ui.sidebar.filter(b=>!['api','telegram','support'].includes(b.id)).map(b => iconButton(b.id==='team'?'people':b.id==='mods'?'cpu':'folder',`${b.icon || ''} ${b.title}`.trim(),b.open,b.title)));
  settingsButton.title='Настройки · Telegram, голос, обновления и подключения';
  extensions.replaceChildren(...ui.composer.map(b => iconButton(b.id==='voice'?'mic':b.id==='coach'?'wand':'cpu',b.icon || b.title,()=>b.run(active))));
  statusbar.replaceChildren(...ui.statusbar.map(b => button(b.icon || b.title, () => b.run(active))));
}
ui.onChange(refreshExtensions);
function resizeComposer() { composer.style.height='auto';composer.style.height=Math.min(220,Math.max(34,composer.scrollHeight))+'px'; }
function header() {
  paintGoal();
  title.textContent = active.title; status.textContent = active.busy ? '● Работает' : '● Готов'; status.classList.toggle('working', active.busy);
  folder.replaceChildren(icon('folder'),document.createTextNode(active.cwd.replace(info?.home || '\0','~') || 'Папка проекта')); folder.title = active.cwd;
  provider.value = active.target; accountSelect.hidden = active.target !== 'codex'; accountSelect.value = active.account; accountSelect.disabled = active.busy; modelChoices.disabled = active.busy || active.target.startsWith('api:'); modelChoices.replaceChildren(icon('cpu'),document.createTextNode((active.model || 'По умолчанию')+(active.effort?' · '+active.effort:'')+(active.fast?' ⚡':''))); stopButton.hidden = !active.busy;
  resizeComposer();
  ringBar.querySelectorAll('.ring-tile[data-home]').forEach(b=>{b.disabled=active.busy || active.target!=='codex';b.classList.toggle('current',active.target==='codex'&&b.dataset.home===active.account);});
  provider.disabled=active.busy;
  for (const label of ['Мультиагент','Подтверждать за меня']) { const b=controls.querySelector(`[aria-label="${label}"]`); b.classList.toggle('active',label==='Мультиагент'?!!active.multi:!!active.autoApprove); b.disabled=active.target.startsWith('api:'); }
  activity.hidden=!active.busy;activity.textContent='✳ Работаю… · Esc — прервать';
  composer.placeholder=active.busy?'Напиши ещё — встанет в очередь…':`Задача для ${active.target==='claude'?'Claude':active.target==='codex'?'Codex':'API'}…`;
  const usage=active.usage?.total || active.usage; usageLabel.textContent=usage ? `↑ ${usage.inputTokens ?? usage.input_tokens ?? '—'}  ↓ ${usage.outputTokens ?? usage.output_tokens ?? '—'}` : '';
  trashButton.lastChild.textContent=showingTrash?'К истории':`Корзина (${(prefs.hidden || []).length})`;trashButton.classList.toggle('active',showingTrash);
  queue.replaceChildren(...(active.queue.length ? [h('div.queue-item', {}, h('small', {}, active.queuePaused ? 'Очередь на паузе' : 'Очередь сообщений'), button(active.queuePaused ? 'Продолжить очередь' : 'Пауза очереди', () => { if (active.queuePaused) return ui.chats.resumeQueue(active); active.queuePaused = true; header(); }))] : []), ...active.queue.map((q, i) => h('div.queue-item', {}, h('span', {}, `В очереди: ${q.text || '(вложение)'}`), button('×', () => { active.queue.splice(i, 1); header(); }))));
  files.replaceChildren(...active.attachments.map((path, i) => { const item = button(`${basename(path)} ×`, () => { active.attachments.splice(i, 1); header(); }); if (isImage(path)) item.prepend(thumbnail(path)); return item; }));
  tabs.replaceChildren(...chats.map((c,i) => {
    const close=iconButton('close',`Закрыть чат: ${c.title}`,()=>ui.chats.close(c));close.className='tab-close';
    const selectButton=button('',()=>select(c));selectButton.className='tab-select';selectButton.setAttribute('aria-label',c.title);
    selectButton.append(h('span.chat-dot',{className:c.busy?'chat-dot working':'chat-dot'}),h('span.chat-info',{},h('strong',{},c.title),h('small',{},`${c.busy?'Работает · ':''}${c.target==='codex'?(accounts.find(a=>a.home===c.account)?.name || 'Codex'):c.target==='claude'?'Claude':'API'} · ${basename(c.cwd)}`)),h('small.chat-shortcut',{},`Ctrl+${i+1}`));
    return h('div.tab',{className:`tab${c===active?' selected':''}`},selectButton,close);
  }));

}
function select(c) {
  if (active) active.draft = composer.value;
  if (mainDock.dataset.panel) ui.closePanel(mainDock.dataset.panel);
  active = c; composer.value = c.draft || ''; follow = true; renderSuggestions(); header(); renderFeed(); emit('open', c);
}
function open(opts = {}) {
  const inherit = active && (!opts.target || opts.target === active.target) ? { target: active.target, cwd: active.cwd, account: active.account, model: active.model, effort: active.effort, sandbox: active.sandbox, extraDirs: [...(active.extraDirs || [])] } : active ? { cwd: active.cwd } : {};
  const c = { id: crypto.randomUUID(), title: 'Новый диалог', target: 'codex', cwd: prefs.cwd || info?.home || '', account: accounts[0]?.home || '',
    sandbox: prefs.sandbox || 'workspace-write', autoApprove: false, extraDirs: [], model: (opts.target === 'claude' ? prefs.claudeModel : prefs.codexModel) || '', effort: prefs[(opts.target || 'codex') + 'Effort'] || '', permissionMode: 'default', fast: false, messages: [], attachments: [], queue: [], gen: 0, ...inherit, ...opts };
  chats.push(c); if (opts.select !== false || !active) { select(c); composer.focus(); } else { header(); emit('create', c); }
  if (opts.prompt) send(opts.prompt, { chat: c, literal: true }); return c;
}
function add(c, kind, text, id = crypto.randomUUID(), extra = {}) {
  let m = c.messages.find(x => x.id === id);
  if (!m) { m = { id, kind, text, origin: c.origin ?? null, ...extra }; c.messages.push(m); } else Object.assign(m, { text, ...extra });
  if (c === active) renderMessage(m); emit('message', c, { message: m }); return m;
}
function renderMessage(m) {
  let el = Array.from(feed.children).find(n => n.dataset.id === m.id);
  if (!el) { el = h('article.message', { 'data-id': m.id }); feed.append(el); }
  el.className = `message ${m.kind}`;
  el.hidden = !!active.focus && ['command', 'thinking', 'file'].includes(m.kind);
  const label = { user: 'Ты', agent: active.target.startsWith('api:') ? (ui.providers.find(p => p.id === active.target)?.title || 'API') : active.target === 'claude' ? 'Claude' : 'Codex', command: 'Терминал', thinking: 'Размышление', file: 'Изменения', approval: 'Нужно разрешение', question: 'Вопрос', error: 'Ошибка', plan: 'План', note: 'Пульт' }[m.kind] || m.kind;
  const body = h('div.message-body');
  if (m.kind === 'agent') markdown(body, m.text);
  else if (['command', 'thinking', 'file'].includes(m.kind)) body.append(h('details', { open: !!active.raw || !m.done }, h('summary', {}, m.text || label), h('pre', {}, m.output || '')));
  else body.textContent = m.text;
  el.replaceChildren(h('div.message-label', {title:label,'aria-label':label},m.kind==='user'?'>':m.kind==='agent'?'●':label), body);
  if (['user','agent'].includes(m.kind)) {
    const actions = h('div.message-actions', {}, button('Скопировать', () => navigator.clipboard.writeText(m.text)));
    if (m.kind === 'user') actions.append(button('Изменить и продолжить', () => showEdit(active, m)));
    el.append(actions);
  }
  if (m.attachments?.length) body.append(h('div.attachment-grid', {}, ...m.attachments.map(path => { const item = button(basename(path), () => call('codex','open',{path,cwd:active.cwd})); if (isImage(path)) item.prepend(thumbnail(path)); return item; })));
  if (m.kind === 'approval' && !m.done) body.append(h('pre', {}, JSON.stringify(m.params, null, 2)), h('div.actions', {},
    button('Разрешить', () => answer(m, true), 'primary'), button('Отклонить', () => answer(m, false))));
  if (m.kind === 'question' && !m.done) {
    const form = h('form');
    for (const q of m.params.questions || []) {
      const input = h('input', { name: q.id, placeholder: 'Свой ответ', required: true, type: q.isSecret ? 'password' : 'text' });
      form.append(h('fieldset', {}, h('legend', {}, q.question), ...(q.options || []).map(o => button(o.label, () => { input.value = o.label; })), input));
    }
    form.append(h('button.primary', { type: 'submit' }, 'Ответить'));
    form.onsubmit = async e => {
      e.preventDefault(); const answers = Object.fromEntries([...new FormData(form)].map(([k, v]) => [k, { answers: [v] }]));
      try { await respond(m, { answers }); m.done = true; renderMessage(m); } catch (e) { ui.toast(String(e)); }
    };
    body.append(form);
  }
  if (follow) feed.scrollTop = feed.scrollHeight;
}
function showEdit(c, message) {
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  const text = h('textarea', {value:message.text, rows:8, 'aria-label':'Изменённое сообщение'});
  const attachments = [...(message.attachments || [])], files = h('div');
  const renderFiles = () => files.replaceChildren(...attachments.map((path,i) => button(`${basename(path)} ×`, () => { attachments.splice(i,1); renderFiles(); })));
  renderFiles();
  modal('Изменить сообщение и продолжить', h('div.panel-body.settings', {}, text, files,
    h('p', {}, 'Текущее продолжение сохранится отдельной веткой. Новая ветка получит историю до изменённого сообщения. Уже выполненные команды и изменения файлов останутся на диске.'),
    button('Сохранить старую ветку и продолжить', async () => { const task = text.value.trim(); if (!task && !attachments.length) throw new Error('Нужно сообщение или вложение'); panel.close(); await ui.chats.edit(c,message.id,task,attachments); }, 'primary')));
}
function renderFeed() {
  feed.replaceChildren();
  if (!active.messages.length) feed.append(h('div.empty', {}, h('h1', {}, 'С чего начнём?'),h('p',{},'Выбери папку проекта и напиши задачу.'),h('div.empty-hints',{},...[['Ctrl+N','Новый чат'],['Ctrl+K','Поиск по истории'],['/','Команды · !команда — терминал проекта'],['Esc','Остановить ответ']].map(([key,text])=>h('div',{},h('kbd',{},key),h('span',{},text))))));
  for (const m of active.messages) renderMessage(m);
}
feed.onscroll = () => follow = feed.scrollHeight - feed.scrollTop - feed.clientHeight < 100;
function pending(m) { const c = chats.find(c => c.id === m.chat); if (!c?.busy || m.done || m.gen !== c.gen) throw new Error('Запрос уже неактивен'); }
function canAutoApprove(m) {
  return m.kind === 'approval' && (m.claude || ['item/commandExecution/requestApproval', 'item/fileChange/requestApproval', 'item/permissions/requestApproval', 'execCommandApproval', 'applyPatchApproval'].includes(m.method));
}
async function respond(m, result) {
  pending(m);
  if (m.claude) {
    const answers = result.answers && Object.fromEntries(Object.entries(result.answers).map(([k, v]) => [k, v.answers.join(', ')]));
    return call('claude', 'respond', { chat: m.chat, gen: m.gen, id: m.rpcId, response: { behavior: 'allow', updatedInput: { ...m.params.input, ...(answers && { answers }) } } });
  }
  return call('codex', 'respond', { chat: m.chat, gen: m.gen, id: m.rpcId, result });
}
async function answer(m, accept) {
  pending(m);
  if (m.claude) {
    await call('claude', 'respond', { chat: m.chat, gen: m.gen, id: m.rpcId, response: accept ? { behavior: 'allow', updatedInput: m.params.input || {} } : { behavior: 'deny', message: 'Пользователь отклонил действие' } });
    m.done = true; m.text += accept ? ' · Разрешено' : ' · Отклонено'; if (active?.id === m.chat) renderMessage(m); return;
  }
  let result = { decision: accept ? (['execCommandApproval', 'applyPatchApproval'].includes(m.method) ? 'approved' : 'accept') : (['execCommandApproval', 'applyPatchApproval'].includes(m.method) ? 'denied' : 'decline') };
  if (m.method === 'item/permissions/requestApproval') result = { permissions: accept ? m.params.permissions : {}, scope: 'turn' };
  if (m.method === 'mcpServer/elicitation/request') result = { action: accept ? 'accept' : 'decline', content: null };
  await respond(m, result); m.done = true; m.text += accept ? ' · Разрешено' : ' · Отклонено'; if (active?.id === m.chat) renderMessage(m);
}
function thumbnail(path) {
  const img = h('img.attachment-preview', {alt:basename(path),loading:'lazy'});
  if (!previews.has(path)) { previews.set(path, call('codex','readImage',{path})); if (previews.size>8) previews.delete(previews.keys().next().value); }
  previews.get(path).then(value => { if (img.isConnected) img.src = value; }).catch(() => img.remove()); return img;
}
async function attachPaths(c, paths) {
  for (const path of paths) {
    if (typeof path !== 'string' || !path || await call('codex','isDir',{path})) continue;
    if (chats.includes(c) && !c.attachments.includes(path)) c.attachments.push(path);
  }
  if (c === active) header();
}
async function attach() { const c=active; await attachPaths(c, await call('codex', 'pick', { dir: c.cwd })); }
composer.onpaste = async e => {
  const images=[...(e.clipboardData?.files || [])].filter(f=>/^image\/(png|jpeg|gif|webp|bmp)$/.test(f.type));
  if (!images.length) return; e.preventDefault(); const c=active;
  try {
    for (const file of images) {
      if (file.size>30*1024*1024) throw new Error('Изображение больше 30 МБ');
      const data=await new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result.split(',')[1]);reader.onerror=()=>reject(new Error('Не прочитать изображение'));reader.readAsDataURL(file);});
      const path=await call('codex','saveImage',{data}); if (chats.includes(c)) c.attachments.push(path);
    }
    if(c===active)header();
  } catch(error) { ui.toast(String(error)); }
};
window.__TAURI__.webview?.getCurrentWebview().onDragDropEvent(e=>{if(e.payload.type==='drop')attachPaths(active,e.payload.paths).catch(ui.toast);}).catch(ui.toast);
const rpc = (c, method, params = {}) => call('codex', 'rpc', { chat: c.id, gen: c.gen, method, params });
async function connect(c) {
  if (c.connected) return;
  c.gen++; await call('codex', 'connect', { chat: c.id, home: c.account, gen: c.gen }); c.connected = true;
}
const effectiveRules = c => c.rulesOverride ?? prefs.rules ?? '';
// Агент знает, где он работает и где лежит код самого Пульта. Добавляется к правилам при запуске, в сравнении правил не участвует.
const PULT_CONTEXT = 'Ты работаешь внутри «Пульта» — настольного приложения для Codex и Claude Code на Mac и Windows. Исходники Пульта: https://github.com/abobalover228-afk/pult-public (приложение — папка windows/, Rust + Tauri 2, интерфейс на JS в windows/ui/). Если просят поправить или объяснить сам Пульт, речь об этом репозитории. Пользователь читает ответы в окне Пульта: Markdown отображается, ссылки на файлы вида путь:строка открываются кликом.';
const withPult = rules => rules ? `${PULT_CONTEXT}\n\n${rules}` : PULT_CONTEXT;
async function thread(c, rules = effectiveRules(c)) {
  await connect(c); if (c.loaded) return;
  const params = { cwd: c.cwd, approvalPolicy: 'on-request', sandbox: c.sandbox || prefs.sandbox || 'workspace-write', ...(c.model && { model: c.model }) };
  params.developerInstructions = withPult(rules);
  if (c.thread) {
    params.threadId = c.thread;
    const path = await call('codex', 'rollout', { thread: c.thread, home: c.account }); if (path) params.path = path;
  }
  const r = await rpc(c, c.thread ? 'thread/resume' : 'thread/start', params);
  c.thread = r.thread.id; c.loaded = true; c.appliedRules = rules;
  // Цель живёт в Codex; после открытия диалога спрашиваем, есть ли она, чтобы показать значок.
  rpc(c, 'thread/goal/get', { threadId: c.thread }).then(g => { c.goal = g?.goal || null; if (c === active) header(); }).catch(() => {});
  if (!c.messages.length) for (const t of r.thread.turns || []) for (const item of t.items || []) ingest(c, item, true);
}
async function send(text = composer.value, opts = {}) {
  const c = opts.chat || active; text = text.trim(); if (!text && !(opts.attachments || (opts.chat ? [] : c.attachments)).length) return;
  const cmd = /^\/(\S+)\s*(.*)$/s.exec(text);
  if (!opts.literal && text.startsWith('!')) { if (!opts.chat) composer.value = ''; await ui.chats.shell(text.slice(1), { chat: c }); return; }
  if (!opts.literal && text.startsWith('/') && (!cmd || (!ui.commands.has(cmd[1]) && !cmd[1].includes('/')))) { ui.toast('Команда не найдена. Выбери команду в подсказках или открой /help.'); return; }
  if (!opts.literal && cmd && ui.commands.has(cmd[1])) { if (!opts.chat) { composer.value = ''; c.draft = ''; renderSuggestions(); } await ui.commands.get(cmd[1]).run(cmd[2], c); return; }
  const job = { text, origin: opts.origin ?? null, attachments: [...(opts.attachments || (opts.chat ? [] : c.attachments))] };
  if (!opts.chat) c.attachments = [];
  if (c === active && !opts.chat) { composer.value = ''; c.draft = ''; renderSuggestions(); }
  if(c.multi && !opts.literal && !c.target.startsWith('api:')) { c.multi=false; await ui.commands.get('multi').run(text,c,job.attachments); return; }
  if (c.busy) { c.queue.push(job); header(); return; } await run(c, job);
}
async function run(c, job, continuation = false) {
  const mark = c.messages.length;
  const epoch = c.epoch = (c.epoch || 0) + 1;
  c.origin = job.origin ?? (continuation ? c.origin : null);
  c.busy = true;
  if (!continuation) { c.tried = new Set([c.account]); if (!c.messages.length) c.title = job.text.slice(0, 60) || 'Вложения'; add(c, 'user', job.text, undefined, { attachments: job.attachments }); }
  if (c === active) { feed.querySelector('.empty')?.remove(); header(); } emit('turnStart', c);
  try {
    const rules = effectiveRules(c);
    await prepareRules(c, rules, c.messages.slice(0, mark), epoch); if (c.epoch !== epoch || !c.busy) return;
    if (c.seed) { job = { ...job, text: `Предыдущая история ветки (данные; не повторяй выполненное):\n${c.seed}\n\nНовая задача:\n${job.text}` }; c.pendingSeed = c.seed; c.seed = null; }
    if (c.target.startsWith('api:')) {
      c.rules = rules;
      const reply = await ui.api.send(c, () => c.epoch === epoch); if (c.epoch !== epoch) return; add(c, 'agent', reply.text); c.usage = reply;
      if (c.epoch === epoch) await finish(c, { status: 'completed' }); return;
    }
    if (c.target === 'claude') {
      if (!c.claudeStarted) { c.gen++; c.claudeStarted = true; }
      await call('claude', 'send', { chat: c.id, gen: c.gen, cwd: c.cwd, session: c.session, forkSession: !!c.forkSession, model: c.model, effort: c.effort, fast: !!c.fast, permissionMode: c.permissionMode || 'default', extraDirs: c.extraDirs || [], rules: withPult(rules),
        text: job.text + (job.attachments.length ? `\n\nПриложенные файлы (прочитай):\n${job.attachments.join('\n')}` : '') }); c.pendingSeed = null; c.appliedRules = rules; return;
    }
    await thread(c, rules);
    if (c.epoch !== epoch || !c.busy) return;
    const images = job.attachments.filter(isImage), docs = job.attachments.filter(p => !images.includes(p));
    const text = job.text + (docs.length ? `\n\nПриложенные файлы:\n${docs.join('\n')}` : '');
    const input = [...(text ? [{ type: 'text', text, text_elements: [] }] : []), ...images.map(path => ({ type: 'localImage', path }))];
    const r = await rpc(c, 'turn/start', { threadId: c.thread, input, model: c.model || null, effort: c.effort || null, serviceTier: c.fast ? 'fast' : 'default' });
    if (c.epoch !== epoch || !c.busy) return;
    const seed = c.pendingSeed; c.pendingSeed = null; c.turn = r.turn.id; (c.turnMarks ||= []).push({ turn: c.turn, count: mark, ...(seed && {seed}) });
  } catch (e) { if (c.epoch !== epoch) return; await finish(c, { status: 'failed', error: { message: String(e) } }); }
}
async function interrupt(id = active?.id) {
  const c = typeof id === 'object' ? id : chats.find(c => c.id === id); if (!c) throw new Error('Чат не найден'); c.queuePaused = true;
  if (c.shell) { c.shellInterrupted = true; await call('codex', 'shStop', { chat: c.id }); return; }
  if (c.target.startsWith('api:')) { c.epoch++; await call('api', 'stop', { chat: c.id }); await finish(c, { status: 'interrupted' }); return; }
  if (c.target === 'claude') {
    c.gen++; c.epoch++;
    await call('claude', 'stop', { chat: c.id, gen: c.gen }); c.claudeStarted = false; await finish(c, { status: 'interrupted' }); return;
  }
  if (c.turn) await rpc(c, 'turn/interrupt', { threadId: c.thread, turnId: c.turn });
  else { c.epoch++; c.gen++; await call('codex', 'stop', { chat: c.id, gen: c.gen }); c.connected = false; c.loaded = false; await finish(c, { status: 'interrupted' }); } header();
}
function ingest(c, it, done = false) {
  const kind = { agentMessage: 'agent', userMessage: 'user', commandExecution: 'command', fileChange: 'file', reasoning: 'thinking', mcpToolCall: 'command' }[it.type]; if (!kind) return;
  const text = it.text ?? it.command ?? (it.content || []).map(x => x.text || '').join('\n');
  return add(c, kind, kind === 'file' ? (it.changes || []).map(x => x.path).join('\n') : text, it.id, { done, output: it.aggregatedOutput || (it.summary || []).join('\n') });
}
async function prepareRules(c, rules, previous, epoch) {
  if (!['codex', 'claude'].includes(c.target) || (c.appliedRules === undefined ? !(rules && (c.thread || c.session)) : c.appliedRules === rules)) return;
  if (previous.length) await saveConversation({...c, localId:c.localId || crypto.randomUUID(), messages:previous});
  if (c.epoch !== epoch) return;
  c.gen++; await call(c.target, 'stop', {chat:c.id,gen:c.gen});
  if (c.epoch !== epoch) return;
  c.connected = false; c.loaded = false; c.claudeStarted = false; c.thread = null; c.session = null; c.forkSession = false;
  c.localId = crypto.randomUUID(); c.turnMarks = []; c.queuePaused = true;
  c.seed = previous.filter(m => ['user', 'agent'].includes(m.kind)).map(m => `${m.kind}: ${m.text}`).join('\n\n');
  c.appliedRules = rules; add(c, 'note', 'Новые правила применяются в отдельном контексте. Предыдущее продолжение сохранено в истории.');
}
async function saveConversation(c) {
  if (!c.messages.length) return;
  c.localId ||= crypto.randomUUID();
  await call('codex', 'saveLocal', { id: c.localId, value: { id: c.localId, title: c.title, provider: c.target.startsWith('api:') ? 'api' : c.target, target: c.target,
    model: c.model, effort: c.effort, fast: !!c.fast, permissionMode: c.permissionMode, rulesOverride: c.rulesOverride, appliedRules: c.appliedRules, sandbox: c.sandbox, extraDirs: c.extraDirs, turnMarks: c.turnMarks, directory: c.cwd, account: c.account, thread: c.thread, session: c.session, forkSession: !!c.forkSession, seed: c.seed, date: Date.now() / 1000,
    messages: c.messages.map(({ rpcId, params, ...m }) => ({ ...m, ...(['approval', 'question'].includes(m.kind) && { done: true }) })) } });
}
async function finish(c, turn) {
  if (c.pendingSeed && ['failed','interrupted'].includes(turn.status)) c.seed ||= c.pendingSeed;
  c.pendingSeed = null;
  c.busy = false; c.turn = null;
  for (const m of c.messages.filter(m => ['approval', 'question'].includes(m.kind) && !m.done)) { m.done = true; m.text += ' · Истекло'; if (c === active) renderMessage(m); }
  if (turn.error?.codexErrorInfo === 'usageLimitExceeded' && prefs.autoSwitch !== false) {
    const state = await call('codex', 'limits', { skip: c.account });
    const next = accounts.filter(a => !c.tried.has(a.home) && state[a.home]?.available)
      .map(a => ({ ...a, left: Math.min(...(state[a.home].limits || []).flatMap(l => l.windows.map(w => w.remaining_percent ?? 0))) }))
      .filter(a => Number.isFinite(a.left) && a.left > 0).sort((a, b) => b.left - a.left)[0];
    if (next) { add(c, 'note', `Лимит кончился. Продолжаю через ${next.name}.`); c.tried.add(next.home); c.account = next.home; c.connected = false; c.loaded = false;
      await run(c, { text: 'Продолжай с того места, где остановился до лимита.', attachments: [] }, true); return; }
  }
  if (turn.error) add(c, 'error', turn.error.message || 'Ход завершился ошибкой');
  if (turn.status === 'interrupted') add(c, 'note', 'Остановлено'); emit('turnEnd', c, { turn, failed: !!turn.error || ['failed', 'interrupted'].includes(turn.status) }); if (c === active) header();
  try { await saveConversation(c); } catch (e) { add(c, 'error', `Не удалось сохранить историю: ${e}`); }
  await loadHistory(); if (!c.queuePaused && !turn.error && turn.status !== 'interrupted' && c.queue.length) await run(c, c.queue.shift());
}
await on('codex', async e => {
  const c = chats.find(c => c.id === e.chat); if (!c) return;
  if (e.cli != null) { const m = c.messages.find(m => m.id === e.cli); if (m) { m.output = (m.output || '') + (e.delta || ''); if (c === active) renderMessage(m); } return; }
  if (e.gen !== c.gen) return;
  if (e.exit) { c.connected = false; c.loaded = false; if (c.busy) await finish(c, { status: 'failed', error: { message: e.reason || 'Codex отключился' } }); else { add(c, 'error', e.reason || 'Codex отключился'); if (c === active) header(); } return; }
  const p = e.params || {}, id = p.itemId || p.item?.id;
  if (e.id != null) {
    if (e.method === 'item/tool/requestUserInput' || e.method.includes('requestApproval') || ['execCommandApproval', 'applyPatchApproval', 'mcpServer/elicitation/request'].includes(e.method)) {
      const m = add(c, e.method === 'item/tool/requestUserInput' ? 'question' : 'approval', p.reason || p.command || 'Подтверди действие', undefined, { chat: c.id, gen: c.gen, rpcId: e.id, method: e.method, params: p });
      if (c.autoApprove && canAutoApprove(m)) await answer(m, true);
    } else await call('codex', 'respond', { chat: c.id, gen: e.gen, id: e.id, error: `Пока не поддерживается: ${e.method}` }); return;
  }
  if (p.threadId && c.thread && p.threadId !== c.thread) return;
  if (e.method === 'thread/goal/updated' || e.method === 'thread/goal/cleared') { c.goal = e.method === 'thread/goal/updated' ? (p.goal || null) : null; if (c === active) header(); return; }
  if (e.method === 'turn/started') { c.turn = p.turn.id; c.busy = true; if (c === active) header(); }
  else if (e.method === 'turn/plan/updated') add(c, 'plan', (p.explanation ? p.explanation + '\n\n' : '') + (p.plan || []).map(step => `${step.status === 'completed' ? '✓' : step.status === 'inProgress' ? '→' : '○'} ${step.step}`).join('\n'), `plan:${c.turn || c.epoch}`);
  else if (e.method === 'thread/tokenUsage/updated') c.usage = p.tokenUsage;
  else if (e.method === 'item/started') ingest(c, p.item);
  else if (e.method === 'item/completed') ingest(c, p.item, true);
  else if (e.method.endsWith('/delta') || e.method.endsWith('Delta')) {
    let m = c.messages.find(x => x.id === id);
    if (!m) m = add(c, e.method.includes('reasoning') ? 'thinking' : e.method.includes('commandExecution') ? 'command' : 'agent', '', id);
    const key = e.method.includes('outputDelta') ? 'output' : 'text'; m[key] = (m[key] || '') + (p.delta || ''); if (c === active) renderMessage(m);
  } else if (e.method === 'turn/completed') await finish(c, p.turn);
  else if (e.method === 'error' && !p.willRetry) add(c, 'error', p.error?.message || JSON.stringify(p));
});
await on('claude', async e => {
  const c = chats.find(c => c.id === e.chat); if (!c || c.gen !== e.gen) return;
  if (e.exit) {
    c.claudeStarted = false;
    if (c.busy) { await finish(c, { status: e.interrupted ? 'interrupted' : 'failed', error: { message: e.reason || 'Claude завершился' } }); }
    return;
  }
  const o = e.event;
  if (o.session_id) { c.session = o.session_id; c.forkSession = false; }
  if (o.type === 'control_request') {
    const p = o.request;
    if (p.subtype !== 'can_use_tool') { await call('claude', 'respond', { chat: c.id, id: o.request_id, response: { behavior: 'deny', message: 'Неизвестный запрос' } }); return; }
    const question = p.tool_name === 'AskUserQuestion';
    const params = { ...p, questions: (p.input?.questions || []).map(q => ({ ...q, id: q.question })) };
    const m = add(c, question ? 'question' : 'approval', question ? 'Claude спрашивает' : `Claude · ${p.tool_name}`, undefined, { claude: true, chat: c.id, gen: c.gen, rpcId: o.request_id, params });
    if (c.autoApprove && !question) await answer(m, true);
  } else if (o.type === 'control_cancel_request') {
    for (const m of c.messages.filter(m => m.rpcId === o.request_id)) { m.done = true; m.text += ' · Отменено'; if (c === active) renderMessage(m); }
  } else if (o.type === 'stream_event' && !o.parent_tool_use_id) {
    const ev = o.event, id = `claude:${c.gen}:${c.claudeMessage || 'message'}:${ev.index || 0}`;
    if (ev.type === 'message_start') c.claudeMessage = ev.message.id;
    if (ev.type === 'content_block_start') {
      const block = ev.content_block;
      if (block.type === 'text') add(c, 'agent', block.text || '', id);
      if (block.type === 'tool_use') add(c, 'command', block.name, block.id, { output: JSON.stringify(block.input, null, 2) });
    } else if (ev.type === 'content_block_delta' && ev.delta.type === 'text_delta') {
      let m = c.messages.find(m => m.id === id); if (!m) m = add(c, 'agent', '', id);
      m.text += ev.delta.text; if (c === active) renderMessage(m);
    }
  } else if (o.type === 'user') {
    for (const block of o.message?.content || []) {
      if (block.type !== 'tool_result') continue;
      const m = c.messages.find(m => m.id === block.tool_use_id); if (!m) continue;
      m.done = true; m.output = typeof block.content === 'string' ? block.content : (block.content || []).map(x => x.text || '').join('\n');
      if (c === active) renderMessage(m);
    }
  } else if (o.type === 'result') {
    c.usage = { ...(o.usage || {}), ...(o.total_cost_usd != null && { totalCostUsd: o.total_cost_usd }) };
    if (o.is_error) add(c, 'error', o.result || (o.errors || []).join('\n') || 'Claude завершил ход с ошибкой');
    await finish(c, { status: o.is_error ? 'failed' : 'completed', ...(o.is_error && { error: { message: 'Ошибка Claude' } }) });
  }
});
async function loadHistory() { history = await call('codex', 'threads', { hidden: showingTrash?[]:prefs.hidden || [], pins: prefs.pins || [] }); history.sort((a,b) => Number((prefs.pins || []).includes(b.id)) - Number((prefs.pins || []).includes(a.id)) || b.date - a.date); renderHistory(); }
async function historyPreference(key, value) { prefs[key] = value; await settings.set(key, value); await loadHistory();if(active)header(); }
ui.chats.pin = async id => historyPreference('pins', (prefs.pins || []).includes(id) ? prefs.pins.filter(x => x !== id) : [...(prefs.pins || []), id]);
ui.chats.trash = async id => { if (!id) throw new Error('Диалог не сохранён'); await historyPreference('hidden', [...new Set([...(prefs.hidden || []), id])]); };
ui.chats.restoreTrash = async id => historyPreference('hidden', id ? (prefs.hidden || []).filter(value => value !== id) : []);
function renderHistory() {
  let group;
  threadList.replaceChildren(...history.filter(t => (showingTrash?(prefs.hidden || []).includes(t.id):!(prefs.hidden || []).includes(t.id)) && `${t.title} ${t.cwd} ${t.account}`.toLowerCase().includes(query)).map(t => {
    const b = button(t.title || 'Без названия', async () => {
      if(showingTrash){await ui.chats.restoreTrash(t.id);return;}
      let c = chats.find(c => c.thread === t.id || (c.localId && t.id === `local:${c.localId}`) || (t.session && c.target === 'claude' && c.session === t.session));
      if (!c) {
        if (t.id.startsWith('claude:')) {
          const messages = await call('claude', 'readHistory', { session: t.session, path: t.path });
          open({ target: 'claude', session: t.session, title: t.title, cwd: t.cwd, messages }); return;
        }
        if (t.id.startsWith('local:')) {
          const saved = await call('codex', 'readLocal', { path: t.path });
          if (!saved.target || !Array.isArray(saved.messages)) throw new Error('Некорректная локальная история');
          open({ target: saved.target, localId: saved.id, title: saved.title, cwd: saved.directory, model: saved.model, effort: saved.effort || '', fast: !!saved.fast, permissionMode: saved.permissionMode || 'default', rulesOverride: saved.rulesOverride, appliedRules: saved.appliedRules, sandbox: saved.sandbox || prefs.sandbox || 'workspace-write', extraDirs: saved.extraDirs || [], turnMarks: saved.turnMarks || [], account: saved.account || accounts[0]?.home, thread: saved.thread, session: saved.session, forkSession: !!saved.forkSession, seed: saved.seed, messages: saved.messages }); return;
        }
        c = open({ thread: t.id, cwd: t.cwd || info.home, title: t.title, account: accounts.find(a => a.name === t.account)?.home || accounts[0]?.home });
        try { await thread(c); renderFeed(); } catch (e) { add(c, 'error', String(e)); }
      } else select(c);
    }, 'thread'); b.setAttribute('aria-label',t.title || 'Без названия'); b.title = `${t.account}\n${t.cwd}`;
    const metadata=h('small.history-meta',{'aria-hidden':'true'});metadata.dataset.text=`${t.account || ''} · ${basename(t.cwd || '')}`;b.append(metadata);
    const pin=button((prefs.pins || []).includes(t.id)?'★':'☆',()=>ui.chats.pin(t.id));pin.title='Закрепить диалог';
    const trash=showingTrash?button('Восстановить',()=>ui.chats.restoreTrash(t.id)):iconButton('trash','В корзину',()=>ui.chats.trash(t.id));
    const date=new Date(t.date*1000),today=new Date(),yesterday=new Date(Date.now()-86400000);
    const name=showingTrash?'Корзина':query?'Результаты поиска':(prefs.pins || []).includes(t.id)?'Закреплённые':date.toDateString()===today.toDateString()?'Сегодня':date.toDateString()===yesterday.toDateString()?'Вчера':Date.now()-date.getTime()<7*86400000?'На этой неделе':'Раньше';
    const row=h('div.history-row',{},b,h('div.history-row-actions',{},pin,trash));
    if(name===group)return row;group=name;return [sectionTitle(name),row];
  }).flat());
}
accountSelect.onchange = () => ui.chats.switchAccount(active, accountSelect.value).catch(e => { header(); ui.toast(String(e)); });
provider.onchange = () => {
  if (active.busy) { provider.value = active.target; ui.toast('Сначала останови текущий ход'); return; }
  open({ target: provider.value, cwd: active.cwd, model: ui.providers.find(p => p.id === provider.value)?.model || '' });
};
function renderSuggestions() {
  const prefix = /^\/(\S*)$/.exec(composer.value);
  const matches = prefix ? [...ui.commands.values()].filter(c => c.name.startsWith(prefix[1].toLowerCase())).sort((a,b) => a.name.localeCompare(b.name)) : [];
  suggestionIndex = Math.max(0, Math.min(suggestionIndex, matches.length - 1));
  suggestions.hidden = !matches.length;
  suggestions.replaceChildren(...matches.map((c, i) => {
    const item = button(`/${c.name} — ${c.hint}`, () => { composer.value = `/${c.name} `; active.draft = composer.value; composer.focus(); renderSuggestions(); }, i === suggestionIndex ? 'selected' : '');
    item.setAttribute('role', 'option'); item.setAttribute('aria-selected', String(i === suggestionIndex));
    return item;
  }));
  suggestions.children[suggestionIndex]?.scrollIntoView({ block: 'nearest' });
}
composer.oninput = () => { resizeComposer(); active.draft = composer.value; suggestionIndex = 0; renderSuggestions(); };
composer.onkeydown = e => {
  if (e.isComposing) return;
  if (!suggestions.hidden && ['ArrowUp', 'ArrowDown', 'Tab', 'Escape'].includes(e.key)) {
    e.preventDefault();
    if (e.key === 'Escape') suggestions.hidden = true;
    else if (e.key === 'Tab') suggestions.children[suggestionIndex]?.click();
    else { suggestionIndex = (suggestionIndex + (e.key === 'ArrowUp' ? -1 : 1) + suggestions.children.length) % suggestions.children.length; renderSuggestions(); }
    return;
  }
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send().catch(ui.toast); }
};
document.onkeydown = e => {
  if(e.key==='Escape' && active?.busy && !panel.open){e.preventDefault();interrupt().catch(ui.toast);return;}
  if (!(e.ctrlKey || e.metaKey)) return;
  if (e.key === 'n') { e.preventDefault(); open(); }
  if (e.key === 'k') { e.preventDefault(); app.classList.remove('sidebar-collapsed');search.focus(); }
  if (e.key === '\\') { e.preventDefault(); toggleSidebar(); }
  if (e.key === 'w' && !e.shiftKey) { e.preventDefault(); ui.chats.close(active).catch(ui.toast); }
  if (/^[1-9]$/.test(e.key) && chats[Number(e.key) - 1]) { e.preventDefault(); select(chats[Number(e.key) - 1]); }
};
const themes = new Map([
  ['dark', { id: 'dark', name: 'Графит', vars: { '--bg': '#101012', '--surface': '#1c1c20', '--raised': '#242428', '--line': '#303034', '--text': '#dedee1', '--muted': '#8b8b92', '--accent': '#d88965' } }],
  ['light', { id: 'light', name: 'Светлая', vars: { '--bg': '#f7f8fb', '--surface': '#ffffff', '--raised': '#edf0f5', '--line': '#d8dce5', '--text': '#17202d', '--muted': '#5e6879', '--accent': '#a3dc70' } }],
]);
ui.theme = {
  list: () => [...themes.values()],
  register(t) { if (!t?.id || !t.vars || Object.entries(t.vars).some(([key, value]) => !/^--[a-z-]+$/.test(key) || !/^#[0-9a-f]{6}$/i.test(value))) throw new Error('Неверная тема'); themes.set(t.id, t); },
  apply(id) { const theme = themes.get(id); if (!theme) throw new Error('Тема не найдена'); for (const [key, value] of Object.entries(themes.get('dark').vars)) document.documentElement.style.setProperty(key, value); for (const [key, value] of Object.entries(theme.vars)) document.documentElement.style.setProperty(key, value); document.documentElement.style.colorScheme = id === 'light' ? 'light' : 'dark'; prefs.theme = id; settings.set('theme', id); },
};
ui.openSettings = () => {
  const theme = h('select', {}, ...ui.theme.list().map(t => h('option', { value: t.id, selected: t.id === (prefs.theme || 'dark') }, t.name)));
  theme.onchange = () => ui.theme.apply(theme.value);
  const rules = h('textarea', { rows: 8, value: prefs.rules || '', placeholder: 'Общие инструкции для новых диалогов' });
  const auto = h('input', { type: 'checkbox', checked: prefs.autoSwitch !== false });
  const showRings = h('input', { type: 'checkbox', checked: prefs.showAccountRings !== false, onchange: async () => { prefs.showAccountRings = showRings.checked; await settings.set('showAccountRings', showRings.checked); await renderQuotas(); } });
  const sandbox = h('select', {}, ...['read-only', 'workspace-write', 'danger-full-access'].map(s => h('option', { value: s, selected: s === (prefs.sandbox || 'workspace-write') }, s)));
  const body = h('div.panel-body.settings', {}, h('label', {}, 'Тема', theme), h('label.inline', {}, showRings, 'Показывать панель лимитов под чатом'), h('label', {}, 'Правила', rules), h('label', {}, 'Доступ к файлам', sandbox), h('label.inline', {}, auto, 'Переключать аккаунт при исчерпании лимита'),
    button('Сохранить', async () => { for (const [k, v] of Object.entries({ rules: rules.value, sandbox: sandbox.value, autoSwitch: auto.checked })) { await settings.set(k, v); prefs[k] = v; } panel.close(); }, 'primary'));
  body.append(h('section',{},h('h3',{},'Подключения'),h('div.actions',{},...[["telegram","Telegram"],["api","API-подключения"],["support","Сервер / Бот"],["updater","Обновления"]].map(([id,label])=>button(label,()=>ui.openPanel(id))))));
  for (const s of ui.settings) { const el = h('section', {id:`settings-${s.id}`},h('h3',{},s.title)); s.render(el); body.append(el); }
  const links=h('nav.settings-nav',{},...['Общие','Подключения',...ui.settings.map(s=>s.title)].map((name,i)=>button(name,()=>{(i?body.querySelectorAll('section')[i-1]:body).scrollIntoView({block:'start'});})));
  modal('Настройки',h('div.settings-layout',{},links,body));
};
async function inlineCLI(c, request, label, ask) {
  if (c.busy) throw new Error('Сначала останови текущий ход');
  if (ask && !confirm(`Выполнить команду с правами пользователя?\n\n${label}`)) return;
  const id = crypto.randomUUID(); c.busy = true; c.shellInterrupted = false; c.shell = id; c.origin = null;
  const m = add(c, 'command', label, id, { output: '' }); if (c === active) header(); emit('turnStart', c);
  try {
    const code = await call('codex', request.program ? 'exec' : 'sh', { ...request, chat: c.id, id, cwd: c.cwd, home: c.account });
    m.done = true; m.output += `\nКод выхода: ${code}`; if (c === active) renderMessage(m);
    c.shell = null; await finish(c, { status: c.shellInterrupted ? 'interrupted' : code === 0 ? 'completed' : 'failed', ...(!c.shellInterrupted && code !== 0 && { error: { message: `Команда завершилась с кодом ${code}` } }) });
    return code;
  } catch (e) { c.shell = null; c.busy = false; m.done = true; add(c, 'error', String(e)); emit('turnEnd', c, { turn: { status: 'failed' }, failed: true }); if (c === active) header(); throw e; }
}
ui.chats.shell = (command, { chat = active, confirm: ask = true } = {}) => inlineCLI(chat, { cmd: command }, command, ask);
ui.chats.exec = (program, args = [], { chat = active, confirm: ask = false } = {}) => inlineCLI(chat, { program, arguments: args }, [program, ...args].join(' '), ask);
ui.chats.rpc = async (c, method, params = {}) => { await connect(c); return rpc(c, method, params); };
/** Поднять диалог в Codex (начать или возобновить), чтобы команды вроде /goal работали после перезапуска и смены аккаунта. */
ui.chats.ensureThread = async c => { await thread(c); return c.thread; };
ui.chats.setGoal = (c, goal) => { c.goal = goal || null; if (c === active) header(); };
ui.chats.save = saveConversation;
ui.chats.restart = async c => {
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  c.gen++; c.epoch = (c.epoch || 0) + 1;
  if (c.target === 'claude') { await call('claude', 'stop', { chat: c.id, gen: c.gen }); c.claudeStarted = false; }
  else if (c.target === 'codex') { await call('codex', 'stop', { chat: c.id, gen: c.gen }); c.connected = false; c.loaded = false; }
  else throw new Error('Перезапуск доступен в Codex и Claude');
};
ui.chats.configure = async (c, changes) => {
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  if (!['codex', 'claude'].includes(c.target)) throw new Error('Настройки модели API меняются в подключении');
  if (Object.keys(changes).some(k => !['model', 'effort', 'fast', 'permissionMode'].includes(k))) throw new Error('Неизвестная настройка модели');
  if ('effort' in changes && !ui.models.efforts(c.target).includes(changes.effort)) throw new Error('Неверная глубина размышлений');
  if ('permissionMode' in changes && (c.target !== 'claude' || !['default', 'plan'].includes(changes.permissionMode))) throw new Error('Неверный режим Claude');
  if (c.target === 'claude' && c.claudeStarted) await ui.chats.restart(c);
  Object.assign(c, changes);
  for (const field of ['model', 'effort']) if (field in changes) {
    const key = c.target + (field === 'model' ? 'Model' : 'Effort');
    await settings.set(key, c[field]); prefs[key] = c[field];
  }
  if (c === active) header();
  await saveConversation(c);
};
ui.chats.edit = async (c, id, text, attachments = []) => {
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  const index = c.messages.findIndex(m => m.id === id && m.kind === 'user');
  if (index < 0) throw new Error('Сообщение не найдено');
  if (!text.trim() && !attachments.length) throw new Error('Нужно сообщение или вложение');
  await saveConversation(c); c.queuePaused = true;
  const messages = c.messages.slice(0,index).filter(m => ['user','agent','note'].includes(m.kind)).map(m => ({...m, id:crypto.randomUUID()}));
  const fork = open({target:c.target,cwd:c.cwd,account:c.account,model:c.model,effort:c.effort,fast:!!c.fast,sandbox:c.sandbox,extraDirs:[...(c.extraDirs||[])],permissionMode:c.permissionMode,rulesOverride:c.rulesOverride,
    title:`${c.title} · правка`,messages,localId:crypto.randomUUID()});
  if (!c.target.startsWith('api:')) fork.seed = messages.filter(m => ['user','agent'].includes(m.kind)).map(m => `${m.kind}: ${m.text}`).join('\n\n');
  await saveConversation(fork); await send(text,{chat:fork,literal:true,attachments}); return fork;
};
ui.chats.rules = c => effectiveRules(c);
ui.chats.openRules = c => {
  const global = h('textarea',{value:prefs.rules || '',rows:5,'aria-label':'Общие правила'});
  const override = h('input',{type:'checkbox',checked:c.rulesOverride !== undefined});
  const local = h('textarea',{value:effectiveRules(c),rows:5,'aria-label':'Правила текущего чата',disabled:!override.checked});
  override.onchange = () => local.disabled = !override.checked;
  modal('Правила приложения и чата',h('div.panel-body.settings',{},h('label',{},'Общие правила',global),h('label.inline',{},override,'Переопределить общие правила в этом чате'),local,
    h('p',{},'Новые правила начатого Codex/Claude-диалога применятся в отдельном контексте с сохранённой историей. Очередь останется на паузе.'),
    button('Сохранить правила',async()=>{await settings.set('rules',global.value);prefs.rules=global.value;c.rulesOverride=override.checked?local.value:undefined;await saveConversation(c);panel.close();},'primary')));
};
ui.chats.review = async (c, instructions) => {
  if (c.target !== 'codex') throw new Error('Review доступно в Codex');
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  const mark = c.messages.length, epoch = c.epoch = (c.epoch || 0) + 1;
  c.busy = true; c.origin = null; emit('turnStart', c); if (c === active) header();
  try {
    const rules = effectiveRules(c); await prepareRules(c, rules, [...c.messages], epoch); if (c.epoch !== epoch || !c.busy) return;
    await thread(c, rules); if (c.epoch !== epoch || !c.busy) return;
    const result = await rpc(c, 'review/start', { threadId: c.thread, delivery: 'inline',
      target: instructions ? { type: 'custom', instructions } : { type: 'uncommittedChanges' } });
    if (c.epoch !== epoch || !c.busy) return;
    c.turn = result.turn.id; (c.turnMarks ||= []).push({ turn: c.turn, count: mark });
  } catch (e) { if (c.epoch === epoch) await finish(c, { status: 'failed', error: { message: String(e) } }); }
};
ui.chats.undo = async c => {
  if (c.target !== 'codex') throw new Error('Откат контекста доступен в Codex');
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  const mark = c.turnMarks?.at(-1); if (!mark || !c.thread) throw new Error('Нет хода для отката');
  if (!confirm('Убрать последний ход из контекста Codex? Изменения файлов останутся на диске.')) return;
  c.busy = true; if (c === active) header();
  try {
    await ui.chats.rpc(c, 'thread/revert', { threadId: c.thread, beforeTurnId: mark.turn });
    c.turnMarks.pop(); c.messages = c.messages.slice(0, mark.count); if (mark.seed) c.seed = mark.seed;
    add(c, 'note', 'Последний ход убран из разговора. Изменения файлов проверь через /diff.');
    if (c === active) renderFeed(); await saveConversation(c);
  } finally { c.busy = false; if (c === active) header(); }
};
ui.chats.close = async c => {
  if (!chats.includes(c)) return;
  if (c.busy) throw new Error('Сначала останови текущий ход');
  await saveConversation(c);
  if (c.target === 'claude') await call('claude', 'stop', { chat: c.id, gen: c.gen });
  if (c.target === 'codex') await call('codex', 'stop', { chat: c.id, gen: c.gen });
  const index = chats.indexOf(c); chats.splice(index, 1); emit('close', c);
  if (active === c) { if (chats.length) select(chats[Math.min(index, chats.length - 1)]); else open(); }
  else header();
  await loadHistory();
};
ui.chats.accounts = () => accounts;
ui.chats.switchAccount = async (c, home) => {
  if (c.target !== 'codex') throw new Error('Аккаунты переключаются в Codex');
  if (c.busy) throw new Error('Сначала заверши текущий ход');
  if (!accounts.some(a => a.home === home)) throw new Error('Аккаунт не найден');
  await ui.chats.restart(c); c.account = home; if (c === active) header(); await saveConversation(c);
};
ui.chats.refresh = c => { if (c === active) { header(); renderFeed(); } };
ui.chats.setAutoApprove = async (c, enabled) => {
  c.autoApprove = enabled;
  if (c === active) header();
  if (enabled && c.busy) for (const m of c.messages.filter(m => !m.done && m.gen === c.gen && canAutoApprove(m))) await answer(m, true);
};
ui.chats.history = async () => { search.focus(); await loadHistory(); };
ui.chats.resumeQueue = async c => { c.queuePaused = false; if (!c.busy && c.queue.length) await run(c, c.queue.shift()); header(); };
ui.chats.answer = async (chatId, messageId, value) => {
  const c = chats.find(c => c.id === chatId), m = c?.messages.find(m => m.id === messageId);
  if (!m || m.done || !['approval', 'question'].includes(m.kind) || !c.busy) throw new Error('Запрос уже неактивен');
  if (m.kind === 'approval') { if (typeof value !== 'boolean') throw new Error('Разрешение должно быть true или false'); await answer(m, value); }
  else {
    if (!value?.answers || typeof value.answers !== 'object') throw new Error('Нужны ответы на вопросы');
    for (const q of m.params.questions || []) if (!Array.isArray(value.answers[q.id]?.answers) || value.answers[q.id].answers.some(a => typeof a !== 'string')) throw new Error('Неверный ответ на вопрос');
    await respond(m, value); m.done = true; if (c === active) renderMessage(m);
  }
};
Object.assign(ui.chats, { draft: () => composer.value, setDraft: text => { composer.value = text; active.draft = text; resizeComposer(); composer.focus(); }, current: () => active, list: () => chats, activate: id => { const c = chats.find(c => c.id === id); if (!c) throw new Error('Чат не найден'); select(c); return c; }, stop: interrupt, open, send, insert: text => { composer.value += text; resizeComposer(); composer.focus(); }, note: (text, c = active) => add(c, 'note', text), onEvent: fn => events.addEventListener('event', e => fn(e.detail)) });
async function renderQuotas() {
  try {
    const state=await call('limits','state');
    // Аккаунт убрали или переименовали — список в меню чата обновляется вместе с кольцами.
    const fresh=await call('app','accounts').catch(()=>null);
    if(Array.isArray(fresh)&&JSON.stringify(fresh)!==JSON.stringify(accounts)){accounts=fresh;accountSelect.replaceChildren(...accounts.map(a=>h('option',{value:a.home},a.name)));accountSelect.value=active?.account;}
    const pickWindow=(acc,long)=>((acc.limits||[]).find(l=>!l.name||l.name.toLowerCase()==='codex')||acc.limits?.[0])?.windows?.find(w=>long?w.minutes>=10000:w.minutes<10000);
    const until=ts=>{if(!ts)return 'сброс неизвестен';const m=Math.round((ts*1000-Date.now())/60000);return m<=0?'уже сброшен':m<60?`через ${m} мин`:m<1440?`через ${Math.floor(m/60)} ч ${m%60} мин`:new Date(ts*1000).toLocaleString('ru',{weekday:'short',hour:'2-digit',minute:'2-digit'});};
    const tile=(name,home,five,week,extra='')=>{
      const v=[five?.remaining_percent,week?.remaining_percent],low=Math.min(...v.filter(Number.isFinite));
      const b=h('button.ring-tile'+extra,{type:'button'},rings(v[0],v[1],Number.isFinite(low)?Math.round(low):'—'),h('span',{},name));
      b.title=`${name}\n5 часов: ${Number.isFinite(v[0])?Math.round(v[0])+'%':'—'} · ${until(five?.resets_at)}\nНеделя: ${Number.isFinite(v[1])?Math.round(v[1])+'%':'—'} · ${until(week?.resets_at)}`+(home?'\nЩелчок — перейти на аккаунт, правый щелчок — действия':'');
      if(home){b.dataset.home=home;b.onclick=()=>ui.chats.switchAccount(active,home).catch(e=>ui.toast(String(e)));b.oncontextmenu=e=>{e.preventDefault();call('limits','tileMenu',{home,name,window:'main'}).catch(ui.toast);};b.disabled=active?.busy||active?.target!=='codex';b.classList.toggle('current',active?.target==='codex'&&home===active?.account);}
      return b;
    };
    const rows=state?.codex?.accounts||[];
    let claude;try{claude=typeof state?.claude==='string'?JSON.parse(state.claude):state?.claude;}catch{}
    const cl=k=>{const r=claude?.rate_limits?.[k];return r&&{remaining_percent:typeof r.used_percentage==='number'?100-r.used_percentage:NaN,resets_at:r.resets_at};};
    ringBar.replaceChildren(...rows.map(acc=>tile(acc.name,acc.home||accounts.find(a=>a.name===acc.name)?.home||'',pickWindow(acc,false),pickWindow(acc,true))),
      ...(claude?.rate_limits?[tile('Claude','',cl('five_hour'),cl('seven_day'),'.claude')]:[]),
      h('button.ring-hide', { type: 'button', title: 'Скрыть панель лимитов', 'aria-label': 'Скрыть панель лимитов', onclick: async () => { prefs.showAccountRings = false; ringBar.hidden = true; await settings.set('showAccountRings', false); } }, '×'));
    ringBar.hidden=prefs.showAccountRings === false || ringBar.childElementCount < 2;
  } catch { /* Ошибки обновления показывает сам виджет. */ }
}
await on('limits',renderQuotas);
try {
  [accounts, info, prefs] = await Promise.all([call('app', 'accounts'), call('app', 'info'), call('app', 'settings')]);
  sidebar.querySelector('.app-version').textContent=`Пульт · ${info.version}`;
  accountSelect.replaceChildren(...accounts.map(a => h('option', { value: a.home }, a.name))); if (themes.has(prefs.theme)) ui.theme.apply(prefs.theme); open(); await loadHistory(); refreshExtensions(); ui.markReady(); renderQuotas(); await call('app', 'ready', { label: 'main' });
} catch (e) { app.append(h('pre', {}, `Не удалось запустить Пульт: ${e}`)); }
