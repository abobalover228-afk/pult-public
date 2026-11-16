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
  constructor(invite, identity, hooks = {}) { this.invite = invite; this.id = identity; this.hooks = hooks; this.peers = new Map(); this.messages = []; this.cursor = 0; this.closed = false; }
  async request(action, body) { return call('team','http',{ ...this.invite, identity:this.id, action, body, cursor:this.cursor }); }
  async start() {
    this.key = await crypto.subtle.importKey('raw',un64(this.invite.key),'AES-GCM',false,['encrypt','decrypt']);
    const joined = await this.request('join',{}); this.cursor = joined.cursor;
    for (const id of joined.peers || []) await this.peer(id,true);
    this.poll();
  }
  async poll() {
    while (!this.closed) {
      try {
        const result = await this.request('events');
        if (this.closed) return;
        for (const e of result.events || []) {
          if (e.sender === this.id) continue;
          if (e.kind === 'leave') this.removePeer(e.sender);
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
      } catch (e) { this.hooks.status?.(`Служба знакомства: ${e}`); await new Promise(r => setTimeout(r,4000)); }
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
    this.peers.delete(id); p.pc.onconnectionstatechange = null; p.pc.onicecandidate = null; p.pc.onnegotiationneeded = null;
    p.dc?.close(); p.pc.close(); p.fragments.clear();
  }
  async peer(id, offer = false) {
    if (offer && ['failed','closed'].includes(this.peers.get(id)?.pc.connectionState)) this.removePeer(id);
    if (this.closed || id === this.id || this.peers.has(id) || this.peers.size >= 7) return this.peers.get(id);
    const pc = new RTCPeerConnection({iceServers:[{urls:['stun:stun.l.google.com:19302','stun:stun1.l.google.com:19302']}]}), p = {pc, pending:[],fragments:new Map(),restarts:0};
    this.peers.set(id,p);
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
      this.hooks.status?.(state === 'failed' ? 'Прямое P2P-соединение недоступно: проверь VPN, firewall и поддержку UDP в сети.' : `P2P: ${state}`);
    };
    if (offer && this.id < id) { this.channel(id,p,pc.createDataChannel('pult-room-v1',{ordered:true})); await pc.setLocalDescription(await pc.createOffer()); await this.signal(id,{kind:'offer',sdp:pc.localDescription.sdp}); }
    return p;
  }
  channel(id,p,dc) {
    p.dc = dc; dc.binaryType = 'arraybuffer';
    dc.onopen = () => { this.send({messages:this.messages.slice(-100)},id);this.hooks.open?.(id); };
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
    this.messages=[...map.values()].sort((a,b)=>a.date-b.date||a.id.localeCompare(b.id)).slice(-1000);this.hooks.messages?.(this.messages);
  }
  send(packet,to) {
    if((packet.messages||[]).length>1)return packet.messages.every(m=>this.send({messages:[m]},to));
    packet={messages:[],...packet};const bytes=enc.encode(JSON.stringify(packet));if(bytes.length>2000000)return false;let sent=false;
    for(const[id,p]of this.peers){if(to&&id!==to)continue;if(p.dc?.readyState!=='open'||p.dc.bufferedAmount+bytes.length*2>=4000000)continue;
      const fid=crypto.randomUUID(),count=Math.ceil(bytes.length/12000);for(let index=0;index<count;index++)p.dc.send(enc.encode(JSON.stringify({id:fid,index,count,data:b64(bytes.slice(index*12000,(index+1)*12000))})));sent=true;}
    return sent;
  }
  event(value,to){return this.send({event:b64(enc.encode(JSON.stringify(value)))},to);}
  async stop(){this.closed=true;for(const id of [...this.peers.keys()])this.removePeer(id);try{await this.request('leave',{});}catch{}}
}
