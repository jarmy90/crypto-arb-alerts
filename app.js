// Config visible en la web
const GITHUB_URL = 'https://raw.githubusercontent.com/jarmy90/crypto-arb-alerts/main/data/alerts.json';
const WATCH = {
  exchanges: ['BINANCE','MEXC'],
  symbols: ['BTC/USDT','ETH/USDT','BNB/USDT','SOL/USDT','XRP/USDT','ADA/USDT','DOGE/USDT','DOT/USDT','POL/USDT','LTC/USDT','AVAX/USDT','LINK/USDT','UNI/USDT','ATOM/USDT','NEAR/USDT'],
  minNet: 0.40, tradeSize: 500, feeBinance: 0.10, feeMexc: 0.05
};
const CONFIG = { alertsUrl: GITHUB_URL, refreshInterval: 12000, maxRecentMinutes: 120 };

let lastFetchTime = null, isLoading = false, lastOk = null;
const elements = {
  alertsContainer: document.getElementById('alertsContainer'),
  emptyState: document.getElementById('emptyState'), errorState: document.getElementById('errorState'),
  errorMessage: document.getElementById('errorMessage'), statusDot: document.getElementById('statusDot'),
  statusText: document.getElementById('statusText'), lastUpdate: document.getElementById('lastUpdate'),
  refreshBtn: document.getElementById('refreshBtn'), activeCount: document.getElementById('activeCount'),
  bestSpread: document.getElementById('bestSpread'), topProfit: document.getElementById('topProfit'),
  watchList: document.getElementById('watchList'), cfgLine: document.getElementById('cfgLine')
};

function normalizeAlerts(j) {
  if (!j) return [];
  if (Array.isArray(j)) return j;
  if (j.symbol) return [j]; // bot-local guarda objeto único
  if (Array.isArray(j.alerts)) return j.alerts;
  if (Array.isArray(j.data)) return j.data;
  return [];
}
function formatTimeAgo(t){ const s=Math.floor((new Date()-new Date(t))/1000); if(s<60) return `${s} seg atrás`; if(s<3600) return `${Math.floor(s/60)} min atrás`; if(s<86400) return `${Math.floor(s/3600)} h atrás`; return `${Math.floor(s/86400)} d atrás`; }
function formatPrice(p){ if(p>=1000) return p.toFixed(2); if(p>=1) return p.toFixed(4); return p.toFixed(8); }
function formatCurrency(a){ return new Intl.NumberFormat('en-US',{style:'currency',currency:'USD'}).format(a); }
function isRecentAlert(t){ return (new Date()-new Date(t))/1000/60 <= CONFIG.maxRecentMinutes; }
function updateStatus(st,msg){ elements.statusDot.className=`status-dot ${st}`; elements.statusText.textContent=msg; }
function updateStats(alerts){
  elements.activeCount.textContent=alerts.length;
  if(alerts.length){ elements.bestSpread.textContent=`${Math.max(...alerts.map(a=>a.net_spread)).toFixed(2)}%`; elements.topProfit.textContent=formatCurrency(Math.max(...alerts.map(a=>a.estimated_profit||a.profit||0))); }
  else { elements.bestSpread.textContent='—'; elements.topProfit.textContent='—'; }
}
function renderWatch(){
  if(elements.watchList) elements.watchList.innerHTML = WATCH.symbols.map(s=>`<span class="pair-chip">${s}</span>`).join('');
  if(elements.cfgLine) elements.cfgLine.textContent = `Exchanges: ${WATCH.exchanges.join(' ↔ ')} | Umbral neto ≥ ${WATCH.minNet}% | Trade ${WATCH.tradeSize} USDT | Fees Binance ${WATCH.feeBinance}% / MEXC ${WATCH.feeMexc}% | Escaneo cada 8s`;
}
function createAlertCard(a){
  const d=document.createElement('div'); d.className='alert-card';
  if(!isRecentAlert(a.timestamp)) d.style.opacity='0.6';
  const buyUrl=(a.pair_urls&&a.pair_urls.buy)||'#', sellUrl=(a.pair_urls&&a.pair_urls.sell)||'#';
  d.innerHTML=`<div class="alert-header"><div class="symbol">${a.symbol||'?'}</div><div class="spread-badge">+${Number(a.net_spread||0).toFixed(2)}%</div></div>
  <div class="direction"><div class="exchange-flow"><span>Compra</span><span class="exchange-name">${a.buy_exchange||''}</span><span class="arrow">→</span><span>Vende</span><span class="exchange-name">${a.sell_exchange||''}</span></div></div>
  <div class="prices"><div class="price-item"><div class="price-label">Compra</div><div class="price-value">$${formatPrice(Number(a.buy_price||0))}</div><a href="${buyUrl}" target="_blank" rel="noopener">Abrir ${a.buy_exchange||''} ↗</a></div>
  <div class="price-item"><div class="price-label">Venta</div><div class="price-value">$${formatPrice(Number(a.sell_price||0))}</div><a href="${sellUrl}" target="_blank" rel="noopener">Abrir ${a.sell_exchange||''} ↗</a></div></div>
  <div class="profit"><span class="profit-label">Profit est. (${WATCH.tradeSize} USDT)</span><span class="profit-value">${formatCurrency(a.estimated_profit??a.profit??0)}</span></div>
  <div class="timestamp">${formatTimeAgo(a.timestamp)} · bruto ${Number(a.gross_spread||0).toFixed(2)}%</div>`;
  return d;
}
function renderAlerts(alerts){
  elements.alertsContainer.innerHTML=''; elements.emptyState.style.display='none'; elements.errorState.style.display='none';
  if(!alerts.length){ elements.emptyState.style.display='block'; elements.emptyState.querySelector('p').textContent='Bot escaneando Binance ↔ MEXC. Si no hay spread ≥0.40% neto no hay alerta. Vuelve en unos segundos.'; updateStats([]); return; }
  [...alerts].sort((a,b)=>new Date(b.timestamp)-new Date(a.timestamp)).forEach(a=>elements.alertsContainer.appendChild(createAlertCard(a)));
  updateStats(alerts);
}
function showError(m){ elements.alertsContainer.innerHTML=''; elements.emptyState.style.display='none'; elements.errorState.style.display='block'; elements.errorMessage.textContent=m; updateStatus('error','Desconectado — reintentando…'); }
async function fetchAlerts(){
  if(isLoading) return; isLoading=true;
  try{
    const r=await fetch(`${CONFIG.alertsUrl}?t=${Date.now()}`,{cache:'no-store'});
    if(!r.ok) throw new Error(`HTTP ${r.status}`);
    const alerts=normalizeAlerts(await r.json());
    lastFetchTime=new Date(); lastOk=new Date();
    renderAlerts(alerts); updateStatus('active','Conectado · Live');
    elements.lastUpdate.textContent=`${lastFetchTime.toLocaleTimeString()} (${formatTimeAgo(alerts[0]?.timestamp||lastFetchTime)} última alerta)`;
  }catch(e){ console.error(e); if(lastOk){ updateStatus('active','Conectado · esperando datos…'); } else showError(`No pude cargar alerts.json: ${e.message}. Revisa https://github.com/jarmy90/crypto-arb-alerts`); }
  finally{ isLoading=false; }
}
elements.refreshBtn.addEventListener('click',fetchAlerts);
function init(){ renderWatch(); fetchAlerts(); setInterval(fetchAlerts,CONFIG.refreshInterval); setInterval(()=>{ if(lastFetchTime) elements.lastUpdate.textContent=`${lastFetchTime.toLocaleTimeString()} · auto-refresh 12s`; },5000); }
if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',init); else init();
