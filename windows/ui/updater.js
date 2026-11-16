import {call,ui,h,settings} from './core.js';
import {button} from './render.js';
let automatic=false,checking=false,lastCheck=0;
const idle=()=>!ui.chats.list().some(c=>c.busy)&&!ui.team?.connected?.()&&!ui.team?.state?.().connected;
async function install(){if(!idle())throw new Error('Заверши работу агентов и отключись от комнаты');await call('updater','install');ui.toast('Проверенный установщик запущен');}
async function autoCheck(){
 if(!automatic||checking||!idle()||Date.now()-lastCheck<3600000)return;
 checking=true;lastCheck=Date.now();
 try{const r=await call('updater','check');if(r.installable&&r.newer&&automatic&&idle())await install();}catch(e){ui.toast(String(e));}finally{checking=false;}
}
ui.addPanel({id:'updater',title:'Обновления',render(el){
 const status=h('p',{},'Установщик принимается только с SHA-256 публичного релиза.');
 const auto=h('input',{type:'checkbox',checked:automatic});
 auto.onchange=async()=>{if(auto.checked&&!confirm('Разрешить автоматическую установку проверенных обновлений, когда агенты и комнаты не работают?')){auto.checked=false;return;}automatic=auto.checked;await settings.set('autoUpdate',automatic);if(automatic)autoCheck();};
 el.append(status,h('label',{},auto,' Автоматически обновлять в простое'),button('Проверить обновления',async()=>{const r=await call('updater','check');status.textContent=`Установлено ${r.current}; релиз ${r.tag}. ${r.installable&&r.newer?'Есть новое проверяемое обновление.':'Нового установщика нет.'}`;}),button('Скачать и запустить установщик',async()=>{if(!idle())throw new Error('Сначала заверши работу агентов и отключись от комнаты');if(!confirm('Скачать проверенный Windows-установщик и запустить обновление?'))return;await install();}));
}});
ui.addSettings({id:'updater',title:'Обновления',render:el=>el.append(button('Открыть обновления',()=>ui.openPanel('updater')))});
await ui.ready;automatic=await settings.get('autoUpdate')===true;
setInterval(()=>autoCheck(),60000);autoCheck();
