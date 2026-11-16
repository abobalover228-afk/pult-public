import {test,expect} from '@playwright/test';
test('room invitation validates key length and blocks remote plaintext',async({page})=>{
 await page.addInitScript(()=>window.__TAURI__={core:{invoke:async()=>null},event:{listen:async()=>()=>{}}});await page.goto('/');
 const result=await page.evaluate(async()=>{const {invitation,b64}=await import('/team-transport.js');const make=v=>'pult-room:'+b64(new TextEncoder().encode(JSON.stringify(v)));const base={server:'https://example.test',room:'a'.repeat(24),access:'b'.repeat(24),key:b64(new Uint8Array(32))};const valid=invitation(make(base));let bad=0;for(const v of [{...base,server:'http://example.test'},{...base,key:b64(new Uint8Array(31))},{...base,server:'https://secret@example.test'}])try{invitation(make(v));}catch{bad++;}return {valid:valid.room,bad};});
 expect(result).toEqual({valid:'a'.repeat(24),bad:3});
});
test('binary room fragments match the Swift packet schema',async({page})=>{
 await page.addInitScript(()=>window.__TAURI__={core:{invoke:async()=>null},event:{listen:async()=>()=>{}}});await page.goto('/');
 const result=await page.evaluate(async()=>{const {DirectRoom,un64}=await import('/team-transport.js');const room=new DirectRoom({},'self');const wire=[];room.peers.set('peer',{dc:{readyState:'open',bufferedAmount:0,send:b=>wire.push(JSON.parse(new TextDecoder().decode(b)))}});const text='x'.repeat(30000);const sent=room.send({messages:[{id:'test',author:'Alice',text,date:1}]});const pieces=wire.map(f=>un64(f.data));const bytes=new Uint8Array(pieces.reduce((n,p)=>n+p.length,0));let n=0;for(const p of pieces){bytes.set(p,n);n+=p.length;}return {sent,count:wire.length,packet:JSON.parse(new TextDecoder().decode(bytes)),max:Math.max(...pieces.map(p=>p.length))};});
 expect(result.sent).toBe(true);expect(result.count).toBe(3);expect(result.max).toBeLessThanOrEqual(12000);expect(result.packet.messages[0].text).toHaveLength(30000);
});

test(`two real WebRTC peers exchange fragmented packets through original rendezvous (${process.env.PULT_RTC_NATIVE_NETWORK === '1' ? 'native network' : 'loopback candidates'})`,async({playwright,request})=>{
 const browser=await playwright.chromium.launch({args:['--allow-loopback-in-peer-connection','--disable-features=WebRtcHideLocalIpsWithMdns','--enable-webrtc-localhost-ip-including-loopback','--force-webrtc-ip-handling-policy=default_public_and_private_interfaces','--force-fieldtrials=WebRTC-AllowLoopback/Enabled/']});
 const {spawn}=await import('node:child_process');
 const server=spawn(process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3'),['../signaling/server.py'],{env:{...process.env,PULT_SIGNAL_PORT:'18787'},stdio:'ignore'});
 try{
  let created;
  for(let i=0;i<100;i++){try{const response=await request.post('http://127.0.0.1:18787/v1/rooms',{data:{},timeout:1000});if(response.status()===201){created=await response.json();break;}}catch{}await new Promise(r=>setTimeout(r,100));}
  expect(created).toBeTruthy();
  const invite={server:'http://127.0.0.1:18787',...created,key:Buffer.alloc(32,7).toString('base64')};
  const pages=[await browser.newPage(),await browser.newPage()];
  for(let i=0;i<pages.length;i++){
   const page=pages[i];page.on('pageerror',e=>console.log('PAGEERROR',i,e.message));
   await page.exposeFunction('roomRequest',async a=>{const response=await request.fetch(`${a.server}/v1/rooms/${a.room}/${a.action}${a.action==='events'?`?after=${a.cursor}`:''}`,{method:a.action==='events'?'GET':'POST',headers:{Authorization:`Bearer ${a.access}`,'X-Pult-Peer':a.identity},...(a.action!=='events'&&{data:a.body||{}})});if(!response.ok())throw Error('HTTP '+response.status());return response.json();});
   await page.addInitScript(()=>window.__TAURI__={core:{invoke:async(_,a)=>a.module==='team'&&a.method==='http'?window.roomRequest(a.args):null},event:{listen:async()=>()=>{}}});
   await page.goto('/');
   await page.evaluate(async({invite,id,loopback})=>{const {DirectRoom}=await import('/team-transport.js');window.packets=[];window.direct=new DirectRoom(invite,id,{event:(sender,p)=>window.packets.push({sender,p}),status:s=>(window.roomStatus=s)});const signal = window.direct.signal.bind(window.direct); window.direct.signal = (peer, value) => { if (loopback && value.kind === 'candidate' && value.candidate.includes(' typ host ')) { const fields = value.candidate.split(' '); fields[4] = '127.0.0.1'; value = { ...value, candidate: fields.join(' ') }; } return signal(peer, value); }; await window.direct.start();},{invite,loopback:process.env.PULT_RTC_NATIVE_NETWORK!=='1',id:i===0?'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA':'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'});
  }
  try{await expect.poll(()=>pages[0].evaluate(()=>[...window.direct.peers.values()].some(p=>p.dc?.readyState==='open')),{timeout:20000}).toBe(true);}catch(e){for(const p of pages)console.log(await p.evaluate(()=>({status:window.roomStatus,peers:[...window.direct.peers].map(([id,p])=>({id,dc:p.dc?.readyState,signaling:p.pc.signalingState,ice:p.pc.iceConnectionState,local:p.pc.localDescription?.type,remote:p.pc.remoteDescription?.type,candidates:p.candidates,pending:p.pending,localSdp:p.pc.localDescription?.sdp}))})));throw e;}
  const sent=await pages[0].evaluate(()=>window.direct.event({snapshot:{revision:1,tasks:[],repository:'x'.repeat(50000)}}));expect(sent).toBe(true);
  await expect.poll(()=>pages[1].evaluate(()=>window.packets.length),{timeout:10000}).toBe(1);
  expect(await pages[1].evaluate(()=>window.packets[0].p.snapshot.repository.length)).toBe(50000);
  for(const page of pages){await page.evaluate(()=>window.direct.stop());await page.close();}
 }finally{server.kill();await browser.close();}
});

test('leaving peers release their slot and a failed peer can rejoin', async ({ page }) => {
 await page.addInitScript(()=>window.__TAURI__={core:{invoke:async()=>null},event:{listen:async()=>()=>{}}}); await page.goto('/');
 const result = await page.evaluate(async () => {
  const { DirectRoom } = await import('/team-transport.js');
  const room = new DirectRoom({}, 'self'); let closed = 0;
  window.RTCPeerConnection = class {
   connectionState = 'new';
   close() { this.connectionState = 'closed'; closed++; }
  };
  const old = await room.peer('peer'); old.pc.connectionState = 'failed';
  const replacement = await room.peer('peer', true);
  room.removePeer('peer');
  return { replaced: old !== replacement, size: room.peers.size, closed };
 });
 expect(result).toEqual({ replaced: true, size: 0, closed: 2 });
});

test('only the offerer restarts failed ICE and retries are bounded', async ({ page }) => {
 await page.addInitScript(()=>window.__TAURI__={core:{invoke:async()=>null},event:{listen:async()=>()=>{}}}); await page.goto('/');
 const result = await page.evaluate(async () => {
  const { DirectRoom } = await import('/team-transport.js');
  window.RTCPeerConnection = class { connectionState = 'new'; restarts = 0; restartIce() { this.restarts++; } };
  const leader = new DirectRoom({}, 'a'), follower = new DirectRoom({}, 'z');
  const a = await leader.peer('z'), z = await follower.peer('a');
  for (let i=0;i<4;i++) { a.pc.connectionState = z.pc.connectionState = 'failed'; a.pc.onconnectionstatechange(); z.pc.onconnectionstatechange(); }
  return [a.pc.restarts,z.pc.restarts];
 });
 expect(result).toEqual([2,0]);
});


async function mockRoomUI(page) {
 await page.addInitScript(() => {
  window.teamCalls = []; window.fixtureBoard = {revision:1,tasks:[],repository:'https://github.com/test/project'};
  window.hostID = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
  window.__TAURI__ = {event:{listen:async()=>()=>{}},core:{invoke:async(_,r)=>{
   if(r.module==='app'&&r.method==='get'&&r.args.key==='team.server')return 'https://example.test';
   if(r.module==='app')return ({accounts:[],info:{home:'/tmp',os:'windows'},settings:{}})[r.method]??null;
   if(r.method==='threads'||(r.module==='api'&&r.method==='list'))return [];
   if(r.module==='team'){
    window.teamCalls.push(r);
    if(r.method==='saved')return {identity:window.hostID};
    if(r.method==='outbox'||r.method==='history')return [];
    if(r.method==='token')return {set:false};
    if(r.method==='board'){
     if(r.args.request.action==='add'){window.fixtureBoard.tasks.push({...r.args.request.task,result:''});window.fixtureBoard.revision++;}
     return {snapshot:structuredClone(window.fixtureBoard),response:r.args.request.id};
    }
    if(r.method==='create')return {code:'pult-room:'+btoa(JSON.stringify({server:'https://example.test',room:'a'.repeat(24),access:'b'.repeat(24),key:btoa(String.fromCharCode(...new Uint8Array(32))),coordinator:r.args.identity}))};
   }
   return null;
  }}};
 });
 await page.goto('/');
 await expect.poll(()=>page.evaluate(async()=>!!(await import('/core.js')).ui.team)).toBe(true);
 await page.evaluate(async()=>{
  const {DirectRoom}=await import('/team-transport.js');
  DirectRoom.prototype.start=async function(){window.fixtureRoom=this;};
  DirectRoom.prototype.stop=async function(){this.closed=true;};
  DirectRoom.prototype.send=function(packet){window.sentPacket=packet;return true;};
  DirectRoom.prototype.event=function(packet){window.sentEvent=packet;return true;};
  const {ui}=await import('/core.js');ui.openPanel('team','right');
 });
}

test('team SDK methods reach the room and reject invalid or unconfirmed work',async({page})=>{
 await mockRoomUI(page);
 await page.getByPlaceholder('Как тебя увидит кент').fill('Алиса');
 await page.getByRole('button',{name:'Позвать кента',exact:true}).click();
 await expect.poll(()=>page.evaluate(async()=>(await import('/core.js')).ui.team.state().ready)).toBe(true);
 const result=await page.evaluate(async()=>{
  const {ui}=await import('/core.js'),mod={modID:'fixture',name:'Fixture'};
  await ui.team.modCall('team.addTask',{title:'SDK task',detail:'Task detail'},mod);
  const task=ui.team.state().board.tasks[0];
  await ui.team.modCall('team.claim',{ids:[task.id]},mod);
  await ui.team.modCall('team.send',{text:'Room message'},mod);
  let rejected=0;for(const params of [{ids:[task.id,task.id]},{ids:['missing']}])try{await ui.team.modCall('team.claim',params,mod);}catch{rejected++;}
  const state=await ui.team.modCall('team.state',{},mod);state.board.tasks.length=0;
  return {task:ui.team.state().board.tasks[0].title,ready:ui.team.state().ready,claims:window.teamCalls.filter(r=>r.args?.request?.action==='claim').length,
   text:window.sentPacket.messages[0].text,rejected};
 });
 expect(result).toEqual({task:'SDK task',ready:true,claims:1,text:'Мод «Fixture»: Room message',rejected:2});
});

test('pasting another invitation after creation never adopts its host identity',async({page})=>{
 await mockRoomUI(page);
 await page.getByPlaceholder('Как тебя увидит кент').fill('Алиса');
 await page.getByRole('button',{name:'Позвать кента',exact:true}).click();
 await expect.poll(()=>page.evaluate(async()=>(await import('/core.js')).ui.team.connected())).toBe(true);
 await page.getByTitle('Настройки комнаты').click();
 await page.getByRole('button',{name:'Выйти из комнаты',exact:true}).click();
 const foreign=await page.evaluate(()=>{
  const v={server:'https://example.test',room:'z'.repeat(24),access:'b'.repeat(24),key:btoa(String.fromCharCode(...new Uint8Array(32))),coordinator:'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'};
  return 'pult-room:'+btoa(JSON.stringify(v));
 });
 await page.getByPlaceholder('Вставь приглашение от кента').fill(foreign);
 await page.getByRole('button',{name:'Войти',exact:true}).click();
 await expect.poll(()=>page.evaluate(async()=>(await import('/core.js')).ui.team.connected())).toBe(true);
 expect(await page.evaluate(async()=>{
  const {ui}=await import('/core.js');let rejected=false;try{await ui.team.modCall('team.addTask',{title:'Task'},{name:'Fixture'});}catch{rejected=true;}
  return {identity:ui.team.state().identity,ready:ui.team.state().ready,rejected};
 })).toEqual({identity:'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',ready:false,rejected:true});
});

test('two peers that cannot connect directly talk through the encrypted server relay',async({browser,request})=>{
 const {spawn}=await import('node:child_process');
 const server=spawn(process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3'),['../signaling/server.py'],{env:{...process.env,PULT_SIGNAL_PORT:'18788',PULT_SIGNAL_RELAY:'1'},stdio:'ignore'});
 try{
  let created;
  for(let i=0;i<100;i++){try{const response=await request.post('http://127.0.0.1:18788/v1/rooms',{data:{},timeout:1000});if(response.status()===201){created=await response.json();break;}}catch{}await new Promise(r=>setTimeout(r,100));}
  expect(created).toBeTruthy();
  const invite={server:'http://127.0.0.1:18788',...created,key:Buffer.alloc(32,9).toString('base64')};
  const pages=[await browser.newPage(),await browser.newPage()];
  for(let i=0;i<2;i++){
   const page=pages[i];
   await page.exposeFunction('roomRequest',async a=>{const response=await request.fetch(`${a.server}/v1/rooms/${a.room}/${a.action}${a.action==='events'?`?after=${a.cursor}`:''}`,{method:a.action==='events'?'GET':'POST',headers:{Authorization:`Bearer ${a.access}`,'X-Pult-Peer':a.identity},...(a.action!=='events'&&{data:a.body||{}})});if(!response.ok())throw Error('HTTP '+response.status());return response.json();});
   await page.addInitScript(()=>window.__TAURI__={core:{invoke:async(_,a)=>a.module==='team'&&a.method==='http'?window.roomRequest(a.args):null},event:{listen:async()=>()=>{}}});
   await page.goto('/');
   await page.evaluate(async({invite,id})=>{const {DirectRoom}=await import('/team-transport.js');window.packets=[];window.opened=0;
    // Прямой канал запрещён: никто не создаёт предложение WebRTC, связь должна пойти через сервер.
    window.room=new DirectRoom(invite,id,{forceRelay:true,event:(s,p)=>window.packets.push(p),open:()=>window.opened++});
    window.room.restore=null;window.room.messages=id.startsWith('A')?[{id:'H1',date:1,author:'Алиса',text:'История до входа'}]:[];
    // ускоряем: не ждём 12 секунд перед приветствием
    const peer=window.room.peer.bind(window.room);window.room.peer=async(p,o)=>{const r=await peer(p,o);setTimeout(()=>window.room.greet(p),200);return r;};
    await window.room.start();},{invite,id:i===0?'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA':'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB'});
  }
  await expect.poll(()=>Promise.all(pages.map(p=>p.evaluate(()=>window.room.reachable().length))),{timeout:20000}).toEqual([1,1]);
  expect(await pages[0].evaluate(()=>window.room.usesRelay)).toBe(true);
  await expect.poll(()=>pages[1].evaluate(()=>window.room.messages.some(m=>m.text==='История до входа')),{timeout:10000}).toBe(true);
  expect(await pages[1].evaluate(()=>window.room.send({messages:[{id:'M2',date:2,author:'Боб',text:'Ответ через сервер 🦊'}]}))).toBe(true);
  await expect.poll(()=>pages[0].evaluate(()=>window.room.messages.some(m=>m.text==='Ответ через сервер 🦊')),{timeout:10000}).toBe(true);
  expect(await pages[0].evaluate(()=>window.room.event({snapshot:{revision:1,tasks:[],repository:'x'.repeat(120000)}}))).toBe(true);
  await expect.poll(()=>pages[1].evaluate(()=>window.packets[0]?.snapshot?.repository.length),{timeout:15000}).toBe(120000);
  for(const page of pages){await page.evaluate(()=>window.room.stop());await page.close();}
 }finally{server.kill();}
});
