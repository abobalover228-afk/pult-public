import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
const runtime=readFileSync(new URL('../ui/mod-runtime.js',import.meta.url),'utf8');
const manifest={format:2,id:'test-mod',name:'Проверочный мод',version:'1',author:'Test',permissions:['chats.read'],commands:[{name:'inspect',title:'Проверить',script:"await pult.call('ui.toast',{text:input});"}],panels:[{id:'tools',title:'Инструменты',placement:'right',html:'<button id="read">Read</button><button id="forbidden">Forbidden</button><pre id="result"></pre><script>read.onclick=()=>pult.call("chats.list").then(x=>result.textContent=JSON.stringify(x));forbidden.onclick=()=>pult.call("files.read",{path:".env"}).catch(e=>result.textContent=String(e));</script>'}],sidebar:[{id:'tools',title:'Инструменты',panel:'tools'}]};
async function harness(page){
  await page.addInitScript(manifest=>{
    if(window!==window.top)return;
    window.modCalls=[];window.modEnabled=true;window.inspectManifest=manifest;window.modRows=[{manifest,fingerprint:'hash',approved:true,enabled:true}];
    window.__TAURI__={core:{convertFileSrc:(_path,scheme)=>`http://${scheme}.localhost/`,invoke:async(_,{module,method,args})=>{
      window.modCalls.push({module,method,args});
      if(module==='app'&&method==='get')return '';
      if(module==='codex'&&method==='pick')return ['fixture.pult'];
      if(module==='mods'){
        if(method==='list')return window.modRows;
        if(method==='inspect')return {manifest:window.inspectManifest,fingerprint:'inspected-hash'};
        if(method==='install')return [];
        if(method==='toggle'){window.modEnabled=args.enabled;window.modRows[0].enabled=args.enabled;return window.modRows;}
        if(method==='command')return {command:window.inspectManifest.commands[0],remainingTurns:20};
        if(method==='sdk'){
          if(!window.modEnabled)throw 'Мод выключен';
          if(args.method==='files.read')throw 'Нет права files.read';
          if(args.method==='settings.get')return {};
          return {remainingTurns:20};
        }
      }
      return null;
    }},event:{listen:async()=>()=>{}}};
  },manifest);
  await page.route('**/mods-harness.html',route=>route.fulfill({contentType:'text/html',body:`<!doctype html><div id="root"></div><script type="module">
    import {ui,h} from '/core.js';
    const root=document.querySelector('#root');window.toasts=[];
    ui.toast=text=>window.toasts.push(text);ui.theme={register(){},apply(){}};
    ui.chats.current=()=>({id:'chat',title:'Secret chat',cwd:'C:/project',target:'codex',model:'test',busy:false,messages:[],queue:[]});ui.chats.list=()=>[ui.chats.current()];ui.chats.onEvent=fn=>window.modChatEvent=fn;
    ui.openPanel=(id)=>{root.replaceChildren();ui.panels.get(id).render(root);};ui.closePanel=()=>{root.replaceChildren();};ui.markReady();
    await import('/mods.js');window.modsLoaded=true;
  </script>`}));
  await page.route('http://pult-mod.localhost/**',route=>{
    const url=new URL(route.request().url()),parts=url.pathname.split('/').filter(Boolean);const script=parts[2]==='command'?`window.__pultRun=async(input)=>{await pult.call('ui.toast',{text:input});};`:'';
    return route.fulfill({contentType:'text/html',headers:{'Content-Security-Policy':"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'none'; frame-src 'none'"},body:`<script>${runtime}</script><script>${script}</script>${manifest.panels[0].html}`});
  });
  await page.goto('/mods-harness.html');await expect.poll(()=>page.evaluate(()=>window.modsLoaded)).toBe(true);
}
test('mod iframe is isolated and backend authorizes every SDK request',async({page})=>{
  await harness(page);await page.evaluate(async()=>{const{ui}=await import('/core.js');ui.openPanel('mod:test-mod:tools');});
  const frame=page.frameLocator('iframe');await expect(page.locator('iframe')).toHaveAttribute('sandbox','allow-scripts');
  await frame.locator('#read').click();await expect(frame.locator('#result')).toContainText('Secret chat');
  await frame.locator('#forbidden').click();await expect(frame.locator('#result')).toContainText('Нет права files.read');
  expect(await frame.locator('body').evaluate(()=>{try{return !!parent.__TAURI__;}catch{return false;}})).toBe(false);
  const calls=await page.evaluate(()=>window.modCalls.filter(c=>c.method==='sdk'));expect(calls.some(c=>c.args.method==='chats.list'&&c.args.id==='test-mod'&&c.args.fingerprint==='hash')).toBe(true);
});
test('foreign message sources cannot impersonate a mod and disable removes its frame',async({page})=>{
  await harness(page);await page.evaluate(()=>window.postMessage({pult:true,id:99,method:'chats.list',params:{}},'*'));
  expect(await page.evaluate(()=>window.modCalls.some(c=>c.args?.method==='chats.list'))).toBe(false);
  await page.evaluate(async()=>{const{ui}=await import('/core.js');ui.openPanel('mod:test-mod:tools');});await expect(page.locator('iframe')).toHaveCount(1);
  await page.evaluate(()=>{window.modEnabled=false;window.modRows[0].enabled=false;});await expect(page.locator('iframe')).toHaveCount(0);
});
test('installation displays exact code and requires an explicit fingerprint approval',async({page})=>{
  await harness(page);await page.evaluate(async()=>{const{ui}=await import('/core.js');ui.openPanel('mods');});
  await page.getByRole('button',{name:'+ Установить .pult'}).click();
  await expect(page.locator('pre')).toContainText('test-mod');await expect(page.getByText('SHA-256 inspected-hash')).toBeVisible();
  expect(await page.evaluate(()=>window.modCalls.some(c=>c.method==='install'))).toBe(false);
  await page.getByRole('button',{name:'Одобряю этот код и права — установить'}).click();
  expect(await page.evaluate(()=>window.modCalls.find(c=>c.method==='install').args)).toMatchObject({path:'fixture.pult',fingerprint:'inspected-hash',approved:true});
});
test('script commands receive input inside their isolated context',async({page})=>{
  await harness(page);await page.evaluate(async()=>{const{ui}=await import('/core.js');await ui.commands.get('test-mod/inspect').run('Hello from mod');});
  await expect.poll(()=>page.evaluate(()=>window.toasts.includes('Hello from mod'))).toBe(true);
  await expect(page.locator('iframe')).toHaveCount(0);
});
