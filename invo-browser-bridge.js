// Invo Chrome Extension / Tampermonkey / Console Script
// Este script se ejecuta en la pestaña de https://app.invoapp.com/notifications
// y envía automáticamente cualquier nueva notificación al bot local en http://localhost:3300/webhook/invo

(function() {
    console.log('[INVO-BRIDGE] Iniciando observador de notificaciones de Invo...');

    const processed = new Set();

    async function sendToBot(tradeData) {
        try {
            const res = await fetch('http://localhost:3300/webhook/invo', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(tradeData)
            });
            const data = await res.json();
            console.log('[INVO-BRIDGE] Trade enviado al bot local:', data);
        } catch (e) {
            console.error('[INVO-BRIDGE] Bot local no responde en http://localhost:3300. ¿Está encendido el .bat?');
        }
    }

    function checkNotifications() {
        // Buscar elementos de notificación en la página
        const textNodes = document.body.innerText;
        const lines = textNodes.split('\n');

        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim();
            // Detectar patrones como: "@henderson_14 opened new trade" o "opened new trade"
            if (line.includes('opened new trade') || line.includes('closed trade')) {
                const isClose = line.includes('closed trade');
                const traderMatch = line.match(/@([a-zA-Z0-9_]+)/) || (lines[i-1] && lines[i-1].match(/@([a-zA-Z0-9_]+)/));
                const trader = traderMatch ? traderMatch[1] : 'trader';
                const id = trader + '_' + (isClose ? 'close' : 'open') + '_' + line;

                if (!processed.has(id)) {
                    processed.add(id);
                    console.log(`[INVO-BRIDGE] ¡Nueva notificación detectada! Trader: @${trader} | Tipo: ${isClose ? 'CIERRE' : 'APERTURA'}`);
                    
                    sendToBot({
                        trader,
                        event: isClose ? 'CLOSED_TRADE' : 'OPENED_TRADE',
                        text: line,
                        timestamp: new Date().toISOString()
                    });
                }
            }
        }
    }

    setInterval(checkNotifications, 3000);
    console.log('[INVO-BRIDGE] Observador activo: revisando cada 3 segundos.');
})();
