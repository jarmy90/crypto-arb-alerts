// Crypto Arbitrage Detector - web v7 (ASCII-safe, UTF-8)
const GITHUB_URL = 'https://raw.githubusercontent.com/jarmy90/crypto-arb-alerts/main/data/alerts.json';
const LIVE_URL = 'https://raw.githubusercontent.com/jarmy90/crypto-arb-alerts/main/data/live.json';
const DEPTH_URL = 'https://raw.githubusercontent.com/jarmy90/crypto-arb-alerts/main/data/depth.json';
const WATCH = {
  exchanges: ['BINANCE','MEXC','BYBIT','OKX'],
  symbols: ['BTC/USDT','ETH/USDT','BNB/USDT','SOL/USDT','XRP/USDT','ADA/USDT','DOGE/USDT','DOT/USDT','POL/USDT','LTC/USDT','AVAX/USDT','LINK/USDT','UNI/USDT','ATOM/USDT','NEAR/USDT'],
  minNet: 0.40, tradeSize: 500, feeBinance: 0.10, feeMexc: 0.05, feeBybit: 0.10, feeOkx: 0.10,
  feeMakerBinance: 0.10, feeMakerMexc: 0.05, feeMakerBybit: 0.10, feeMakerOkx: 0.10
};
const CONFIG = { alertsUrl: GITHUB_URL, refreshInterval: 12000, maxRecentMinutes: 15 };

let lastFetchTime = null, isLoading = false, lastOk = null;
const elements = {
  alertsContainer: document.getElementById('alertsContainer'),
  historyContainer: document.getElementById('historyContainer'),
  historyBox: document.getElementById('historyBox'),
  emptyState: document.getElementById('emptyState'), errorState: document.getElementById('errorState'),
  errorMessage: document.getElementById('errorMessage'), statusDot: document.getElementById('statusDot'),
  statusText: document.getElementById('statusText'), lastUpdate: document.getElementById('lastUpdate'),
  refreshBtn: document.getElementById('refreshBtn'), activeCount: document.getElementById('activeCount'),
  bestSpread: document.getElementById('bestSpread'), topProfit: document.getElementById('topProfit'),
  watchList: document.getElementById('watchList'), cfgLine: document.getElementById('cfgLine'),
  liveBox: document.getElementById('liveBox'), liveTime: document.getElementById('liveTime'),
  depthBox: document.getElementById('depthBox'), depthTime: document.getElementById('depthTime')
};

function normalizeAlerts(j) {
  if (!j) return [];
  if (Array.isArray(j)) return j;
  if (j.symbol) return [j];
  if (Array.isArray(j.alerts)) return j.alerts;
  if (Array.isArray(j.data)) return j.data;
  return [];
}
function formatTimeAgo(t){ const s=Math.floor((new Date()-new Date(t))/1000); if(s<60) return s+' seg atras'; if(s<3600) return Math.floor(s/60)+' min atras'; if(s<86400) return Math.floor(s/3600)+' h atras'; return Math.floor(s/86400)+' d atras'; }
function formatPrice(p){ if(p>=1000) return p.toFixed(2); if(p>=1) return p.toFixed(4); return p.toFixed(8); }
function formatCurrency(a){ return new Intl.NumberFormat('en-US',{style:'currency',currency:'USD'}).format(a); }
function isRecentAlert(t){ return (new Date()-new Date(t))/1000/60 <= CONFIG.maxRecentMinutes; }
function updateStatus(st,msg){ elements.statusDot.className='status-dot '+st; elements.statusText.textContent=msg; }
function updateStats(recent){
  elements.activeCount.textContent=recent.length;
  if(recent.length){ elements.bestSpread.textContent=Math.max(...recent.map(a=>a.net_spread)).toFixed(2)+'%'; elements.topProfit.textContent=formatCurrency(Math.max(...recent.map(a=>a.estimated_profit||a.profit||0))); }
  else { elements.bestSpread.textContent='--'; elements.topProfit.textContent='--'; }
}
function renderWatch(){
  if(elements.watchList) elements.watchList.innerHTML = WATCH.symbols.map(s=>'<span class="pair-chip">'+s+'</span>').join(' ');
  if(elements.cfgLine) elements.cfgLine.textContent = 'Exchanges: '+WATCH.exchanges.join(' - ')+' | Umbral neto >= '+WATCH.minNet+'% | Trade '+WATCH.tradeSize+' USDT | Fees Bin '+WATCH.feeBinance+'% / Mex '+WATCH.feeMexc+'% / Byb '+WATCH.feeBybit+'% / OKX '+WATCH.feeOkx+'% | Escaneo cada 8s';
}
function pairLinks(a){
  const sym=a.symbol||'BTC/USDT'; const uf=sym.replace('/','_'); const parts=sym.split('/'); const base=parts[0], quote=parts[1]||'USDT';
  const url=(ex)=>ex==='BINANCE'?'https://www.binance.com/en/trade/'+uf+'?type=spot':ex==='MEXC'?'https://www.mexc.com/exchange/'+uf:ex==='BYBIT'?'https://www.bybit.com/en/trade/spot/'+base+'/'+quote:'https://www.okx.com/trade-spot/'+base.toLowerCase()+'-'+quote.toLowerCase();
  return { buy: (a.pair_urls&&a.pair_urls.buy)||url(a.buy_exchange), sell: (a.pair_urls&&a.pair_urls.sell)||url(a.sell_exchange) };
}
function createAlertCard(a, historic){
  const d=document.createElement('div'); d.className='alert-card';
  if(historic){ d.style.opacity='0.55'; d.style.borderStyle='dashed'; }
  const L=pairLinks(a);
  d.innerHTML='<div class="alert-header"><div class="symbol">'+(a.symbol||'?')+(historic?' - historico':'')+'</div><div class="spread-badge">+'+Number(a.net_spread||0).toFixed(2)+'%</div></div>'
  +'<div class="direction"><div class="exchange-flow"><span>Compra</span><span class="exchange-name">'+(a.buy_exchange||'')+'</span><span class="arrow">-&gt;</span><span>Vende</span><span class="exchange-name">'+(a.sell_exchange||'')+'</span></div></div>'
  +'<div class="prices"><div class="price-item"><div class="price-label">Compra</div><div class="price-value">$'+formatPrice(Number(a.buy_price||0))+'</div><a href="'+L.buy+'" target="_blank" rel="noopener">Abrir '+(a.buy_exchange||'')+'</a></div>'
  +'<div class="price-item"><div class="price-label">Venta</div><div class="price-value">$'+formatPrice(Number(a.sell_price||0))+'</div><a href="'+L.sell+'" target="_blank" rel="noopener">Abrir '+(a.sell_exchange||'')+'</a></div></div>'
  +'<div class="profit"><span class="profit-label">Profit est. ('+WATCH.tradeSize+' USDT)</span><span class="profit-value">'+formatCurrency(a.estimated_profit??a.profit??0)+'</span></div>'
  +'<div class="timestamp">'+formatTimeAgo(a.timestamp)+' - bruto '+Number(a.gross_spread||0).toFixed(2)+'% - '+new Date(a.timestamp).toLocaleString()+'</div>';
  return d;
}
function renderAlerts(alerts){
  elements.alertsContainer.innerHTML=''; elements.emptyState.style.display='none'; elements.errorState.style.display='none';
  const sorted=[...alerts].sort((a,b)=>new Date(b.timestamp)-new Date(a.timestamp));
  const recent=sorted.filter(a=>isRecentAlert(a.timestamp));
  const old=sorted.filter(a=>!isRecentAlert(a.timestamp));
  updateStats(recent);
  if(recent.length){ recent.forEach(a=>elements.alertsContainer.appendChild(createAlertCard(a,false))); }
  else { elements.emptyState.style.display='block'; elements.emptyState.querySelector('p').textContent='Sin spread >= '+WATCH.minNet+'% en los ultimos '+CONFIG.maxRecentMinutes+' min. El live de arriba manda; abajo solo queda el historico.'; }
  if(elements.historyBox && elements.historyContainer){
    elements.historyContainer.innerHTML='';
    if(old.length){ elements.historyBox.style.display='block'; old.slice(0,10).forEach(a=>elements.historyContainer.appendChild(createAlertCard(a,true))); }
    else elements.historyBox.style.display='none';
  }
}
function showError(m){ elements.alertsContainer.innerHTML=''; elements.emptyState.style.display='none'; elements.errorState.style.display='block'; elements.errorMessage.textContent=m; updateStatus('error','Desconectado - reintentando...'); }
async function fetchAlerts(){
  if(isLoading) return; isLoading=true;
  try{
    const r=await fetch(CONFIG.alertsUrl+'?t='+Date.now(),{cache:'no-store'});
    if(!r.ok) throw new Error('HTTP '+r.status);
    const alerts=normalizeAlerts(await r.json());
    lastFetchTime=new Date(); lastOk=new Date();
    renderAlerts(alerts); updateStatus('active','Conectado - Live');
    const newest=alerts[0]&&alerts[0].timestamp;
    elements.lastUpdate.textContent='web '+lastFetchTime.toLocaleTimeString()+' - ultima alerta '+(newest?formatTimeAgo(newest):'nunca');
  }catch(e){ console.error(e); if(lastOk){ updateStatus('active','Conectado - esperando datos...'); } else showError('No pude cargar alerts.json: '+e.message); }
  finally{ isLoading=false; }
}
elements.refreshBtn.addEventListener('click',()=>{fetchAlerts();fetchLive();fetchDepth();renderVersion();});
const WEB_VERSION='13';
const STALE_S=90, DEAD_S=300;
const STATE_COLOR={OBSERVAR:'warn',PREPARAR:'prep','NIVEL REDUCIDO':'warn','POSIBLE EJECUCION':'prep','POSIBLE FILL PARCIAL':'prep','POSIBLE FILL':'yes',RETIRAR:'bad'};
function esc(s){ return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;'); }
function loadOrders(){ try{ return JSON.parse(localStorage.getItem('arb_orders')||'[]'); }catch(e){ return []; } }
function saveOrders(o){ localStorage.setItem('arb_orders',JSON.stringify(o)); }
// Funcion UNICA de neto en la web (misma formula que el bot): buy, sell, maker, taker, slip, margen.
function computeNet(buy,sell,makerFee,takerFee,slip,safe){
  buy=Number(buy); sell=Number(sell);
  if(!(buy>0&&sell>0)) return null;
  return ((sell/buy)-1)*100-makerFee-takerFee-(slip||0)-(safe||0);
}
function bookLevels(sym,ex,side){
  const B=window._books||{}; const r=B[sym]; if(!r) return null;
  const e=r[ex.toLowerCase()]; if(!e) return null;
  return (side==='ask'?e.asks:e.bids)||null;
}
function bookL1(sym,ex,side){ const lv=bookLevels(sym,ex,side); return (lv&&lv.length)?Number(lv[0].p):null; }
function exitVwap(sym,ex,side,amount){
  const lv=bookLevels(sym,ex,side); if(!lv||!lv.length) return {ok:false,gotU:0,lvls:0};
  let got=0,vwap=0,n=0;
  for(const l of lv){ const p=Number(l.p),q=Number(l.q),u=p*q; const need=amount-got; if(need<=0) break; const take=Math.min(u,need); vwap+=(take/amount)*p; got+=take; n++; }
  if(got<amount) return {ok:false,gotU:got,lvls:n};
  return {ok:true,vwap:vwap,gotU:got,lvls:n};
}
function depthAgeS(){ if(!window._depthUpdated) return null; return (Date.now()-window._depthUpdated)/1000; }
function liveAgeS(){ if(!window._liveUpdated) return null; return (Date.now()-window._liveUpdated)/1000; }
function takerFee(ex){ return ex==='MEXC'?WATCH.feeMexc:ex==='BYBIT'?WATCH.feeBybit:ex==='OKX'?(WATCH.feeOkx||0.10):WATCH.feeBinance; }
function makerFee(ex){ return ex==='MEXC'?(WATCH.feeMakerMexc||0.05):ex==='BYBIT'?(WATCH.feeMakerBybit||0.10):ex==='OKX'?(WATCH.feeMakerOkx||0.10):(WATCH.feeMakerBinance||0.10); }
// Recalculo de salida para una orden manual con el libro ACTUAL (nunca reutiliza el neto antiguo).
function orderExitRecalc(o, amount){
  const amt=amount||o.qtyUSDT||WATCH.tradeSize;
  const da=depthAgeS();
  if(da==null) return {state:'EXCHANGE DESCONECTADO', detail:'sin libro'};
  if(da>STALE_S) return {state:'DATOS ANTIGUOS', detail:'libro de hace '+Math.round(da)+' s'};
  if(o.type==='COMPRA EN COLA'){
    const w=exitVwap(o.symbol,o.exitEx,'bid',amt);
    if(!w.ok) return {state:'LIQUIDEZ INSUFICIENTE', covered:w.gotU, need:amt};
    const l1=bookL1(o.symbol,o.exitEx,'bid');
    const slip=(l1-w.vwap)/l1*100;
    const net=computeNet(o.price,w.vwap,makerFee(o.makerEx),takerFee(o.exitEx),slip,0.05);
    return {state:'OK', net:net, vwap:w.vwap, lvls:w.lvls, slip:slip};
  }
  const w=exitVwap(o.symbol,o.exitEx,'ask',amt);
  if(!w.ok) return {state:'LIQUIDEZ INSUFICIENTE', covered:w.gotU, need:amt};
  const l1=bookL1(o.symbol,o.exitEx,'ask');
  const slip=(w.vwap-l1)/l1*100;
  const net=computeNet(w.vwap,o.price,makerFee(o.makerEx),takerFee(o.exitEx),slip,0.05);
  return {state:'OK', net:net, vwap:w.vwap, lvls:w.lvls, slip:slip};
}
function renderOrders(){
  const box=document.getElementById('ordersBox'); if(!box) return;
  const orders=loadOrders();
  if(!orders.length){ box.innerHTML='<div class="combo">Sin ordenes manuales. Pulsa HE PUESTO LA ORDEN en una senal para seguirla aqui.</div>'; return; }
  let html='';
  for(const o of orders){
    let verdict, cls, extra='';
    const inv='<div class="combo">INVENTARIO NO VERIFICADO: necesitas el activo ya disponible en '+esc(o.exitEx)+' para la segunda pata.</div>';
    if(o.status==='CANCELADA'){ verdict='CANCELADA'; cls='no'; }
    else if(o.status==='COMPLETADA'){
      const r=orderExitRecalc(o, o.qtyUSDT||WATCH.tradeSize);
      extra='<div class="combo" style="color:#ef4444">EXPOSICION ABIERTA: la pata maker esta completada, falta vender.</div>';
      if(r.state==='DATOS ANTIGUOS'){ verdict='DATOS ANTIGUOS - no calcular salida'; cls='bad'; }
      else if(r.state==='EXCHANGE DESCONECTADO'){ verdict='EXCHANGE DESCONECTADO'; cls='bad'; }
      else if(r.state==='LIQUIDEZ INSUFICIENTE'){ verdict='LIQUIDEZ INSUFICIENTE ('+Math.round(r.covered)+'/'+r.need+' USDT)'; cls='bad'; }
      else if(r.net>=WATCH.minNet){ verdict='SALIR AHORA +'+r.net.toFixed(2)+'% (vwap '+r.vwap.toFixed(4)+', '+r.lvls+' niveles)'; cls='yes'; }
      else if(r.net<0){ verdict='SALIDA POSIBLE EN PERDIDA '+r.net.toFixed(2)+'% - no oculta'; cls='bad'; }
      else { verdict='marginal +'+r.net.toFixed(2)+'% - vigilar'; cls='warn'; }
    }
    else if(o.status==='PARCIAL'){
      const done=Number(o.fillQty||0), amt=Number(o.qtyUSDT||WATCH.tradeSize), pend=Math.max(0,amt-done);
      const r=orderExitRecalc(o, done>0?done:amt);
      const base=(r.state==='OK')?('completado '+done+' USDT -> neto '+r.net.toFixed(2)+'% (vwap '+r.vwap.toFixed(4)+')'):(r.state+' '+(r.covered!=null?Math.round(r.covered)+'/'+r.need:''));
      verdict='FILL PARCIAL - '+base+' - pendiente '+pend+' USDT'; cls='prep';
    }
    else {
      const r=orderExitRecalc(o, o.qtyUSDT||WATCH.tradeSize);
      if(r.state==='DATOS ANTIGUOS'){ verdict='DATOS ANTIGUOS - no operable'; cls='bad'; }
      else if(r.state==='EXCHANGE DESCONECTADO'){ verdict='sin datos de salida'; cls='no'; }
      else if(r.state==='LIQUIDEZ INSUFICIENTE'){ verdict='RETIRAR - sin liquidez de salida'; cls='bad'; }
      else if(r.net>=WATCH.minNet){ verdict='OPORTUNIDAD VIGENTE +'+r.net.toFixed(2)+'% - MANTENER'; cls='yes'; }
      else if(r.net>0){ verdict='floja +'+r.net.toFixed(2)+'% - vigilar'; cls='warn'; }
      else { verdict='RETIRAR '+r.net.toFixed(2)+'% - cancela'; cls='bad'; }
    }
    html+='<div class="mkt"><div class="mkt-head"><span class="mkt-sym">'+esc(o.symbol)+' '+esc(o.side)+' '+esc(o.makerEx)+' @ '+esc(o.price)+'</span><span class="mkt-net '+cls+'">'+esc(verdict)+'</span></div>'
    +'<div class="combo">Salida prevista: '+esc(o.exitEx)+' | importe: '+esc(o.qtyUSDT||WATCH.tradeSize)+' USDT | puesta: '+esc(o.time||'')+' | estado: '+esc(o.status)+(o.fillNote?' | nota: '+esc(o.fillNote):'')+'</div>'+inv
    +'<div class="combo"><button data-act="done" data-id="'+o.id+'">ME HAN COMPLETADO</button> <button data-act="partial" data-id="'+o.id+'">FILL PARCIAL</button> <button data-act="cancel" data-id="'+o.id+'">CANCELE LA ORDEN</button></div></div>';
  }
  box.innerHTML=html;
  box.querySelectorAll('button').forEach(b=>b.addEventListener('click',()=>{
    const orders=loadOrders(); const o=orders.find(x=>x.id===b.dataset.id); if(!o) return;
    if(b.dataset.act==='cancel') o.status='CANCELADA';
    if(b.dataset.act==='done') o.status='COMPLETADA';
    if(b.dataset.act==='partial'){ const q=prompt('Cantidad completada en USDT (numero):', String(o.qtyUSDT||WATCH.tradeSize)); o.status='PARCIAL'; if(q&&!isNaN(Number(q))) o.fillQty=Number(q); }
    saveOrders(orders); renderOrders();
  }));
}
function levelVolAt(sym,ex,side,price){
  const lv=bookLevels(sym,ex,side); if(!lv) return null;
  for(const l of lv){ if(Number(l.p)===Number(price)) return Number(l.p)*Number(l.q); }
  return null;
}
function placeOrderFromSignal(i){
  const s=(window._signals||[])[i]; if(!s) return;
  const q=prompt('Importe de la orden en USDT (numero):', String(WATCH.tradeSize));
  const amt=(q&&!isNaN(Number(q))&&Number(q)>0)?Number(q):WATCH.tradeSize;
  const mSide=(s.model==='A')?'bid':'ask';
  const vis=levelVolAt(s.symbol,s.maker_exchange,mSide,s.limit_price);
  const orders=loadOrders();
  orders.unshift({id:'o'+Date.now(), symbol:s.symbol, type:s.type, side:s.model==='A'?'BUY':'SELL', makerEx:s.maker_exchange, exitEx:s.exit_exchange, price:s.limit_price, qtyUSDT:amt, visibleVolThen:vis, exitPriceThen:s.exit_price, netThen:s.net, botVer:(window._botVer||null), webVer:WEB_VERSION, time:new Date().toISOString(), status:'EN COLA'});
  saveOrders(orders); renderOrders();
  document.getElementById('ordersBox').scrollIntoView();
}
async function fetchDepth(){
  try{
    const r=await fetch(DEPTH_URL+'?t='+Date.now(),{cache:'no-store'});
    if(!r.ok) throw new Error('HTTP '+r.status);
    const j=await r.json();
    const rows=j.signals||[];
    window._signals=rows;
    window._botVer=j.ver||null;
    window._depthUpdated=new Date(j.updated||Date.now()).getTime();
    window._books={}; (j.books||[]).forEach(b=>{ window._books[b.symbol]=b; });
    const stale=((Date.now()-window._depthUpdated)/1000)>STALE_S;
    let html='';
    if(stale) html+='<div class="mkt"><div class="mkt-head"><span class="mkt-sym">DATOS ANTIGUOS</span><span class="mkt-net bad">BOT PARADO o sin actualizar</span></div><div class="combo">Libro de hace mas de '+STALE_S+' s. No se muestra PREPARAR ni POSIBLE FILL como operables.</div></div>';
    for(let i=0;i<rows.slice(0,15).length;i++){
      const s=rows[i];
      let dispState=s.state, cls=STATE_COLOR[s.state]||'no';
      if(stale&&(s.state==='PREPARAR'||s.state.indexOf('POSIBLE FILL')===0)){ dispState='DATOS ANTIGUOS'; cls='bad'; }
      html+='<div class="mkt"><div class="mkt-head"><span class="mkt-sym">'+s.symbol+' - '+s.type+'</span><span class="mkt-net '+cls+'">'+dispState+'</span></div>'
      +'<div class="combo">Maker <b>'+s.maker_exchange+'</b> limite <b>'+s.limit_price+'</b> -&gt; salida inmediata <b>'+s.exit_exchange+' '+s.exit_price+'</b> ['+s.model+'] - evidencia: <b>'+esc(s.evidence||'snapshot')+'</b></div>'
      +'<div class="combo">Cola delante: <b>'+(s.queue_ahead_usdt==null?'--':s.queue_ahead_usdt+' USDT')+'</b> - agotamiento <b>'+(s.depletion_rate==null?'--':s.depletion_rate+' USDT/s')+'</b> - fill estimado <b>'+(s.est_fill_s==null?'--':s.est_fill_s+' s')+'</b> - lecturas positivas <b>'+s.pos_reads+'</b> - edad <b>'+s.age_s+' s</b></div>'
      +'<div class="combo">Bruto <b>'+s.gross+'%</b> - maker <b>'+s.maker_fee+'%</b> - taker <b>'+s.taker_fee+'%</b> - slippage <b>'+s.slippage+'%</b> - margen <b>'+s.safety+'%</b> = <b>NETO '+s.net+'%</b> - salida max <b>'+s.exit_vol_usdt+' USDT</b> (niveles '+s.exit_lvls+')</div>'
      +'<div class="combo">'+esc(s.state_reason||'')+'</div>'
      +'<div class="combo">INVENTARIO NO VERIFICADO: necesitas el activo ya disponible en '+s.exit_exchange+'.</div>'
      +'<div class="combo"><a href="'+(s.pair_urls?s.pair_urls.buy:'#')+'" target="_blank" rel="noopener">Abrir '+s.maker_exchange+'</a> - <a href="'+(s.pair_urls?s.pair_urls.sell:'#')+'" target="_blank" rel="noopener">Abrir '+s.exit_exchange+'</a> <button data-sig="'+i+'">HE PUESTO LA ORDEN</button></div></div>';
    }
    if(!rows.length) html='<div class="combo">Sin senales ahora. El bot publica cuando un modelo A/B da neto sobre el umbral con salida liquida.</div>';
    const books=j.books||[];
    if(books.length){
      html+='<div class="combo" style="margin:.6rem 0">Siguiente en cola por mercado (top 20 asks/bids, muestro 5, solo profundidad). Abre cada par:</div>';
      for(const b of books){
        let inner='';
        for(const ex of ['binance','mexc','bybit','okx']){
          if(!b[ex]) continue;
          const a=(b[ex].asks||[]).slice(0,5).map((l,i)=>'A'+(i+1)+' '+l.p+' ('+l.q+')').join(' - ');
          const dd=(b[ex].bids||[]).slice(0,5).map((l,i)=>'B'+(i+1)+' '+l.p+' ('+l.q+')').join(' - ');
          inner+='<div style="margin:.25rem 0"><b>'+ex.toUpperCase()+'</b><br><span>ASK: '+a+'</span><br><span>BID: '+dd+'</span></div>';
        }
        html+='<details style="margin:.3rem 0"><summary><b>'+b.symbol+'</b> - ver cola</summary><div style="font-size:.78rem">'+inner+'</div></details>';
      }
    }
    if(elements.depthBox) elements.depthBox.innerHTML=html;
    if(elements.depthBox) elements.depthBox.querySelectorAll('button[data-sig]').forEach(b=>b.addEventListener('click',()=>placeOrderFromSignal(Number(b.dataset.sig))));
    if(elements.depthTime) elements.depthTime.textContent=new Date(j.updated||Date.now()).toLocaleTimeString()+' ('+formatTimeAgo(j.updated||Date.now())+')';
    renderOrders();
  }catch(e){ if(elements.depthBox) elements.depthBox.innerHTML='Depth aun no publicado - corre el bot para generarlo.'; }
}
async function fetchLive(){
  try{
    const r=await fetch(LIVE_URL+'?t='+Date.now(),{cache:'no-store'});
    if(!r.ok) throw new Error('HTTP '+r.status);
    const j=await r.json();
    const rows=j.symbols||[];
    const f=(v)=>{ v=Number(v); return v>=1000?v.toFixed(2):v>=1?v.toFixed(4):v.toFixed(6); };
    let html='<div style="overflow-x:auto"><table class="live-table"><thead><tr><th>Par</th><th>Bin ASK<br><span>c</span></th><th>Bin BID<br><span>v</span></th><th>Mex ASK<br><span>c</span></th><th>Mex BID<br><span>v</span></th><th>Byb ASK<br><span>c</span></th><th>Byb BID<br><span>v</span></th><th>OKX ASK<br><span>c</span></th><th>OKX BID<br><span>v</span></th><th>Neto</th></tr></thead><tbody>';
    for(const s of rows.slice(0,15)){
      const ok=s.best>=WATCH.minNet;
      const bB=Number(s.binance_bid),bA=Number(s.binance_ask),mB=Number(s.mexc_bid),mA=Number(s.mexc_ask);
      const yB=Number(s.bybit_bid||0),yA=Number(s.bybit_ask||0);
      const oB=Number(s.okx_bid||0),oA=Number(s.okx_ask||0);
      const hasY=!!(s.bybit_bid&&s.bybit_ask), hasO=!!(s.okx_bid&&s.okx_ask);
      const minAsk=Math.min(bA,mA,...(hasY?[yA]:[]),...(hasO?[oA]:[]));
      const maxBid=Math.max(bB,mB,...(hasY?[yB]:[]),...(hasO?[oB]:[]));
      const td=(v,cls)=>'<td class="'+cls+'">'+f(v)+'</td>';
      html+='<tr class="'+(ok?'arb':'')+'"><td class="sym">'+s.symbol.replace('/','')+'</td>'+td(bA,bA===minAsk?'bb':'')+td(bB,bB===maxBid?'bs':'')+td(mA,mA===minAsk?'bb':'')+td(mB,mB===maxBid?'bs':'')+(hasY?td(yA,yA===minAsk?'bb':'')+td(yB,yB===maxBid?'bs':''):'<td>--</td><td>--</td>')+(hasO?td(oA,oA===minAsk?'bb':'')+td(oB,oB===maxBid?'bs':''):'<td>--</td><td>--</td>')+'<td class="net '+(ok?'yes':'no')+'">'+Number(s.best).toFixed(2)+'%</td></tr>';
    }
    html+='</tbody></table></div><div class="combo">ASK=compro (naranja) - BID=vendo (azul) - verde=arb &gt;='+WATCH.minNet+'%</div>';
    window._liveRows={}; rows.forEach(s=>{ window._liveRows[s.symbol]=s; });
    window._liveUpdated=new Date(j.updated||Date.now()).getTime();
    window._liveBotVer=j.ver||window._liveBotVer||null;
    if(elements.liveBox) elements.liveBox.innerHTML=html||'sin datos';
    if(elements.liveTime) elements.liveTime.textContent=new Date(j.updated||Date.now()).toLocaleTimeString()+' ('+formatTimeAgo(j.updated||Date.now())+') - del bot';
    renderOrders();
  }catch(e){ if(elements.liveBox) elements.liveBox.innerHTML='live aun no publicado por el bot - corre <b>.\\bot.ps1</b> para generarlo. ('+e.message+')'; }
}
let _commitCache=null;
async function fetchCommit(){
  if(_commitCache) return _commitCache;
  try{
    const r=await fetch('https://api.github.com/repos/jarmy90/crypto-arb-alerts/commits?per_page=1&sha=main',{cache:'no-store'});
    if(!r.ok) throw new Error('HTTP '+r.status);
    const j=await r.json();
    _commitCache={sha:String(j[0].sha).slice(0,7), date:j[0].commit.author.date};
  }catch(e){ _commitCache={sha:'--', date:null}; }
  return _commitCache;
}
function exStatus(ex){
  const k=ex.toLowerCase();
  let live=false, book=false;
  const L=window._liveRows||{}, B=window._books||{};
  for(const s in L){ const r=L[s]; if(r&&(r[k+'_bid']!=null||r[k+'_ask']!=null)){ live=true; break; } }
  for(const s in B){ const r=B[s]; if(r&&r[k]&&((r[k].asks||[]).length||(r[k].bids||[]).length)){ book=true; break; } }
  if(live&&book) return 'OK';
  if(live||book) return 'PARCIAL';
  return 'SIN DATOS';
}
async function renderVersion(){
  const box=document.getElementById('verBox'); if(!box) return;
  const botVer=window._botVer||window._liveBotVer||null;
  const la=liveAgeS(), da=depthAgeS();
  const c=await fetchCommit();
  let bot, bcls;
  const desync=botVer&&botVer!==WEB_VERSION;
  if(desync){ bot='DESINCRONIZADO (web '+WEB_VERSION+' / bot '+botVer+')'; bcls='bad'; }
  else if(la==null&&da==null){ bot='SIN DATOS'; bcls='no'; }
  else if(Math.max(la==null?9999:la,da==null?9999:da)>DEAD_S){ bot='BOT PARADO'; bcls='bad'; }
  else if(Math.max(la==null?9999:la,da==null?9999:da)>STALE_S){ bot='RETRASADO'; bcls='warn'; }
  else { bot='LIVE'; bcls='yes'; }
  const exs=WATCH.exchanges.map(e=>e+':'+exStatus(e)).join(' - ');
  box.innerHTML='<div class="combo">Web <b>v'+WEB_VERSION+'</b> - bot <b>'+(botVer?('v'+botVer):'--')+'</b> - commit <b>'+esc(c.sha)+'</b> '+(c.date?esc(c.date):'')
  +' - ticker hace <b>'+(la==null?'--':Math.round(la)+' s')+'</b> - libro hace <b>'+(da==null?'--':Math.round(da)+' s')+'</b></div>'
  +'<div class="combo">Bot: <b>'+bot+'</b> - '+esc(exs)+'</div>';
  const hb=document.getElementById('verBadge');
  if(hb){ hb.innerHTML='<span class="mkt-net '+bcls+'">'+bot+'</span>'; }
}
function init(){ renderWatch(); fetchAlerts(); fetchLive(); fetchDepth(); renderVersion(); setInterval(fetchAlerts,CONFIG.refreshInterval); setInterval(fetchLive,15000); setInterval(fetchDepth,30000); setInterval(renderVersion,5000); }
if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',init); else init();
