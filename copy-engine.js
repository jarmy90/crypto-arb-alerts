const fs = require('fs');
const path = require('path');
const mexc = require('./mexc-client');

// Archivos de estado local y público
const STATE_FILE = path.join(__dirname, 'data', 'copytrade_state.json');
const PUBLIC_LOG_FILE = path.join(__dirname, 'data', 'copytrade_log.json');

// Cargar o inicializar estado
function loadState() {
    try {
        if (fs.existsSync(STATE_FILE)) {
            return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
        }
    } catch {}
    return {
        processedNotificationIds: [],
        activeCopyTrades: {},
        tradeHistory: []
    };
}

function saveState(state) {
    try {
        if (!fs.existsSync(path.join(__dirname, 'data'))) {
            fs.mkdirSync(path.join(__dirname, 'data'), { recursive: true });
        }
        fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
        
        // Exportar vista pública ligera (para GitHub Pages / Web)
        const publicView = {
            lastUpdated: new Date().toISOString(),
            activePositionsCount: Object.keys(state.activeCopyTrades).length,
            activeTrades: state.activeCopyTrades,
            recentHistory: state.tradeHistory.slice(-10)
        };
        fs.writeFileSync(PUBLIC_LOG_FILE, JSON.stringify(publicView, null, 2));
    } catch (e) {
        console.error('Error guardando estado:', e.message);
    }
}

// Mapear símbolo de Invo a MEXC Futures
function resolveMexcSymbol(invoSymbol) {
    let clean = invoSymbol.toUpperCase().replace('$', '').replace('/', '_').trim();
    if (!clean.includes('_')) {
        clean = clean + '_USDT';
    }
    // Si viene como TOKEN_USDC y no existe directo, el equivalente perpetuo en MEXC suele ser TOKEN_USDT
    if (clean.endsWith('_USDC')) {
        clean = clean.replace('_USDC', '_USDT');
    }
    return clean;
}

// Ejecutar propuesta de Trade con normas fijadas
async function executeCopyTrade(tradeSignal) {
    const state = loadState();
    const mexcSymbol = resolveMexcSymbol(tradeSignal.symbol);

    console.log(`\n========================================`);
    console.log(`[SEÑAL RECIBIDA] Trader: ${tradeSignal.trader} | Par: ${mexcSymbol}`);
    console.log(`Dirección: ${tradeSignal.direction} | Leverage: ${tradeSignal.leverage || 3}X`);
    console.log(`========================================`);

    // 1. Verificar si ya tenemos posición activa en este símbolo
    const existing = await mexc.getOpenPositions(mexcSymbol);
    if (existing && existing.length > 0) {
        console.log(`[OMITIDO] Ya existe una posición abierta en ${mexcSymbol}. Evitando duplicidad.`);
        return { success: false, reason: 'ALREADY_OPEN' };
    }

    // 2. Comprobar límite de posiciones abiertas simultáneas (Máx 5)
    const allPositions = await mexc.getOpenPositions();
    if (allPositions.length >= 5) {
        console.log(`[OMITIDO] Límite de 5 posiciones simultáneas alcanzado. Posiciones abiertas: ${allPositions.length}`);
        return { success: false, reason: 'MAX_POSITIONS_REACHED' };
    }

    // 3. Consultar contrato y ticker en MEXC
    const contract = await mexc.getContractDetail(mexcSymbol);
    if (!contract || !contract.apiAllowed) {
        console.log(`[ERROR] Contrato ${mexcSymbol} no disponible en MEXC Futuros.`);
        return { success: false, reason: 'SYMBOL_NOT_FOUND' };
    }

    const ticker = await mexc.getTicker(mexcSymbol);
    if (!ticker || !ticker.lastPrice) {
        console.log(`[ERROR] No se pudo obtener precio para ${mexcSymbol}.`);
        return { success: false, reason: 'TICKER_ERROR' };
    }

    const currentPrice = parseFloat(ticker.lastPrice);
    const isLong = tradeSignal.direction.toUpperCase() === 'LONG';
    const leverage = Math.min(tradeSignal.leverage || 3, 10); // Máximo 10x por seguridad

    // 4. Calcular margen: Objetivo de $30 USDT por operación (aprox 8.5% del bank)
    const asset = await mexc.getAccountAssets();
    const availableBalance = asset ? parseFloat(asset.availableBalance) : 75;
    const targetMargin = Math.min(30.0, availableBalance * 0.40); // ~$30 USDT por trade

    if (targetMargin < 2.0) {
        console.log(`[ERROR] Saldo disponible insuficiente para abrir posición (Disponible: ${availableBalance} USDT).`);
        return { success: false, reason: 'INSUFFICIENT_FUNDS' };
    }

    const nominalValue = targetMargin * leverage;
    const contractSize = contract.contractSize || 1;
    let vol = Math.floor(nominalValue / (currentPrice * contractSize));
    if (vol < (contract.minVol || 1)) {
        vol = contract.minVol || 1;
    }

    console.log(`[CALCULADO] Margen: ~${targetMargin.toFixed(2)} USDT | Vol: ${vol} contratos | Precio: ${currentPrice}`);

    // 5. Ajustar apalancamiento
    await mexc.setLeverage(mexcSymbol, leverage);

    // 6. Enviar orden a mercado
    const side = isLong ? 1 : 3; // 1: open long, 3: open short
    const orderRes = await mexc.submitMarketOrder(mexcSymbol, side, vol, leverage);
    if (!orderRes || !orderRes.success) {
        console.log(`[ERROR ORDEN] Fallo al enviar orden a MEXC:`, orderRes);
        return { success: false, reason: orderRes ? orderRes.message : 'SUBMIT_ERROR' };
    }

    const orderId = orderRes.data;
    console.log(`[ORDEN EJECUTADA] MEXC Order ID: ${orderId}`);

    // 7. Calcular Take Profit: Objetivo de GANAR AL MENOS $10 DÓLARES (o el TP del trader si existe)
    const priceScale = contract.priceScale || 4;
    let tpPrice = 0;
    let slPrice = 0;

    if (tradeSignal.takeProfit && tradeSignal.stopLoss) {
        // Usar los valores del trader si los tiene
        tpPrice = parseFloat(tradeSignal.takeProfit.toFixed(priceScale));
        slPrice = parseFloat(tradeSignal.stopLoss.toFixed(priceScale));
    } else {
        // Objetivo: Ganar al menos +10.0 USDT en este trade
        // deltaPrecio = 10 / (vol * contractSize)
        const totalCoins = vol * contractSize;
        const deltaProfitPerCoin = 10.0 / totalCoins;
        
        // Stop Loss protector: limitado a max ~2.5 USDT de pérdida (ratio 4:1 a favor)
        const deltaLossPerCoin = 2.5 / totalCoins;

        if (isLong) {
            tpPrice = parseFloat((currentPrice + deltaProfitPerCoin).toFixed(priceScale));
            slPrice = parseFloat((currentPrice - deltaLossPerCoin).toFixed(priceScale));
        } else {
            tpPrice = parseFloat((currentPrice - deltaProfitPerCoin).toFixed(priceScale));
            slPrice = parseFloat((currentPrice + deltaLossPerCoin).toFixed(priceScale));
        }
    }

    console.log(`[OBJETIVO +$10 BENEFICIO] TP Fijado: ${tpPrice} | SL Protector: ${slPrice}`);

    // 8. Colocar órdenes de protección en MEXC
    let tpOrderId = null;
    let slOrderId = null;
    try {
        const tpRes = await mexc.setTakeProfit(mexcSymbol, vol, isLong, tpPrice);
        if (tpRes && tpRes.success) tpOrderId = tpRes.data;
        const slRes = await mexc.setStopLoss(mexcSymbol, vol, isLong, slPrice);
        if (slRes && slRes.success) slOrderId = slRes.data;
    } catch (e) {
        console.error('Error al colocar TP/SL:', e.message);
    }

    // 9. Guardar posición activa en el registro
    state.activeCopyTrades[mexcSymbol] = {
        trader: tradeSignal.trader,
        symbol: mexcSymbol,
        direction: tradeSignal.direction,
        leverage,
        entryPrice: currentPrice,
        vol,
        margin: targetMargin,
        tpPrice,
        slPrice,
        tpOrderId,
        slOrderId,
        openedAt: new Date().toISOString()
    };
    saveState(state);

    return { success: true, symbol: mexcSymbol, orderId, tpPrice, slPrice };
}

// Cierre automático si el trader cierra en Invo
async function handleTraderClose(invoSymbol, trader) {
    const mexcSymbol = resolveMexcSymbol(invoSymbol);
    const state = loadState();

    if (!state.activeCopyTrades[mexcSymbol]) {
        return; // No tenemos copiado ese trade
    }

    const trade = state.activeCopyTrades[mexcSymbol];
    console.log(`[CIERRE DETECTADO EN INVO] El trader ${trader} cerró ${mexcSymbol}. Ejecutando cierre inmediato en MEXC...`);

    const isLong = trade.direction.toUpperCase() === 'LONG';
    const closeRes = await mexc.closePositionMarket(mexcSymbol, trade.vol, isLong);

    // Cancelar órdenes plan de TP/SL pendientes
    if (trade.tpOrderId) await mexc.cancelPlanOrder(mexcSymbol, trade.tpOrderId);
    if (trade.slOrderId) await mexc.cancelPlanOrder(mexcSymbol, trade.slOrderId);

    // Mover a historial
    trade.closedAt = new Date().toISOString();
    trade.closeReason = 'TRADER_MANUALLY_CLOSED';
    state.tradeHistory.push(trade);
    delete state.activeCopyTrades[mexcSymbol];
    saveState(state);

    console.log(`[POSICIÓN CERRADA] ${mexcSymbol} cerrada con éxito en MEXC.`);
}

module.exports = {
    loadState,
    saveState,
    executeCopyTrade,
    handleTraderClose,
    resolveMexcSymbol
};
