# AlgoTrade01 — MetaTrader 5 EA

`Experts/AlgoTrade01.mq5` is a button-controlled MetaTrader 5 Expert Advisor (EA) implementing the requested AlgoTrade01 workflow.

## Controls

The EA adds three chart buttons:

- **BUY** — opens one 0.01-lot buy order.
- **SELL** — opens one 0.01-lot sell order.
- **STOP** — closes all positions opened by this EA and disables the current basket.

Only one basket can be active at a time. The EA identifies its positions using the configurable magic number (`InpMagic`).

## Workflow implemented

1. The first order is opened at `InpLots` (default `0.01`) with a 20-pip stop loss.
2. When the initial order reaches 20 pips of favorable movement, the EA requests nine more 0.01-lot orders in the same direction.
3. After scaling in, all EA positions close when the initial order retraces to +10 pips from its original entry price.
4. If the initial order's stop loss is hit at -20 pips, the remaining basket is closed and a new basket is opened in the opposite direction.
5. The same stop-loss reversal behavior applies to the next direction.

The 10-pip close is treated as a **retracement level after the +20-pip scale-in**, not as an immediate take-profit. This avoids closing the basket on the same tick that the nine additional orders are opened.

## Installation

1. Open MetaTrader 5 and choose **File → Open Data Folder**.
2. Copy `Experts/AlgoTrade01.mq5` into the terminal's `MQL5/Experts` directory.
3. Open MetaEditor, open the file, and press **Compile**.
4. Attach `AlgoTrade01` to the desired chart and enable **Algo Trading**.
5. Test in the Strategy Tester or a demo account before using live funds.

## Important limitations and settings

- The requested ten separate positions require a **hedging** MT5 account. A netting account aggregates positions, so it cannot represent ten independent 0.01-lot positions.
- The added positions do not receive individual broker-side stop losses; the EA manages the basket using the initial position's stop loss and its timer/tick logic. Keep the terminal and EA running.
- `InpScaleInPips`, `InpBasketClosePips`, `InpStopLossPips`, `InpLots`, `InpAddOrders`, and `InpReverseOnStopLoss` are inputs and can be changed when attaching the EA.
- “Pips” are calculated conventionally: one pip equals 10 points for 3/5-digit symbols and one point for 2/4-digit symbols.
- Broker minimum volume, volume step, margin, spread, market hours, and execution rules can cause an order to be rejected. The EA logs rejected orders in the Experts tab.
- This is an order-execution implementation, not financial advice. Validate behavior with a demo account and broker-specific symbol settings first.
