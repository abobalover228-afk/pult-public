import { call, ui, h } from './core.js';
import { button } from './render.js';
async function render(el) {
  const accounts = await call('app', 'accounts');
  const provider = h('select', { 'aria-label': 'MCP провайдер' }, h('option', { value: 'codex' }, 'Codex'), h('option', { value: 'claude' }, 'Claude'));
  const account = h('select', { 'aria-label': 'MCP аккаунт' }, ...accounts.map(a => h('option', { value: a.home }, a.name)));
  provider.onchange = () => account.hidden = provider.value !== 'codex';
  const list = h('div'), name = h('input', { placeholder: 'Имя MCP-сервера', value: 'my-server' });
  const executable = h('input', { placeholder: 'Программа (например, npx)' }), args = h('textarea', { placeholder: 'JSON-массив аргументов', value: '[]', rows: 3 });
  const url = h('input', { placeholder: 'HTTPS URL вместо программы (необязательно)' });
  const options = () => ({ provider: provider.value, home: account.value });
  const reload = async () => {
    for (const c of ui.chats.list().filter(c => c.target === 'codex' && c.connected && !c.busy)) {
      try { await call('codex', 'rpc', { chat: c.id, gen: c.gen, method: 'config/mcpServer/reload', params: {} }); } catch {}
    }
    ui.toast('MCP сохранён. Для Claude открой новый диалог; активный ход Codex сначала заверши.');
  };
  el.replaceChildren(h('div.settings', {}, h('label', {}, 'Провайдер', provider), h('label', {}, 'Аккаунт Codex', account),
    button('Подключить нативный Computer use', async () => { await call('mcp', 'add', { ...options(), name: 'pult-computer', native: true }); await reload(); }, 'primary'),
    h('small', {}, 'Модель получит инструмент computer. Его отдельное видимое окно требует включения управления пользователем.'),
    button('Обновить список MCP', async () => { const rows = await call('mcp', 'list', options()); list.replaceChildren(...rows.map(r => h('p', {}, `${r.enabled === false ? '○' : '●'} ${r.name}`))); }), list,
    h('h3', {}, 'Внешний MCP'), h('label', {}, 'Имя', name), h('label', {}, 'Программа', executable), h('label', {}, 'Аргументы', args), h('label', {}, 'Или HTTP', url),
    h('small', {}, 'Добавляй доверенные серверы. Не помещай ключи в URL и аргументы; используй .env сервера.'),
    button('Добавить MCP', async () => { const request = { ...options(), name: name.value, ...(url.value ? { url: url.value } : { executable: executable.value, arguments: JSON.parse(args.value) }) }; await call('mcp', 'add', request); await reload(); })));
}
ui.addPanel({ id: 'mcp', title: 'MCP-серверы', render });
ui.addSidebar({ id: 'mcp', title: 'MCP-серверы', icon: '⌘', open: () => ui.openPanel('mcp') });
