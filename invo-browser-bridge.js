// Invo Complete Trade Sniffer & Auto-Executor
// Se ejecuta directamente en la pestaña de https://app.invoapp.com/
// Lee directamente las notificaciones y los clics en tarjetas de trade para enviar símbolo, dirección, apalancamiento y TP

(function() {
    console.log('[INVO-AUTOBRIDGE v2.0] Iniciado en app.invoapp.com');

    const processed = new Set();

    async function sendTrade(trade) {
        try {
            console.log('[INVO-AUTOBRIDGE] Enviando operación a MEXC vía bot local:', trade);
            const res = await fetch('http://localhost:3300/webhook/invo', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(trade)
            });
            const data = await res.json();
            console.log('[INVO-AUTOBRIDGE] Respuesta de MEXC:', data);
        } catch (e) {
            console.warn('[INVO-AUTOBRIDGE] Asegúrate de que el archivo INICIAR_BOT.bat esté abierto en tu portátil.');
        }
    }

    // 1. Escaneo inteligente del DOM cada 2 segundos
    setInterval(() => {
        const fullText = document.body.innerText;
        
        // Detectar si estamos en la tarjeta de un trade (como AZTEC, GRASS, SOL...)
        const lines = fullText.split('\n').map(l => l.trim()).filter(Boolean);

        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];

            // Patrón: "AZTEC 3X" o "$SOL 5X" o "BTC 10X"
            const matchToken = line.match(/^(\$?[A-Z0-9]{2,10})\s+([0-9]+)X$/i);
            if (matchToken) {
                const rawSym = matchToken[1].replace('$', '').toUpperCase();
                const lev = parseInt(matchToken[2], 10);
                
                // Buscar precio actual, TP y dirección
                let tp = 0;
                let isShort = false;

                // Revisar siguientes 10 líneas
                for (let j = i; j < Math.min(lines.length, i + 15); j++) {
                    if (lines[j].toLowerCase().includes('take-profit') && lines[j+1]) {
                        const tpMatch = lines[j+1].match(/[\$]?([0-9\.]+)/);
                        if (tpMatch) tp = parseFloat(tpMatch[1]);
                    }
                }

                // Obtener precio de apertura
                const priceMatch = (lines[i+1] || '').match(/[\$]?([0-9\.]+)/);
                const currentP = priceMatch ? parseFloat(priceMatch[1]) : 0;
                if (tp > 0 && currentP > 0) {
                    if (tp < currentP) isShort = true; // Si TP es menor que entrada -> SHORT
                }

                const tradeKey = `${rawSym}_${lev}_${tp}_${lines.slice(0, 5).join('_')}`;
                if (!processed.has(tradeKey)) {
                    processed.add(tradeKey);
                    console.log(`[TRADE ENCONTRADO EN PANTALLA] Par: ${rawSym} | Lev: ${lev}X | Dirección: ${isShort ? 'SHORT' : 'LONG'} | TP: ${tp}`);
                    sendTrade({
                        trader: 'InvoTrader',
                        symbol: rawSym + '_USDT',
                        direction: isShort ? 'SHORT' : 'LONG',
                        leverage: lev,
                        takeProfit: tp > 0 ? tp : null,
                        event: 'OPENED_TRADE'
                    });
                }
            }
        }
    }, 2000);

    console.log('[INVO-AUTOBRIDGE v2.0] ✅ Escaneando trades y notificaciones.');
})();
