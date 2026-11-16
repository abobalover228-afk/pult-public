import { ui, h } from './core.js';
import { button } from './render.js';

const levels = {
  codex: ['', 'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'],
  claude: ['', 'low', 'medium', 'high', 'xhigh', 'max'],
};
let chat, generation = 0;
ui.models = {
  efforts: provider => levels[provider] || [],
  open(c) {
    if (c.busy) throw new Error('Сначала заверши текущий ход');
    if (!levels[c.target]) throw new Error('Модель API меняется в настройках подключения');
    ui.closePanel('models'); chat = c; ui.openPanel('models');
  },
  async list(c) {
    if (c.target === 'claude') return ['opus', 'sonnet', 'haiku'].map(model => ({ model, displayName: model, description: 'Версия из установленного Claude Code' }));
    if (c.target !== 'codex') throw new Error('Каталог доступен в Codex и Claude');
    const rows = [], cursors = new Set(); let cursor;
    for (let page = 0; page < 100; page++) {
      const result = await ui.chats.rpc(c, 'model/list', { limit: 100, ...(cursor && { cursor }) });
      if (!Array.isArray(result?.data)) throw new Error('CLI не вернул список моделей');
      rows.push(...result.data.filter(row => !row.hidden && typeof (row.model || row.id) === 'string'));
      if (!result.nextCursor) return [...new Map(rows.map(row => [row.model || row.id, row])).values()];
      if (cursors.has(result.nextCursor)) throw new Error('CLI повторил страницу каталога моделей');
      cursors.add(result.nextCursor); cursor = result.nextCursor;
    }
    throw new Error('Слишком много страниц каталога моделей');
  },
};
ui.addPanel({ id: 'models', title: 'Модель и режим работы', onClose: () => generation++, render: el => {
  const c = chat, token = ++generation;
  const status = h('p', { role: 'status' }, 'Загружаю модели…');
  const controls = h('div.settings'); el.append(status, controls);
  const load = async () => {
    controls.replaceChildren(); status.textContent = 'Загружаю модели…';
    try {
      const rows = await ui.models.list(c); if (token !== generation) return;
      const select = h('select', { 'aria-label': 'Выбор модели' }, h('option', { value: '' }, 'По умолчанию'),
        ...rows.map(row => h('option', { value: row.model || row.id }, row.displayName || row.model || row.id)));
      if (c.model && !rows.some(row => (row.model || row.id) === c.model)) select.append(h('option', { value: c.model }, c.model));
      select.value = c.model || '';
      const detail = h('p');
      const effort = h('select', { 'aria-label': 'Глубина размышлений' });
      function choices(initial = false) {
        const row = rows.find(row => (row.model || row.id) === select.value);
        detail.textContent = row?.description || '';
        const supported = row?.supportedReasoningEfforts?.map(e => e.reasoningEffort).filter(e => levels.codex.includes(e));
        const values = supported?.length ? ['', ...new Set(supported)] : levels[c.target];
        effort.replaceChildren(...values.map(value => h('option', { value }, value || 'Автоматически')));
        effort.value = initial && values.includes(c.effort || '') ? (c.effort || '') : '';
      }
      choices(true); select.onchange = () => choices();
      const fast = h('input', { type: 'checkbox', checked: !!c.fast });
      const plan = h('input', { type: 'checkbox', checked: c.permissionMode === 'plan' });
      controls.append(h('label', {}, 'Модель', select), detail, h('label', {}, 'Глубина размышлений', effort),
        h('label.inline', {}, fast, 'Fast — возможен дополнительный расход у провайдера'),
        ...(c.target === 'claude' ? [h('label.inline', {}, plan, 'Режим планирования Claude')] : []),
        button('Применить', async () => {
          await ui.chats.configure(c, { model: select.value, effort: effort.value, fast: fast.checked,
            ...(c.target === 'claude' && { permissionMode: plan.checked ? 'plan' : 'default' }) });
          ui.closePanel('models');
        }, 'primary'));
      status.textContent = `${c.target === 'codex' ? 'Каталог установленного Codex' : 'Модели Claude Code'} · ${rows.length}`;
    } catch (e) { if (token === generation) { status.textContent = String(e); controls.replaceChildren(button('Повторить', load)); } }
  };
  load();
} });
