# AlgoTrade01 — MetaTrader 5 EA

`Experts/AlgoTrade01.mq5` implements the confirmed workflow.

## Confirmed workflow

For a BUY or SELL signal:

1. Open one `0.01` lot position.
2. The first position has a `$2` stop-loss amount. Its `$1` target is a **trigger**, so the first position stays open when it reaches `$1` profit.
3. At that `$1` first-position trigger, open 9 more positions in the same direction, each also `0.01` lots. The expected stack is:

```text
0.01 × 10 positions
```

4. Each `0.01` position has a `$2` stop loss. The stack is closed together when the combined floating basket profit reaches `$10`.
5. If any stack position hits its `$2` stop loss, the EA closes the remaining stack and reverses direction, opening the opposite call with the **same lot size as the position that hit SL**. For the current stack this is normally `0.01` lots.

The EA deliberately does not send a broker-side `$1` TP to the first position, because that would close it instead of keeping it open to trigger the 9 additional orders. The `$1` trigger and `$10` combined basket TP are managed by the EA. The `$2` stop loss is applied to every position.

## Controls

- **BUY** starts a BUY sequence.
- **SELL** starts a SELL sequence.
- **STOP** closes all positions belonging to this EA and stops the sequence.

## Inputs

- `InpOrderLots`: default `0.01`
- `InpStackOrders`: default `9`
- `InpTriggerProfit`: default `1.0`
- `InpBasketTakeProfit`: default `10.0`
- `InpStopLossPer001`: default `2.0`

All monetary values are in the MT5 account's deposit currency. `OrderCalcProfit()` is used to calculate symbol-specific price distances. A hedging account is recommended so the 10 positions remain separate.

## Installation

Copy `Experts/AlgoTrade01.mq5` into the terminal's `MQL5/Experts` folder, compile it in MetaEditor, attach it to a chart, and enable **Algo Trading**. Test on a demo account first. Errors and order results are printed in the Experts tab.
