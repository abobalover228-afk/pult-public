import { call, ui, h } from './core.js';
import { button } from './render.js';
let connections = [];
async function refresh() {
  connections = await call('api', 'list');
  ui.setProviders(connections.map(c => ({ id: `api:${c.id}`, title: c.name, model: c.model })));
}
function editor(el, c = { id: crypto.randomUUID(), name: '', baseURL: '', model: '' }) {
  const name = h('input', { value: c.name, placeholder: 'Название подключения', required: true });
  const url = h('input', { value: c.baseURL, placeholder: 'https://provider.example/v1', required: true });
  const model = h('input', { value: c.model, placeholder: 'Модель', required: true });
  const key = h('input', { type: 'password', autocomplete: 'new-password', placeholder: connections.some(x => x.id === c.id) ? 'Оставь пустым, чтобы сохранить ключ' : 'API-ключ', required: !connections.some(x => x.id === c.id) });
  const form = h('form.settings', {}, h('label', {}, 'Название', name), h('label', {}, 'Base URL', url), h('label', {}, 'Модель', model), h('label', {}, 'API-ключ', key),
    h('small', {}, 'Ключ хранится в локальном .env приложения. При отправке используется API выбранного провайдера; запросы могут оплачиваться по его тарифам.'), h('button.primary', { type: 'submit' }, 'Сохранить подключение'));
  form.onsubmit = async e => {
    e.preventDefault(); const submit = form.querySelector('button[type=submit]'); submit.disabled = true;
    try { await call('api', 'save', { connection: { id: c.id, name: name.value, baseURL: url.value, model: model.value }, key: key.value }); key.value = ''; await refresh(); render(el); ui.toast('Подключение сохранено'); }
    catch (e) { ui.toast(String(e)); } finally { submit.disabled = false; }
  };
  el.replaceChildren(form);
}
function render(el) {
  el.replaceChildren(h('p', {}, 'Совместимые с Chat Completions API. Текст, изображения и локальная история.'),
    ...connections.map(c => h('div.limit-card', {}, h('h3', {}, c.name), h('small', {}, `${c.baseURL} · ${c.model}`),
      h('div.actions', {}, button('Открыть чат', () => { ui.chats.open({ target: `api:${c.id}`, model: c.model }); ui.closePanel(); }), button('Изменить', () => editor(el, c)), button('Удалить', async () => { if (!confirm(`Удалить подключение «${c.name}» и его ключ? История останется на диске.`)) return; await call('api', 'remove', { id: c.id }); await refresh(); render(el); })))),
    button('+ Подключение', () => editor(el)));
}
ui.addPanel({ id: 'api', title: 'API-подключения', render });
ui.addSidebar({ id: 'api', title: 'API-подключения', icon: '↗', open: () => ui.openPanel('api') });
ui.addSettings({ id: 'api', title: 'API', render: el => el.append(button('Управлять подключениями', () => ui.openPanel('api'))) });
ui.api = {
  async send(c, current = () => true) {
    const messages = [];
    for (const m of c.messages.filter(m => m.kind === 'user' || m.kind === 'agent')) {
      const content = [{ type: 'text', text: m.text || '(вложение)' }];
      for (const path of m.attachments || []) {
        if (/\.(png|jpe?g|webp|gif)$/i.test(path)) content.push({ type: 'image_url', image_url: { url: await call('codex', 'readImage', { path }) } });
        else content.push({ type: 'text', text: `Файл ${path}:\n${await call('api', 'readText', { path })}` });
      }
      messages.push({ role: m.kind === 'user' ? 'user' : 'assistant', content: content.length === 1 ? content[0].text : content });
    }
    if (!current()) throw new Error('Запрос отменён до отправки');
    return call('api', 'send', { chat: c.id, connection: c.target.slice(4), messages: [...(c.rules ? [{ role: 'system', content: c.rules }] : []), ...messages] });
  },
};
try { await refresh(); } catch (e) { ui.toast(String(e)); }
