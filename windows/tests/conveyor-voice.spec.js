import { test, expect } from '@playwright/test';
async function fixture(page) {
  await page.addInitScript(() => {
    window.calls = [];
    window.__TAURI__ = { core: { invoke: async (_, r) => {
      window.calls.push(r);
      if (r.module === 'app' && r.method === 'get' && r.args.key === 'conveyor') return null;
      if (r.module === 'voice' && r.method === 'voices') return {voices:[{id:'ru-one',name:'Милена',language:'ru-RU'},{id:'en-one',name:'Alex',language:'en-US'}]};
      if (r.module === 'voice' && ['listen','speak'].includes(r.method)) return new Promise((resolve, reject) => { window.speech = {resolve,reject,method:r.method}; });
      if (r.module === 'voice' && r.method === 'stop') { window.speech?.reject('Голос остановлен'); window.speech = null; }
      return null;
    } }, event: { listen: async () => () => {} } };
  });
  await page.goto('/limits.html');
  await page.evaluate(() => document.body.className = '');
  await page.evaluate(async () => {
    const { ui } = await import('/core.js');
    window.sent = []; window.chats = []; window.events = [];
    Object.assign(ui.chats, {
      current: () => window.currentChat,
      list: () => window.chats,
      open: opts => { const c = { ...opts, id: crypto.randomUUID(), messages: [] }; window.chats.push(c); return c; },
      close: async () => {},
      send: async (text, {chat}) => { window.sent.push({text,chat:chat.id}); chat.messages.push({kind:'user',text}); },
      onEvent: fn => window.events.push(fn)
    });
    ui.markReady();
    await import('/conveyor.js'); await import('/voice.js');
    window.currentChat = ui.chats.open({});
    window.makeReview = () => {
      const e = {id:crypto.randomUUID(),title:'Новый конвейер',goal:'Проверить задачу',status:'running',wave:0,parallel:2,roles:{planner:{},worker:{},review1:{},review2:{}},waves:[],log:Array.from({length:60},(_,i)=>({t:Date.now(),text:'Событие '+i}))};
      const t = {id:'task',title:'Исправление',status:'review',round:0,reviews:[],cwd:'/tmp'};
      e.waves = [{tasks:[t,{id:'queued',status:'queued',title:'Следующая задача',reviews:[]}]}];
      for (const slot of ['review1','review2']) { const c=ui.chats.open({conveyor:{epic:e.id,task:t.id,role:'reviewer',slot}}); c.messages=[{kind:'user',text:'Проверь'}]; t.reviews.push({slot,chat:c.id,verdict:'pending',notes:[]}); }
      ui.conveyor.epics().push(e); window.epic=e; window.task=t;
    };
    window.reviewReply = (slot,text,failed=false) => { const c=window.chats.find(c=>c.id===window.task.reviews.find(r=>r.slot===slot).chat); c.messages.push({kind:'agent',text}); ui.conveyor.event({type:'turnEnd',chat:c,failed}); };
  });
}
test('empty reviews retry without sending fixes; invalid fix cannot pass', async ({page}) => {
  await fixture(page);
  await page.evaluate(()=>{window.makeReview();window.reviewReply('review1','');});
  await expect.poll(()=>page.evaluate(()=>window.sent.length)).toBe(1);
  expect(await page.evaluate(()=>({status:task.status,round:task.round,retry:task.reviews[0].retried}))).toEqual({status:'review',round:0,retry:true});
  await page.evaluate(()=>window.reviewReply('review1','```pult-review\n{"verdict":"fix","notes":[" "]}\n```'));
  await expect.poll(()=>page.evaluate(()=>task.status)).toBe('needsYou');
  expect(await page.evaluate(()=>({round:task.round,verdict:task.reviews[0].verdict,sent:window.sent.length}))).toEqual({round:0,verdict:'error',sent:1});
});
test('valid review blocks trigger exactly one fix round; old chats are ignored',async({page})=>{
  await fixture(page);
  await page.evaluate(()=>{window.makeReview();window.reviewReply('review1','```pult-review\n{"verdict":"ok","notes":[]}\n```');window.reviewReply('review2','```pult-review\n{"verdict":"fix","notes":["src/a.js:12 — ошибка"]}\n```');});
  await expect.poll(()=>page.evaluate(()=>task.status)).toBe('fixing');
  expect(await page.evaluate(()=>({round:task.round,text:sent[0].text}))).toEqual({round:1,text:expect.stringContaining('src/a.js:12')});
  await page.evaluate(()=>window.reviewReply('review2',''));
  expect(await page.evaluate(()=>sent.length)).toBe(1);
});
test('history is collapsed and bounded when expanded',async({page})=>{
  await fixture(page);
  await page.evaluate(async()=>{const {ui}=await import('/core.js');window.makeReview();ui.conveyor.epics().splice(0,ui.conveyor.epics().length-1);window.task.status='working';window.task.title='Корзина';window.epic.title='Магазин в боте';window.epic.waves[0].tasks[1].title='Оплата заказа';window.epic.waves[0].tasks.push(...['История заказов','Уведомления о статусе','Каталог','Доставка'].map((title,i)=>({id:'extra'+i,title,status:i%2?'working':'queued',reviews:[]})));const host=document.createElement('div');host.style.cssText='height:760px;width:100%;';document.body.replaceChildren(host);ui.panels.get('conveyor').render(host);});
  // Select the fixture epic after mounting.
  await page.getByRole('button',{name:/Магазин в боте/}).click();
  const history=page.locator('.cv-history');
  await expect(history).not.toHaveAttribute('open','');
  expect(await history.evaluate(el=>el.getBoundingClientRect().height)).toBeLessThan(60);
  await history.locator('summary').click();
  await expect(history).toHaveAttribute('open','');
  expect(await page.locator('.cv-log').evaluate(el=>el.clientHeight)).toBeLessThanOrEqual(188);
  await history.locator('summary').click();
  await expect(page.locator('.cv-node')).toHaveCount(6);
  await expect(page.locator('.particle-sphere')).toHaveCount(1);
  await page.screenshot({path:'test-results/conveyor-design.png', animations:'disabled'});
});
test('sphere listens, sends, speaks and resumes listening; stop cancels late results',async({page})=>{
  await fixture(page);
  await page.evaluate(async()=>{const {ui}=await import('/core.js');const host=document.createElement('div');host.style.cssText='height:680px';document.body.replaceChildren(host);ui.panels.get('voice-sphere').render(host);});
  await page.getByRole('button',{name:'Начать разговор',exact:true}).click();
  await expect(page.locator('.voice-status')).toHaveText('Слушаю тебя');
  await expect(page.getByRole('button',{name:'Завершить разговор',exact:true})).toBeEnabled();
  await page.evaluate(()=>window.speech.resolve({text:'Привет, Пульт'}));
  await expect.poll(()=>page.evaluate(()=>window.sent.length)).toBe(1);
  await expect(page.locator('.voice-status')).toHaveText('Думаю');
  await page.evaluate(()=>{currentChat.messages.push({kind:'agent',text:'Привет, брат'});window.events.forEach(fn=>fn({type:'turnEnd',chat:currentChat}));});
  await expect(page.locator('.voice-status')).toHaveText('Отвечаю');
  await page.screenshot({path:'test-results/voice-sphere.png'});
  await page.evaluate(()=>window.speech.resolve({ok:true}));
  await expect(page.locator('.voice-status')).toHaveText('Слушаю тебя');
  await expect(page.getByRole('button',{name:'Завершить разговор',exact:true})).toBeEnabled();
  await page.getByRole('button',{name:'Завершить разговор',exact:true}).click();
  await expect(page.locator('.voice-status')).toHaveText('На связи');
  expect(await page.evaluate(()=>window.sent.length)).toBe(1);
});

test('voice selection is saved and used for preview and conversation', async ({page}) => {
  await fixture(page);
  await page.evaluate(async()=>{const {ui}=await import('/core.js');const host=document.createElement('div');host.style.cssText='height:680px';document.body.replaceChildren(host);ui.panels.get('voice-sphere').render(host);});
  await expect(page.getByLabel('Голос озвучки')).toContainText('Милена');
  await page.getByLabel('Голос озвучки').selectOption('ru-one');
  await expect.poll(()=>page.evaluate(()=>calls.find(r=>r.module==='app'&&r.method==='set'&&r.args.key==='voice')?.args.value.voice)).toBe('ru-one');
  await page.getByRole('button',{name:'Послушать',exact:true}).click();
  await expect.poll(()=>page.evaluate(()=>calls.filter(r=>r.module==='voice'&&r.method==='speak').at(-1)?.args.voice)).toBe('ru-one');
  await page.evaluate(()=>speech.resolve({ok:true}));
  await expect(page.locator('.voice-status')).toHaveText('На связи');
  await page.getByRole('button',{name:'Начать разговор',exact:true}).click();
  await page.evaluate(()=>speech.resolve({text:'Как дела?'}));
  await expect.poll(()=>page.evaluate(()=>sent.length)).toBe(1);
  await page.evaluate(()=>{currentChat.messages.push({kind:'agent',text:'Всё хорошо'});events.forEach(fn=>fn({type:'turnEnd',chat:currentChat}));});
  await expect.poll(()=>page.evaluate(()=>calls.filter(r=>r.module==='voice'&&r.method==='speak').length)).toBe(2);
  expect(await page.evaluate(()=>calls.filter(r=>r.module==='voice'&&r.method==='speak').at(-1).args.voice)).toBe('ru-one');
});
