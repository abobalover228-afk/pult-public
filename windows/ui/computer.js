import { call, on, ui, h } from './core.js';
import { button } from './render.js';
const root = document.querySelector('#computer-controller');
async function controller(el) {
  async function render() {
    const state = await call('computer', 'state');
    el.replaceChildren(h('h2', {}, state.enabled ? '● Экраном управляет AI' : 'Управление экраном выключено'),
      h('p', {}, 'Computer use: снимки экрана, мышь и клавиатура. Включай для своей текущей задачи. Остановка блокирует следующие действия.'),
      button(state.enabled ? 'СТОП — отключить управление' : 'Разрешить управление этим сеансом', async () => { await call('computer', state.enabled ? 'stop' : 'enable'); await render(); }, state.enabled ? 'danger' : 'primary'),
      !state.supported ? h('p.limit-error', {}, 'Нативное управление доступно в сборках для Windows и macOS.') : null);
  }
  await on('computer', render); await render();
}
if (root) {
  window.addEventListener('pult-error', e => { root.append(h('p.limit-error', { role: 'alert' }, e.detail)); });
  document.addEventListener('keydown', e => { if (e.key === 'Escape') call('computer', 'stop'); });
  await controller(root);
} else {
  ui.addPanel({ id: 'computer', title: 'Computer use', render: el => el.append(h('p', {}, 'Нативный Rust-инструмент работает через MCP: скриншоты, мышь, клавиатура. После подключения модель откроет отдельное окно контроллера. Управление включается пользователем в том окне и выключается кнопкой СТОП.'), button('Настроить MCP', () => ui.openPanel('mcp'), 'primary')) });
  ui.addSidebar({ id: 'computer', title: 'Computer use', icon: '▣', open: () => ui.openPanel('computer') });
}
