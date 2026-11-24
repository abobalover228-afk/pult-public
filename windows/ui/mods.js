import { devinProvider, devinClient } from './devin.js';
import { call, on, ui, h, settings } from './core.js';
import { button } from './render.js';
const records=new Map(),contexts=new Set(),logs=new Map();
let rows=[],refreshing=false,signature='';
const allPanels=m=>[...(m.panel?[{id:'main',...m.panel,placement:'sheet'}]:[]),...(m.panels||[])];
const summary=c=>({id:c.id,title:c.title,status:c.busy?'working':'ready',cwd:c.cwd,provider:c.target,model:c.model,busy:!!c.busy,active:c===ui.chats.current()});
const current=(p={})=>{const c=p.id?ui.chats.list().find(c=>c.id===p.id):ui.chats.current();if(!c)throw new Error('Чат не найден');return c;};
function log(owner,message){const list=logs.get(owner)||[];list.push(String(message).slice(0,2000));logs.set(owner,list.slice(-80));}
const native=(r,method,params={})=>call('mods','sdk',{id:r.manifest.id,fingerprint:r.fingerprint,method,params,root:((method.startsWith('files.')||method.startsWith('git.'))&&params.id?current(params):ui.chats.current())?.cwd||''});
function destroy(context){if(!contexts.delete(context))return;context.frame.remove();clearTimeout(context.timeout);}
function teardown(id){
  for(const c of [...contexts])if(c.record.manifest.id===id)destroy(c);
  for(const kind of ['commands','panels','sidebar','composer','statusbar']){
    const collection=ui[kind];if(!collection)continue;
    const ids=collection instanceof Map?[...collection.keys()]:collection.map(x=>x.id);
    for(const key of ids)if(key.startsWith(`mod:${id}:`)||key.startsWith(`${id}/`)){if(kind==='panels')ui.closePanel(key);ui.remove(kind,key);}
  }
  records.delete(id);
  if(id==='devin')ui.setProviders(ui.providers.filter(p=>p.id!==devinProvider));
}
function frame(r,kind,name,input=''){
  const id=r.manifest.id;
  const base=window.__TAURI__.core.convertFileSrc('','pult-mod').replace(/\/$/,'');
  const url=`${base}/${id}/${r.fingerprint}/${kind}/${name}`;
  const el=h('iframe.mod-frame',{sandbox:'allow-scripts',title:`${r.manifest.name} · ${name}`,referrerpolicy:'no-referrer',credentialless:true,src:url});
  el.style.cssText='width:100%;height:100%;min-height:320px;border:0;background:#181b21';
  const ctx={record:r,frame:el,kind};contexts.add(ctx);
  el.onload=()=>{if(ctx.loaded){destroy(ctx);return;}ctx.loaded=true;el.contentWindow.postMessage({pult:true,start:true,input},'*');};
  if(kind!=='panel'){el.hidden=true;document.body.append(el);if(kind==='command')ctx.timeout=setTimeout(()=>destroy(ctx),120000);}
  return ctx;
}
async function openPanel(r,id,placement){
  const p=allPanels(r.manifest).find(p=>p.id===id);if(!p)throw new Error('Панель мода не найдена');
  await native(r,'app.info');
  ui.openPanel(`mod:${r.manifest.id}:${id}`,placement||p.placement||'main');
}
async function command(r,c,input=''){
  const result=await call('mods','command',{id:r.manifest.id,fingerprint:r.fingerprint,name:c.name});c=result.command;
  if(c.prompt!=null){const text=c.prompt.replaceAll('{{input}}',input);await ui.chats.send(`Задача мода «${r.manifest.name}»:\n${text}`,{literal:true});}
  else if(c.script!=null)frame(r,'command',c.name,input);
  else if(c.shell!=null){
    const source=c.shell.replaceAll('{{input}}',input);
    if(!confirm(`Мод «${r.manifest.name}» запрашивает запуск команды с правами пользователя:\n\n${source}\n\nВыполнить именно этот код?`))return;
    await native(r,'app.info');const chat=ui.chats.current();
    ui.chats.note(`Мод «${r.manifest.name}» · терминал:\n${source}`,chat);
    const code=await call('codex','sh',{chat:chat.id,id:crypto.randomUUID(),cmd:source,cwd:chat.cwd,home:chat.account});
    ui.chats.note(`Команда мода завершена: ${code}`,chat);
  }
}
function applyTheme(r){
  if(r){const theme=r.manifest.theme;ui.theme.register({id:`mod:${r.manifest.id}`,name:r.manifest.name,vars:{'--accent':theme.accent,...(theme.background&&{'--bg':theme.background})}});ui.theme.apply(`mod:${r.manifest.id}`);}
  else ui.theme.apply('dark');
  settings.set('modTheme',r?.manifest.id||'');
}

function register(r){
  const m=r.manifest;records.set(m.id,r);
  for(const p of allPanels(m)){
    let context;
    ui.addPanel({id:`mod:${m.id}:${p.id}`,title:`${m.name} · ${p.title}`,slot:p.placement||'main',render(el){context=frame(r,'panel',p.id);el.append(context.frame);},onClose(){if(context)destroy(context);},dispose(){if(context)destroy(context);}});
  }
  for(const c of m.commands)ui.addCommand({name:`${m.id}/${c.name}`,hint:c.title,run:input=>command(r,c,input)});
  const action=a=>async()=>{if(a.panel)await openPanel(r,a.panel);else await command(r,m.commands.find(c=>c.name===a.command));};
  for(const a of m.sidebar||[])ui.addSidebar({id:`mod:${m.id}:${a.id}`,title:a.title,icon:'◇',open:action(a)});
  for(const a of m.toolbar||[])ui.addComposerButton({id:`mod:${m.id}:toolbar-${a.id}`,title:a.title,icon:a.title,run:action(a)});
  for(const a of m.statusbar||[])(ui.addStatusButton||ui.addComposerButton).call(ui,{id:`mod:${m.id}:status-${a.id}`,title:a.title,icon:a.title,run:action(a),open:action(a)});
  if(m.background)frame(r,'background','run');
}
async function refresh(){
  if(refreshing)return;refreshing=true;
  try{
    const result=await call('mods','list');rows=Array.isArray(result)?result:[];
    const enabled=new Map(rows.filter(r=>r.enabled&&r.approved&&r.manifest).map(r=>[r.manifest.id,r]));
    for(const[id,r]of records)if(enabled.get(id)?.fingerprint!==r.fingerprint)teardown(id);
    for(const[id,r]of enabled)if(!records.has(id))register(r);
    if(records.has('devin') && !ui.providers.some(p=>p.id===devinProvider))
      ui.setProviders([...ui.providers,{id:devinProvider,title:'Devin Cloud',model:''}]);
  }finally{refreshing=false;}
}
async function event(r,name,detail,permission){
  if(permission&&!r.manifest.permissions.includes(permission))return;
  try{await native(r,'app.info');for(const ctx of contexts)if(ctx.record===r)ctx.frame.contentWindow?.postMessage({pult:true,event:name,detail},'*');}
  catch{teardown(r.manifest.id);}
}
async function broker(ctx,method,p){
  const r=ctx.record,m=r.manifest;
  const result=await native(r,method,p);
  switch(method){
    case 'log':log(m.id,p.message||'');return {ok:true};
    case 'ui.toast':ui.toast(String(p.text||'').slice(0,300));return {ok:true};
    case 'ui.openPanel':await openPanel(r,p.panel||'main',p.placement);return {ok:true};
    case 'ui.openChat':ui.chats.activate(ui.chats.current().id);return {ok:true};
    case 'ui.openTeam':ui.openPanel('team');return {ok:true};
    case 'ui.teamSettings':ui.openPanel('team');return {ok:true};
    case 'ui.modSettings':ui.openPanel('mods');return {ok:true};
    case 'chats.list':return ui.chats.list().map(summary);
    case 'chats.read':{const c=current(p);return {...summary(c),messages:c.messages.slice(-Math.max(1,Math.min(200,Number.isFinite(p.limit)?Math.floor(p.limit):50))).map(m=>({id:m.id,kind:m.kind,text:String(m.text||'').slice(0,16000),done:!!m.done}))};}
    case 'chats.create':{
      if(ui.chats.list().length>=30)throw new Error('Открыто уже 30 чатов');
      if(p.provider&&!['codex','claude'].includes(p.provider))throw new Error('Неизвестный провайдер');
      return summary(ui.chats.open({title:String(p.title||'Чат мода').slice(0,160),cwd:p.cwd||ui.chats.current().cwd,target:p.provider||'codex',model:String(p.model||''),select:p.select===true}));
    }
    case 'chats.send':{
      const c=current(p),text=p.text;if(typeof text!=='string'||!text.trim()||new TextEncoder().encode(text).length>200000||text.trimStart().startsWith('/')||text.trimStart().startsWith('!')||c.queue.length>=10)throw new Error('Нужна задача до 200 КБ, без slash/shell; очередь до 10');
      await ui.chats.send(`Задача мода «${m.name}»:\n${text}`,{chat:c,literal:true});return {id:c.id,remainingTurns:result.remainingTurns};
    }
    case 'chats.stop':await ui.chats.stop(current(p).id);return {ok:true};
    case 'chats.activate':ui.chats.activate(current(p).id);return {ok:true};
    case 'chats.append':ui.chats.note(`Мод «${m.name}» · ${String(p.text||'').slice(0,16000)}`,current(p));return {ok:true};
    case 'team.state':case 'team.send':case 'team.addTask':case 'team.claim':
      if(!ui.team?.modCall)throw new Error('Командная работа ещё не подключена');return ui.team.modCall(method,p,{modID:m.id,name:m.name});
    default:return result;
  }
}
addEventListener('message',async e=>{
  const ctx=[...contexts].find(c=>c.frame.contentWindow===e.source);if(!ctx||!e.data?.pult)return;
  if(e.data.done){if(ctx.kind==='command')destroy(ctx);return;}
  const now=performance.now();if(!ctx.rateStart||now-ctx.rateStart>=1000){ctx.rateStart=now;ctx.rate=0;}if(++ctx.rate>80){ctx.frame.contentWindow.postMessage({pult:true,reply:true,id:e.data.id,error:'Не более 80 вызовов SDK в секунду'},'*');return;}
  const {id,method,params={}}=e.data;
  if(!Number.isSafeInteger(id)||typeof method!=='string'||!params||Array.isArray(params)||typeof params!=='object')return;
  let response;
  try{if(new TextEncoder().encode(JSON.stringify(e.data)).length>1000000)throw new Error('Вызов SDK больше 1 МБ');response={result:await broker(ctx,method,params)};}
  catch(error){response={error:String(error)};log(ctx.record.manifest.id,error);}
  if(contexts.has(ctx))ctx.frame.contentWindow.postMessage({pult:true,reply:true,id,...response},'*');
});
async function install(el){
  const paths=await call('codex','pick',{});if(!paths[0])return;
  const inspected=await call('mods','inspect',{path:paths[0]}),m=inspected.manifest;
  const review=h('div.settings',{},h('h3',{},`${m.name} · ${m.version} · ${m.author}`),h('p',{},`Права: ${m.permissions.join(', ')||'нет'}`),
    h('p',{},'Мод выполняет авторский код. Права process/shell дают запуск программ с правами пользователя; chats.read открывает личные чаты. Проверь код перед одобрением.'),
    h('pre',{},JSON.stringify(m,null,2)),h('small',{},`SHA-256 ${inspected.fingerprint}`),
    button('Одобряю этот код и права — установить',async()=>{await call('mods','install',{path:paths[0],fingerprint:inspected.fingerprint,approved:true});await refresh();await render(el);},'primary'),button('Отмена',()=>render(el)));
  el.replaceChildren(review);
}
async function render(el){
  await refresh();el.replaceChildren(h('p',{},'Моды .pult · SDK 1 и 2'),h('div.actions',{},button('+ Установить .pult',()=>install(el),'primary'),button('Перечитать файлы модов',async()=>{await refresh();await render(el);}),button('Стандартная тема',()=>applyTheme(null))));
  for(const r of rows){
    if(r.error){el.append(h('p.error',{},`${r.id}: ${r.error}`));continue;}
    const m=r.manifest,box=h('section.limit-card',{},h('h3',{},`${m.name} · ${m.version}`),h('small',{},`${m.author} · ${m.description||''}`),h('p',{},`Права: ${m.permissions.join(', ')||'нет'}`));
    if(!r.approved)box.append(h('p.error',{},'Файл изменён. API и код заблокированы до повторной установки и одобрения.'));
    box.append(h('div.actions',{},button(r.enabled?'Выключить':'Включить',async()=>{await call('mods','toggle',{id:m.id,enabled:!r.enabled});await refresh();await render(el);}),button('Удалить мод',async()=>{if(confirm(`Удалить «${m.name}»? Данные мода останутся на диске.`)){await call('mods','remove',{id:m.id});await refresh();await render(el);}})));
    if(r.enabled){
      for(const[key,value]of Object.entries(await native(r,'settings.get'))){const input=h('input',{value});input.onchange=()=>native(r,'settings.set',{key,value:input.value}).catch(ui.toast);box.append(h('label',{},key,input));}
      const actions=h('div.actions',{},button('Ещё 20 автоходов',()=>call('mods','resetTurns',{id:m.id})));if(m.theme)actions.append(button('Применить тему',()=>applyTheme(r)));
      for(const p of allPanels(m))actions.append(button(p.title,()=>openPanel(r,p.id)));box.append(actions);
      for(const c of m.commands)box.append(button(`/${m.id}/${c.name} — ${c.title}`,()=>command(r,c)));
    }
    box.append(h('details',{},h('summary',{},'Код и журнал'),h('pre',{},JSON.stringify(m,null,2)),h('pre',{},(logs.get(m.id)||[]).join('\n'))));el.append(box);
  }
}
ui.addPanel({id:'mods',title:'Моды',render});
ui.addSidebar({id:'mods',title:'Моды',icon:'◇',open:()=>ui.openPanel('mods')});
ui.addSettings({id:'mods',title:'Моды',render:el=>el.append(button('Управлять модами',()=>ui.openPanel('mods')))});
addEventListener('keydown',e=>{
  if(e.repeat||e.target.closest('input,textarea,[contenteditable=true]'))return;
  for(const r of records.values())for(const c of r.manifest.commands){if(!c.shortcut)continue;const keys=c.shortcut.toLowerCase().split('+'),key=keys.pop();const cmd=keys.includes('cmd'),ctrl=keys.includes('ctrl')||(cmd&&!navigator.platform.includes('Mac'));
    if(e.key.toLowerCase()===key&&e.ctrlKey===ctrl&&e.metaKey===(cmd&&navigator.platform.includes('Mac'))&&e.altKey===keys.includes('alt')&&e.shiftKey===keys.includes('shift')){e.preventDefault();command(r,c).catch(ui.toast);return;}}
});
await ui.ready;
ui.chats.onEvent(e=>{
  if(e.type==='turnEnd')for(const r of records.values())event(r,'chat.finished',{id:e.chat.id,text:[...e.chat.messages].reverse().find(m=>m.kind==='agent')?.text||'',failed:!!e.turn?.error,teamTask:e.chat.teamTask||''},'chats.read');
  if(e.type==='message'&&['approval','question'].includes(e.message.kind))for(const r of records.values())event(r,e.message.kind==='question'?'chat.question':'chat.approval',{id:e.chat.id},'chats.read');
});
await on('mods',e=>{const r=records.get(e.id);if(r&&r.fingerprint===e.fingerprint)event(r,e.event,e.detail);});
// Пульс модов: тик раз в секунду; список модов с диска — раз в 5 с, их настройки — раз в 2 с.
// Раньше всё это шло каждые 0,5 с и держало процессор занятым без дела.
let pulseRunning=false,pulse=0;
setInterval(async()=>{
  pulse++;if(pulseRunning||(document.hidden&&pulse%10))return;pulseRunning=true;
  try{
    if(pulse%5===1)await refresh();const chats=ui.chats.list().map(summary),next=JSON.stringify(chats);const changed=next!==signature;signature=next;
    for(const r of records.values()){
      await event(r,'app.tick',{time:Date.now()/1000});if(changed)await event(r,'chats.changed',{chats,activeID:ui.chats.current()?.id},'chats.read');
      if(pulse%2===1||!r.settingsKey){const values=await native(r,'settings.get'),key=JSON.stringify(values);if(key!==r.settingsKey){r.settingsKey=key;await event(r,'settings.changed',{settings:values});}}
    }
  }catch(error){console.error(error);}finally{pulseRunning=false;}
},1000);
try{await refresh();const theme=await settings.get('modTheme');if(records.has(theme))applyTheme(records.get(theme));}catch(error){ui.toast(String(error));}

ui.devin = { connect() {
  const r = records.get('devin');
  if (!r) throw new Error('Включи мод Devin');
  return devinClient((method, params) => native(r, method, params));
} };
