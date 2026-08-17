const $ = s => document.querySelector(s);
const $$ = s => [...document.querySelectorAll(s)];
let token = localStorage.getItem('ccnexus-token') || '';
let state = { devices: [], activity: [], publicUrl: location.origin };
let refreshTimer;

async function api(url, options = {}) {
  const headers = { 'Content-Type': 'application/json', ...(options.headers || {}) };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(url, { ...options, headers });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}
function toast(msg) { const el=$('#toast'); el.textContent=msg; el.classList.add('show'); setTimeout(()=>el.classList.remove('show'),2400); }
function esc(v='') { return String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c])); }
function timeAgo(t) { if(!t)return 'never'; const s=Math.max(0,Math.floor((Date.now()-t)/1000)); if(s<60)return `${s}s ago`; if(s<3600)return `${Math.floor(s/60)}m ago`; if(s<86400)return `${Math.floor(s/3600)}h ago`; return new Date(t).toLocaleDateString(); }
function icon(d){ return d.kind==='turtle'?'⬡':d.peripherals?.some(p=>p.type==='speaker')?'♫':'▦'; }
function speakers(d){ return (d.peripherals||[]).filter(p=>p.type==='speaker'); }

async function refresh(){
  try { state = await api('/api/state'); render(); }
  catch(e){ if(e.message.toLowerCase().includes('token')) logout(); }
}
function render(){
  const online=state.devices.filter(d=>d.online), turtles=online.filter(d=>d.kind==='turtle'), sp=state.devices.reduce((n,d)=>n+speakers(d).length,0);
  $('#onlineCount').textContent=online.length; $('#deviceCount').textContent=state.devices.length; $('#speakerCount').textContent=sp; $('#turtleCount').textContent=turtles.length;
  $('#overviewDevices').innerHTML=state.devices.length?state.devices.slice(0,7).map(d=>`<div class="device-row"><div class="device-icon">${icon(d)}</div><div><b>${esc(d.label)}</b><small>${esc(d.kind)} • ${speakers(d).length} speaker(s)</small></div><span class="status ${d.online?'online':''}">${d.online?'● online':timeAgo(d.lastSeen)}</span></div>`).join(''):'No devices paired yet.';
  $('#activity').innerHTML=state.activity?.length?state.activity.slice(0,10).map(a=>`<div class="timeline-item"><b>${esc(a.message)}</b><small>${timeAgo(a.at)}</small></div>`).join(''):'No activity yet.';
  const speakerNodes=state.devices.filter(d=>speakers(d).length);
  $('#speakerTargets').innerHTML=speakerNodes.length?speakerNodes.map(d=>`<label class="check"><input type="checkbox" name="speaker" value="${d.id}" ${d.online?'':'disabled'}><span><b>${esc(d.label)}</b> — ${speakers(d).map(s=>esc(s.name)).join(', ')} ${d.online?'':'(offline)'}</span></label>`).join(''):'Pair a computer with a connected speaker first.';
  const turtlesAll=state.devices.filter(d=>d.kind==='turtle');
  $('#turtleSelect').innerHTML=`<option value="">Select turtle…</option>`+turtlesAll.map(d=>`<option value="${d.id}" ${d.online?'':'disabled'}>${esc(d.label)}${d.online?'':' (offline)'}</option>`).join('');
  $('#redstoneDevice').innerHTML=`<option value="">Select device…</option>`+state.devices.map(d=>`<option value="${d.id}" ${d.online?'':'disabled'}>${esc(d.label)}</option>`).join('');
  $('#deviceTable').innerHTML=state.devices.length?`<table><thead><tr><th>Device</th><th>Type</th><th>Peripherals</th><th>Position</th><th>Fuel</th><th>Status</th><th></th></tr></thead><tbody>${state.devices.map(d=>`<tr><td><b>${esc(d.label)}</b><br><small>#${esc(d.computerId)}</small></td><td>${esc(d.kind)}</td><td>${(d.peripherals||[]).map(p=>esc(p.type)).join(', ')||'—'}</td><td>${d.telemetry?.position?`${d.telemetry.position.x}, ${d.telemetry.position.y}, ${d.telemetry.position.z}`:'—'}</td><td>${d.telemetry?.fuel??'—'}</td><td><span class="status ${d.online?'online':''}">${d.online?'● online':'offline'}</span></td><td><button class="btn remove" data-id="${d.id}">Remove</button></td></tr>`).join('')}</tbody></table>`:'<p class="empty">No devices paired.</p>';
  $$('.remove').forEach(b=>b.onclick=()=>removeDevice(b.dataset.id));
  const install=`wget run ${state.publicUrl||location.origin}/install.lua`; $('#installCommand').textContent=install; $('#pairInstall').textContent=install;
  renderTurtle(); drawMap();
}
function renderTurtle(){ const d=state.devices.find(x=>x.id===$('#turtleSelect').value); if(!d){$('#turtleTelemetry').innerHTML='Select an online turtle.';return;} const t=d.telemetry||{},p=t.position; $('#turtleTelemetry').innerHTML=`<div class="kv"><div><span>Fuel</span><b>${esc(t.fuel??'unknown')}</b></div><div><span>GPS</span><b>${p?`${p.x}, ${p.y}, ${p.z}`:'unavailable'}</b></div><div><span>Job</span><b>${esc(t.job?.status||'idle')}</b></div><div><span>Progress</span><b>${t.job?`${t.job.done||0}/${t.job.total||0}`:'—'}</b></div></div>`; }
function drawMap(){ const c=$('#map'),ctx=c.getContext('2d'); const w=c.width,h=c.height; ctx.clearRect(0,0,w,h); ctx.strokeStyle='#14263a';ctx.lineWidth=1; for(let x=0;x<w;x+=45){ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,h);ctx.stroke()} for(let y=0;y<h;y+=45){ctx.beginPath();ctx.moveTo(0,y);ctx.lineTo(w,y);ctx.stroke()} const ds=state.devices.filter(d=>d.kind==='turtle'&&d.telemetry?.position); if(!ds.length){ctx.fillStyle='#6f8198';ctx.font='16px system-ui';ctx.textAlign='center';ctx.fillText('Waiting for turtle GPS telemetry',w/2,h/2);return;} const xs=ds.map(d=>d.telemetry.position.x),zs=ds.map(d=>d.telemetry.position.z),minX=Math.min(...xs)-5,maxX=Math.max(...xs)+5,minZ=Math.min(...zs)-5,maxZ=Math.max(...zs)+5; ds.forEach(d=>{const p=d.telemetry.position,x=45+(p.x-minX)/(maxX-minX||1)*(w-90),y=45+(p.z-minZ)/(maxZ-minZ||1)*(h-90);ctx.beginPath();ctx.arc(x,y,11,0,Math.PI*2);ctx.fillStyle=d.online?'#41e4ff':'#52677c';ctx.shadowColor='#41e4ff';ctx.shadowBlur=16;ctx.fill();ctx.shadowBlur=0;ctx.fillStyle='#eaf8ff';ctx.textAlign='left';ctx.font='bold 14px system-ui';ctx.fillText(d.label,x+18,y+4);ctx.fillStyle='#71839a';ctx.font='11px system-ui';ctx.fillText(`${p.x}, ${p.y}, ${p.z}`,x+18,y+19);}); }

function showView(id){ $$('.view').forEach(v=>v.classList.toggle('active',v.id===id)); $$('.nav').forEach(n=>n.classList.toggle('active',n.dataset.view===id)); const names={overview:['NETWORK STATUS','Command Overview'],music:['AUDIO ROUTING','Audio Nexus'],turtles:['AUTONOMOUS MINING','Turtle Fleet'],automation:['WORLD CONTROL','Automation'],devices:['NEXUS NODES','Device Mesh'],setup:['GET CONNECTED','Installation & Setup']}; $('#viewEyebrow').textContent=names[id][0];$('#viewTitle').textContent=names[id][1]; }
async function login(e){e.preventDefault(); const candidate=$('#token').value.trim(); const data=await fetch('/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:candidate})}).then(r=>r.json()); if(!data.ok){$('#loginError').textContent='That token was not accepted.';return;} token=candidate;localStorage.setItem('ccnexus-token',token);$('#login').classList.remove('show'); await refresh(); clearInterval(refreshTimer);refreshTimer=setInterval(refresh,2000);}
function logout(){localStorage.removeItem('ccnexus-token');token='';$('#login').classList.add('show');}
async function removeDevice(id){if(!confirm('Remove this device and revoke its token?'))return;await api(`/api/devices/${id}`,{method:'DELETE'});toast('Device removed');refresh();}
async function command(id,commandData){return api(`/api/devices/${id}/command`,{method:'POST',body:JSON.stringify(commandData)});}

$('#loginForm').addEventListener('submit',e=>login(e).catch(x=>$('#loginError').textContent=x.message));
$$('.nav').forEach(n=>n.onclick=()=>showView(n.dataset.view));
function openPair(){ $('#pairModal').classList.add('show'); $('#pairCode').textContent='------'; }
$('#pairBtn').onclick=openPair; $$('.pair-inline').forEach(b=>b.onclick=openPair); $('#closePair').onclick=()=>$('#pairModal').classList.remove('show');
$('#generateCode').onclick=async()=>{try{const d=await api('/api/pairing-code',{method:'POST'});$('#pairCode').textContent=d.code;toast('Pairing code created');}catch(e){toast(e.message)}};
$('#volume').oninput=e=>$('#volumeValue').textContent=`${e.target.value}×`;
$('#strength').oninput=e=>$('#strengthValue').textContent=e.target.value;
$('#audioForm').onsubmit=async e=>{e.preventDefault();const ids=$$('input[name=speaker]:checked').map(x=>x.value);if(!ids.length)return toast('Select at least one online speaker computer');const url=$('#audioUrl').value;try{await api('/api/audio/play',{method:'POST',body:JSON.stringify({url,deviceIds:ids,volume:Number($('#volume').value)})});$('#nowPlaying').textContent=url.includes('youtu')?'YouTube stream':'Remote media stream';$('#nowTarget').textContent=`Routing to ${ids.length} node(s)`;toast('Audio stream started')}catch(x){toast(x.message)}};
$('#stopAudio').onclick=async()=>{const ids=$$('input[name=speaker]:checked').map(x=>x.value);await api('/api/audio/stop',{method:'POST',body:JSON.stringify({deviceIds:ids})});$('#nowPlaying').textContent='Nothing playing';toast('Audio stopped')};
$('#turtleSelect').onchange=renderTurtle;
$('#startQuarry').onclick=async()=>{const id=$('#turtleSelect').value;if(!id)return toast('Select a turtle');try{await command(id,{type:'quarry_start',width:Number($('#qWidth').value),length:Number($('#qLength').value),depth:Number($('#qDepth').value)});toast('Quarry job dispatched')}catch(e){toast(e.message)}};
$('#pauseQuarry').onclick=async()=>{const id=$('#turtleSelect').value;if(id){await command(id,{type:'quarry_pause'});toast('Pause/resume sent')}};
$('#stopQuarry').onclick=async()=>{const id=$('#turtleSelect').value;if(id){await command(id,{type:'quarry_stop'});toast('Stop sent')}};
async function redstoneControl(on){const id=$('#redstoneDevice').value;if(!id)return toast('Select a device');const strength=on?Number($('#strength').value):0;try{await api(`/api/lights/${id}`,{method:'POST',body:JSON.stringify({side:$('#redstoneSide').value,strength})});toast(`Redstone set to ${strength}`)}catch(e){toast(e.message)}}
$('#lightOn').onclick=()=>redstoneControl(true);$('#lightOff').onclick=()=>redstoneControl(false);$('#copyInstall').onclick=()=>navigator.clipboard.writeText($('#installCommand').textContent).then(()=>toast('Installer command copied'));

if(token){$('#token').value=token;fetch('/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token})}).then(r=>r.json()).then(d=>{if(d.ok){$('#login').classList.remove('show');refresh();refreshTimer=setInterval(refresh,2000)}else logout()});}
