import { expect, test } from '@playwright/test';

const linked = '0d5d108b7fd348c19abf8f8463916408';
const url = 'https://app.devin.ai/sessions/' + linked;

async function desktop(page, legacy = false) {
  await page.addInitScript(({ linked, legacy }) => {
    const message = (event_id, source, message) => ({ event_id, source, type: source + '_message', message });
    const sessions = { ['devin-' + linked]: { status: 'finished', messages: [{ ...message('initial', 'user', 'Исходная задача'), type: 'initial_user_message' }, message('old', 'devin', 'Переписка Devin')] } };
    const manifest = { id: 'devin', name: 'Devin', permissions: [], commands: [], sidebar: [], panels: [] };
    const calls = window.devinCalls = [];
    window.sessions = sessions;
    window.__TAURI__ = { event: { listen: async () => () => {} }, core: { invoke: async (_, { module, method, args }) => {
      if (module === 'app') return ({ accounts: [], info: { home: '/tmp', os: 'windows' }, settings: {} })[method] ?? null;
      if (method === 'threads') return Object.values(window.saved || {}).map(row => ({
        id: 'local:' + row.id, path: row.id, title: row.title, cwd: row.directory, date: row.date,
      }));
      if (method === 'saveLocal') { (window.saved ||= {})[args.id] = args.value; return null; }
      if (method === 'readLocal') return window.saved[args.path];
      if (method === 'open') { window.openedDevin = args.url; return null; }
      if (module !== 'mods') return null;
      if (method === 'list') return [{ manifest, fingerprint: 'fixture', approved: true, enabled: true }];
      if (args.method === 'settings.get') return legacy ? {} : { org: 'org-test' };
      if (args.method === 'secrets.get') return legacy ? 'apk_fixture' : 'cog_fixture';
      if (args.method !== 'network.fetch') return {};
      const { url, method: httpMethod, body } = args.params;
      const request = new URL(url);
      const path = request.pathname;
      calls.push({ path, method: httpMethod });
      const [session, endpoint] = path.split('/sessions')[1].split('/').filter(Boolean);
      const response = data => ({ status: 200, body: JSON.stringify(data) });
      if (httpMethod === 'POST' && !session) {
        const id = 'devin-created-' + calls.filter(r => r.path === path && r.method === 'POST').length;
        sessions[id] = { status: 'working', messages: [message(id + '-prompt', 'user', JSON.parse(body).prompt), message(id + '-first', 'devin', 'Первый ответ')] };
        return response({ session_id: id });
      }
      const row = sessions[session];
      if (httpMethod === 'POST') {
        row.messages.push(message(session + '-followup', 'user', JSON.parse(body).message), message(session + '-reply', 'devin', 'Ответ на продолжение'));
        row.status = 'finished';
        return response({});
      }
      if (endpoint === 'messages') {
        const after = Number(request.searchParams.get('after') || 0);
        return response({ items: row.messages.slice(after), end_cursor: String(row.messages.length), has_next_page: false });
      }
      return response({ title: 'Сессия с сайта', status: row.status, ...(!legacy && { acus_consumed: 1.25 }), messages: row.messages });
    } } };
  }, { linked, legacy });
  await page.goto('/');
  const provider = page.getByLabel('Провайдер', { exact: true });
  await expect(provider.locator('option', { hasText: 'Devin' })).toHaveCount(1);
  await provider.selectOption('api:devin');
}

async function send(page, text) {
  const input = page.getByLabel('Сообщение');
  await input.fill(text);
  await input.press('Enter');
}

test('Devin creates separate sessions, streams updates and continues from local history', async ({ page }) => {
  await desktop(page);
  await send(page, 'Первая задача');
  await expect(page.locator('.agent .message-body')).toHaveText('Первый ответ');
  await expect(page.locator('.message.user')).toHaveCount(1);
  await send(page, '/usage');
  await expect(page.getByText('Статус Devin: working · ACU: 1.25')).toBeVisible();
  await page.evaluate(() => {
    const row = window.sessions['devin-created-1'];
    row.status = 'finished';
    row.messages.push({ event_id: 'second', source: 'devin', message: 'Второй ответ' });
  });
  await expect(page.locator('.agent .message-body')).toHaveText(['Первый ответ', 'Второй ответ'], { timeout: 7000 });
  await expect(page.locator('.status')).not.toContainText('Работает');
  await page.evaluate(async () => {
    const { ui } = await import('/core.js');
    const previous = ui.chats.current();
    ui.chats.open();
    await ui.chats.close(previous);
  });
  await send(page, 'Вторая задача');
  await expect(page.locator('.agent .message-body')).toHaveText('Первый ответ');
  await send(page, '/stop');
  await expect(page.locator('.status')).not.toContainText('Работает');
  await expect.poll(() => page.evaluate(() => Object.values(window.saved).find(r => r.title === 'Вторая задача')?.session)).toBe('devin-created-2');
  await page.getByRole('button', { name: 'Первая задача', exact: true }).click();
  await send(page, 'Продолжай');
  await expect(page.locator('.agent .message-body').last()).toHaveText('Ответ на продолжение');
  await expect(page.locator('.message.user')).toHaveCount(2);
  expect(await page.evaluate(() => window.devinCalls.filter(c => c.method === 'POST').map(c => c.path))).toEqual([
    '/v3/organizations/org-test/sessions', '/v3/organizations/org-test/sessions',
    '/v3/organizations/org-test/sessions/devin-created-1/messages',
  ]);
});

test('legacy Devin key attaches a session, imports its messages and supports /usage and /open', async ({ page }) => {
  await desktop(page, true);
  await send(page, '/session ' + url);
  await expect(page.locator('.agent .message-body')).toHaveText('Переписка Devin');
  await expect(page.locator('.user .message-body')).toHaveText('Исходная задача');
  await send(page, '/usage');
  await expect(page.getByText('Статус Devin: finished · ACU: API не вернул данные')).toBeVisible();
  await send(page, '/open');
  await expect.poll(() => page.evaluate(() => window.openedDevin)).toBe(url);
  await send(page, 'Продолжай');
  await expect(page.locator('.agent .message-body').last()).toHaveText('Ответ на продолжение');
  expect(await page.evaluate(() => window.devinCalls.filter(c => c.method === 'POST').map(c => c.path))).toEqual([
    '/v1/sessions/devin-' + linked + '/message',
  ]);
});
