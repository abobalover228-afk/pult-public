import {test,expect} from '@playwright/test';
test('Telegram task origin is kept and private turn results are not sent',async({page})=>{
 await page.addInitScript(()=>{window.calls=[];window.handlers={};window.chat={id:'chat1',title:'Test',messages:[{kind:'agent',text:'private answer',origin:null}]};window.__TAURI__={core:{invoke:async(_,r)=>{window.calls.push(r);if(r.method==='state')return {};return null;}},event:{listen:async(name,fn)=>{window.handlers[name]=fn;return()=>{};}}};});
 await page.route('**/integration-harness.html',route=>route.fulfill({contentType:'text/html',body:'<!doctype html><body></body>'}));
 await page.goto('/integration-harness.html');
 await page.evaluate(async()=>{const {ui}=await import('/core.js');ui.chats.current=()=>window.chat;ui.chats.list=()=>[window.chat];ui.chats.onEvent=fn=>window.chatEvent=fn;ui.chats.send=async(text,opts)=>window.sent={text,origin:opts.origin,literal:opts.literal};ui.markReady();await import('/telegram.js');});
 await page.evaluate(()=>window.chatEvent({type:'turnEnd',chat:window.chat,origin:undefined}));
 expect(await page.evaluate(()=>window.calls.filter(c=>c.module==='telegram'&&c.method==='send').length)).toBe(0);
 await page.evaluate(()=>window.handlers.telegram({payload:{text:'remote task'}}));
 await expect.poll(()=>page.evaluate(()=>window.sent)).toEqual({text:'remote task',origin:'telegram',literal:true});
 await page.evaluate(()=>window.chatEvent({type:'turnEnd',chat:window.chat,origin:'telegram'}));
 await expect.poll(()=>page.evaluate(()=>window.calls.filter(c=>c.module==='telegram'&&c.method==='send').length)).toBe(2);
});

 test('updater refuses installation while a team room is connected',async({page})=>{
 await page.addInitScript(()=>{window.calls=[];window.__TAURI__={core:{invoke:async(_,r)=>{window.calls.push(r);return null;}},event:{listen:async()=>()=>{}}};});
 await page.route('**/integration-harness.html',r=>r.fulfill({contentType:'text/html',body:'<!doctype html><body><div id="content"></div></body>'}));
 await page.goto('/integration-harness.html');
 await page.evaluate(async()=>{const {ui}=await import('/core.js');ui.team={connected:()=>true};ui.chats.list=()=>[];ui.markReady();await import('/updater.js');ui.panels.get('updater').render(document.querySelector('#content'));});
 await page.getByRole('button',{name:'Скачать и запустить установщик'}).click();
 expect(await page.evaluate(()=>window.calls.some(c=>c.method==='install'))).toBe(false);
 });

test('Telegram answers a multi-question request separately',async({page})=>{
 await page.addInitScript(()=>{window.calls=[];window.handlers={};window.chat={id:'chat1',title:'Test',messages:[{id:'question1',kind:'question',origin:'telegram',done:false,params:{questions:[{id:'one',question:'Первый?'},{id:'two',question:'Второй?'}]}}]};window.__TAURI__={core:{invoke:async(_,r)=>{window.calls.push(r);return null;}},event:{listen:async(name,fn)=>{window.handlers[name]=fn;return()=>{};}}};});
 await page.route('**/integration-harness.html',r=>r.fulfill({contentType:'text/html',body:'<!doctype html><body></body>'}));await page.goto('/integration-harness.html');
 await page.evaluate(async()=>{const {ui}=await import('/core.js');ui.chats.current=()=>window.chat;ui.chats.list=()=>[window.chat];ui.chats.onEvent=()=>{};ui.chats.answer=async(...args)=>window.answer=args;ui.markReady();await import('/telegram.js');});
 await page.evaluate(()=>window.handlers.telegram({payload:{text:'Ответ один'}}));
 expect(await page.evaluate(()=>window.answer)).toBeUndefined();
 await page.evaluate(()=>window.handlers.telegram({payload:{text:'Ответ два'}}));
 await expect.poll(()=>page.evaluate(()=>window.answer)).toEqual(['chat1','question1',{answers:{one:{answers:['Ответ один']},two:{answers:['Ответ два']}}}]);
});
