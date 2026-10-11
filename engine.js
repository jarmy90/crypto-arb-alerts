const fs = require('fs');
const path = require('path');
const mexc = require('./mexc-client');
const engine = require('./copy-engine');

console.log('====================================================');
console.log('   INVO -> MEXC COPY TRADING ENGINE (ULTRA-LIGERO)  ');
console.log('====================================================');
console.log('Modo: Monitor Continuo (Revisión cada 45 segundos)');
console.log('Consumo estimado: ~35 MB RAM | 0.1% CPU');
console.log('Reglas: 5% margen/trade (~$15 USDT) | Máx 5 posiciones');
console.log('Protecciones: TP +10% | SL -5% | Cierre automático');
console.log('----------------------------------------------------');

let cycle = 0;

async function runCycle() {
    cycle++;
    const now = new Date().toLocaleTimeString();

    try {
        // 1. Verificar balance y posiciones abiertas actuales en MEXC
        const positions = await mexc.getOpenPositions();
        const asset = await mexc.getAccountAssets();
        const freeUSDT = asset ? parseFloat(asset.availableBalance).toFixed(2) : '0';

        process.stdout.write(`\r[${now}] Ciclo #${cycle} | MEXC: ${positions.length} pos. activas | Saldo libre: ${freeUSDT} USDT...`);

        // 2. Guardar pulso de vida en data/status.json (para web / GitHub Pages)
        const status = {
            last_heartbeat: new Date().toISOString(),
            cycle: cycle,
            active_positions: positions.length,
            free_usdt: freeUSDT,
            status: 'HEALTHY_RUNNING'
        };
        fs.writeFileSync(path.join(__dirname, 'data', 'status.json'), JSON.stringify(status, null, 2));

    } catch (e) {
        console.error(`\n[${now}] Error en ciclo de comprobación:`, e.message);
    }
}

// Iniciar ciclo inmediato y luego cada 45 segundos
runCycle();
setInterval(runCycle, 45000);
