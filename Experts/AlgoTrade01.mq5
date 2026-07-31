//+------------------------------------------------------------------+
//| AlgoTrade01.mq5                                                  |
//| First-profit trigger -> 10-position basket -> combined TP        |
//+------------------------------------------------------------------+
#property strict
#property version "3.00"
#property description "0.01 trigger, add 9 x 0.01, close basket at $10, reverse at SL"

#include <Trade/Trade.mqh>

input double InpOrderLots          = 0.01;       // Every order volume
input int    InpStackOrders        = 9;          // Orders added after trigger
input double InpTriggerProfit      = 1.0;        // First-order trigger in account currency
input double InpBasketTakeProfit   = 10.0;       // Combined basket TP
input double InpStopLossPer001     = 2.0;        // SL per 0.01 lot
input ulong  InpMagic              = 20260731;   // EA magic number
input bool   InpReverseOnStopLoss  = true;       // Reverse after any EA SL
input int    InpDeviationPoints    = 20;         // Maximum price deviation

CTrade trade;
string PREFIX = "AT01_";
ulong initial_ticket = 0;
ulong initial_position_id = 0;
ENUM_POSITION_TYPE direction = WRONG_VALUE;
bool running = false;
bool stacked = false;
bool processing_exit = false;

// Converts account currency to a price distance using the symbol's real tick value.
double PriceDistanceForMoney(ENUM_ORDER_TYPE order_type, double volume, double money, double entry)
{
   if(money <= 0.0 || volume <= 0.0) return 0.0;
   double low = 0.0, high = 100.0 * _Point, profit = 0.0;
   for(int n = 0; n < 20; n++)
   {
      if(!OrderCalcProfit(order_type, _Symbol, volume, entry,
         order_type == ORDER_TYPE_BUY ? entry + high : entry - high, profit)) return 0.0;
      if(MathAbs(profit) >= money) break;
      high *= 2.0;
   }
   for(int n = 0; n < 50; n++)
   {
      double middle = (low + high) / 2.0;
      if(!OrderCalcProfit(order_type, _Symbol, volume, entry,
         order_type == ORDER_TYPE_BUY ? entry + middle : entry - middle, profit)) return 0.0;
      if(MathAbs(profit) < money) low = middle; else high = middle;
   }
   return NormalizeDouble((low + high) / 2.0, _Digits);
}

double MoneyStopLoss(ENUM_POSITION_TYPE type, double volume, double entry)
{
   ENUM_ORDER_TYPE order = type == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double money = InpStopLossPer001 * volume / 0.01;
   double distance = PriceDistanceForMoney(order, volume, money, entry);
   return NormalizeDouble(type == POSITION_TYPE_BUY ? entry - distance : entry + distance, _Digits);
}

bool IsOurPosition(ulong ticket)
{
   if(ticket == 0 || !PositionSelectByTicket(ticket)) return false;
   return PositionGetString(POSITION_SYMBOL) == _Symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic;
}

int OurPositionCount()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
      if(IsOurPosition(PositionGetTicket(i))) count++;
   return count;
}

double OurFloatingProfit()
{
   double total = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(IsOurPosition(ticket)) total += PositionGetDouble(POSITION_PROFIT);
   }
   return total;
}

void ResetState()
{
   initial_ticket = 0;
   initial_position_id = 0;
   direction = WRONG_VALUE;
   running = false;
   stacked = false;
}

void MakeButton(string name, string text, int x, color background)
{
   ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0))
   {
      Print("Could not create button ", name, ": ", GetLastError());
      return;
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 20);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, 90);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 30);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, background);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 100);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
   ChartRedraw(0);
}

bool ApplyStopLoss(ulong ticket)
{
   if(!IsOurPosition(ticket)) return false;
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = MoneyStopLoss(type, volume, entry);
   if(sl == 0.0)
   {
      Print("Could not calculate SL for ticket ", ticket);
      return false;
   }
   // TP is deliberately zero: the first order's $1 level is a trigger,
   // and the basket is closed only at the combined $10 target.
   if(!trade.PositionModify(ticket, sl, 0.0))
   {
      Print("Could not apply SL to ticket ", ticket, ": ", trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

bool CloseOurPositions()
{
   bool ok = true;
   for(int pass = 0; pass < 3; pass++)
   {
      for(int i = PositionsTotal() - 1; i >= 0; --i)
      {
         ulong ticket = PositionGetTicket(i);
         if(IsOurPosition(ticket) && !trade.PositionClose(ticket, InpDeviationPoints))
         {
            Print("Could not close ticket ", ticket, ": ", trade.ResultRetcodeDescription());
            ok = false;
         }
      }
      if(OurPositionCount() == 0) break;
   }
   return ok && OurPositionCount() == 0;
}

// Opens one 0.01 position. It is sent without stops first, then the actual fill
// price is used to set the $2 stop loss so spread/slippage cannot reject the entry.
bool OpenOne(ENUM_ORDER_TYPE order_type, bool is_initial)
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   bool sent = order_type == ORDER_TYPE_BUY
               ? trade.Buy(InpOrderLots, _Symbol, 0.0, 0.0, 0.0, "AT01|STACK")
               : trade.Sell(InpOrderLots, _Symbol, 0.0, 0.0, 0.0, "AT01|STACK");
   if(!sent)
   {
      Print("Order failed: ", trade.ResultRetcodeDescription());
      return false;
   }

   ulong found = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(IsOurPosition(ticket) && PositionGetString(POSITION_COMMENT) == "AT01|STACK")
      {
         // For additions, an unprotected position is the newly-created one.
         if(is_initial || PositionGetDouble(POSITION_SL) == 0.0)
         {
            found = ticket;
            break;
         }
      }
   }
   if(found == 0)
   {
      Print("Order filled but position could not be identified.");
      return false;
   }

   if(is_initial)
   {
      initial_ticket = found;
      PositionSelectByTicket(found);
      initial_position_id = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      direction = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   }
   ApplyStopLoss(found);
   return true;
}

void StartSignal(ENUM_ORDER_TYPE order_type)
{
   if(OurPositionCount() > 0)
   {
      Print("A basket is already active. Press STOP first.");
      return;
   }
   processing_exit = false;
   ResetState();
   if(OpenOne(order_type, true))
   {
      running = true;
      stacked = false;
      Print("Started ", direction == POSITION_TYPE_BUY ? "BUY" : "SELL",
            " 0.01 lot. Trigger=$", DoubleToString(InpTriggerProfit, 2),
            ", SL=$", DoubleToString(InpStopLossPer001 * InpOrderLots / 0.01, 2));
   }
}

void AddStack()
{
   int successful = 0;
   for(int i = 0; i < InpStackOrders; i++)
   {
      if(OpenOne(direction == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, false))
         successful++;
   }
   stacked = successful > 0;
   Print("Stack opened: ", successful, " additional positions; total expected ", successful + 1);
}

void ReverseAfterStop()
{
   if(processing_exit) return;
   processing_exit = true;
   ENUM_POSITION_TYPE old_direction = direction;
   CloseOurPositions();
   ResetState();
   if(InpReverseOnStopLoss)
      StartSignal(old_direction == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
   processing_exit = false;
}

void ManageStrategy()
{
   if(!running || initial_ticket == 0 || processing_exit) return;
   if(!IsOurPosition(initial_ticket)) return; // SL is handled by OnTradeTransaction.

   if(!stacked && PositionSelectByTicket(initial_ticket) &&
      PositionGetDouble(POSITION_PROFIT) >= InpTriggerProfit)
   {
      Print("Initial order reached $", DoubleToString(InpTriggerProfit, 2),
            ". Keeping it open and adding ", InpStackOrders, " more 0.01 orders.");
      AddStack();
   }

   if(stacked && OurFloatingProfit() >= InpBasketTakeProfit)
   {
      processing_exit = true;
      Print("Basket profit reached $", DoubleToString(OurFloatingProfit(), 2),
            ". Closing the entire stack.");
      CloseOurPositions();
      ResetState();
      processing_exit = false;
   }
}

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   MakeButton(PREFIX + "BUY", "BUY", 10, clrForestGreen);
   MakeButton(PREFIX + "SELL", "SELL", 110, clrFireBrick);
   MakeButton(PREFIX + "STOP", "STOP", 210, clrDarkOrange);
   EventSetTimer(1);
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("WARNING: A hedging account is recommended for 10 separate stack positions.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectDelete(0, PREFIX + "BUY");
   ObjectDelete(0, PREFIX + "SELL");
   ObjectDelete(0, PREFIX + "STOP");
}

void OnTick() { ManageStrategy(); }
void OnTimer() { ManageStrategy(); }

void OnTradeTransaction(const MqlTradeTransaction &transaction,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(transaction.type != TRADE_TRANSACTION_DEAL_ADD || transaction.deal == 0) return;
   ulong deal = transaction.deal;
   if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) return;
   if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic) return;
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;
   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON);
   if(reason == DEAL_REASON_SL) ReverseAfterStop();
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   Print("AlgoTrade01 button clicked: ", sparam);
   if(sparam == PREFIX + "BUY") StartSignal(ORDER_TYPE_BUY);
   else if(sparam == PREFIX + "SELL") StartSignal(ORDER_TYPE_SELL);
   else if(sparam == PREFIX + "STOP")
   {
      processing_exit = true;
      CloseOurPositions();
      ResetState();
      processing_exit = false;
      Print("AlgoTrade01 stopped by user.");
   }
}
//+------------------------------------------------------------------+
