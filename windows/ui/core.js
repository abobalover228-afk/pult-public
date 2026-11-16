// Общий слой интерфейса. Каждый файл ui/*.js — ES-модуль, сам регистрирует свои части через `ui`.
// Оболочку (сайдбар, область чата, панели, настройки) рисует chat.js и он же наполняет `ui.chats`.
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

/** Вызов Rust: call('codex', 'start', {...}) → Promise<значение>; ошибка — строка. */
export const call = (module, method, args = {}) => invoke('call', { module, method, args });
/** События из Rust: on('codex', payload => …). */
export const on = (event, fn) => listen(event, e => fn(e.payload));
/** Настройки (settings.json в папке данных). */
export const settings = { get: key => call('app', 'get', { key }), set: (key, value) => call('app', 'set', { key, value }) };
/** h('div.cls#id', {onclick, …}, ...children) → элемент. */
export function h(spec, props = {}, ...kids) {
  const [tag, ...rest] = spec.split(/(?=[.#])/);
  const el = document.createElement(tag || 'div');
  for (const r of rest) r[0] === '.' ? el.classList.add(r.slice(1)) : (el.id = r.slice(1));
  for (const [k, v] of Object.entries(props)) k in el ? (el[k] = v) : el.setAttribute(k, v);
  el.append(...kids.flat().filter(x => x != null && x !== false));
  return el;
}

const bus = new EventTarget();
const changed = () => bus.dispatchEvent(new Event('change'));
export const ui = {
  commands: new Map(),   // slash-команды: {name, hint, run(args, chat)}
  sidebar: [],           // кнопки сайдбара: {id, title, icon, open(), badge?()}
  panels: new Map(),     // панели: {id, title, slot: 'main'|'left'|'right'|'sheet', render(el)}
  settings: [],          // разделы настроек: {id, title, render(el)}
  composer: [],          // кнопки у поля ввода: {id, title, icon, run(chat)}
  addCommand(c) { this.commands.set(c.name, c); changed(); },
  addSidebar(b) { this.sidebar.push(b); changed(); },
  addPanel(p) { this.panels.set(p.id, p); changed(); },
  addSettings(s) { this.settings.push(s); changed(); },
  addComposerButton(b) { this.composer.push(b); changed(); },
  remove(kind, id) { const c = this[kind]; c instanceof Map ? c.delete(id) : c.splice(0, c.length, ...c.filter(x => x.id !== id)); changed(); },
  /** Оболочка перерисовывает свои списки по этому событию. */
  onChange(fn) { bus.addEventListener('change', fn); },
  // Ниже — реализует chat.js (до его загрузки вызывать нельзя; вызывайте из обработчиков, а не при импорте):
  openPanel(id) {}, closePanel(id) {}, toast(text) {}, openSettings(id) {},
  theme: { list() { return []; }, apply(id) {}, register(t) {} },  // t: {id, name, vars: {'--bg': '#…', …}}
  chats: {
    current() { return null; },            // активный чат: {id, title, target: 'codex'|'claude'|'api', cwd, account, busy, messages}
    list() { return []; },
    open(opts) {},                         // {target, cwd, title, account, prompt?} → чат
    send(text, opts) {},                   // в активный чат (или opts.chat); opts.attachments — пути
    insert(text) {},                       // вставить текст в поле ввода
    note(text, chat) {},                   // служебная строка в ленте
    onEvent(fn) {},                        // fn({type: 'turnStart'|'turnEnd'|'message'|'open'|'close', chat, …})
  },
};
