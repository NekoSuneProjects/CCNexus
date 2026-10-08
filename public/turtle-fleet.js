const $ = s => document.querySelector(s);
let state = { worlds: [], devices: [] };
let worldId = localStorage.getItem('ccnexus-fleet-world') || '';
let turtleId = localStorage.getItem('ccnexus-fleet-turtle') || '';
let stationCache = {};

function esc(v=''){ return String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c])); }
function age(t){ if(!t)return 'never'; const s=Math.max(0,Math.floor((Date.now()-Number(t))/1000)); if(s<60)return `${s}s ago`; if(s<3600)return `${Math.floor(s/60)}m ago`; return `${Math.floor(s/3600)}h ago`; }
function world(){ return state.worlds.find(w=>w.id===worldId) || state.worlds[0]; }
function turtles(){ return state.devices.filter(d=>d.worldId===worldId && d.kind==='turtle'); }
function fleetTurtles(){ return turtles().filter(d=>d.telemetry?.fleet); }
function selected(){ return turtles().find(d=>d.id===turtleId); }
function stationKey(){ return `ccnexus-fleet-stations-${worldId}`; }
function loadCache(){ try{ stationCache=JSON.parse(localStorage.getItem(stationKey())||'{}')||{}; }catch{stationCache={};} }
function saveCache(){ localStorage.setItem(stationKey(),JSON.stringify(stationCache)); }
function stationArray(v){ if(Array.isArray(v))return v; if(v&&typeof v==='object')return Object.values(v); return []; }
function mergeStations(){
  for(const d of turtles()) for(const s of stationArray(d.telemetry?.stations)) if(s?.name) stationCache[String(s.name).toLowerCase()]={...stationCache[String(s.name).toLowerCase()],...s};
  saveCache();
}
function stations(){ return Object.values(stationCache).sort((a,b)=>String(a.label||a.name).localeCompare(String(b.label||b.name))); }
function preserveSelect(el, options, placeholder='Select…', preferred=''){
  const old=el.value||preferred; el.innerHTML=`<option value="">${esc(placeholder)}</option>`+options.map(o=>`<option value="${esc(o.value)}">${esc(o.label)}</option>`).join('');
  if([...el.options].some(o=>o.value===old)) el.value=old; else if(preferred&&[...el.options].some(o=>o.value===preferred))el.value=preferred;
}
async function api(url,options={}){
  const headers={...(options.body?{'Content-Type':'application/json'}:{}),...(options.headers||{})};
  const r=await fetch(url,{...options,headers,credentials:'same-origin'}); const d=await r.json().catch(()=>({}));
  if(!r.ok) throw new Error(d.error||`HTTP ${r.status}`); return d;
}
async function command(id,command){ return api(`/api/devices/${encodeURIComponent(id)}/command`,{method:'POST',body:JSON.stringify(command)}); }
function showError(e){ const x=$('#authError'); x.style.display='block'; x.textContent=String(e?.message||e); }
function clearError(){ $('#authError').style.display='none'; }

async function refresh(){
  try{
    state=await api('/api/state'); clearError();
    if(!worldId||!state.worlds.some(w=>w.id===worldId)) worldId=state.defaultWorldId||state.worlds[0]?.id||'';
    localStorage.setItem('ccnexus-fleet-world',worldId); loadCache(); mergeStations();
    const ts=turtles(); if(!turtleId||!ts.some(t=>t.id===turtleId)) turtleId=ts[0]?.id||'';
    localStorage.setItem('ccnexus-fleet-turtle',turtleId); render();
  }catch(e){ showError(`${e.message}. Sign in on the main CCNexus dashboard first.`); }
}

function render(){
  preserveSelect($('#world'),state.worlds.map(w=>({value:w.id,label:`${w.name} · ${w.onlineCount||0} online`})),'Workspace',worldId); $('#world').value=worldId;
  preserveSelect($('#turtle'),turtles().map(t=>({value:t.id,label:`${t.label}${t.telemetry?.fleet?' · Fleet':''}${t.online?'':' · offline'}`})),'Select turtle',turtleId); $('#turtle').value=turtleId;
  $('#online').textContent=`${turtles().filter(t=>t.online).length}/${turtles().length} turtles online`;
  mergeStations(); renderStationOptions(); renderStations(); renderTelemetry(); renderTurtleList(); drawMap();
  $('#normalInstall').textContent=`wget run ${location.origin}/install.lua`;
  $('#fleetInstall').textContent=`wget run ${location.origin}/scripts/install-turtle-fleet.lua`;
}

function renderTelemetry(){
  const d=selected(); if(!d){ $('#telemetry').innerHTML='<div><span>Status</span><b>No turtle selected</b></div>'; return; }
  const t=d.telemetry||{},p=t.position,nav=t.nav||{},job=t.job||t.lastJob;
  const source=p?.source||nav.source||(p?'gps':'unavailable'); const gpsClass=source==='gps'?'good':p?'warn':'bad';
  $('#telemetry').innerHTML=`
    <div><span>Status</span><b class="${d.online?'good':'bad'}">${d.online?'ONLINE':'OFFLINE CACHE'}</b></div>
    <div><span>Agent</span><b>${esc(d.agentVersion||'?')}${t.fleet?' · Fleet':''}</b></div>
    <div><span>Position</span><b>${p?`${p.x}, ${p.y}, ${p.z}`:'unavailable'}</b></div>
    <div><span>Position source</span><b class="${gpsClass}">${esc(String(source).replaceAll('_',' ').toUpperCase())}</b></div>
    <div><span>Last GPS fix</span><b>${p?.lastGpsAt||nav.lastGpsAt?age(p?.lastGpsAt||nav.lastGpsAt):'never'}</b></div>
    <div><span>Heading</span><b>${esc(nav.headingName||'UNKNOWN')}</b></div>
    <div><span>Fuel</span><b>${esc(t.fuel??'unknown')}</b></div>
    <div><span>Fuel policy</span><b>${t.fuelPolicy?`low ${esc(t.fuelPolicy.low)} → ${esc(t.fuelPolicy.target)}`:'normal agent'}</b></div>
    <div><span>Job</span><b>${job?`${esc(job.type)} / ${esc(job.status)}`:'IDLE'}</b></div>
    <div><span>Progress</span><b>${job?`${job.done||0}/${job.total||0}`:'—'}</b></div>
    <div style="grid-column:1/-1"><span>Detail</span><b>${esc(job?.error||job?.detail||'—')}</b></div>`;
}
function renderTurtleList(){
  $('#turtles').innerHTML=turtles().length?turtles().map(d=>{const p=d.telemetry?.position,src=p?.source||d.telemetry?.nav?.source||'none';return `<div class="turtle-row ${d.id===turtleId?'selected':''}" data-id="${d.id}"><div><b>${esc(d.label)}</b><div class="muted">${p?`${p.x},${p.y},${p.z} · ${esc(src)}`:'no position'} · fuel ${esc(d.telemetry?.fuel??'?')}</div></div><span class="${d.online?'good':'bad'}">${d.online?'●':'○'}</span></div>`}).join(''):'<div class="muted">No turtles in this workspace.</div>';
  document.querySelectorAll('.turtle-row').forEach(r=>r.onclick=()=>{turtleId=r.dataset.id;localStorage.setItem('ccnexus-fleet-turtle',turtleId);$('#turtle').value=turtleId;render();});
}
function renderStationOptions(){
  const opts=stations().map(s=>({value:s.name,label:`${s.label||s.name} · ${s.type||'station'} (${s.x},${s.y},${s.z})`}));
  for(const id of ['fuelStation','deliverySource','deliveryDest','cropStation','cropBase','treeStation','treeBase','qBase']) preserveSelect($('#'+id),opts,'Select station…');
  if(!$('#fuelStation').value&&stationCache.fuel)$('#fuelStation').value='fuel';
  if(!$('#deliverySource').value&&stationCache.quarry)$('#deliverySource').value='quarry';
  if(!$('#deliveryDest').value&&stationCache.base)$('#deliveryDest').value='base';
  if(!$('#cropStation').value&&stationCache.crop)$('#cropStation').value='crop';
  if(!$('#cropBase').value&&stationCache.base)$('#cropBase').value='base';
  if(!$('#treeStation').value&&stationCache.tree)$('#treeStation').value='tree';
  if(!$('#treeBase').value&&stationCache.base)$('#treeBase').value='base';
  if(!$('#qBase').value&&stationCache.base)$('#qBase').value='base';
}
function renderStations(){
  $('#stations').innerHTML=stations().length?stations().map(s=>`<div class="station-row"><div><b>${esc(s.label||s.name)}</b><div class="muted">${esc(s.name)} · ${esc(s.type||'station')} · ${s.x},${s.y},${s.z} · ${esc(s.side||'down')}</div></div><button class="station-delete danger" data-name="${esc(s.name)}">×</button></div>`).join(''):'<div class="muted">No shared stations captured yet.</div>';
  document.querySelectorAll('.station-delete').forEach(b=>b.onclick=()=>deleteStation(b.dataset.name));
}

function drawMap(){
  const c=$('#map'),ctx=c.getContext('2d'),w=c.width,h=c.height;ctx.clearRect(0,0,w,h);ctx.fillStyle='#07101a';ctx.fillRect(0,0,w,h);
  ctx.strokeStyle='#14283b';ctx.lineWidth=1;for(let x=0;x<w;x+=50){ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,h);ctx.stroke()}for(let y=0;y<h;y+=50){ctx.beginPath();ctx.moveTo(0,y);ctx.lineTo(w,y);ctx.stroke()}
  const points=[]; for(const d of turtles()){const p=d.telemetry?.position;if(p)points.push({kind:'turtle',d,p})} for(const s of stations())points.push({kind:'station',s,p:s});
  if(!points.length){ctx.fillStyle='#8297ac';ctx.font='18px system-ui';ctx.textAlign='center';ctx.fillText('Waiting for GPS or last-known Turtle Fleet positions',w/2,h/2);return}
  const xs=points.map(o=>Number(o.p.x)),zs=points.map(o=>Number(o.p.z)),minX=Math.min(...xs)-4,maxX=Math.max(...xs)+4,minZ=Math.min(...zs)-4,maxZ=Math.max(...zs)+4;
  const xy=p=>[55+(Number(p.x)-minX)/(maxX-minX||1)*(w-110),55+(Number(p.z)-minZ)/(maxZ-minZ||1)*(h-110)];
  for(const o of points){const [x,y]=xy(o.p);if(o.kind==='station'){ctx.save();ctx.translate(x,y);ctx.rotate(Math.PI/4);ctx.fillStyle='#ffd45e';ctx.fillRect(-8,-8,16,16);ctx.restore();ctx.fillStyle='#ffd45e';ctx.font='bold 13px system-ui';ctx.textAlign='left';ctx.fillText(o.s.label||o.s.name,x+14,y+4);ctx.fillStyle='#73889e';ctx.font='11px system-ui';ctx.fillText(`${o.p.x},${o.p.y},${o.p.z}`,x+14,y+18)}else{const sel=o.d.id===turtleId;ctx.beginPath();ctx.arc(x,y,sel?12:9,0,Math.PI*2);ctx.fillStyle=sel?'#6df2ff':o.d.online?'#657c91':'#3b4957';ctx.fill();if(sel){ctx.strokeStyle='#d9fbff';ctx.lineWidth=2;ctx.stroke()}ctx.fillStyle='#eaf8ff';ctx.font=`${sel?'bold ':''}13px system-ui`;ctx.textAlign='left';ctx.fillText(o.d.label,x+16,y+3);ctx.fillStyle='#73889e';ctx.font='11px system-ui';ctx.fillText(`${o.p.x},${o.p.y},${o.p.z} · ${o.p.source||'gps'}`,x+16,y+17)}}
}

function requireFleet(){ const d=selected(); if(!d)throw new Error('Select a turtle'); if(!d.online)throw new Error('Selected turtle is offline'); if(!d.telemetry?.fleet)throw new Error('Selected turtle is still using the normal agent. Run the Turtle Fleet installer on it first.'); return d; }
async function sendSelected(c){ const d=requireFleet(); await command(d.id,c); }
async function sendAllFleet(c){ const ds=fleetTurtles().filter(d=>d.online); if(!ds.length)throw new Error('No online Turtle Fleet agents'); await Promise.all(ds.map(d=>command(d.id,c))); }

async function captureStation(){
  try{
    const d=requireFleet(),p=d.telemetry?.position;if(!p)throw new Error('Selected turtle has no position yet');
    if(p.source&&p.source!=='gps'&&!confirm(`Position source is ${p.source}, not a live GPS fix. Capture this last-known/dead-reckoning position anyway?`))return;
    let name=$('#stationName').value.trim().toLowerCase().replace(/[^a-z0-9_.-]+/g,'_');if(!name)throw new Error('Enter a station key');
    const s={name,label:name,stationType:$('#stationType').value,x:Number(p.x),y:Number(p.y),z:Number(p.z),side:$('#stationSide').value,heading:d.telemetry?.nav?.heading};
    stationCache[name]={name,label:name,type:s.stationType,x:s.x,y:s.y,z:s.z,side:s.side,heading:s.heading};saveCache();await sendAllFleet({type:'station_set',...s});render();
  }catch(e){alert(e.message)}
}
async function syncStations(){try{for(const s of stations())await sendAllFleet({type:'station_set',name:s.name,label:s.label,stationType:s.type,x:s.x,y:s.y,z:s.z,side:s.side,heading:s.heading});alert('Stations synced to all online Turtle Fleet agents.')}catch(e){alert(e.message)}}
async function deleteStation(name){try{delete stationCache[name];saveCache();await sendAllFleet({type:'station_delete',name});render()}catch(e){alert(e.message)}}

$('#world').onchange=e=>{worldId=e.target.value;localStorage.setItem('ccnexus-fleet-world',worldId);loadCache();turtleId='';refresh()};
$('#turtle').onchange=e=>{turtleId=e.target.value;localStorage.setItem('ccnexus-fleet-turtle',turtleId);render()};
$('#back').onclick=()=>location.href='/';
$('#capture').onclick=captureStation;$('#syncStations').onclick=syncStations;
$('#stationType').onchange=e=>{const defaults={base:'base',quarry:'quarry',fuel:'fuel',crop:'crop',tree:'tree'};if(defaults[e.target.value])$('#stationName').value=defaults[e.target.value]};

$('#fuelSelected').onclick=async()=>{try{await sendSelected({type:'fleet_config',fuelStation:$('#fuelStation').value,lowFuel:Number($('#lowFuel').value),targetFuel:Number($('#targetFuel').value)});alert('Fuel policy updated.')}catch(e){alert(e.message)}};
$('#fuelAll').onclick=async()=>{try{await sendAllFleet({type:'fleet_config',fuelStation:$('#fuelStation').value,lowFuel:Number($('#lowFuel').value),targetFuel:Number($('#targetFuel').value)});alert('Fuel policy sent to all online Fleet turtles.')}catch(e){alert(e.message)}};
$('#refuelNow').onclick=async()=>{try{await sendSelected({type:'refuel_now'});}catch(e){alert(e.message)}};
$('#deliveryStart').onclick=async()=>{try{await sendSelected({type:'delivery_start',sourceStation:$('#deliverySource').value,destStation:$('#deliveryDest').value,cycles:Number($('#deliveryCycles').value),interval:Number($('#deliveryInterval').value)});}catch(e){alert(e.message)}};
$('#cropStart').onclick=async()=>{try{await sendSelected({type:'farm_start',station:$('#cropStation').value,baseStation:$('#cropBase').value,width:Number($('#cropWidth').value),length:Number($('#cropLength').value),seedSlot:Number($('#cropSeed').value),cycles:Number($('#cropCycles').value),interval:Number($('#cropInterval').value)});}catch(e){alert(e.message)}};
$('#treeStart').onclick=async()=>{try{await sendSelected({type:'tree_patrol_start',station:$('#treeStation').value,baseStation:$('#treeBase').value,width:Number($('#treeWidth').value),length:Number($('#treeLength').value),saplingSlot:Number($('#treeSapling').value)});}catch(e){alert(e.message)}};
$('#quarryStart').onclick=async()=>{try{await sendSelected({type:'quarry_start',width:Number($('#qWidth').value),length:Number($('#qLength').value),depth:Number($('#qDepth').value),baseStation:$('#qBase').value});}catch(e){alert(e.message)}};
$('#pause').onclick=()=>sendSelected({type:'job_pause'}).catch(e=>alert(e.message));$('#resume').onclick=()=>sendSelected({type:'job_resume'}).catch(e=>alert(e.message));$('#stop').onclick=()=>sendSelected({type:'job_stop'}).catch(e=>alert(e.message));

refresh();setInterval(refresh,2000);
