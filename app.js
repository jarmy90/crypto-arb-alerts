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
function showError(m){ elements.alertsContainer.innerHTML=''; elements.emptyState.style.display='none'; elements.errorState.style.display='block'; elements.errorMessage.textContent=m; }
async function fetchAlerts(){
  if(isLoading) return; isLoading=true;
  try{
    const r=await fetch(CONFIG.alertsUrl+'?t='+Date.now(),{cache:'no-store'});
    if(!r.ok) throw new Error('HTTP '+r.status);
    const alerts=normalizeAlerts(await r.json());
    lastOk=new Date();
    renderAlerts(alerts);
  }catch(e){ console.error(e); if(!lastOk) showError('No pude cargar alerts.json: '+e.message); }
  finally{ isLoading=false; }
}
elements.refreshBtn.addEventListener('click',()=>{fetchAlerts();fetchLive();fetchDepth();fetchStatus();});
const WEB_VERSION='13.3';
const STATUS_URL='https://raw.githubusercontent.com/jarmy90/crypto-arb-alerts/main/data/status.json';
const MARKETS_URL='https://raw.githubusercontent.com/jarmy90/crypto-arb-alerts/main/data/markets.json';
const LIVE_MAX_S=5, DELAYED_MAX_S=15, DEAD_S=60, DESYNC_S=180;
const STALE_S=90;
const STATE_COLOR={OBSERVAR:'warn',PRESEÑAL:'warn',CERCA:'warn',PREPARAR:'prep','NIVEL REDUCIDO':'warn','POSIBLE EJECUCION':'prep','POSIBLE FILL PARCIAL':'prep','POSIBLE FILL':'yes',RETIRAR:'bad'};
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
  if(da>DELAYED_MAX_S) return {state:'DATOS ANTIGUOS', detail:'libro de hace '+Math.round(da)+' s'};
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
  if(!isOperable()){ alert('EL BOT ESTA PARADO o los datos son antiguos. No se puede poner ordenes desde una senal vieja.'); return; }
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
    const sysNow=computeSystemState();
    const operable=(sysNow.state==='LIVE');
    let html='';
    if(!operable) html+='<div class="mkt"><div class="mkt-head"><span class="mkt-sym">NO OPERABLE: '+sysNow.state+'</span><span class="mkt-net bad">'+esc(sysNow.detail||'')+'</span></div><div class="combo">Las senales de abajo son la ultima foto conocida. No se puede poner ordenes ni considerar PREPARAR/POSIBLE FILL como vigentes.</div></div>';
    for(let i=0;i<rows.slice(0,15).length;i++){
      const s=rows[i];
      if(s.state==='CERCA'){ continue; }
      let dispState=s.state, cls=STATE_COLOR[s.state]||'no';
      if(!operable&&(s.state==='PREPARAR'||s.state.indexOf('POSIBLE FILL')===0)){ dispState='BLOQUEADA ('+sysNow.state+')'; cls='bad'; }
      const feeBadge=(s.fee_verified)?'verificada':'FEE NO VERIFICADA';
      const sz=(s.sizes||[]).filter(r=>r.covered).map(r=>r.size+':'+r.net+'%').join(' ');
      html+='<div class="mkt"><div class="mkt-head"><span class="mkt-sym">'+s.symbol+' - '+s.type+'</span><span class="mkt-net '+cls+'">'+dispState+'</span></div>'
      +'<div class="combo">Grupo <b>'+esc(s.normalized_symbol||s.symbol)+'</b> ('+esc(s.base||'')+'/'+esc(s.quote||'')+') - maker <b>'+s.maker_exchange+'</b> ['+esc(s.maker_native_symbol||'')+'] limite <b>'+s.limit_price+'</b> -&gt; salida inmediata <b>'+s.exit_exchange+'</b> ['+esc(s.exit_native_symbol||'')+'] '+s.exit_price+' ['+s.model+'] - evidencia: <b>'+esc(s.evidence||'snapshot')+'</b> - calidad: <b>'+esc(s.quality||'')+'</b></div>'
      +'<div class="combo">Umbral dinamico <b>'+s.dyn_threshold+'%</b> (bruto incluido) = maker '+s.maker_fee+' + taker '+s.taker_fee+' + slip '+s.slippage+' + latencia/slippage-parcial/volatilidad/margen - exceso <b>'+s.excess+'%</b> - fee '+feeBadge+'</div>'
      +'<div class="combo">Tamanos: '+esc(sz||'--')+' - mejor% <b>'+s.best_pct_size+'</b> - mejor abs <b>'+s.best_abs_size+'</b> - recomendado <b>'+s.recommended_size+'</b></div>'
      +'<div class="combo">Flujo: <b>'+esc(s.flow_state||'')+'</b> fav '+s.flow_fav+' vs contra '+s.flow_contra+' USDT ('+s.flow_n+' ops, media '+s.flow_avg+', acel '+s.flow_accel+')</div>'
      +'<div class="combo">Salida viva '+s.age_s+' s: min '+s.exit_min+' max '+s.exit_max+' media '+s.exit_avg+'% - survival '+s.survival_ratio+' ('+esc(s.survival_class||'')+') - desapariciones '+s.exit_gaps+'</div>'
      +'<div class="combo">Score <b>'+s.score+'/100 ['+esc(s.score_band||'')+']</b> - '+esc(s.score_detail||'')+'</div>'
      +'<div class="combo">Cola delante: <b>'+(s.queue_ahead_usdt==null?'--':s.queue_ahead_usdt+' USDT')+'</b> - agotamiento <b>'+(s.depletion_rate==null?'--':s.depletion_rate+' USDT/s')+'</b> - fill estimado <b>'+(s.est_fill_s==null?'NO CALCULABLE':s.est_fill_s+' s')+'</b> ('+esc(s.fill_quality||'')+') - lecturas <b>'+s.pos_reads+'</b></div>'
      +'<div class="combo">'+esc(s.state_reason||'')+'</div>'
      +'<div class="combo">INVENTARIO NO VERIFICADO: necesitas el activo ya disponible en '+s.exit_exchange+'.</div>'
      +'<div class="combo"><a href="'+(s.pair_urls?s.pair_urls.buy:'#')+'" target="_blank" rel="noopener">Abrir '+s.maker_exchange+'</a> - <a href="'+(s.pair_urls?s.pair_urls.sell:'#')+'" target="_blank" rel="noopener">Abrir '+s.exit_exchange+'</a> <button data-sig="'+i+'"'+(operable?'':' disabled')+'>HE PUESTO LA ORDEN</button></div></div>';
    }
    const cerca=rows.filter(s=>s.state==='CERCA');
    if(cerca.length){
      html+='<div class="combo" style="margin:.8rem 0"><b>CASI OPORTUNIDADES (no operables, sin verde, sin boton):</b></div>';
      for(const s of cerca.slice(0,10)){
        html+='<div class="mkt"><div class="mkt-head"><span class="mkt-sym">'+s.symbol+' '+s.type+'</span><span class="mkt-net warn">CERCA</span></div>'
        +'<div class="combo">'+s.maker_exchange+' -&gt; '+s.exit_exchange+' neto <b>'+s.net+'%</b> - umbral <b>'+s.dyn_threshold+'%</b> - falta <b>'+(Number(s.dyn_threshold)-Number(s.net)).toFixed(2)+'%</b> - cola '+s.queue_ahead_usdt+' - fill '+(s.est_fill_s==null?'NO CALCULABLE':s.est_fill_s+' s')+'</div></div>';
      }
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
    const qsel=quoteSel();
    let html='<div style="overflow-x:auto"><table class="live-table"><thead><tr><th>Par</th><th>Bin ASK<br><span>c</span></th><th>Bin BID<br><span>v</span></th><th>Mex ASK<br><span>c</span></th><th>Mex BID<br><span>v</span></th><th>Byb ASK<br><span>c</span></th><th>Byb BID<br><span>v</span></th><th>OKX ASK<br><span>c</span></th><th>OKX BID<br><span>v</span></th><th>Neto</th></tr></thead><tbody>';
    let shown=0;
    for(const s of rows){
      if(s.quote&&(qsel==='USDC'||qsel==='USDT')&&s.quote!==qsel) continue;
      const g=groupMembers(s.symbol);
      if(g&&Object.keys(g.members||{}).length<2) continue;
      shown++;
      const ok=(s.best!=null&&s.best>=WATCH.minNet);
      const P={BINANCE:[s.binance_ask,s.binance_bid],MEXC:[s.mexc_ask,s.mexc_bid],BYBIT:[s.bybit_ask,s.bybit_bid],OKX:[s.okx_ask,s.okx_bid]};
      const asks=Object.keys(P).filter(e=>P[e][0]!=null&&Number(P[e][0])>0).map(e=>Number(P[e][0]));
      const bids=Object.keys(P).filter(e=>P[e][1]!=null&&Number(P[e][1])>0).map(e=>Number(P[e][1]));
      const minAsk=asks.length?Math.min.apply(null,asks):null;
      const maxBid=bids.length?Math.max.apply(null,bids):null;
      const cell=(e,idx,cls)=>{ const v=P[e][idx]; if(v==null||!(Number(v)>0)) return '<td class="na">NO DISPONIBLE</td>'; const n=Number(v); return '<td class="'+(((idx===0&&n===minAsk)||(idx===1&&n===maxBid))?cls:'')+'">'+f(n)+'</td>'; };
      const star=(s.principal||(window._markets&&window._markets.principal&&window._markets.principal[s.base]===s.quote))?' ★':'';
      html+='<tr class="'+(ok?'arb':'')+'"><td class="sym">'+s.symbol+star+'</td>'+cell('BINANCE',0,'bb')+cell('BINANCE',1,'bs')+cell('MEXC',0,'bb')+cell('MEXC',1,'bs')+cell('BYBIT',0,'bb')+cell('BYBIT',1,'bs')+cell('OKX',0,'bb')+cell('OKX',1,'bs')+'<td class="net '+(ok?'yes':'no')+'">'+(s.best==null?'--':Number(s.best).toFixed(2)+'%')+'</td></tr>';
    }
    html+='</tbody></table></div><div class="combo">ASK=compro (naranja) - BID=vendo (azul) - verde=arb &gt;='+WATCH.minNet+'% - celdas grises: par no disponible en ese exchange - ★: cotizacion principal</div>';
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
function groupMembers(sym){
  const M=window._markets||null;
  if(!M||!M.groups) return null;
  for(const g of M.groups){ if(g.normalized===sym) return g; }
  return null;
}
function quoteSel(){ return window._quoteSel||'ALL'; }
async function fetchMarkets(){
  try{
    const r=await fetch(MARKETS_URL+'?t='+Date.now(),{cache:'no-store'});
    if(!r.ok) throw new Error('HTTP '+r.status);
    window._markets=await r.json();
  }catch(e){ window._markets=null; }
  renderQuoteSel();
}
function renderQuoteSel(){
  const box=document.getElementById('quoteSel'); if(!box) return;
  const q=[['ALL','Todos'],['USDC','USDC'],['USDT','USDT']];
  box.innerHTML=q.map(x=>'<button data-q="'+x[0]+'"'+(quoteSel()===x[0]?' class="on"':'')+'>'+x[1]+'</button>').join(' ');
  box.querySelectorAll('button').forEach(b=>b.addEventListener('click',()=>{ window._quoteSel=b.dataset.q; renderQuoteSel(); fetchLive(); }));
}
function ageOf(t){ if(!t) return null; return (Date.now()-new Date(t).getTime())/1000; }
// Estado unico del sistema. Peor criterio entre ticker, depth, heartbeat y versiones.
// LIVE<=5s, RETRASADO<=15s (sin PREPARAR), DATOS ANTIGUOS>15s (no operable), BOT PARADO>60s.
function computeSystemState(){
  const st=window._status||null;
  const botVer=window._botVer||window._liveBotVer||null;
  const tickerAge=(st&&st.ticker_updated_at)?ageOf(st.ticker_updated_at):liveAgeS();
  const depthAge=(st&&st.depth_updated_at)?ageOf(st.depth_updated_at):depthAgeS();
  const hbAge=(st&&st.bot_heartbeat_at)?ageOf(st.bot_heartbeat_at):null;
  const tradesAge=(st&&st.trades_updated_at)?ageOf(st.trades_updated_at):null;
  if(tickerAge==null&&depthAge==null&&hbAge==null) return {state:'SIN DATOS', cls:'no', detail:'sin datos validos', ages:{}};
  if(botVer&&botVer!==WEB_VERSION) return {state:'DESINCRONIZADO', cls:'bad', detail:'web v'+WEB_VERSION+' / bot v'+botVer, ages:{ticker:tickerAge,depth:depthAge,hb:hbAge}};
  const ages=[tickerAge,depthAge,hbAge].filter(a=>a!=null);
  const worst=Math.max.apply(null,ages);
  const liveU=(st&&st.ticker_updated_at)||null, depthU=(st&&st.depth_updated_at)||null;
  if(liveU&&depthU&&Math.abs(new Date(liveU)-new Date(depthU))/1000>DESYNC_S) return {state:'DESINCRONIZADO', cls:'bad', detail:'ticker y libro de momentos incompatibles', ages:{ticker:tickerAge,depth:depthAge,hb:hbAge}};
  if(worst>DEAD_S) return {state:'BOT PARADO', cls:'bad', detail:'sin heartbeat ni datos hace '+Math.round(worst)+' s', ages:{ticker:tickerAge,depth:depthAge,hb:hbAge}};
  if(worst>DELAYED_MAX_S) return {state:'DATOS ANTIGUOS', cls:'bad', detail:'datos de hace '+Math.round(worst)+' s, no operables', ages:{ticker:tickerAge,depth:depthAge,hb:hbAge}};
  if(worst>LIVE_MAX_S) return {state:'RETRASADO', cls:'warn', detail:'datos de hace '+Math.round(worst)+' s, solo referencia', ages:{ticker:tickerAge,depth:depthAge,hb:hbAge,trades:tradesAge}};
  return {state:'LIVE', cls:'yes', detail:'ticker, libro y heartbeat recientes', ages:{ticker:tickerAge,depth:depthAge,hb:hbAge,trades:tradesAge}};
}
function isOperable(){ return computeSystemState().state==='LIVE'; }
async function fetchStatus(){
  try{
    const r=await fetch(STATUS_URL+'?t='+Date.now(),{cache:'no-store'});
    if(!r.ok) throw new Error('HTTP '+r.status);
    window._status=await r.json();
  }catch(e){ window._status=null; }
  renderVersion();
}
async function renderVersion(){
  const box=document.getElementById('verBox'); if(!box) return;
  const sys=computeSystemState();
  const botVer=window._botVer||window._liveBotVer||null;
  const st=window._status||null;
  const c=await fetchCommit();
  const a=sys.ages||{};
  const fmt=(v)=>v==null?'--':Math.round(v)+' s';
  const exs=WATCH.exchanges.map(e=>e+':'+exStatus(e)).join(' - ');
  box.innerHTML='<div class="combo">Web <b>v'+WEB_VERSION+'</b> - bot <b>'+(botVer?('v'+botVer):'--')+'</b> - commit <b>'+esc(c.sha)+'</b> '+(c.date?esc(c.date):'')
  +' - ciclo <b>'+esc((st&&st.cycle_id)||'--')+'</b> ('+esc((st&&st.cycle_duration_ms!=null)?(st.cycle_duration_ms+' ms'):'--')+')</div>'
  +'<div class="combo">Ticker hace <b>'+fmt(a.ticker)+'</b> - libro hace <b>'+fmt(a.depth)+'</b> - heartbeat hace <b>'+fmt(a.hb)+'</b> - trades hace <b>'+fmt(a.trades)+'</b></div>'
  +'<div class="combo">Estado: <b>'+sys.state+'</b> - '+esc(sys.detail)+'</div>'
  +'<div class="combo">'+esc(exs)+'</div>';
  const M=window._markets||null;
  const hl=document.getElementById('healthLine');
  if(hl){
    let h='Grupos con 2+ exchanges: <b>'+((M&&M.groups)?M.groups.filter(g=>Object.keys(g.members||{}).length>=2).length:'--')+'</b>';
    if(M&&M.suspended&&M.suspended.length){ h+=' - SUSPENDIDO: '+M.suspended.slice(0,8).map(x=>esc(x.base+'/'+x.quote+' en '+x.exchange)).join(', ')+(M.suspended.length>8?' (+'+(M.suspended.length-8)+' mas)':''); }
    else { h+=' - sin suspendidos'; }
    if(M&&M.updated){ h+=' - catalogo '+formatTimeAgo(M.updated); }
    hl.innerHTML=h;
  }
  const hb=document.getElementById('sysBadge');
  if(hb){ hb.innerHTML='<span class="mkt-net '+sys.cls+'">'+sys.state+'</span>'; }
  const old=document.getElementById('verBadge');
  if(old){ old.innerHTML=''; }
  updateRefreshButton(sys.state);
  applyTableState(sys.state);
}
function updateRefreshButton(state){
  const b=document.getElementById('refreshBtn'); if(!b) return;
  const n=document.getElementById('refreshNote'); 
  if(state==='LIVE'||state==='RETRASADO'){ b.textContent='RECARGAR DATOS'; b.disabled=false; if(n) n.textContent='Recargar relee lo ultimo publicado. No genera precios nuevos.'; }
  else { b.textContent='EL BOT ESTA PARADO'; b.disabled=false; if(n) n.textContent='Actualizar la pagina no genera precios nuevos. El bot debe estar activo.'; }
}
function applyTableState(state){
  const t=document.getElementById('priceTitle');
  const ageEl=document.getElementById('priceAge');
  const liveU=(window._status&&window._status.ticker_updated_at)||null;
  const age=liveU?(Date.now()-new Date(liveU).getTime())/1000:liveAgeS();
  const ageTxt=age==null?'':'('+(age<=LIVE_MAX_S?'hace '+Math.round(age)+' s':age<=DELAYED_MAX_S?'hace '+Math.round(age)+' s':'hace '+Math.round(age)+' s')+')';
  const ov=document.getElementById('tableOverlay');
  const box=document.getElementById('liveBox');
  if(t) t.textContent = state==='LIVE'?'Precio live':state==='RETRASADO'?'Precio retrasado':state==='BOT PARADO'?'Bot parado':'Ultima fotografia, no operable';
  if(ageEl) ageEl.textContent = ageTxt;
  const blocked=(state!=='LIVE');
  if(box){ if(blocked) box.classList.add('dim'); else box.classList.remove('dim'); }
  if(ov){ ov.innerHTML = blocked?'<div class="stale-overlay"><div><b>DATOS ANTIGUOS. NO UTILIZAR PARA ARBITRAJE.</b><br><span style="color:#9ca3af">Estado: '+state+'. El bot debe estar activo.</span></div></div>':''; }
}
function switchTab(which){
  document.getElementById('tabLive').style.display=(which==='live')?'':'none';
  document.getElementById('tabHist').style.display=(which==='hist')?'':'none';
  document.getElementById('tabBtnLive').className=(which==='live')?'on':'';
  document.getElementById('tabBtnHist').className=(which==='hist')?'on':'';
}
function init(){ renderWatch(); fetchAlerts(); fetchLive(); fetchDepth(); fetchStatus(); fetchMarkets(); renderOrders();
  const bL=document.getElementById('tabBtnLive'), bH=document.getElementById('tabBtnHist');
  if(bL) bL.addEventListener('click',()=>switchTab('live'));
  if(bH) bH.addEventListener('click',()=>switchTab('hist'));
  setInterval(fetchAlerts,30000); setInterval(fetchLive,15000); setInterval(fetchDepth,30000); setInterval(fetchStatus,10000); setInterval(fetchMarkets,300000); setInterval(renderVersion,5000); setInterval(renderOrders,10000); }
if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',init); else init();

