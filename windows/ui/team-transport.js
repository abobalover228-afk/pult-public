import { call } from './core.js';
const enc = new TextEncoder(), dec = new TextDecoder();
export const b64 = bytes => btoa(Array.from(bytes, b => String.fromCharCode(b)).join(''));
export const un64 = text => Uint8Array.from(atob(text), c => c.charCodeAt(0));
export function invitation(code) {
  if (code.length > 4000) throw Error('Приглашение слишком длинное');
  const raw = code.startsWith('pult-room:') ? code.slice(10) : new URL(code).hash.slice(1);
  const v = JSON.parse(dec.decode(un64(raw)));
  const u = new URL(v.server);
  if (!(u.protocol === 'https:' || (u.protocol === 'http:' && ['localhost','127.0.0.1','[::1]'].includes(u.hostname))) || u.username || u.password || u.search || u.hash || !/^[\w-]{20,80}$/.test(v.room) || !/^[\w-]{20,80}$/.test(v.access) || un64(v.key).length !== 32) throw Error('Неверное приглашение');
  return v;
}
export class DirectRoom {
  constructor(invite, identity, hooks = {}) { this.invite = invite; this.id = identity; this.hooks = hooks; this.peers = new Map(); this.messages = []; this.cursor = 0; this.closed = false;
    // Пересылка через сервер — запасной путь, когда напрямую не соединилось. Формат совпадает с Mac-версией на Swift.
    this.relayOn = false; this.relayed = new Set(); this.greeted = new Set(); this.relayParts = new Map(); }
  /** Участники, с которыми есть связь: напрямую или через сервер. */
  reachable() { return [...this.peers.keys()].filter(id => this.peers.get(id)?.dc?.readyState === 'open' || this.relayed.has(id)); }
  get usesRelay() { return this.reachable().some(id => this.peers.get(id)?.dc?.readyState !== 'open'); }
  changed() { this.hooks.peers?.(this.reachable().length); }
  async request(action, body) { return call('team','http',{ ...this.invite, identity:this.id, action, body, cursor:this.cursor }); }
  async start() {
    this.key = await crypto.subtle.importKey('raw',un64(this.invite.key),'AES-GCM',false,['encrypt','decrypt']);
    await this.join();
    this.poll();
  }
  async join() {
    const joined = await this.request('join',{}); this.cursor = joined.cursor; this.relayOn = joined.relay === true;
    for (const id of joined.peers || []) await this.peer(id,true);
  }
  async poll() {
    while (!this.closed) {
      try {
        const result = await this.request('events');
        if (this.closed) return;
        for (const e of result.events || []) {
          if (e.sender === this.id) continue;
          if (e.kind === 'leave') this.removePeer(e.sender);
          if (e.kind === 'relay') await this.relayReceive(e.sender, e.box).catch(() => this.hooks.status?.('Отклонён неверный пакет'));
          if (e.kind === 'join') await this.peer(e.sender,true);
          if (e.kind === 'signal') {
            try {
              const bytes = un64(e.box), aad = enc.encode(`${this.invite.room}|${e.sender}|${this.id}`);
              const data = await crypto.subtle.decrypt({name:'AES-GCM',iv:bytes.slice(0,12),additionalData:aad},this.key,bytes.slice(12));
              await this.receiveSignal(e.sender,JSON.parse(dec.decode(data)));
            } catch { this.hooks.status?.('Отклонён неверный сигнал'); }
          }
        }
        this.cursor = result.cursor;
      } catch (e) {
        if (this.closed) return;
        const text = String(e);
        // 403 — комнаты больше нет; 409/410 — сервер нас забыл или мы отстали от очереди: входим заново.
        if (/HTTP 403/.test(text)) { this.hooks.status?.('Комнаты больше нет на сервере. Создай новую и отправь кенту приглашение.'); this.hooks.gone?.(); return; }
        if (/HTTP 40[9]|HTTP 410/.test(text)) { try { await this.join(); continue; } catch {} }
        this.hooks.status?.(this.reachable().length ? 'Связь с кентом есть; сервер комнат недоступен.' : 'Нет связи с сервером комнат. Повторяем…');
        await new Promise(r => setTimeout(r,4000));
      }
    }
  }
  async signal(peer, value) {
    if (this.closed) return;
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const cipher = new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv:nonce,additionalData:enc.encode(`${this.invite.room}|${this.id}|${peer}`)},this.key,enc.encode(JSON.stringify(value))));
    const bytes = new Uint8Array(12+cipher.length); bytes.set(nonce);bytes.set(cipher,12);
    await this.request('signal',{recipient:peer,box:b64(bytes)});
  }
  removePeer(id) {
    const p = this.peers.get(id); if (!p) return;
    this.peers.delete(id); this.relayed.delete(id); this.greeted.delete(id); this.changed(); p.pc.onconnectionstatechange = null; p.pc.onicecandidate = null; p.pc.onnegotiationneeded = null;
    p.dc?.close(); p.pc.close(); p.fragments.clear();
  }
  async peer(id, offer = false) {
    if (offer && ['failed','closed'].includes(this.peers.get(id)?.pc.connectionState)) this.removePeer(id);
    if (this.closed || id === this.id || this.peers.has(id) || this.peers.size >= 7) return this.peers.get(id);
    const pc = new RTCPeerConnection({iceServers:[{urls:['stun:stun.l.google.com:19302','stun:stun1.l.google.com:19302']}]}), p = {pc, pending:[],fragments:new Map(),restarts:0};
    this.peers.set(id,p);
    // Напрямую не поднялось за 12 секунд — предлагаем связь через сервер.
    setTimeout(() => this.greet(id), 12000);
    p.candidates=[];pc.onicecandidate = e => { if(e.candidate)p.candidates.push(e.candidate.candidate); if (e.candidate && !e.candidate.candidate.includes(' typ relay ')) this.signal(id,{kind:'candidate',candidate:e.candidate.candidate,mid:e.candidate.sdpMid,line:e.candidate.sdpMLineIndex}).catch(e => this.hooks.status?.(String(e))); };
    pc.ondatachannel = e => this.channel(id,p,e.channel);
    pc.onnegotiationneeded = async () => {
      if (!p.restarts || this.closed || pc.signalingState !== 'stable') return;
      try { await pc.setLocalDescription(await pc.createOffer({iceRestart:true})); await this.signal(id,{kind:'offer',sdp:pc.localDescription.sdp}); }
      catch (e) { this.hooks.status?.(`Повторное соединение: ${e}`); }
    };
    pc.onconnectionstatechange = () => {
      const state = pc.connectionState;
      if (state === 'failed' && this.id < id && p.restarts < 2 && !this.closed) {
        p.restarts++; pc.restartIce();
      }
      if (['failed','disconnected','closed'].includes(state)) { this.greeted.delete(id); this.greet(id); }
      if (this.relayed.has(id)) return;
      this.hooks.status?.(state === 'failed' ? (this.relayOn ? 'Напрямую не соединилось. Пробуем через сервер…' : 'Напрямую не соединилось, а пересылка на этом сервере выключена. Проверь VPN и firewall.')
        : state === 'connected' ? 'Прямое соединение' : state === 'connecting' || state === 'new' ? 'Соединяемся с кентом…' : `Соединение: ${state}`);
    };
    if (offer && this.id < id && !this.hooks.forceRelay) { this.channel(id,p,pc.createDataChannel('pult-room-v1',{ordered:true})); await pc.setLocalDescription(await pc.createOffer()); await this.signal(id,{kind:'offer',sdp:pc.localDescription.sdp}); }
    return p;
  }
  channel(id,p,dc) {
    p.dc = dc; dc.binaryType = 'arraybuffer';
    dc.onopen = () => { const was = this.relayed.delete(id); this.greeted.delete(id); this.changed(); this.hooks.status?.('Прямое соединение'); this.send({messages:this.messages.slice(-100)},id); if (!was) this.hooks.open?.(id); };
    dc.onclose = () => { this.changed(); };
    dc.onmessage = async e => {
      try {
        const bytes = typeof e.data === 'string' ? enc.encode(e.data) : new Uint8Array(e.data); if (bytes.length>20000) return;
        const f = JSON.parse(dec.decode(bytes)); if (typeof f.id !== 'string' || f.id.length > 80 || typeof f.data !== 'string' || !Number.isInteger(f.count)||f.count<1||f.count>167||!Number.isInteger(f.index)||f.index<0||f.index>=f.count) return;
        for (const [k,v] of p.fragments) if (Date.now()-v.time>30000) p.fragments.delete(k);
        if (!p.fragments.has(f.id) && p.fragments.size>=8) return;
        const part = un64(f.data);if(part.length>12000)return;
        const item = p.fragments.get(f.id)||{time:Date.now(),count:f.count,parts:new Map()}; if(item.count!==f.count)return;
        item.parts.set(f.index,part);p.fragments.set(f.id,item);if(item.parts.size!==f.count)return;p.fragments.delete(f.id);
        const length=[...item.parts.values()].reduce((n,p)=>n+p.length,0);if(length>2000000)return;
        const joined=new Uint8Array(length);let offset=0;for(let i=0;i<f.count;i++){const part=item.parts.get(i);joined.set(part,offset);offset+=part.length;}
        const packet=JSON.parse(dec.decode(joined));if(!Array.isArray(packet.messages)||packet.messages.length>100)return;
        this.merge(packet.messages);if(packet.event)this.hooks.event?.(id,JSON.parse(dec.decode(un64(packet.event))));
      }catch{this.hooks.status?.('Отклонён неверный пакет');}
    };
  }
  async receiveSignal(id,s) {
    if (this.closed) return;
    const p = await this.peer(id,false); if(!p)return;
    if(s.kind==='candidate' && typeof s.candidate==='string' && s.candidate.length<4096 && !s.candidate.includes(' typ relay ')) {
      const c={candidate:s.candidate,sdpMid:s.mid,sdpMLineIndex:s.line}; if(p.pc.remoteDescription)await p.pc.addIceCandidate(c);else if(p.pending.length<100)p.pending.push(c);return;
    }
    if(!['offer','answer'].includes(s.kind)||typeof s.sdp!=='string'||s.sdp.length>=32000)return;
    await p.pc.setRemoteDescription({type:s.kind,sdp:s.sdp});for(const c of p.pending)await p.pc.addIceCandidate(c);p.pending=[];
    if(s.kind==='offer'){await p.pc.setLocalDescription(await p.pc.createAnswer());await this.signal(id,{kind:'answer',sdp:p.pc.localDescription.sdp});}
  }
  merge(rows) {
    const map=new Map(this.messages.map(m=>[m.id,m]));
    for(const m of rows)if(typeof m.id==='string'&&typeof m.author==='string'&&m.author.length>0&&m.author.length<=80&&typeof m.text==='string'&&enc.encode(m.text).length<=16000&&m.text.length&&Number.isFinite(m.date))map.set(m.id,m);
    const before=this.messages.length;this.messages=[...map.values()].sort((a,b)=>a.date-b.date||a.id.localeCompare(b.id)).slice(-1000);
    // История при подключении приходит сотней пакетов: интерфейс обновляем один раз за кадр.
    if(this.messages.length!==before&&!this.announcing){this.announcing=true;queueMicrotask(()=>{this.announcing=false;this.hooks.messages?.(this.messages);});}
  }
  send(packet,to) {
    if((packet.messages||[]).length>1)return packet.messages.every(m=>this.send({messages:[m]},to));
    packet={messages:[],...packet};const bytes=enc.encode(JSON.stringify(packet));if(bytes.length>2000000)return false;let sent=false;
    for(const[id,p]of this.peers){if(to&&id!==to)continue;if(p.dc?.readyState!=='open'){if(this.relayed.has(id)){this.relay(bytes,id);sent=true;}continue;}if(p.dc.bufferedAmount+bytes.length*2>=4000000)continue;
      const fid=crypto.randomUUID(),count=Math.ceil(bytes.length/12000);for(let index=0;index<count;index++)p.dc.send(enc.encode(JSON.stringify({id:fid,index,count,data:b64(bytes.slice(index*12000,(index+1)*12000))})));sent=true;}
    return sent;
  }
  // MARK: пересылка через сервер. Части по 24 КБ, AES-GCM ключом комнаты, AAD relay|комната|отправитель|получатель.
  async relaySeal(peer,part){
    const nonce=crypto.getRandomValues(new Uint8Array(12));
    const cipher=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv:nonce,additionalData:enc.encode(`relay|${this.invite.room}|${this.id}|${peer}`)},this.key,enc.encode(JSON.stringify(part))));
    const bytes=new Uint8Array(12+cipher.length);bytes.set(nonce);bytes.set(cipher,12);
    await this.request('relay',{recipient:peer,box:b64(bytes)});
  }
  greet(id){
    if(this.closed||!this.relayOn||!this.peers.has(id)||this.peers.get(id)?.dc?.readyState==='open'||this.greeted.has(id))return;
    this.greeted.add(id);this.relaySeal(id,{id:crypto.randomUUID().toUpperCase(),index:0,count:0,data:''}).catch(()=>this.greeted.delete(id));
  }
  relay(bytes,peer){
    const id=crypto.randomUUID().toUpperCase(),count=Math.max(1,Math.ceil(bytes.length/24000));
    // По порядку: сервер выдаёт события в очерёдности поступления.
    let chain=Promise.resolve();
    for(let index=0;index<count;index++)chain=chain.then(()=>this.relaySeal(peer,{id,index,count,data:b64(bytes.slice(index*24000,(index+1)*24000))}));
    chain.catch(()=>this.hooks.status?.('Не удалось переслать через сервер'));
  }
  async relayReceive(sender,box){
    const bytes=un64(box);
    const data=await crypto.subtle.decrypt({name:'AES-GCM',iv:bytes.slice(0,12),additionalData:enc.encode(`relay|${this.invite.room}|${sender}|${this.id}`)},this.key,bytes.slice(12));
    const part=JSON.parse(dec.decode(data));
    if(typeof part.id!=='string'||part.id.length>80||!Number.isInteger(part.count)||!Number.isInteger(part.index)||typeof part.data!=='string')return;
    const p=await this.peer(sender,false);if(!p)return;
    // На приветствие отвечаем всегда (кент мог перезайти), на ответ — нет, иначе обмен не кончится.
    if(part.count===0&&part.index===0)this.relaySeal(sender,{id:crypto.randomUUID().toUpperCase(),index:1,count:0,data:''}).catch(()=>{});
    if(p.dc?.readyState!=='open'&&!this.relayed.has(sender)){
      this.relayed.add(sender);this.changed();this.hooks.status?.('Связь через сервер · содержимое зашифровано ключом комнаты');
      this.send({messages:this.messages.slice(-100)},sender);this.hooks.open?.(sender);
    }
    if(part.count<1||part.count>90||part.index<0||part.index>=part.count)return;
    const chunk=un64(part.data);if(chunk.length>24000)return;
    for(const[k,v]of this.relayParts)if(Date.now()-v.time>60000)this.relayParts.delete(k);
    if(!this.relayParts.has(part.id)&&this.relayParts.size>=16)return;
    const item=this.relayParts.get(part.id)||{time:Date.now(),count:part.count,parts:new Map()};if(item.count!==part.count)return;
    item.parts.set(part.index,chunk);this.relayParts.set(part.id,item);if(item.parts.size!==part.count)return;this.relayParts.delete(part.id);
    const length=[...item.parts.values()].reduce((n,c)=>n+c.length,0);if(length>2000000)return;
    const joined=new Uint8Array(length);let offset=0;for(let i=0;i<part.count;i++){joined.set(item.parts.get(i),offset);offset+=item.parts.get(i).length;}
    const packet=JSON.parse(dec.decode(joined));if(!Array.isArray(packet.messages)||packet.messages.length>100)return;
    this.merge(packet.messages);if(packet.event)this.hooks.event?.(sender,JSON.parse(dec.decode(un64(packet.event))));
  }
  event(value,to){return this.send({event:b64(enc.encode(JSON.stringify(value)))},to);}
  async stop(){this.closed=true;for(const id of [...this.peers.keys()])this.removePeer(id);try{await this.request('leave',{});}catch{}}
}
