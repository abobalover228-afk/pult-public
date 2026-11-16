import {call,ui,h,settings} from './core.js';
import {button} from './render.js';
let image = null, dimming = 0.65;
const background = h('div.wallpaper', {'aria-hidden':'true', hidden:true});
document.body.prepend(background);
async function apply(value) {
  if (value) {
    if (typeof value !== 'string' || !/^data:image\/(png|jpeg|gif|webp|bmp);base64,/.test(value)) throw new Error('Неверное изображение фона');
    const picture = new Image(); picture.src = value; await picture.decode();
  }
  image = value; background.hidden = !image;
  background.style.backgroundImage = image ? `linear-gradient(rgba(0,0,0,${dimming}),rgba(0,0,0,${dimming})),url(${JSON.stringify(image)})` : '';
}
ui.addSettings({id:'wallpaper',title:'Фон',render(el){
  const slider = h('input', {type:'range',min:0.2,max:0.9,step:0.05,value:dimming,'aria-label':'Затемнение фона'});
  const percent = h('small', {}, `${Math.round(dimming*100)}%`);
  slider.oninput = () => { dimming = Number(slider.value); percent.textContent = `${Math.round(dimming*100)}%`; background.style.backgroundImage = image ? `linear-gradient(rgba(0,0,0,${dimming}),rgba(0,0,0,${dimming})),url(${JSON.stringify(image)})` : ''; };
  slider.onchange = () => settings.set('backgroundDimming',dimming).catch(ui.toast);
  el.append(button('Выбрать картинку фона',async()=>{
    const paths = await call('codex','pick',{images:true}); if (!paths?.[0]) return;
    const candidate = await call('codex','readImage',{path:paths[0]});
    const picture = new Image(); picture.src = candidate; await picture.decode();
    await apply(await call('codex','wallpaper',{path:paths[0]}));
  }),button('Сбросить фон',async()=>{await call('codex','wallpaper');await apply(null);}),h('label',{},'Затемнение',slider,percent));
}});
await ui.ready;
const saved = await settings.get('backgroundDimming'); if (typeof saved === 'number' && saved>=0.2 && saved<=0.9) dimming=saved;
try { await apply(await call('codex','wallpaper',{read:true})); } catch (e) { ui.toast(String(e)); }
