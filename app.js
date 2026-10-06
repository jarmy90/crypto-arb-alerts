// Configuration
const GITHUB_URL = 'https://raw.githubusercontent.com/jarmy90/crypto-arb-alerts/main/data/alerts.json';
const CONFIG = {
    // Local file first (when served via server.ps1), fallback to GitHub
    alertsUrl: (location.protocol.startsWith('http') && (location.hostname === 'localhost' || location.hostname === '127.0.0.1'))
      ? '../data/alerts.json'
      : GITHUB_URL,
    refreshInterval: 12000, // 12 seconds
    maxRecentMinutes: 15 // Consider alerts from last 15 minutes as "active"
};

// State
let lastFetchTime = null;
let isLoading = false;

// DOM Elements
const elements = {
    alertsContainer: document.getElementById('alertsContainer'),
    emptyState: document.getElementById('emptyState'),
    errorState: document.getElementById('errorState'),
    errorMessage: document.getElementById('errorMessage'),
    statusDot: document.getElementById('statusDot'),
    statusText: document.getElementById('statusText'),
    lastUpdate: document.getElementById('lastUpdate'),
    refreshBtn: document.getElementById('refreshBtn'),
    activeCount: document.getElementById('activeCount'),
    bestSpread: document.getElementById('bestSpread'),
    topProfit: document.getElementById('topProfit')
};

// Utility Functions
function formatTimeAgo(timestamp) {
    const now = new Date();
    const then = new Date(timestamp);
    const seconds = Math.floor((now - then) / 1000);
    
    if (seconds < 60) return `${seconds} seconds ago`;
    if (seconds < 3600) return `${Math.floor(seconds / 60)} minutes ago`;
    if (seconds < 86400) return `${Math.floor(seconds / 3600)} hours ago`;
    return `${Math.floor(seconds / 86400)} days ago`;
}

function formatPrice(price) {
    if (price >= 1000) return price.toFixed(2);
    if (price >= 1) return price.toFixed(4);
    return price.toFixed(8);
}

function formatCurrency(amount) {
    return new Intl.NumberFormat('en-US', {
        style: 'currency',
        currency: 'USD',
        minimumFractionDigits: 2,
        maximumFractionDigits: 2
    }).format(amount);
}

function isRecentAlert(timestamp) {
    const now = new Date();
    const then = new Date(timestamp);
    const minutes = (now - then) / 1000 / 60;
    return minutes <= CONFIG.maxRecentMinutes;
}

// UI Update Functions
function updateStatus(status, message) {
    elements.statusDot.className = `status-dot ${status}`;
    elements.statusText.textContent = message;
}

function updateLastFetchTime() {
    if (lastFetchTime) {
        elements.lastUpdate.textContent = formatTimeAgo(lastFetchTime);
    }
}

function updateStats(alerts) {
    const recentAlerts = alerts.filter(alert => isRecentAlert(alert.timestamp));
    elements.activeCount.textContent = recentAlerts.length;
    
    if (recentAlerts.length > 0) {
        const bestSpread = Math.max(...recentAlerts.map(a => a.net_spread));
        elements.bestSpread.textContent = `${bestSpread.toFixed(2)}%`;
        const topProfit = Math.max(...recentAlerts.map(a => a.estimated_profit));
        elements.topProfit.textContent = formatCurrency(topProfit);
    } else {
        elements.bestSpread.textContent = 'â€”';
        elements.topProfit.textContent = 'â€”';
    }
}

function createAlertCard(alert) {
    const card = document.createElement('div');
    card.className = 'alert-card';
    
    const isRecent = isRecentAlert(alert.timestamp);
    if (!isRecent) card.style.opacity = '0.6';
    
    card.innerHTML = `
        <div class="alert-header">
            <div class="symbol">${alert.symbol}</div>
            <div class="spread-badge">+${alert.net_spread.toFixed(2)}%</div>
        </div>
        <div class="direction">
            <div class="exchange-flow">
                <span>Buy on</span>
                <span class="exchange-name">${alert.buy_exchange}</span>
                <span class="arrow">â†’</span>
                <span>Sell on</span>
                <span class="exchange-name">${alert.sell_exchange}</span>
            </div>
        </div>
        <div class="prices">
            <div class="price-item">
                <div class="price-label">Buy Price</div>
                <div class="price-value">$${formatPrice(alert.buy_price)}</div>
            </div>
            <div class="price-item">
                <div class="price-label">Sell Price</div>
                <div class="price-value">$${formatPrice(alert.sell_price)}</div>
            </div>
        </div>
        <div class="profit">
            <span class="profit-label">Est. Profit (500 USDT)</span>
            <span class="profit-value">${formatCurrency(alert.estimated_profit)}</span>
        </div>
        <div class="timestamp">${formatTimeAgo(alert.timestamp)}</div>
    `;
    
    return card;
}

function renderAlerts(alerts) {
    elements.alertsContainer.innerHTML = '';
    elements.emptyState.style.display = 'none';
    elements.errorState.style.display = 'none';
    
    if (!alerts || alerts.length === 0) {
        elements.emptyState.style.display = 'block';
        return;
    }
    
    const sortedAlerts = [...alerts].sort((a, b) => 
        new Date(b.timestamp) - new Date(a.timestamp)
    );
    
    sortedAlerts.forEach(alert => {
        const card = createAlertCard(alert);
        elements.alertsContainer.appendChild(card);
    });
    
    updateStats(sortedAlerts);
}

function showError(message) {
    elements.alertsContainer.innerHTML = '';
    elements.emptyState.style.display = 'none';
    elements.errorState.style.display = 'block';
    elements.errorMessage.textContent = message;
    updateStatus('error', 'Connection error');
}

async function fetchAlerts() {
    if (isLoading) return;
    isLoading = true;
    
    try {
        const urls = [CONFIG.alertsUrl];
        if (CONFIG.alertsUrl !== GITHUB_URL) urls.push(GITHUB_URL);
        let response = null; let lastErr = null;
        for (const base of urls) {
            try {
                const url = `${base}?t=${Date.now()}`;
                response = await fetch(url, {
                    method: 'GET',
                    headers: { 'Cache-Control': 'no-cache, no-store, must-revalidate', 'Pragma': 'no-cache', 'Expires': '0' }
                });
                if (response.ok) break;
                lastErr = new Error(`HTTP ${response.status} en ${base}`);
                response = null;
            } catch (e) { lastErr = e; response = null; }
        }
        if (!response) throw lastErr || new Error('No se pudo cargar alerts.json (local ni GitHub).');
        
        const alerts = await response.json();
        lastFetchTime = new Date();
        renderAlerts(alerts);
        updateStatus('active', 'Live');
    } catch (error) {
        console.error('Error fetching alerts:', error);
        showError(error.message || 'Failed to load alerts.');
    } finally {
        isLoading = false;
    }
}

elements.refreshBtn.addEventListener('click', () => { fetchAlerts(); });

function init() {
    console.log('ðŸš€ Crypto Arbitrage Detector initializing...');
    
    fetchAlerts();
    setInterval(fetchAlerts, CONFIG.refreshInterval);
    setInterval(() => { updateLastFetchTime(); }, 1000);
    
    console.log(`âœ… Initialized. Refreshing every ${CONFIG.refreshInterval / 1000}s`);
}

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
} else {
    init();
}

