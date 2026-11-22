import { test, expect } from '@playwright/test';
test('Codex echoes reconcile with local messages, including repeated text and attachments', async ({ page }) => {
  await page.addInitScript(() => {
    const listeners = {};
    let turn = 0;
    window.__TAURI__ = { event: { listen: async (name, fn) => { (listeners[name] ||= []).push(fn); return () => {}; } }, core: { invoke: async (_, r) => {
      if (r.module === 'app') return ({ accounts: [], info: { home: '/tmp', os: 'windows' }, settings: {} })[r.method] ?? null;
      if (r.method === 'threads' || r.method === 'list') return [];
      if (r.method === 'rpc') {
        if (r.args.method === 'thread/start') return { thread: { id: 'thread', turns: [] } };
        if (r.args.method === 'turn/start') {
          const id = `turn-${++turn}`;
          const emit = (method, params) => Promise.all(listeners.codex.map(fn => fn({ payload: { chat: r.args.chat, gen: r.args.gen, method, params } })));
          const item = { id: `user-${turn}`, type: 'userMessage', content: r.args.params.input };
          await emit('item/started', { item });
          await emit('item/completed', { item });
          setTimeout(() => emit('turn/completed', { turn: { id, status: 'completed' } }), 20);
          return { turn: { id } };
        }
      }
      return null;
    } } };
  });
  await page.goto('/');
  for (let count = 1; count <= 2; count++) {
    await page.evaluate(async () => {
      const { ui } = await import('/core.js');
      await ui.chats.send('на гит обнову', { literal: true, attachments: ['/tmp/picture.png', '/tmp/doc.txt'] });
    });
    await expect(page.locator('.message.user')).toHaveCount(count);
    await expect.poll(() => page.evaluate(async () => !!(await import('/core.js')).ui.chats.current().busy)).toBe(false);
  }
  expect(await page.evaluate(async () => (await import('/core.js')).ui.chats.current().messages.filter(m => m.kind === 'user').map(m => ({ text: m.text, attachments: m.attachments, server: m.codexItemId })))).toEqual([1, 2].map(n => ({ text: 'на гит обнову', attachments: ['/tmp/picture.png', '/tmp/doc.txt'], server: `user-${n}` })));
});

test('local Claude transcript restores its session and message history', async ({ page }) => {
  await page.addInitScript(() => {
    window.__TAURI__ = { event: { listen: async () => () => {} }, core: { invoke: async (_, r) => {
      if (r.module === 'app') return ({ accounts: [{ name: 'Test', home: '/tmp/test' }], info: { home: '/tmp', os: 'windows' }, settings: {} })[r.method] ?? null;
      if (r.method === 'threads') return [{ id: 'local:fixture', path: '/fixture', title: 'Claude fixture', cwd: '/tmp', account: 'Claude', date: 1 }];
      if (r.method === 'readLocal') return { id: 'fixture', target: 'claude', session: 'session-fixture', title: 'Claude fixture', directory: '/tmp', messages: [{ id: 'm', kind: 'agent', text: 'Сохранённый ответ', done: true }] };
      if (r.module === 'api' && r.method === 'list') return [];
      return null;
    } } };
  });
  await page.goto('/');
  await page.getByRole('button', { name: 'Claude fixture', exact: true }).click();
  await expect(page.locator('.agent .message-body')).toHaveText('Сохранённый ответ');
  const session = await page.evaluate(async () => (await import('/core.js')).ui.chats.current().session);
  expect(session).toBe('session-fixture');
});

test('native Claude history loads transcript and reuses the open session tab', async ({ page }) => {
  await page.addInitScript(() => {
    window.historyReads = 0;
    window.__TAURI__ = { event: { listen: async () => () => {} }, core: { invoke: async (_, r) => {
      if (r.module === 'app') return ({ accounts: [], info: { home: '/tmp', os: 'windows' }, settings: {} })[r.method] ?? null;
      if (r.method === 'threads') return [{ id: 'claude:session-fixture', session: 'session-fixture', path: '/fixture.jsonl', title: 'Native Claude', cwd: '/tmp', date: 1 }];
      if (r.module === 'claude' && r.method === 'readHistory') { window.historyReads++; return [{ id: 'a', kind: 'agent', text: 'Ответ из CLI', done: true }]; }
      if (r.module === 'api' && r.method === 'list') return [];
      return null;
    } } };
  });
  await page.goto('/');
  const history = page.locator('button.thread').filter({ hasText: /^Native Claude$/ });
  await history.click();
  await expect(page.locator('.agent .message-body')).toHaveText('Ответ из CLI');
  const first = await page.evaluate(async () => (await import('/core.js')).ui.chats.current().id);
  await history.click();
  expect(await page.evaluate(async () => ({ id: (await import('/core.js')).ui.chats.current().id, reads: window.historyReads }))).toEqual({ id: first, reads: 1 });
});

test('restored local history reuses its existing tab and preserves pending branch context', async ({ page }) => {
 await page.addInitScript(() => {
  window.reads = 0;
  window.__TAURI__ = { event: { listen: async () => () => {} }, core: { invoke: async (_, r) => {
   if (r.module === 'app') return ({ accounts: [], info: { home: '/tmp', os: 'windows' }, settings: {} })[r.method] ?? null;
   if (r.method === 'threads') return [{ id: 'local:branch', title: 'Branch fixture', path: '/fixture', date: 1 }];
   if (r.method === 'readLocal') { window.reads++; return { id: 'branch', target: 'claude', directory: '/tmp', title: 'Branch fixture', seed: 'Previous context', messages: [{ id: 'old', kind: 'user', text: 'Previous context' }] }; }
   if (r.module === 'api' && r.method === 'list') return [];
   return null;
  } } };
 });
 await page.goto('/'); const row = page.locator('button.thread').filter({ hasText: /^Branch fixture$/ });
 await row.click(); await row.click();
 expect(await page.evaluate(async () => ({ reads: window.reads, seed: (await import('/core.js')).ui.chats.current().seed }))).toEqual({ reads: 1, seed: 'Previous context' });
});

for (const mode of ['assistant', 'result', 'stream-and-assistant']) {
  test(`Claude final reply survives ${mode} delivery without duplicates`, async ({ page }) => {
    await page.addInitScript(() => {
      window.nativeListeners = {};
      window.__TAURI__ = { event: { listen: async (name, fn) => { (window.nativeListeners[name] ||= []).push(fn); return () => {}; } }, core: { invoke: async (_, r) => {
        if (r.module === 'app') return ({accounts:[], info:{home:'/tmp',os:'macos'},settings:{}})[r.method] ?? null;
        if (r.method === 'threads' || r.method === 'list') return [];
        return null;
      } } };
    });
    await page.goto('/');
    await expect.poll(()=>page.evaluate(async()=>!!(await import('/core.js')).ui.chats.current())).toBe(true);
    await page.evaluate(async mode => {
      const {ui} = await import('/core.js');
      const c = ui.chats.open({target:'claude'});
      c.messages.push({kind:'user',text:'Проверь',id:'user'}); c.busy = true;
      const emit = event => Promise.all(window.nativeListeners.claude.map(fn=>fn({payload:{chat:c.id,gen:c.gen,event}})));
      const text='```pult-review\n{"verdict":"ok","notes":[]}\n```';
      if (mode === 'stream-and-assistant') {
        await emit({type:'stream_event',event:{type:'message_start',message:{id:'reply'}}});
        await emit({type:'stream_event',event:{type:'content_block_start',index:0,content_block:{type:'text',text:''}}});
        await emit({type:'stream_event',event:{type:'content_block_delta',index:0,delta:{type:'text_delta',text}}});
      }
      if (mode !== 'result') await emit({type:'assistant',message:{id:'reply',content:[{type:'text',text}]}});
      await emit({type:'result',is_error:false,result:text});
    }, mode);
    expect(await page.evaluate(async()=> (await import('/core.js')).ui.chats.current().messages.filter(m=>m.kind==='agent').map(m=>m.text))).toEqual(['```pult-review\n{"verdict":"ok","notes":[]}\n```']);
  });
}
