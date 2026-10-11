# Reglas Oficiales de Copy Trading: Invo -> MEXC

Este documento establece las **normas operativas fijas** implementadas en el bot para replicar a los 20 mejores traders de Invo en la cuenta de futuros de MEXC.

---

## 1. Asignación de Capital (Bank: ~353 USDT)

- **Margen por Operación:** **5.0% del saldo operativo** (~$15.00 a $17.00 USDT por trade).
- **Máximo de Posiciones Simultáneas:** **5 posiciones** (para evitar sobreexposición si varios traders abren a la vez).
- **Reserva de Seguridad Intocable:** **20.0% del capital** (~$70.60 USDT) reservado para volatilidad, funding rates y drawdowns.
- **Tipo de Margen:** **Aislado (Isolated)** para proteger el resto de la cuenta.

---

## 2. Reglas de Take Profit (TP) y Stop Loss (SL)

### Caso A: El trader de Invo define TP y SL
- El bot extrae y replica sus precios exactos adaptados a los ticks y decimales del contrato de MEXC.

### Caso B: El trader NO define TP o SL (Protección Algorítmica Asimétrica 2:1)
- **Take Profit (TP):** **+10.0% de beneficio sobre el margen** (ROE).
- **Stop Loss (SL):** **-5.0% de pérdida máxima sobre el margen** (ROE).
- **Relación Beneficio / Riesgo:** **2 a 1**. Permite rentabilidad matemática incluso con una tasa de acierto del 40%.

### Caso C: Cierre Anticipado del Trader (*Follow Trader Exit*)
- Si el trader de Invo publica `closed trade` o retira la posición de *Open* antes de que el precio alcance el TP o SL, el bot **cancela las órdenes pendientes y cierra de inmediato a precio de mercado**.

---

## 3. Aclaración Técnica sobre Órdenes Condicionales en MEXC

En la interfaz de MEXC Futuros:
- Una orden de compra (`LONG`) abierta genera:
  1. **1 Posición Abierta en Long** (visible en la pestaña *Posiciones*).
  2. **1 Orden Plan de Venta para TP** (visible en la pestaña *Órdenes Plan / Condicionales* con precio superior).
  3. **1 Orden Plan de Venta para SL** (visible en la pestaña *Órdenes Plan / Condicionales* con precio inferior).

Ambas órdenes de venta tienen la etiqueta `Cerrar Long (side: 4)` y **no abren una posición corta**, sino que actúan como límites automáticos para asegurar ganancias o cortar pérdidas cuando el precio los toca.
