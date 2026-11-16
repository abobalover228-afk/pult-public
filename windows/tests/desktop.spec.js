import { test, expect } from '@playwright/test';
async function desktop(page, label = 'main') {
  await page.addInitScript(label => {
    window.calls = []; window.handlers = {}; window.apiConnections = []; window.computerEnabled = false;
    window.emitCodex = event => window.handlers.codex({ payload: event });
    window.__TAURI__ = {
      window: { getCurrentWindow: () => ({ label }) },
      webview: { getCurrentWebview: () => ({ onDragDropEvent: async fn => { window.dropHandler=fn; return ()=>{}; } }) },
      event: { listen: async (name, fn) => { const previous = window.handlers[name]; window.handlers[name] = e => { previous?.(e); return fn(e); }; return () => {}; } },
      core: { invoke: async (_, request) => {
        window.calls.push(request);
        const { module, method, args } = request;
        if (method === 'saveLocal' && window.failSave) throw new Error('Disk full');
        if (module === 'voice' && method === 'listen' && window.delayVoice) return new Promise(resolve => window.finishVoice = resolve);
        if (module === 'computer') {
          if (method === 'enable') window.computerEnabled = true;
          if (method === 'stop') window.computerEnabled = false;
          return { enabled: window.computerEnabled, supported: true, mcp: true };
        }
        if (module === 'accounts' && method === 'list') return [{ name: 'Основной', home: 'C:\\Users\\test\\.codex', signedIn: true, email: 'main@example.com', plan: 'plus' }, { name: 'Запасной', home: 'C:\\Users\\test\\.codex-2', signedIn: false }];
        if (module === 'accounts' && method === 'browsers') return { selected: 'auto', items: [{ name: 'Google Chrome', private: true }, { name: 'Safari', private: false }] };
        if (module === 'accounts' && method === 'login') { window.loginCalls = (window.loginCalls || 0) + 1; return { id: 'L1', home: 'C:\\Users\\test\\.codex-3' }; }
        if (module === 'mcp') return method === 'list' ? [{ name: 'test-server', enabled: true }] : { ok: true };
        if (module === 'api') {
          if (method === 'list') return window.apiConnections;
          if (method === 'save') { window.apiConnections = [args.connection]; return window.apiConnections; }
          if (method === 'send') return { text: 'Ответ API', inputTokens: 10, outputTokens: 5 };
        }
        if (module === 'app') return ({
          accounts: [{ name: 'Основной', home: 'C:\\Users\\test\\.codex' }, { name: 'Запасной', home: 'C:\\Users\\test\\.codex-2' }],
          info: { home: 'C:\\Users\\test', os: 'windows', version: '2.4.0' }, settings: {},
        })[method] ?? null;
        if (module === 'limits' && method === 'state') return {
          codex: { accounts: [{ name: 'Основной', available: true, plan: 'plus', limits: [{ name: 'Codex', windows: [{ minutes: 300, remaining_percent: 72, resets_at: 1900000000 }] }] }], updated: Date.now() },
          claude: JSON.stringify({ saved_at: Date.now()/1000, rate_limits: { five_hour: { used_percentage: 91 } } }), names: [],
        };
        if (method === 'threads') return [{ id: 'existing', title: 'Починить сборку', account: 'Основной', cwd: 'C:\\project', date: 1 }];
        if (method === 'readImage') { if (window.delayImage) await new Promise(resolve => { (window.pendingImages ||= []).push(resolve); window.finishImage=()=>window.pendingImages.splice(0).forEach(fn=>fn()); }); return 'data:image/png;base64,dGVzdA=='; }
        if (method === 'saveImage') { if(window.delaySaveImage) await new Promise(resolve=>window.finishSavedImage=resolve); return 'C:\\project\\paste.png'; }
        if (method === 'resolveDir') return 'C:\\project\\child';
        if (method === 'pick') return ['C:\\project\\test.png'];
        if (method === 'rpc') {
          if (args.method === 'model/list') return window.modelPages?.[args.params.cursor || 'first'] || { data: [{ model: 'fixture-model', displayName: 'Fixture Model', supportedReasoningEfforts: [{ reasoningEffort: 'high' }] }] };
          if (args.method === 'thread/fork') return { thread: { id: 'fork-thread', turns: [] } };
          if (args.method.startsWith('thread/')) return { thread: { id: args.params.threadId || 'thread-1', turns: [] } };
          if (args.method === 'review/start') return { reviewThreadId: 'thread-1', turn: { id: 'review-turn' } };
          if (args.method === 'turn/start') return { turn: { id: 'turn-1' } };
        }
        return null;
      } },
    };
  }, label);
  await page.goto(label === 'main' ? '/' : '/limits.html');
}
const chatIdentity = page => page.evaluate(() => {
  const c = window.calls.find(x => x.method === 'connect'); return { chat: c.args.chat, gen: c.args.gen };
});
const event = (page, identity, method, params, id) => page.evaluate(e => window.emitCodex(e), { ...identity, method, params, ...(id != null && { id }) });

test('opens shell, searches history and saves settings', async ({ page }) => {
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  await desktop(page);
  await expect(page.getByRole('heading', { name: 'С чего начнём?' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Починить сборку' })).toBeVisible();
  await page.getByLabel('Поиск диалогов').fill('несуществующий');
  await expect(page.getByRole('button', { name: 'Починить сборку' })).toHaveCount(0);
  await page.getByRole('button', { name: '⚙ Настройки' }).click();
  await page.getByPlaceholder('Общие инструкции для новых диалогов').fill('Проверяй результат');
  await page.getByRole('button', { name: 'Сохранить', exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.calls.some(c => c.method === 'set' && c.args.key === 'rules' && c.args.value === 'Проверяй результат'))).toBe(true);
  expect(errors).toEqual([]);
});

test('streams markdown safely, sends attachments and drains queued messages', async ({ page }) => {
  await desktop(page);
  await page.getByRole('button', { name: '+ Файлы' }).click();
  await page.getByLabel('Сообщение').fill('Первая задача'); await page.getByRole('button', { name: 'Отправить ↑' }).click();
  await expect(page.locator('.status')).toHaveText('● Работает');
  const identity = await chatIdentity(page);
  const start = await page.evaluate(() => window.calls.find(c => c.args?.method === 'turn/start'));
  expect(start.args.params.input).toContainEqual({ type: 'localImage', path: 'C:\\project\\test.png' });
  await event(page, identity, 'item/started', { item: { id: 'answer', type: 'agentMessage', text: '' } });
  await event(page, identity, 'item/agentMessage/delta', { itemId: 'answer', delta: '**Готово** <img src=x onerror="window.pwned=true"><script>window.pwned=true</script>' });
  await expect(page.locator('.agent strong')).toHaveText('Готово');
  expect(await page.evaluate(() => window.pwned)).toBeUndefined();
  await expect(page.locator('.agent img, .agent script')).toHaveCount(0);
  await page.getByLabel('Сообщение').fill('Вторая задача'); await page.getByRole('button', { name: 'Отправить ↑' }).click();
  await expect(page.locator('.queue')).toContainText('Вторая задача');
  await event(page, identity, 'turn/completed', { turn: { id: 'turn-1', status: 'completed' } });
  await expect.poll(() => page.evaluate(() => window.calls.filter(c => c.args?.method === 'turn/start').length)).toBe(2);
});

test('approval is explicit and user input is returned to the requesting process', async ({ page }) => {
  await desktop(page); await page.getByLabel('Сообщение').fill('Задача'); await page.getByRole('button', { name: 'Отправить ↑' }).click();
  const identity = await chatIdentity(page);
  await event(page, identity, 'item/commandExecution/requestApproval', { command: 'git status', reason: 'Проверка' }, 45);
  expect(await page.evaluate(() => window.calls.filter(c => c.method === 'respond').length)).toBe(0);
  await page.getByRole('button', { name: 'Отклонить', exact: true }).click();
  expect(await page.evaluate(() => window.calls.find(c => c.method === 'respond').args)).toMatchObject({ chat: identity.chat, id: 45, result: { decision: 'decline' } });
  await event(page, identity, 'item/tool/requestUserInput', { questions: [{ id: 'choice', question: 'Какой вариант?', options: [{ label: 'Первый' }, { label: 'Второй' }] }] }, 46);
  await page.getByRole('button', { name: 'Первый', exact: true }).click();
  expect(await page.evaluate(() => window.calls.filter(c => c.method === 'respond').length)).toBe(1);
  await page.getByRole('button', { name: 'Ответить', exact: true }).click();
  expect(await page.evaluate(() => window.calls.filter(c => c.method === 'respond').at(-1).args)).toMatchObject({ id: 46, result: { answers: { choice: { answers: ['Первый'] } } } });
});

test('accounts window signs in with a one-time code and adds the account by itself', async ({ page }) => {
  await desktop(page, 'accounts');
  await page.evaluate(() => { navigator.clipboard.writeText = async text => { window.copied = text; }; });
  await expect(page.getByText('Аккаунты Codex')).toBeVisible();
  await page.getByLabel('Браузер для входа').selectOption('default');
  expect(await page.evaluate(() => window.calls.some(c => c.module === 'accounts' && c.method === 'browser' && c.args.name === 'default'))).toBe(true);
  await page.getByLabel('Браузер для входа').selectOption('Google Chrome');
  await expect(page.getByText('main@example.com · Plus')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Войти', exact: true })).toBeVisible();
  await page.getByRole('button', { name: '+ Добавить аккаунт' }).click();
  await expect.poll(() => page.evaluate(() => window.loginCalls)).toBe(1);
  await page.evaluate(() => window.handlers.accounts({ payload: { id: 'L1', stage: 'code', url: 'https://auth.openai.com/codex/device', code: 'M98Q-ID862' } }));
  await expect(page.getByText('auth.openai.com/codex/device')).toBeVisible();
  await expect(page.locator('.ac-code b')).toHaveCount(9);
  expect(await page.evaluate(() => window.copied)).toBe('M98Q-ID862');
  expect(await page.evaluate(() => window.calls.some(c => c.module === 'accounts' && c.method === 'openPrivate' && c.args.url === 'https://auth.openai.com/codex/device'))).toBe(true);
  await page.evaluate(() => window.handlers.accounts({ payload: { id: 'L1', stage: 'done', name: 'ivan', email: 'ivan@example.com', plan: 'plus' } }));
  await expect(page.getByText('ivan · ivan@example.com · Plus')).toBeVisible();
  await page.screenshot({ path: 'test-results/accounts.png' });
});

test('limits dock shows nested rings for every account and Claude', async ({ page }) => {
  await desktop(page, 'limits');
  await expect(page.locator('.dk-tile')).toHaveCount(2);
  await expect(page.locator('.dk-tile').first()).toContainText('Основной');
  await expect(page.locator('.dk-tile').first().locator('text')).toHaveText('72');
  await expect(page.locator('.dk-tile.claude text')).toHaveText('9');
  await expect.poll(() => page.evaluate(() => window.calls.some(c => c.module === 'limits' && c.method === 'fit' && c.args.width > 100))).toBe(true);
});

test('desktop layout fits a small Windows screen', async ({ page }) => {
  await page.setViewportSize({ width: 1100, height: 760 }); await desktop(page);
  await page.screenshot({ path: 'test-results/desktop.png' });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});


test('Claude streams answers and requires approval before a tool runs', async ({ page }) => {
  await desktop(page);
  await page.getByLabel('Провайдер').selectOption('claude');
  await page.getByLabel('Сообщение').fill('Задача Claude');
  await page.getByRole('button', { name: 'Отправить ↑' }).click();
  const request = await page.evaluate(() => window.calls.find(c => c.module === 'claude' && c.method === 'send'));
  expect(request.args.text).toBe('Задача Claude');
  const send = event => page.evaluate(e => window.handlers.claude({ payload: e }), { chat: request.args.chat, gen: request.args.gen, event });
  await send({ type: 'stream_event', event: { type: 'message_start', message: { id: 'msg1' } } });
  await send({ type: 'stream_event', event: { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } } });
  await send({ type: 'stream_event', event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: '**Ответ Claude**' } } });
  await expect(page.locator('.agent strong')).toHaveText('Ответ Claude');
  await send({ type: 'control_request', request_id: 'approval1', request: { subtype: 'can_use_tool', tool_name: 'Bash', input: { command: 'git status' } } });
  await page.getByRole('button', { name: 'Разрешить', exact: true }).click();
  expect(await page.evaluate(() => window.calls.find(c => c.module === 'claude' && c.method === 'respond').args)).toMatchObject({ id: 'approval1', response: { behavior: 'allow', updatedInput: { command: 'git status' } } });
  await send({ type: 'result', is_error: false });
  await expect(page.locator('.status')).toHaveText('● Готов');
});


test('API configuration joins provider picker and chat preserves local history', async ({ page }) => {
  await desktop(page);
  await page.getByRole('button', { name: '↗ API-подключения' }).click();
  await page.getByRole('button', { name: '+ Подключение' }).click();
  await page.getByPlaceholder('Название подключения', { exact: true }).fill('Мой API');
  await page.getByPlaceholder('https://provider.example/v1').fill('https://provider.example/v1');
  await page.getByPlaceholder('Модель', { exact: true }).fill('my-model');
  await page.getByPlaceholder('API-ключ', { exact: true }).fill('test-secret');
  await page.getByRole('button', { name: 'Сохранить подключение' }).click();
  await page.getByRole('button', { name: 'Открыть чат', exact: true }).click();
  await expect(page.getByLabel('Провайдер')).toContainText('Мой API');
  await page.getByLabel('Сообщение').fill('Привет API');
  await page.getByRole('button', { name: 'Отправить ↑' }).click();
  await expect(page.locator('.agent .message-body')).toHaveText('Ответ API');
  await expect(page.locator('.status')).toHaveText('● Готов');
  const request = await page.evaluate(() => window.calls.find(c => c.module === 'api' && c.method === 'send'));
  expect(request.args.messages).toEqual([{ role: 'user', content: 'Привет API' }]);
  const saved = await page.evaluate(() => window.calls.find(c => c.method === 'saveLocal'));
  expect(saved.args.value.provider).toBe('api');
  expect(saved.args.value.messages.map(m => m.text)).toEqual(['Привет API', 'Ответ API']);
  expect(JSON.stringify(saved)).not.toContain('test-secret');
});


test('stopping while API attachments load prevents the HTTP request', async ({ page }) => {
  await desktop(page);
  await page.evaluate(async () => {
    window.apiConnections = [{ id: 'ea4d601f-e605-4cbc-8a8d-e55485a34cee', name: 'Local API', baseURL: 'http://localhost:1234/v1', model: 'test' }];
    const { ui } = await import('/core.js'); ui.setProviders(window.apiConnections.map(c => ({ id: 'api:' + c.id, title: c.name, model: c.model })));
    window.delayImage = true;
  });
  await page.getByLabel('Провайдер').selectOption('api:ea4d601f-e605-4cbc-8a8d-e55485a34cee');
  await page.getByRole('button', { name: '+ Файлы' }).click();
  await page.getByLabel('Сообщение').fill('Картинка'); await page.getByRole('button', { name: 'Отправить ↑' }).click();
  await expect.poll(() => page.evaluate(() => window.calls.filter(r=>r.method==='readImage').length)).toBeGreaterThanOrEqual(2);
  await page.getByRole('button', { name: 'Стоп', exact: true }).click();
  await page.evaluate(() => window.finishImage());
  await expect(page.locator('.status')).toHaveText('● Готов');
  expect(await page.evaluate(() => window.calls.filter(c => c.module === 'api' && c.method === 'send').length)).toBe(0);
});


test('computer controller starts disabled and exposes an explicit stop', async ({ page }) => {
  await desktop(page); await page.goto('/computer.html');
  await expect(page.getByRole('heading')).toHaveText('Управление экраном выключено');
  expect(await page.evaluate(() => window.calls.filter(c => c.module === 'computer' && c.method === 'action').length)).toBe(0);
  await page.getByRole('button', { name: 'Разрешить управление этим сеансом' }).click();
  await expect(page.getByRole('heading')).toHaveText('● Экраном управляет AI');
  await page.getByRole('button', { name: 'СТОП — отключить управление' }).click();
  await expect(page.getByRole('heading')).toHaveText('Управление экраном выключено');
});

test('MCP settings configure native and external servers without shell interpolation', async ({ page }) => {
  await desktop(page); await page.getByRole('button', { name: '⌘ MCP-серверы' }).click();
  await page.getByRole('button', { name: 'Подключить нативный Computer use' }).click();
  expect(await page.evaluate(() => window.calls.find(c => c.module === 'mcp' && c.method === 'add').args)).toMatchObject({ provider: 'codex', name: 'pult-computer', native: true });
  await page.getByPlaceholder('Имя MCP-сервера').fill('external');
  await page.getByPlaceholder('Программа (например, npx)').fill('C:\\Program Files\\server.exe');
  await page.getByPlaceholder('JSON-массив аргументов').fill('["a & b"]');
  await page.getByRole('button', { name: 'Добавить MCP', exact: true }).click();
  expect(await page.evaluate(() => window.calls.filter(c => c.module === 'mcp' && c.method === 'add').at(-1).args.arguments)).toEqual(['a & b']);
});


test('background chats preserve human draft and attachments and keep job origins', async ({ page }) => {
  await desktop(page); await page.getByLabel('Сообщение').fill('Не трогай черновик');
  await page.getByRole('button', { name: '+ Файлы' }).click();
  const result = await page.evaluate(async () => {
    const { ui } = await import('/core.js'); await ui.ready;
    const human = ui.chats.current(); const events = [];
    ui.chats.onEvent(e => events.push({ type: e.type, origin: e.origin }));
    const bot = ui.chats.open({ title: 'Фоновый', select: false });
    await ui.chats.send('/model literal task', { chat: bot, literal: true, origin: 'telegram:42' });
    return { human: ui.chats.current().id === human.id, attachments: human.attachments.length, events, bot: bot.messages[0].text };
  });
  expect(result.human).toBe(true); expect(result.attachments).toBe(1);
  expect(result.bot).toBe('/model literal task');
  expect(result.events).toContainEqual({ type: 'turnStart', origin: 'telegram:42' });
  await expect(page.getByLabel('Сообщение')).toHaveValue('Не трогай черновик');
});

test('dock lifecycle survives placement changes and disposes a removed panel', async ({ page }) => {
  await desktop(page);
  await page.evaluate(async () => {
    const { ui, h } = await import('/core.js'); await ui.ready; window.closedPanels = 0; window.disposedPanels = 0;
    ui.addPanel({ id: 'fixture', title: 'Fixture', render: el => el.append(h('p', {}, 'Dock content')), onClose: () => window.closedPanels++, dispose: () => window.disposedPanels++ });
    ui.openPanel('fixture', 'left');
  });
  await expect(page.locator('.dock.left')).toContainText('Dock content');
  await page.evaluate(async () => (await import('/core.js')).ui.openPanel('fixture', 'main'));
  await expect(page.locator('.main-dock')).toContainText('Dock content');
  await page.evaluate(async () => (await import('/core.js')).ui.openPanel('fixture', 'sheet'));
  await expect(page.getByRole('dialog')).toContainText('Dock content');
  await page.evaluate(async () => (await import('/core.js')).ui.remove('panels', 'fixture'));
  expect(await page.evaluate(() => [window.closedPanels, window.disposedPanels])).toEqual([1, 1]);
});

test('Codex fork creates a provider thread and leaves the source intact', async ({ page }) => {
  await desktop(page);
  const result = await page.evaluate(async () => {
    const { ui } = await import('/core.js');
    const source = ui.chats.current(); source.thread = 'source-thread'; source.title = 'Source';
    await ui.commands.get('fork').run('', source);
    const fork = ui.chats.current();
    return { source: source.thread, fork: fork.thread, seed: fork.seed ?? null, request: window.calls.find(c => c.args?.method === 'thread/fork')?.args.params };
  });
  expect(result).toEqual({ source: 'source-thread', fork: 'fork-thread', seed: null, request: { threadId: 'source-thread', cwd: 'C:\\Users\\test' } });
});

test('Claude fork requests a new CLI session without sending history as a prompt', async ({ page }) => {
  await desktop(page);
  const result = await page.evaluate(async () => {
    const { ui } = await import('/core.js');
    const source = ui.chats.current(); source.target = 'claude'; source.session = 'original-session';
    source.messages = [{ id: 'old', kind: 'user', text: 'Old context' }];
    await ui.commands.get('fork').run('', source);
    const fork = ui.chats.current();
    await ui.chats.send('Continue', { chat: fork, literal: true });
    return { original: source.session, request: window.calls.find(c => c.module === 'claude' && c.method === 'send').args };
  });
  expect(result.original).toBe('original-session');
  expect(result.request).toMatchObject({ session: 'original-session', forkSession: true, text: 'Continue' });
});

test('Claude compact uses its own transport and API compact is rejected', async ({ page }) => {
 await desktop(page);
 const result = await page.evaluate(async () => {
  const { ui } = await import('/core.js'); const c = ui.chats.current(); c.target = 'claude';
  await ui.commands.get('compact').run('', c);
  const sent = window.calls.find(r => r.module === 'claude' && r.method === 'send');
  const api = ui.chats.open({ target: 'api:fixture' }); let error;
  try { await ui.commands.get('compact').run('', api); } catch (e) { error = e.message; }
  return { text: sent.args.text, codexRPC: window.calls.some(r => r.args?.method === 'thread/compact/start'), error };
 });
 expect(result.text).toBe('/compact'); expect(result.codexRPC).toBe(false); expect(result.error).toContain('Codex и Claude');
});

test('cd resolves relative paths and opens a separate project chat', async ({ page }) => {
 await desktop(page);
 const result = await page.evaluate(async () => {
  const { ui } = await import('/core.js'); const source = ui.chats.current();
  const invoke = window.__TAURI__.core.invoke;
  window.__TAURI__.core.invoke = async (name, r) => r.method === 'resolveDir' ? 'C:\\project\\child' : invoke(name, r);
  await ui.commands.get('cd').run('child', source);
  return { old: source.cwd, current: ui.chats.current().cwd, different: source.id !== ui.chats.current().id };
 });
 expect(result).toEqual({ old: 'C:\\Users\\test', current: 'C:\\project\\child', different: true });
});

test('restarting Claude preserves session and next turn resumes it', async ({ page }) => {
 await desktop(page);
 const result = await page.evaluate(async () => {
  const { ui } = await import('/core.js'); const c = ui.chats.current();
  c.target = 'claude'; c.session = 'preserved-session'; c.claudeStarted = true; c.gen = 7;
  await ui.commands.get('restart').run('', c);
  await ui.chats.send('Continue', { chat: c, literal: true });
  return { stop: window.calls.some(r => r.module === 'claude' && r.method === 'stop'), send: window.calls.find(r => r.module === 'claude' && r.method === 'send').args };
 });
 expect(result.stop).toBe(true); expect(result.send).toMatchObject({ session: 'preserved-session', gen: 9, text: 'Continue' });
});


test('API persistence failure preserves completion and saves each response once', async ({ page }) => {
  await desktop(page);
  const result = await page.evaluate(async () => {
    window.failSave = true;
    const { ui } = await import('/core.js');
    const c = ui.chats.open({ target: 'api:fixture' });
    const ended = [];
    ui.chats.onEvent(e => { if (e.type === 'turnEnd') ended.push(e); });
    await ui.chats.send('Hello', { chat: c, literal: true });
    return { saves: window.calls.filter(r => r.method === 'saveLocal').length,
      busy: c.busy, messages: c.messages.map(m => ({ kind: m.kind, text: m.text })),
      ended: ended.map(e => e.turn?.status) };
  });
  expect(result.saves).toBe(1);
  expect(result.busy).toBe(false);
  expect(result.messages).toContainEqual({ kind: 'agent', text: 'Ответ API' });
  expect(result.messages.some(m => m.kind === 'error' && m.text.includes('Disk full'))).toBe(true);
  expect(result.ended).toEqual(['completed']);
});


test('model picker reads every page, filters hidden models and applies settings without a turn', async ({ page }) => {
  await desktop(page);
  await page.evaluate(() => { window.modelPages = {
    first: { data: [{ model: 'first', displayName: 'First' }, { model: 'hidden', hidden: true }], nextCursor: 'second' },
    second: { data: [{ model: 'second', displayName: 'Second', description: 'Second page model', supportedReasoningEfforts: [{ reasoningEffort: 'high' }] }] },
  }; });
  await page.getByRole('button', { name: 'Модели', exact: true }).click();
  const models = page.getByLabel('Выбор модели');
  await expect(models.locator('option')).toHaveCount(3);
  await models.selectOption('second');
  await expect(page.getByText('Second page model', { exact: true })).toBeVisible();
  await expect(page.getByLabel('Глубина размышлений').locator('option')).toHaveCount(2);
  await page.getByLabel('Глубина размышлений').selectOption('high');
  await page.getByLabel('Fast — возможен дополнительный расход у провайдера').check();
  await page.getByRole('button', { name: 'Применить', exact: true }).click();
  expect(await page.evaluate(async () => {
    const c = (await import('/core.js')).ui.chats.current();
    return { model: c.model, effort: c.effort, fast: c.fast, turns: window.calls.filter(r => r.args?.method === 'turn/start').length };
  })).toEqual({ model: 'second', effort: 'high', fast: true, turns: 0 });
  await page.getByLabel('Сообщение', { exact: true }).fill('Test turn');
  await page.getByRole('button', { name: 'Отправить ↑', exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.calls.find(r => r.args?.method === 'turn/start')?.args.params)).toMatchObject({ model: 'second', effort: 'high', serviceTier: 'fast' });
});

test('Claude model options restart the idle CLI and reach its next invocation', async ({ page }) => {
  await desktop(page);
  const result = await page.evaluate(async () => {
    const { ui } = await import('/core.js');
    const c = ui.chats.open({ target: 'claude', session: 'preserved', claudeStarted: true, gen: 5 });
    await ui.commands.get('effort').run('high', c);
    await ui.commands.get('fast').run('on', c);
    await ui.commands.get('plan').run('on', c);
    await ui.chats.send('Plan the task', { chat: c, literal: true });
    return { stops: window.calls.filter(r => r.module === 'claude' && r.method === 'stop').length,
      request: window.calls.find(r => r.module === 'claude' && r.method === 'send').args };
  });
  expect(result.stops).toBe(1);
  expect(result.request).toMatchObject({ session: 'preserved', effort: 'high', fast: true, permissionMode: 'plan', text: 'Plan the task', gen: 7 });
});

test('model changes reject busy chats and unsupported API modes without invoking a provider', async ({ page }) => {
  await desktop(page);
  expect(await page.evaluate(async () => {
    const { ui } = await import('/core.js'); const errors = [];
    const c = ui.chats.open({ target: 'codex', busy: true, model: 'original' });
    try { await ui.chats.configure(c, { model: 'other' }); } catch (e) { errors.push(String(e)); }
    const api = ui.chats.open({ target: 'api:fixture' });
    try { await ui.commands.get('fast').run('on', api); } catch (e) { errors.push(String(e)); }
    return { model: c.model, errors: errors.length, requests: window.calls.filter(r => r.method === 'send' || r.args?.method === 'turn/start').length };
  })).toEqual({ model: 'original', errors: 2, requests: 0 });
});

test('catalog pagination rejects repeating cursors instead of looping', async ({ page }) => {
  await desktop(page);
  await page.evaluate(() => { window.modelPages = { first: { data: [], nextCursor: 'repeat' }, repeat: { data: [], nextCursor: 'repeat' } }; });
  await page.getByRole('button', { name: 'Модели', exact: true }).click();
  await expect(page.getByText('Error: CLI повторил страницу каталога моделей', { exact: true })).toBeVisible();
  expect(await page.evaluate(() => window.calls.filter(r => r.args?.method === 'model/list').length)).toBe(2);
});


test('closing a tab saves history, stops its process and preserves other drafts', async ({ page }) => {
  await desktop(page);
  expect(await page.evaluate(async () => {
    const { ui } = await import('/core.js');
    const first = ui.chats.current(); first.thread = 'existing'; first.messages = [{ id: 'a', kind: 'agent', text: 'Keep this reply' }];
    const second = ui.chats.open({ target: 'claude' }); ui.chats.setDraft('Unsent draft');
    const closed = []; ui.chats.onEvent(e => { if (e.type === 'close') closed.push(e.chat.id); });
    await ui.chats.close(first);
    return { active: ui.chats.current().id === second.id, draft: ui.chats.draft(), closed: closed.length,
      stopped: window.calls.some(r => r.module === 'codex' && r.method === 'stop' && r.args.chat === first.id),
      saved: window.calls.find(r => r.method === 'saveLocal').args.value.messages[0].text };
  })).toEqual({ active: true, draft: 'Unsent draft', closed: 1, stopped: true, saved: 'Keep this reply' });
  await page.locator('.tab').hover();
  await page.getByRole('button', { name: 'Закрыть чат: Новый диалог', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'С чего начнём?' })).toBeVisible();
});

test('slash suggestions complete commands and background commands preserve the foreground draft', async ({ page }) => {
  await desktop(page);
  const composer = page.getByLabel('Сообщение', { exact: true });
  await composer.fill('/eff');
  await expect(page.getByRole('listbox', { name: 'Команды' })).toBeVisible();
  await composer.press('Tab');
  await expect(composer).toHaveValue('/effort ');
  await page.evaluate(async () => {
    const { ui } = await import('/core.js');
    const background = ui.chats.open({ select: false });
    ui.chats.setDraft('Foreground work');
    await ui.chats.send('/status', { chat: background });
  });
  await expect(composer).toHaveValue('Foreground work');
});

test('CLI arguments retain Windows paths and shell metacharacters without shell expansion', async ({ page }) => {
  await desktop(page);
  const result = await page.evaluate(async () => {
    const { commandWords } = await import('/commands.js');
    let rejected = false; try { commandWords('exec "unfinished'); } catch { rejected = true; }
    return { words: commandWords(String.raw`exec --cd "C:\Users\Брат\My Project" '$(touch /tmp/nope)' ""`), rejected };
  });
  expect(result).toEqual({ words: ['exec', '--cd', 'C:\\Users\\Брат\\My Project', '$(touch /tmp/nope)', ''], rejected: true });
});

test('provider exit completes failed turns and expires pending approvals', async ({ page }) => {
  await desktop(page);
  await page.getByLabel('Сообщение', { exact: true }).fill('Task');
  await page.getByRole('button', { name: 'Отправить ↑', exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.calls.some(r => r.args?.method === 'turn/start'))).toBe(true);
  const identity = await chatIdentity(page);
  await event(page, identity, 'item/commandExecution/requestApproval', { command: 'test' }, 10);
  await page.evaluate(async identity => {
    window.finished = []; const { ui } = await import('/core.js');
    ui.chats.onEvent(e => { if (e.type === 'turnEnd') window.finished.push(e.turn.status); });
    await window.emitCodex({ ...identity, exit: true, reason: 'Process crashed' });
  }, identity);
  await expect(page.getByRole('button', { name: 'Разрешить', exact: true })).toHaveCount(0);
  expect(await page.evaluate(async () => ({ busy: (await import('/core.js')).ui.chats.current().busy, ended: window.finished }))).toEqual({ busy: false, ended: ['failed'] });
});

test('review runs through native Codex transport and undo reverts context while preserving files', async ({ page }) => {
  await desktop(page);
  const result = await page.evaluate(async () => {
    const { ui } = await import('/core.js'); const c = ui.chats.current();
    await ui.commands.get('review').run('', c);
    const request = window.calls.find(r => r.args?.method === 'review/start');
    await window.emitCodex({ chat: c.id, gen: c.gen, method: 'turn/completed', params: { turn: { id: c.turn, status: 'completed' } } });
    return { request: request.args.params, mark: c.turnMarks.at(-1), busy: c.busy };
  });
  expect(result.request).toEqual({ threadId: 'thread-1', delivery: 'inline', target: { type: 'uncommittedChanges' } });
  expect(result.mark.turn).toBe('review-turn'); expect(result.busy).toBe(false);
  page.once('dialog', dialog => dialog.accept());
  await page.evaluate(async () => { const { ui } = await import('/core.js'); await ui.commands.get('undo').run('', ui.chats.current()); });
  const reverted = await page.evaluate(() => window.calls.find(r => r.args?.method === 'thread/revert'));
  expect(reverted.args.params).toEqual({ threadId: 'thread-1', beforeTurnId: 'review-turn' });
});


test('partial slash commands never become paid provider prompts', async ({ page }) => {
 await desktop(page);
 const composer=page.getByLabel('Сообщение',{exact:true});
 for(const text of ['/','/ver','/unknown-command']){
  await composer.fill(text);await composer.press('Enter');await expect(composer).toHaveValue(text);
 }
 expect(await page.evaluate(()=>window.calls.filter(r=>r.method==='connect'||r.method==='send'||r.args?.method==='turn/start').length)).toBe(0);
});


test('editing creates a fresh context and preserves the source continuation and queue',async({page})=>{
 await desktop(page);
 const result=await page.evaluate(async()=>{
  const {ui}=await import('/core.js');const source=ui.chats.current();source.thread='source-thread';source.rulesOverride='Custom rules';
  source.messages=[{id:'u1',kind:'user',text:'Earlier question'},{id:'a1',kind:'agent',text:'Earlier reply'},{id:'u2',kind:'user',text:'Old task'},{id:'a2',kind:'agent',text:'Old continuation'}];
  source.queue=[{text:'Unsent source task',attachments:[]}];
  const fork=await ui.chats.edit(source,'u2','Corrected task');
  const turn=window.calls.find(r=>r.args?.method==='turn/start');
  return {old:source.messages.at(-1).text,queue:source.queue.length,paused:source.queuePaused,fresh:fork.thread!=='source-thread',
   text:turn.args.params.input[0].text,visible:fork.messages.findLast(m=>m.kind==='user').text,
   rules:window.calls.find(r=>r.args?.method==='thread/start').args.params.developerInstructions.replace(/^Ты работаешь внутри «Пульта».*?\n\n/s,''),
   saved:window.calls.some(r=>r.method==='saveLocal'&&r.args.value.thread==='source-thread')};
 });
 expect(result).toMatchObject({old:'Old continuation',queue:1,paused:true,fresh:true,visible:'Corrected task',rules:'Custom rules',saved:true});
 expect(result.text).toContain('Earlier reply');expect(result.text).toContain('Corrected task');expect(result.text).not.toContain('Old continuation');expect(result.text).not.toContain('Old task');
});

test('changed rules detach the old provider context and pause queued work',async({page})=>{
 await desktop(page);
 const result=await page.evaluate(async()=>{
  const {ui}=await import('/core.js');const c=ui.chats.current();
  c.thread='old-thread';c.loaded=true;c.connected=true;c.appliedRules='Old rules';c.rulesOverride='New rules';
  c.messages=[{id:'u',kind:'user',text:'Previous question'},{id:'a',kind:'agent',text:'Previous answer'}];
  c.queue=[{text:'Old queued task',attachments:[]}];
  await ui.chats.send('New task',{chat:c,literal:true});
  const start=window.calls.find(r=>r.args?.method==='thread/start');const turn=window.calls.find(r=>r.args?.method==='turn/start');
  return {newThread:c.thread,paused:c.queuePaused,queued:c.queue.length,rules:start.args.params.developerInstructions.replace(/^Ты работаешь внутри «Пульта».*?\n\n/s,''),pult:start.args.params.developerInstructions.includes('github.com/abobalover228-afk/pult-public'),text:turn.args.params.input[0].text,
   saved:window.calls.some(r=>r.method==='saveLocal'&&r.args.value.thread==='old-thread'&&r.args.value.messages.length===2)};
 });
 expect(result).toMatchObject({newThread:'thread-1',paused:true,queued:1,rules:'New rules',pult:true,saved:true});
 expect(result.text).toContain('Previous answer');expect(result.text).toContain('New task');
});

test('file links open local Windows paths with line and column through Rust',async({page})=>{
 await desktop(page);
 const targets=await page.evaluate(async()=>{
  const {localFileTarget}=await import('/render.js');
  let rejected=0;for(const path of ['javascript:alert(1)','file://remote.example/share','//remote/share'])try{localFileTarget(path);}catch{rejected++;}
  return {windows:localFileTarget('C:/Users/Test/My%20Project/src/main.rs:12:3'),relative:localFileTarget('src/lib.rs#L42'),file:localFileTarget('file:///C:/Users/Test/main.rs:7'),rejected};
 });
 expect(targets).toEqual({windows:{path:'C:/Users/Test/My Project/src/main.rs',line:12,col:3},relative:{path:'src/lib.rs',line:42},file:{path:'C:/Users/Test/main.rs',line:7},rejected:3});
 await page.evaluate(async()=>{const {ui}=await import('/core.js');const c=ui.chats.current();c.messages=[{id:'link',kind:'agent',text:'[main](C:/project/main.rs:12:3)'}];ui.chats.refresh(c);});
 await page.getByRole('link',{name:'main',exact:true}).click();
 expect(await page.evaluate(()=>window.calls.find(r=>r.method==='open')?.args)).toMatchObject({path:'C:/project/main.rs',line:12,col:3});
});

test('stopping Claude preserves queued jobs and persists interrupted history',async({page})=>{
 await desktop(page);
 const result=await page.evaluate(async()=>{
  const {ui}=await import('/core.js');const c=ui.chats.open({target:'claude',busy:true,claudeStarted:true,gen:1});
  c.messages=[{id:'u',kind:'user',text:'In progress'}];c.queue=[{text:'Queued task',attachments:[]}];
  await ui.chats.stop(c.id);
  return {busy:c.busy,paused:c.queuePaused,queue:c.queue.length,saved:window.calls.find(r=>r.method==='saveLocal').args.value.messages.at(-1).text};
 });
 expect(result).toEqual({busy:false,paused:true,queue:1,saved:'Остановлено'});
});


test('dictation can be stopped twice-clicking and a late transcript cannot overwrite another tab',async({page})=>{
 await desktop(page);await page.evaluate(()=>window.delayVoice=true);
 const mic=page.getByRole('button',{name:'🎙',exact:true});
 await mic.click();await expect(mic).toBeEnabled();
 await expect.poll(()=>page.evaluate(()=>typeof window.finishVoice)).toBe('function');
 await mic.click();
 await expect.poll(()=>page.evaluate(()=>window.calls.some(r=>r.module==='voice'&&r.method==='stop'))).toBe(true);
 await page.evaluate(async()=>{const {ui}=await import('/core.js');ui.chats.open();ui.chats.setDraft('Keep this draft');window.finishVoice({text:'Late microphone result'});});
 await expect(page.getByLabel('Сообщение',{exact:true})).toHaveValue('Keep this draft');
 expect(await page.evaluate(()=>window.calls.filter(r=>r.args?.method==='turn/start').length)).toBe(0);
});


test('clipboard images and native file drops attach locally without stealing another tab',async({page})=>{
 await desktop(page);
 await page.evaluate(async()=>{
  window.delaySaveImage=true;const {ui}=await import('/core.js');window.pasteChat=ui.chats.current();
  const canvas=document.createElement('canvas');canvas.width=canvas.height=1;
  const blob=await new Promise(resolve=>canvas.toBlob(resolve));const transfer=new DataTransfer();transfer.items.add(new File([blob],'clipboard.png',{type:'image/png'}));
  document.querySelector('textarea[aria-label="Сообщение"]').dispatchEvent(new ClipboardEvent('paste',{clipboardData:transfer,bubbles:true,cancelable:true}));
 });
 await expect.poll(()=>page.evaluate(()=>typeof window.finishSavedImage)).toBe('function');
 await page.evaluate(async()=>{const {ui}=await import('/core.js');ui.chats.open();ui.chats.setDraft('Other tab draft');window.finishSavedImage();});
 await expect.poll(()=>page.evaluate(()=>window.pasteChat.attachments.length)).toBe(1);
 expect(await page.evaluate(async()=>({old:window.pasteChat.attachments[0],fresh:(await import('/core.js')).ui.chats.current().attachments.length}))).toEqual({old:'C:\\project\\paste.png',fresh:0});
 await page.evaluate(()=>window.dropHandler({payload:{type:'drop',paths:['C:/project/dropped.png','C:/project/dropped.png']}}));
 await expect.poll(()=>page.evaluate(async()=>(await import('/core.js')).ui.chats.current().attachments)).toEqual(['C:/project/dropped.png']);
 await expect(page.getByLabel('Сообщение',{exact:true})).toHaveValue('Other tab draft');
 expect(await page.evaluate(()=>window.calls.filter(r=>r.args?.method==='turn/start'||r.method==='send').length)).toBe(0);
});

test('Mac layout keeps chats in sidebar, quotas in the dock, and model controls beside the composer',async({page})=>{
 await page.setViewportSize({width:1100,height:760});await desktop(page);
 await expect(page.locator('.sidebar .tabs .tab')).toHaveCount(1);
 await expect(page.locator('.sidebar-quotas')).toHaveCount(0);
 await expect(page.locator('.ring-bar .ring-tile')).toHaveCount(2);
 await expect(page.locator('.ring-bar .ring-tile').first()).toContainText('Основной');
 await expect(page.locator('.composer').getByLabel('Провайдер')).toBeVisible();
 await expect(page.locator('.composer').getByRole('button',{name:'Модели',exact:true})).toBeVisible();
 const main=page.locator('.workspace');
 await page.getByRole('button',{name:'Скрыть боковую панель',exact:true}).click();
 await expect(page.locator('.sidebar')).toBeHidden();
 await page.getByRole('button',{name:'Показать боковую панель',exact:true}).click();
 await expect(page.locator('.sidebar')).toBeVisible();
 await page.getByLabel('Сообщение',{exact:true}).fill('Первая строка\nВторая строка\nТретья строка\nЧетвёртая строка');
 expect(await page.getByLabel('Сообщение',{exact:true}).evaluate(el=>el.clientHeight)).toBeGreaterThan(55);
 await page.evaluate(async()=>{
  const {ui}=await import('/core.js');const c=ui.chats.current();c.title='Обновить интерфейс Пульта';c.model='gpt-6.1-sol';
  c.messages=[{id:'u',kind:'user',text:'Сделай интерфейс как в Пульте на Mac.'},{id:'a',kind:'agent',text:'### Компактное рабочее место\n\nЧаты и история слева. Модель, вложения и разрешения — под полем ввода.\n\n- История и квоты всегда под рукой\n- Настройки открываются отдельной панелью\n\n```rust\nfn main() {\n    println!("Пульт");\n}\n```'}];ui.chats.refresh(c);
 });
 await page.screenshot({path:'test-results/mac-style-chat.png'});
 await page.getByRole('button',{name:'⚙ Настройки',exact:true}).click();
 await expect(page.locator('.settings-nav')).toBeVisible();
 await expect(page.getByRole('button',{name:'Telegram',exact:true})).toBeVisible();
 await page.screenshot({path:'test-results/mac-style-settings.png'});
 for(const width of [720,900,1440]){
  await page.setViewportSize({width,height:760});
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
 }
});

test('multiagent composer chip keeps image attachments in the requested provider turn',async({page})=>{
 await desktop(page);
 await page.getByRole('button',{name:'+ Файлы',exact:true}).click();
 await page.getByRole('button',{name:'Мультиагент',exact:true}).click();
 await expect(page.getByRole('button',{name:'Мультиагент',exact:true})).toHaveClass(/active/);
 await page.getByLabel('Сообщение',{exact:true}).fill('Проверь проект');
 await page.getByRole('button',{name:'Отправить ↑',exact:true}).click();
 await expect.poll(()=>page.evaluate(()=>window.calls.find(r=>r.args?.method==='turn/start')?.args.params.input)).toEqual(expect.arrayContaining([expect.objectContaining({type:'localImage',path:'C:\\project\\test.png'})]));
});

test('sidebar trash opens recoverable history without restoring everything',async({page})=>{
 await desktop(page);
 await page.locator('.history-row').hover();
 await page.getByRole('button',{name:'В корзину',exact:true}).click();
 await expect(page.locator('button.thread')).toHaveCount(0);
 await page.getByRole('button',{name:'Открыть корзину',exact:true}).click();
 await expect(page.locator('button.thread')).toHaveCount(1);
 expect(await page.evaluate(()=>window.calls.filter(r=>r.method==='set'&&r.args.key==='hidden').at(-1).args.value)).toEqual(['existing']);
 await page.getByRole('button',{name:'Починить сборку',exact:true}).click();
 await expect(page.locator('button.thread')).toHaveCount(0);
 expect(await page.evaluate(()=>window.calls.filter(r=>r.method==='set'&&r.args.key==='hidden').at(-1).args.value)).toEqual([]);
});

test('account rings can be hidden and restored in settings', async ({ page }) => {
  await desktop(page);
  const bar = page.getByLabel('Лимиты аккаунтов');
  await expect(bar).toBeVisible();
  await page.getByRole('button', { name: 'Скрыть панель лимитов', exact: true }).click();
  await expect(bar).toBeHidden();
  await page.locator('.toolbar-actions').getByRole('button', { name: 'Настройки', exact: true }).click();
  await page.getByLabel('Показывать панель лимитов под чатом').check();
  await expect(bar).toBeVisible();
});
