const fs = require('fs');
const http = require('http');
const path = require('path');
const mexc = require('./mexc-client');
const engine = require('./copy-engine');

console.log('====================================================');
console.log('   INVO -> MEXC COPY TRADING ENGINE (ULTRA-LIGERO)  ');
console.log('====================================================');
console.log('Modo: Monitor Continuo + Puente Webhook en Localhost:3300');
console.log('Consumo estimado: ~35 MB RAM | 0.1% CPU');
console.log('Reglas: Margen $30 USDT | Objetivo Mínimo +10$ por trade');
console.log('Protecciones: SL protector $2.50 | Cierre automático');
console.log('----------------------------------------------------');

let cycle = 0;
let lastNotificationSeen = 'Esperando primera señal...';

// Servidor ultra-ligero para recibir notificaciones desde la pestaña de Chrome
const server = http.createServer((req, res) => {
    // Permitir CORS para que la pestaña de invoapp.com pueda comunicarse con localhost
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') {
        res.writeHead(204);
        res.end();
        return;
    }

    if (req.url === '/webhook/invo' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', async () => {
            try {
                const data = JSON.parse(body);
                const now = new Date().toLocaleTimeString();
                lastNotificationSeen = `[${now}] @${data.trader}: ${data.event}`;
                console.log(`\n🔔 [NOTIFICACIÓN RECIBIDA EN VIVO] ${lastNotificationSeen}`);

                if (data.event === 'OPENED_TRADE') {
                    // Extraer o procesar apertura
                    // Si trae el símbolo lo ejecuta directamente
                    if (data.symbol) {
                        await engine.executeCopyTrade({
                            trader: data.trader,
                            symbol: data.symbol,
                            direction: data.direction || 'LONG',
                            leverage: data.leverage || 5
                        });
                    }
                } else if (data.event === 'CLOSED_TRADE' && data.symbol) {
                    await engine.handleTraderClose(data.symbol, data.trader);
                }

                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ status: 'OK', received: true }));
            } catch (err) {
                res.writeHead(400);
                res.end(JSON.stringify({ error: err.message }));
            }
        });
        return;
    }

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'BOT_RUNNING', lastNotification: lastNotificationSeen }));
});

const PORT = 3300;
server.listen(PORT, '127.0.0.1', () => {
    console.log(`[PUENTE ACTIVO] Escuchando notificaciones en http://localhost:${PORT}`);
});

async function runCycle() {
    cycle++;
    const now = new Date().toLocaleTimeString();

    try {
        const positions = await mexc.getOpenPositions();
        const asset = await mexc.getAccountAssets();
        const freeUSDT = asset ? parseFloat(asset.availableBalance).toFixed(2) : '0';

        process.stdout.write(`\r[${now}] Ciclo #${cycle} | MEXC: ${positions.length} pos. activas | Saldo: ${freeUSDT} USDT | Última Notificación: ${lastNotificationSeen}`);

        const status = {
            last_heartbeat: new Date().toISOString(),
            cycle: cycle,
            active_positions: positions.length,
            free_usdt: freeUSDT,
            last_notification: lastNotificationSeen,
            status: 'HEALTHY_RUNNING'
        };
        fs.writeFileSync(path.join(__dirname, 'data', 'status.json'), JSON.stringify(status, null, 2));

    } catch (e) {
        console.error(`\n[${now}] Error en ciclo:`, e.message);
    }
}

runCycle();
setInterval(runCycle, 15000); // Revisión rápida cada 15 segundos
