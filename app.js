// Crypto Arbitrage Detector - web v7 (ASCII-safe, UTF-8)
const GITHUB_URL = 'https://raw.githubusercontent.com/jarmy90/crypto-arb-alerts/main/data/alerts.json';
const LIVE_URL = 'https://raw.githubusercontent.com/jarmy90/crypto-arb-alerts/main/data/live.json';
const WATCH = {
  exchanges: ['BINANCE','MEXC','BYBIT','OKX'],
  symbols: ['BTC/USDT','ETH/USDT','BNB/USDT','SOL/USDT','XRP/USDT','ADA/USDT','DOGE/USDT','DOT/USDT','POL/USDT','LTC/USDT','AVAX/USDT','LINK/USDT','UNI/USDT','ATOM/USDT','NEAR/USDT'],
  minNet: 0.40, tradeSize: 500, feeBinance: 0.10, feeMexc: 0.05, feeBybit: 0.10, feeOkx: 0.10
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
  liveBox: document.getElementById('liveBox'), liveTime: document.getElementById('liveTime')
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
elements.refreshBtn.addEventListener('click',()=>{fetchAlerts();fetchLive();});
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
    if(elements.liveBox) elements.liveBox.innerHTML=html||'sin datos';
    if(elements.liveTime) elements.liveTime.textContent=new Date(j.updated||Date.now()).toLocaleTimeString()+' ('+formatTimeAgo(j.updated||Date.now())+') - del bot';
  }catch(e){ if(elements.liveBox) elements.liveBox.innerHTML='live aun no publicado por el bot - corre <b>.\\bot.ps1</b> para generarlo. ('+e.message+')'; }
}
function init(){ renderWatch(); fetchAlerts(); fetchLive(); setInterval(fetchAlerts,CONFIG.refreshInterval); setInterval(fetchLive,15000); }
if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',init); else init();
