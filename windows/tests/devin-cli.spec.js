import { test, expect } from '@playwright/test';
// Devin CLI (ACP) как провайдер наравне с Codex и Claude.
const options = [
  { id: 'mode', currentValue: 'accept-edits', options: ['accept-edits', 'smart', 'ask', 'plan', 'bypass'].map(value => ({ value, name: value })) },
  { id: 'model', currentValue: 'claude-fable-5-2-medium', options: [{ value: 'swe-2-flash-medium', name: 'SWE-2 Flash' }, { value: 'swe-2-flash-high', name: 'SWE-2 Flash' }, { value: 'claude-fable-5-2-medium', name: 'Claude Fable 5.2' }] },
  { id: 'thought_level', currentValue: 'xhigh', options: ['low', 'medium', 'high', 'xhigh', 'max'].map(value => ({ value, name: value })) },
  { id: 'speed', currentValue: 'standard', options: [{ value: 'standard', name: 'Standard' }, { value: 'fast', name: 'Fast' }] },
];
async function boot(page, settings = {}, sessions = []) {
  await page.addInitScript(({ settings, options, sessions }) => {
    window.calls = []; window.handlers = {};
    window.devinEmit = (method, params, id) => { const c = window.calls.findLast(c => c.module === 'devin' && c.method === 'connect').args; return window.handlers.devin({ payload: { chat: c.chat, gen: c.gen, method, params, ...(id != null && { id }) } }); };
    window.__TAURI__ = {
      window: { getCurrentWindow: () => ({ label: 'main' }) },
      webview: { getCurrentWebview: () => ({ onDragDropEvent: async () => () => {} }) },
      event: { listen: async (name, fn) => { const previous = window.handlers[name]; window.handlers[name] = e => { previous?.(e); return fn(e); }; return () => {}; } },
      core: { invoke: async (_, request) => {
        window.calls.push(request);
        const { module, method, args } = request;
        if (module === 'app') return ({ accounts: [{ name: 'Основной', home: '/codex' }], info: { home: '/home', os: 'macos', version: 'test' }, settings, get: settings[args.key] ?? null })[method] ?? null;
        if (module === 'devin') {
          if (method === 'available') return true;
          if (method === 'list') return sessions;
          if (method === 'usage') return { plan: 'Devin Max', today: { sessions: 3, credits: 1.5, acu: 0.25 } };
          if (method === 'rpc') {
            if (args.method === 'session/new') return { sessionId: 'warp-ferret', configOptions: options };
            if (args.method === 'session/load') { await window.devinEmit('session/update', { sessionId: 'old-one', update: { sessionUpdate: 'user_message_chunk', content: { type: 'text', text: 'Старый вопрос' }, _meta: { 'cognition.ai/eventId': '1' } } }); await window.devinEmit('session/update', { sessionId: 'old-one', update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Старый ответ' }, _meta: { 'cognition.ai/eventId': '2' } } }); return { configOptions: options }; }
            if (args.method === 'session/set_config_option') { const o = options.find(o => o.id === args.params.configId); o.currentValue = args.params.value; return { configOptions: options }; }
            if (args.method === 'session/prompt') return new Promise(resolve => { window.finishPrompt = stopReason => resolve({ stopReason, usage: { inputTokens: 10, outputTokens: 2 } }); });
          }
          return null;
        }
        if (module === 'limits' && method === 'state') return { codex: { accounts: [{ name: 'Основной', home: '/codex', limits: [{ windows: [{ minutes: 300, remaining_percent: 50 }] }] }] } };
        if (method === 'threads') return [];
        if (module === 'api' && method === 'list') return [];
        return null;
      } },
    };
  }, { settings, options, sessions });
  await page.goto('/');
}
const devinCalls = (page, name) => page.evaluate(name => window.calls.filter(c => c.module === 'devin' && c.args?.method === name).map(c => c.args.params), name);
const update = (page, u) => page.evaluate(u => window.devinEmit('session/update', { sessionId: 'warp-ferret', update: u }), u);

test('Devin streams a turn, shows tool calls and finishes when the prompt returns', async ({ page }) => {
  await boot(page);
  await page.getByLabel('Провайдер').selectOption('devin');
  await page.getByLabel('Сообщение', { exact: true }).fill('Почини тесты');
  await page.getByRole('button', { name: 'Отправить ↑', exact: true }).click();
  await expect.poll(() => devinCalls(page, 'session/prompt')).toHaveLength(1);
  const [prompt] = await devinCalls(page, 'session/prompt');
  expect(prompt.sessionId).toBe('warp-ferret');
  expect(prompt.prompt[0].text).toContain('Инструкции Пульта');
  expect(prompt.prompt[0].text).toContain('Почини тесты');
  await update(page, { sessionUpdate: 'tool_call', toolCallId: 't1', title: 'Ran npm test', kind: 'execute', status: 'pending' });
  await update(page, { sessionUpdate: 'tool_call_update', toolCallId: 't1', status: 'completed', content: [{ type: 'content', content: { type: 'text', text: '12 passed' } }], _meta: { terminal_exit: { exit_code: 0 } } });
  await update(page, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: '**Готово**, ' } });
  await update(page, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'тесты зелёные.' } });
  await expect(page.locator('.message.command')).toContainText('Ran npm test');
  await expect(page.locator('.message.agent .message-body')).toHaveText('Готово, тесты зелёные.');
  await expect(page.locator('.message.user .message-body')).toHaveText('Почини тесты');
  await page.evaluate(() => window.finishPrompt('end_turn'));
  await expect(page.locator('.status')).toHaveText('● Готов');
  // Второе сообщение уходит в ту же сессию и без повторных инструкций.
  await page.getByLabel('Сообщение', { exact: true }).fill('Ещё');
  await page.getByRole('button', { name: 'Отправить ↑', exact: true }).click();
  await expect.poll(() => devinCalls(page, 'session/prompt')).toHaveLength(2);
  expect((await devinCalls(page, 'session/prompt'))[1].prompt[0].text).not.toContain('Инструкции Пульта');
  expect(await devinCalls(page, 'session/new')).toHaveLength(1);
});

test('full access switches Devin to bypass and answers its permission requests itself', async ({ page }) => {
  await boot(page, { sandbox: 'danger-full-access', autoApprove: true });
  await page.getByLabel('Провайдер').selectOption('devin');
  await page.getByLabel('Сообщение', { exact: true }).fill('Задача');
  await page.getByRole('button', { name: 'Отправить ↑', exact: true }).click();
  await expect.poll(() => devinCalls(page, 'session/prompt')).toHaveLength(1);
  expect(await devinCalls(page, 'session/set_config_option')).toContainEqual({ sessionId: 'warp-ferret', configId: 'mode', value: 'bypass' });
  await page.evaluate(() => window.devinEmit('session/request_permission', { sessionId: 'warp-ferret', toolCall: { toolCallId: 'c', _meta: { 'cognition.ai/editableCommand': 'curl example.com' } }, options: [{ optionId: 'allow_once', kind: 'allow_once' }, { optionId: 'reject_once', kind: 'reject_once' }] }, 'perm-1'));
  await expect.poll(() => page.evaluate(() => window.calls.find(c => c.module === 'devin' && c.method === 'respond')?.args)).toMatchObject({ id: 'perm-1', result: { outcome: { outcome: 'selected', optionId: 'allow_once' } } });
  await expect(page.getByRole('button', { name: 'Разрешить', exact: true })).toHaveCount(0);
});

test('without auto approval Devin asks and the choice maps to its options', async ({ page }) => {
  await boot(page);
  await page.getByLabel('Провайдер').selectOption('devin');
  await page.getByLabel('Сообщение', { exact: true }).fill('Задача');
  await page.getByRole('button', { name: 'Отправить ↑', exact: true }).click();
  await expect.poll(() => devinCalls(page, 'session/prompt')).toHaveLength(1);
  await page.evaluate(() => window.devinEmit('session/request_permission', { sessionId: 'warp-ferret', toolCall: { toolCallId: 'c', _meta: { 'cognition.ai/editableCommand': 'rm -rf dist' } }, options: [{ optionId: 'allow_once', kind: 'allow_once' }, { optionId: 'reject_once', kind: 'reject_once' }] }, 'perm-2'));
  await expect(page.locator('.message.approval .approval-what')).toHaveText('$ rm -rf dist');
  await page.getByRole('button', { name: 'Отклонить', exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.calls.find(c => c.module === 'devin' && c.method === 'respond')?.args.result)).toEqual({ outcome: { outcome: 'selected', optionId: 'reject_once' } });
});

test('model picker lists Devin models by family and applies model, depth and speed on the next turn', async ({ page }) => {
  await boot(page, { devinCatalog: options });
  await page.getByLabel('Провайдер').selectOption('devin');
  await page.getByRole('button', { name: 'Модели' }).click();
  const select = page.getByLabel('Выбор модели');
  await expect(select.locator('optgroup')).toHaveCount(2);
  await select.selectOption('swe-2-flash-high');
  await page.getByLabel('Глубина размышлений').selectOption('high');
  await page.getByLabel('Fast').check();
  await page.getByLabel('Режим Devin').selectOption('plan');
  await page.getByRole('button', { name: 'Применить' }).click();
  await page.getByLabel('Сообщение', { exact: true }).fill('Задача');
  await page.getByRole('button', { name: 'Отправить ↑', exact: true }).click();
  await expect.poll(() => devinCalls(page, 'session/prompt')).toHaveLength(1);
  expect((await devinCalls(page, 'session/set_config_option')).map(p => [p.configId, p.value])).toEqual([['mode', 'plan'], ['model', 'swe-2-flash-high'], ['thought_level', 'high'], ['speed', 'fast']]);
});

test('Devin sessions appear in history and reopen with their transcript', async ({ page }) => {
  await boot(page, {}, [{ id: 'devin:old-one', session: 'old-one', title: 'Сессия из терминала', cwd: '/home/p', date: 5, account: 'Devin' }]);
  await page.getByRole('button', { name: 'Сессия из терминала', exact: true }).click();
  await expect(page.locator('.message.user .message-body')).toHaveText('Старый вопрос');
  await expect(page.locator('.message.agent .message-body')).toHaveText('Старый ответ');
  expect(await devinCalls(page, 'session/load')).toEqual([{ sessionId: 'old-one', cwd: '/home/p', mcpServers: [] }]);
});

test('stop cancels the Devin turn through ACP', async ({ page }) => {
  await boot(page);
  await page.getByLabel('Провайдер').selectOption('devin');
  await page.getByLabel('Сообщение', { exact: true }).fill('Долгая задача');
  await page.getByRole('button', { name: 'Отправить ↑', exact: true }).click();
  await expect.poll(() => devinCalls(page, 'session/prompt')).toHaveLength(1);
  await page.getByRole('button', { name: 'Стоп' }).click();
  expect(await page.evaluate(() => window.calls.find(c => c.module === 'devin' && c.method === 'notify')?.args)).toMatchObject({ method: 'session/cancel', params: { sessionId: 'warp-ferret' } });
  await page.evaluate(() => window.finishPrompt('cancelled'));
  await expect(page.locator('.message.note')).toContainText('Остановлено');
});

test('when every Codex account is out of limits the dialog continues in Devin with its history', async ({ page }) => {
  await boot(page);
  await page.evaluate(async () => { const { ui } = await import('/core.js'); await ui.chats.send('Сделай фичу', { literal: true }); });
  const codex = await page.evaluate(() => window.calls.find(c => c.method === 'connect' && c.module === 'codex').args);
  await page.evaluate(e => window.handlers.codex({ payload: e }), { chat: codex.chat, gen: codex.gen, method: 'turn/completed', params: { turn: { id: 't', status: 'failed', error: { message: 'limit', codexErrorInfo: 'usageLimitExceeded' } } } });
  await expect.poll(() => devinCalls(page, 'session/prompt')).toHaveLength(1);
  const [prompt] = await devinCalls(page, 'session/prompt');
  expect(prompt.prompt[0].text).toContain('user: Сделай фичу');
  expect(prompt.prompt[0].text).toContain('Продолжай с того места');
  await expect(page.locator('.message.note').first()).toContainText('Продолжаю в Devin');
  expect(await page.evaluate(async () => (await import('/core.js')).ui.chats.current().target)).toBe('devin');
});

test('limits bar shows Devin plan and today spend, and opens a Devin chat', async ({ page }) => {
  await boot(page);
  const tile = page.locator('.ring-tile.devin');
  await expect(tile).toContainText('1.5');
  await expect(tile).toHaveAttribute('title', /Devin Max[\s\S]*3 сессий · 1.5 кредитов · 0.25 ACU/);
  await tile.click();
  expect(await page.evaluate(async () => (await import('/core.js')).ui.chats.current().target)).toBe('devin');
});
