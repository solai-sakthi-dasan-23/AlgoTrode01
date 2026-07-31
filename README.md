# AlgoTrade01 — MetaTrader 5 EA

`Experts/AlgoTrade01.mq5` is a button-controlled MetaTrader 5 Expert Advisor (EA) implementing the requested AlgoTrade01 workflow.

## Controls

The EA adds three chart buttons:

- **BUY** — opens one 0.01-lot buy order.
- **SELL** — opens one 0.01-lot sell order.
- **STOP** — closes all positions opened by this EA and disables the current basket.

Only one basket can be active at a time. The EA identifies its positions using the configurable magic number (`InpMagic`).

## Workflow implemented

1. The first order is opened at `InpLots` (default `0.01`). Each order receives a monetary stop loss of `$2 per 0.01 lot` and take profit of `$1 per 0.01 lot`.
2. When the initial order reaches 20 pips of favorable movement, the EA requests nine more 0.01-lot orders in the same direction. Each additional order receives the same proportional monetary levels.
3. Therefore, a 0.01-lot order has `$1` TP / `$2` SL; a 0.02-lot order would have `$2` TP / `$4` SL; a 0.03-lot order would have `$3` TP / `$6` SL, and so on. The current basket uses ten separate 0.01-lot orders as requested.
4. If the initial order's stop loss is hit, the remaining basket is closed and a new basket is opened in the opposite direction.
5. The same stop-loss reversal behavior applies to the next direction.

Monetary distances are calculated using MT5 `OrderCalcProfit`, so they adapt to the symbol's tick value, contract size, exchange rate, and account currency. The EA retains the 20-pip scale-in trigger from the original workflow.

## Installation

1. Open MetaTrader 5 and choose **File → Open Data Folder**.
2. Copy `Experts/AlgoTrade01.mq5` into the terminal's `MQL5/Experts` directory.
3. Open MetaEditor, open the file, and press **Compile**.
4. Attach `AlgoTrade01` to the desired chart and enable **Algo Trading**.
5. Test in the Strategy Tester or a demo account before using live funds.

## Important limitations and settings

- The requested ten separate positions require a **hedging** MT5 account. A netting account aggregates positions, so it cannot represent ten independent 0.01-lot positions.
- Every order receives its own broker-side SL/TP. The monetary inputs are `InpTakeProfitPer001` (default `$1`) and `InpStopLossPer001` (default `$2`) for each 0.01 lot.
- Because the initial order now has a `$1` take profit, it may reach its TP before the original 20-pip scale-in trigger on some symbols. If you want scaling to occur first, the TP behavior and scale-in trigger need to be defined as a combined basket rule.
- `InpScaleInPips`, `InpBasketClosePips`, `InpLots`, `InpAddOrders`, and `InpReverseOnStopLoss` are inputs and can be changed when attaching the EA.
- “Pips” are calculated conventionally: one pip equals 10 points for 3/5-digit symbols and one point for 2/4-digit symbols; the dollar SL/TP itself is calculated separately from the symbol specification.
- Broker minimum volume, volume step, margin, spread, market hours, and execution rules can cause an order to be rejected. The EA logs rejected orders in the Experts tab.
- This is an order-execution implementation, not financial advice. Validate behavior with a demo account and broker-specific symbol settings first.
