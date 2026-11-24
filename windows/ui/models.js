import { ui, h } from './core.js';
import { button } from './render.js';

const levels = {
  codex: ['', 'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'],
  claude: ['', 'low', 'medium', 'high', 'xhigh', 'max'],
  devin: ['', 'low', 'medium', 'high', 'xhigh', 'max'],
};
const devinModes = [['default', 'Code — пишет и правит код'], ['smart', 'Smart — сам решает, что безопасно'], ['ask', 'Ask — только отвечает, без правок'], ['plan', 'Plan — сначала план']];
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
    if (c.target === 'devin') {
      // Каталог отдаёт сам Devin CLI (session/new → configOptions): все модели аккаунта, с вариантами глубины.
      const options = await ui.chats.devinCatalog(c);
      const models = options?.find(o => o.id === 'model')?.options || [];
      if (!models.length) throw new Error('Devin не вернул список моделей. Проверь вход: devin auth status');
      return models.map(o => ({ model: o.value, displayName: o.name, family: o.name, description: o.description || '' }));
    }
    if (c.target !== 'codex') throw new Error('Каталог доступен в Codex, Claude и Devin');
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
      // У Devin десятки вариантов одной модели (глубина, Fast, Lightning) — группируем по семействам.
      const families = c.target === 'devin' ? [...new Set(rows.map(r => r.family))] : [];
      const select = h('select', { 'aria-label': 'Выбор модели' }, h('option', { value: '' }, 'По умолчанию'),
        ...(c.target === 'devin' ? families.map(f => h('optgroup', { label: f }, ...rows.filter(r => r.family === f).map(r => h('option', { value: r.model }, r.model)))) :
          rows.map(row => h('option', { value: row.model || row.id }, row.displayName || row.model || row.id))));
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
      const mode = h('select', { 'aria-label': 'Режим Devin' }, ...devinModes.map(([value, label]) => h('option', { value }, label)));
      mode.value = devinModes.some(([v]) => v === c.permissionMode) ? c.permissionMode : 'default';
      controls.append(h('label', {}, 'Модель', select), detail, h('label', {}, 'Глубина размышлений', effort),
        h('label.inline', {}, fast, 'Fast — возможен дополнительный расход у провайдера'),
        ...(c.target === 'claude' ? [h('label.inline', {}, plan, 'Режим планирования Claude')] : []),
        ...(c.target === 'devin' ? [h('label', {}, 'Режим работы', mode), h('p', {}, 'При «Полном доступе» и «Подтверждать за меня» Devin работает в режиме Bypass — без запросов.')] : []),
        button('Применить', async () => {
          await ui.chats.configure(c, { model: select.value, effort: effort.value, fast: fast.checked,
            ...(c.target === 'claude' && { permissionMode: plan.checked ? 'plan' : 'default' }),
            ...(c.target === 'devin' && { permissionMode: mode.value }) });
          ui.closePanel('models');
        }, 'primary'));
      status.textContent = `${{ codex: 'Каталог установленного Codex', claude: 'Модели Claude Code', devin: 'Модели аккаунта Devin' }[c.target]} · ${rows.length}`;
    } catch (e) { if (token === generation) { status.textContent = String(e); controls.replaceChildren(button('Повторить', load)); } }
  };
  load();
} });
