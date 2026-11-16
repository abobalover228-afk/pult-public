import {call,ui,h,settings} from './core.js';
let enabled=true;
ui.addSettings({id:'notifications',title:'Уведомления',render(el){
  const input=h('input',{type:'checkbox',checked:enabled});
  input.onchange=async()=>{await settings.set('notifications',input.checked);enabled=input.checked;};
  el.append(h('label.inline',{},input,'Системные уведомления о завершении и запросах внимания'));
}});
await ui.ready;
enabled=await settings.get('notifications')!==false;
ui.chats.onEvent(e=>{
  if(!enabled)return;
  let title,body;
  if(e.type==='turnEnd'){
    title=`${e.failed?'Ошибка':'Готово'} · ${e.chat.title}`;
    body=e.failed?'Проверь результат в Пульте.':e.chat.messages.findLast(m=>m.kind==='agent')?.text||'Ход завершён.';
  }else if(e.type==='message'&&!e.message.done&&['approval','question'].includes(e.message.kind)){
    title=`${e.message.kind==='approval'?'Нужно разрешение':'Нужен ответ'} · ${e.chat.title}`;body=e.message.text;
  }else return;
  call('app','notify',{title,body,background:true}).catch(ui.toast);
});
