# AlgoTrade01 — MetaTrader 5 EA

`Experts/AlgoTrade01.mq5` is a button-controlled MetaTrader 5 Expert Advisor implementing consecutive lot progression.

## Exact trading behavior

- Clicking **BUY** opens a buy order of `0.01` lots.
- Clicking **SELL** opens a sell order of `0.01` lots.
- Every order has a monetary TP of `$1 per 0.01 lot` and SL of `$2 per 0.01 lot`.
- When the order reaches TP, the EA immediately opens another order in the **same direction**, increasing volume by `0.01`:
  - `0.01` → TP `$1`, SL `$2`
  - `0.02` → TP `$2`, SL `$4`
  - `0.03` → TP `$3`, SL `$6`
  - `0.04` → TP `$4`, SL `$8`
- This continues consecutively in the same direction until an order hits SL.
- When SL is hit, the EA reverses direction and restarts at `0.01` lots.
- Clicking **STOP** closes the EA's positions and stops the sequence.

The EA uses `OnTradeTransaction()` and checks the broker's actual deal reason (`DEAL_REASON_TP` or `DEAL_REASON_SL`) so a TP advances the lot size while an SL reverses the signal. Monetary price distances are calculated with `OrderCalcProfit()` using the symbol's tick value, contract size, and account currency.

## Installation

1. Open MetaTrader 5 and select **File → Open Data Folder**.
2. Copy `Experts/AlgoTrade01.mq5` into `MQL5/Experts`.
3. Open the file in MetaEditor and press **Compile**.
4. Attach the EA to a chart and enable **Algo Trading**.
5. Test on a demo account first.

## Important notes

- A hedging account is recommended. The progression is designed as one active position at a time; netting accounts are supported for this one-position sequence, but account/broker rules still apply.
- The values are in the account's deposit currency. If the account currency is USD, they are dollar amounts.
- The broker must permit the requested volume, volume step, margin, and stop distance. Errors are printed in the Experts tab.
- If the EA is removed or the terminal is disconnected while an order is open, it cannot react to the next TP/SL until it is running again.
- This is an execution implementation, not financial advice. Validate it with the Strategy Tester and a demo account before live trading.
