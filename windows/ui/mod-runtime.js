(()=>{
  const pending=new Map(),listeners=new Map();let sequence=0,started=false;
  window.pult=Object.freeze({apiVersion:2,call(method,params={}){return new Promise((resolve,reject)=>{const id=++sequence;pending.set(id,{resolve,reject});parent.postMessage({pult:true,id,method,params},'*');});},on(event,fn){const set=listeners.get(event)||new Set();set.add(fn);listeners.set(event,set);return()=>set.delete(fn);}});
  addEventListener('message',e=>{
    if(e.source!==parent)return;const m=e.data;if(!m||!m.pult)return;
    if(m.reply){const p=pending.get(m.id);if(p){pending.delete(m.id);m.error?p.reject(new Error(m.error)):p.resolve(m.result);}}
    if(m.event)for(const fn of [...(listeners.get(m.event)||[])]){try{fn(m.detail);}catch(e){pult.call('log',{message:String(e)}).catch(()=>{});}}
    if(m.start&&!started){started=true;if(window.__pultRun)Promise.resolve().then(()=>window.__pultRun(m.input||'')).catch(e=>pult.call('log',{message:String(e)})).finally(()=>parent.postMessage({pult:true,done:true},'*'));}
  });
  addEventListener('unhandledrejection',e=>pult.call('log',{message:String(e.reason)}).catch(()=>{}));
})();
