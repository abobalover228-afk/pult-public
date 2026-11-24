import { test, expect } from '@playwright/test';
// Тотал-апдейт: полный доступ без вопросов, вкладки после перезапуска, карточка агентов, длинные ленты, конфликт «active writer».
async function boot(page, { settings = {}, threads = [], local = {}, resumeErrors = 0 } = {}) {
  await page.addInitScript(({ settings, threads, local, resumeErrors }) => {
    window.calls = []; window.handlers = {}; let failures = resumeErrors;
    window.__TAURI__ = {
      window: { getCurrentWindow: () => ({ label: 'main' }) },
      webview: { getCurrentWebview: () => ({ onDragDropEvent: async () => () => {} }) },
      event: { listen: async (name, fn) => { const previous = window.handlers[name]; window.handlers[name] = e => { previous?.(e); return fn(e); }; return () => {}; } },
      core: { invoke: async (_, request) => {
        window.calls.push(request);
        const { module, method, args } = request;
        if (module === 'app') return ({ accounts: [{ name: 'Основной', home: '/codex' }], info: { home: '/home', os: 'macos', version: 'test' }, settings, get: settings[args.key] ?? null })[method] ?? null;
        if (method === 'threads') return threads;
        if (method === 'readLocal') return local[args.path];
        if (module === 'api' && method === 'list') return [];
        if (method === 'rpc') {
          if (args.method === 'thread/resume' && failures-- > 0) throw 'thread 01a1 already has an active writer';
          if (args.method === 'thread/fork') return { thread: { id: 'forked', turns: [] } };
          if (args.method.startsWith('thread/')) return { thread: { id: args.params.threadId || 'thread-1', turns: [] } };
          if (args.method === 'turn/start') return { turn: { id: 'turn-1' } };
        }
        return null;
      } },
    };
  }, { settings, threads, local, resumeErrors });
  await page.goto('/');
}
const sendTask = async (page, text = 'Задача') => { await page.getByLabel('Сообщение', { exact: true }).fill(text); await page.getByRole('button', { name: 'Отправить ↑', exact: true }).click(); };
const rpcCall = (page, name) => page.evaluate(name => window.calls.find(c => c.args?.method === name)?.args.params, name);

test('full access with auto approval never asks Codex or Claude for permission', async ({ page }) => {
  await boot(page, { settings: { sandbox: 'danger-full-access', autoApprove: true } });
  await expect(page.locator('.status')).toContainText('полный доступ');
  await sendTask(page);
  await expect.poll(() => rpcCall(page, 'turn/start')).toMatchObject({ approvalPolicy: 'never' });
  expect(await rpcCall(page, 'thread/start')).toMatchObject({ approvalPolicy: 'never', sandbox: 'danger-full-access' });
  const chat = await page.evaluate(() => window.calls.find(c => c.method === 'connect').args);
  // Даже если Codex всё же спросит — ответ уходит сам, без карточки с кнопками и без уведомления.
  await page.evaluate(e => window.handlers.codex({ payload: e }), { chat: chat.chat, gen: chat.gen, method: 'item/commandExecution/requestApproval', params: { command: 'rm -rf build' }, id: 7 });
  await expect.poll(() => page.evaluate(() => window.calls.find(c => c.method === 'respond')?.args.result)).toEqual({ decision: 'accept' });
  await expect(page.getByRole('button', { name: 'Разрешить', exact: true })).toHaveCount(0);
  await expect(page.locator('.message.approval.auto')).toContainText('rm -rf build');
  expect(await page.evaluate(() => window.calls.some(c => c.method === 'notify' && /разрешение/i.test(c.args.title)))).toBe(false);

  await page.evaluate(async () => { const { ui } = await import('/core.js'); ui.chats.open({ target: 'claude', cwd: '/home' }); });
  await sendTask(page, 'Задача Claude');
  await expect.poll(() => page.evaluate(() => window.calls.find(c => c.module === 'claude' && c.method === 'send')?.args.permissionMode)).toBe('bypassPermissions');
});

test('auto approval is remembered for new chats and stays manual without it', async ({ page }) => {
  await boot(page, { settings: { sandbox: 'workspace-write' } });
  await sendTask(page);
  await expect.poll(() => rpcCall(page, 'turn/start')).toMatchObject({ approvalPolicy: 'on-request' });
  await page.getByRole('button', { name: 'Подтверждать за меня', exact: true }).click();
  expect(await page.evaluate(() => window.calls.find(c => c.method === 'set' && c.args.key === 'autoApprove')?.args.value)).toBe(true);
  await page.evaluate(async () => (await import('/core.js')).ui.chats.open());
  expect(await page.evaluate(async () => (await import('/core.js')).ui.chats.current().autoApprove)).toBe(true);
});

test('open tabs come back after restart with the last active one selected', async ({ page }) => {
  const saved = id => ({ id, target: 'codex', title: `Диалог ${id}`, directory: '/home/p', account: '/codex', messages: [{ id: `${id}-m`, kind: 'agent', text: `Ответ ${id}`, done: true }] });
  await boot(page, {
    settings: { openChats: { ids: ['a', 'b'], active: 'b' } },
    threads: [{ id: 'local:a', path: '/a', title: 'Диалог a', cwd: '/home/p', date: 2 }, { id: 'local:b', path: '/b', title: 'Диалог b', cwd: '/home/p', date: 1 }],
    local: { '/a': saved('a'), '/b': saved('b') },
  });
  await expect(page.locator('.tab')).toHaveCount(2);
  await expect(page.locator('.heading strong')).toHaveText('Диалог b');
  await expect(page.locator('.agent .message-body')).toHaveText('Ответ b');
});

test('subagents show up as one live roster card instead of flooding the feed', async ({ page }) => {
  await boot(page);
  await sendTask(page, 'Сделай командой');
  await expect.poll(() => rpcCall(page, 'turn/start')).toBeTruthy();
  const chat = await page.evaluate(() => window.calls.find(c => c.method === 'connect').args);
  const emit = (method, params) => page.evaluate(e => window.handlers.codex({ payload: e }), { chat: chat.chat, gen: chat.gen, method, params });
  await emit('turn/started', { threadId: 'thread-1', turn: { id: 'turn-1' } });
  await emit('item/started', { threadId: 'thread-1', item: { id: 'spawn', type: 'collabAgentToolCall', tool: 'spawnAgent', prompt: 'Проверь тесты', receiverThreadIds: ['sub-1'], agentsStates: { 'sub-1': { status: 'running' } }, status: 'inProgress' } });
  await emit('item/started', { threadId: 'sub-1', item: { id: 'sub-cmd', type: 'commandExecution', command: 'npm test' } });
  await expect(page.locator('.agent-row')).toHaveCount(1);
  await expect(page.locator('.agent-row')).toContainText('$ npm test');
  await emit('turn/completed', { threadId: 'sub-1', turn: { id: 'sub-turn', status: 'completed' } });
  await expect(page.locator('.agent-row')).toHaveClass(/completed/);
  await expect(page.locator('.message.command')).toHaveCount(0);
  expect(await page.evaluate(async () => (await import('/core.js')).ui.chats.current().busy)).toBe(true);
});

test('long dialogs keep only the tail in the page and load earlier messages on demand', async ({ page }) => {
  const messages = Array.from({ length: 400 }, (_, i) => ({ id: `m${i}`, kind: i % 2 ? 'agent' : 'user', text: `Сообщение ${i}`, done: true }));
  await boot(page, { threads: [{ id: 'local:long', path: '/long', title: 'Длинный', cwd: '/home', date: 1 }], local: { '/long': { id: 'long', target: 'codex', title: 'Длинный', directory: '/home', messages } } });
  await page.getByRole('button', { name: 'Длинный', exact: true }).click();
  await expect(page.locator('.feed .message')).toHaveCount(150);
  await expect(page.locator('.feed .message').last()).toContainText('Сообщение 399');
  await page.getByRole('button', { name: /Показать ранние сообщения \(250\)/ }).click();
  await expect(page.locator('.feed .message')).toHaveCount(400);
});

test('a dialog held by another Codex process continues in a fork instead of failing', async ({ page }) => {
  await boot(page, { resumeErrors: 2, threads: [{ id: 'busy-thread', title: 'Занятый', account: 'Основной', cwd: '/home', date: 1 }] });
  await page.getByRole('button', { name: 'Занятый', exact: true }).click();
  await expect(page.locator('.message.note')).toContainText('открыт в другом процессе Codex');
  await expect(page.locator('.message.error')).toHaveCount(0);
  expect(await page.evaluate(async () => (await import('/core.js')).ui.chats.current().thread)).toBe('forked');
});
