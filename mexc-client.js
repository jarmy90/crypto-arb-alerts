const crypto = require('crypto');
const https = require('https');
const fs = require('fs');
const path = require('path');

// Cargar variables de entorno sin dependencias externas
try {
    const envPath = path.join(__dirname, '.env');
    if (fs.existsSync(envPath)) {
        const envLines = fs.readFileSync(envPath, 'utf8').split('\n');
        for (const line of envLines) {
            const trimmed = line.trim();
            if (!trimmed || trimmed.startsWith('#')) continue;
            const idx = trimmed.indexOf('=');
            if (idx > 0) {
                const k = trimmed.slice(0, idx).trim();
                const v = trimmed.slice(idx + 1).trim();
                process.env[k] = v;
            }
        }
    }
} catch (e) {
    console.error('Error cargando .env:', e.message);
}

const API_KEY = process.env.MEXC_API_KEY;
const SECRET_KEY = process.env.MEXC_SECRET_KEY;

if (!API_KEY || !SECRET_KEY) {
    console.error('ERROR: Credenciales MEXC_API_KEY y MEXC_SECRET_KEY no encontradas en .env');
    process.exit(1);
}

// Cliente HTTP Seguro para MEXC Futures
function mexcRequest(apiPath, method = 'GET', payload = null) {
    return new Promise((resolve, reject) => {
        const timestamp = Date.now();
        let signString = API_KEY + timestamp;
        let bodyStr = '';

        if (payload && (method === 'POST' || method === 'DELETE')) {
            bodyStr = JSON.stringify(payload);
            signString += bodyStr;
        } else if (apiPath.includes('?')) {
            const query = apiPath.split('?')[1];
            signString += query;
        }

        const signature = crypto.createHmac('sha256', SECRET_KEY).update(signString).digest('hex');

        const headers = {
            'ApiKey': API_KEY,
            'Request-Time': timestamp.toString(),
            'Signature': signature,
            'Content-Type': 'application/json',
            'User-Agent': 'Mozilla/5.0 InvoMexcCopyTrader'
        };

        const req = https.request({
            hostname: 'contract.mexc.com',
            path: apiPath,
            method,
            headers
        }, res => {
            let data = '';
            res.on('data', chunk => data += chunk);
            res.on('end', () => {
                try {
                    resolve(JSON.parse(data));
                } catch (e) {
                    resolve({ success: false, raw: data });
                }
            });
        });

        req.on('error', reject);
        if (bodyStr) req.write(bodyStr);
        req.end();
    });
}

// 1. Obtener balance de la cuenta de futuros
async function getAccountAssets() {
    const res = await mexcRequest('/api/v1/private/account/assets', 'GET');
    if (res && res.success && res.data) {
        return res.data.find(a => a.currency === 'USDT') || null;
    }
    return null;
}

// 2. Obtener posiciones abiertas
async function getOpenPositions(symbol = '') {
    const query = symbol ? `?symbol=${symbol}` : '';
    const res = await mexcRequest(`/api/v1/private/position/open_positions${query}`, 'GET');
    return (res && res.success) ? res.data : [];
}

// 3. Ajustar apalancamiento (Aislado)
async function setLeverage(symbol, leverage) {
    return await mexcRequest('/api/v1/private/position/change_leverage', 'POST', {
        symbol,
        leverage: Math.min(Math.max(leverage, 1), 20),
        openType: 1, // Isolated
        positionType: 1
    });
}

// 4. Obtener detalle de contrato
async function getContractDetail(symbol) {
    return new Promise((resolve) => {
        https.get(`https://contract.mexc.com/api/v1/contract/detail?symbol=${symbol}`, res => {
            let data = '';
            res.on('data', c => data += c);
            res.on('end', () => {
                try {
                    const parsed = JSON.parse(data);
                    resolve(parsed.data || null);
                } catch {
                    resolve(null);
                }
            });
        }).on('error', () => resolve(null));
    });
}

// 5. Obtener ticker de precio
async function getTicker(symbol) {
    return new Promise((resolve) => {
        https.get(`https://contract.mexc.com/api/v1/contract/ticker?symbol=${symbol}`, res => {
            let data = '';
            res.on('data', c => data += c);
            res.on('end', () => {
                try {
                    const parsed = JSON.parse(data);
                    resolve(parsed.data || null);
                } catch {
                    resolve(null);
                }
            });
        }).on('error', () => resolve(null));
    });
}

// 6. Enviar orden a mercado
async function submitMarketOrder(symbol, side, vol, leverage) {
    // side: 1 = open long, 3 = open short
    return await mexcRequest('/api/v1/private/order/submit', 'POST', {
        symbol,
        vol,
        leverage,
        side,
        type: 5, // Market
        openType: 1 // Isolated
    });
}

// 7. Configurar orden de Take Profit (Plan Order)
async function setTakeProfit(symbol, vol, isLong, tpPrice) {
    return await mexcRequest('/api/v1/private/planorder/place', 'POST', {
        symbol,
        vol,
        side: isLong ? 4 : 2, // 4: close long, 2: close short
        openType: 1,
        triggerType: isLong ? 1 : 2, // 1: >= triggerPrice, 2: <= triggerPrice
        triggerPrice: tpPrice,
        price: tpPrice,
        executeCycle: 24,
        trend: isLong ? 1 : 2,
        orderType: 2 // Limit trigger
    });
}

// 8. Configurar orden de Stop Loss (Plan Order)
async function setStopLoss(symbol, vol, isLong, slPrice) {
    return await mexcRequest('/api/v1/private/planorder/place', 'POST', {
        symbol,
        vol,
        side: isLong ? 4 : 2,
        openType: 1,
        triggerType: isLong ? 2 : 1, // 2: <= triggerPrice, 1: >= triggerPrice
        triggerPrice: slPrice,
        price: isLong ? parseFloat((slPrice * 0.995).toFixed(4)) : parseFloat((slPrice * 1.005).toFixed(4)),
        executeCycle: 24,
        trend: isLong ? 2 : 1,
        orderType: 2
    });
}

// 9. Cierre total inmediato de posición a mercado
async function closePositionMarket(symbol, vol, isLong) {
    return await mexcRequest('/api/v1/private/order/submit', 'POST', {
        symbol,
        vol,
        side: isLong ? 4 : 2, // 4: close long, 2: close short
        type: 5, // Market
        openType: 1
    });
}

// 10. Listar órdenes plan activas
async function getPlanOrders(symbol) {
    const res = await mexcRequest(`/api/v1/private/planorder/list/orders?symbol=${symbol}`, 'GET');
    return (res && res.success) ? res.data : [];
}

// 11. Cancelar orden plan
async function cancelPlanOrder(symbol, orderId) {
    return await mexcRequest('/api/v1/private/planorder/cancel', 'POST', [{
        symbol,
        orderId
    }]);
}

module.exports = {
    getAccountAssets,
    getOpenPositions,
    setLeverage,
    getContractDetail,
    getTicker,
    submitMarketOrder,
    setTakeProfit,
    setStopLoss,
    closePositionMarket,
    getPlanOrders,
    cancelPlanOrder
};
