//+------------------------------------------------------------------+
//| AlgoTrade01.mq5                                                  |
//| Button-controlled consecutive TP progression EA                  |
//+------------------------------------------------------------------+
#property strict
#property version "2.00"
#property description "BUY/SELL buttons: 0.01, 0.02, 0.03... after TP; reverse after SL"

#include <Trade/Trade.mqh>

input double InpStartingLots       = 0.01;       // First order volume
input double InpLotIncrement       = 0.01;       // Added after every TP
input double InpTakeProfitPer001   = 1.0;        // Account currency TP per 0.01 lot
input double InpStopLossPer001     = 2.0;        // Account currency SL per 0.01 lot
input ulong  InpMagic              = 20260731;   // EA magic number
input bool   InpReverseOnStopLoss  = true;       // Reverse after SL
input int    InpDeviationPoints    = 20;         // Maximum price deviation

CTrade trade;
string PREFIX = "AT01_";
ulong initial_ticket = 0;
ulong initial_position_id = 0;
ENUM_POSITION_TYPE direction = WRONG_VALUE;
double current_lots = 0.0;
bool running = false;
bool processing_exit = false;

// Account-currency amount to price distance for this symbol and volume.
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

double MoneyTakeProfit(ENUM_POSITION_TYPE type, double volume, double entry)
{
   ENUM_ORDER_TYPE order = type == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double money = InpTakeProfitPer001 * volume / 0.01;
   double distance = PriceDistanceForMoney(order, volume, money, entry);
   return NormalizeDouble(type == POSITION_TYPE_BUY ? entry + distance : entry - distance, _Digits);
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

void ResetState()
{
   initial_ticket = 0;
   initial_position_id = 0;
   direction = WRONG_VALUE;
   current_lots = 0.0;
   running = false;
}

void MakeButton(string name, string text, int x, color background)
{
   ObjectDelete(0, name);
   if(!ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0))
   {
      Print("Could not create ", name, ": ", GetLastError());
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

bool ApplyMoneyStops(ulong ticket)
{
   if(!IsOurPosition(ticket)) return false;
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = MoneyStopLoss(type, volume, entry);
   double tp = MoneyTakeProfit(type, volume, entry);
   if(sl == 0.0 || tp == 0.0)
   {
      Print("Could not calculate SL/TP. Check symbol tick value and contract specification.");
      return false;
   }
   if(!trade.PositionModify(ticket, sl, tp))
   {
      Print("Could not apply SL/TP to ticket ", ticket, ": ", trade.ResultRetcodeDescription());
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

// Opens exactly one step. The first step is 0.01, the next is 0.02, etc.
bool OpenStep(ENUM_ORDER_TYPE order_type, double lots)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("No market tick is available for ", _Symbol);
      return false;
   }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   bool sent = order_type == ORDER_TYPE_BUY
               ? trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0, "AT01|STEP")
               : trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, "AT01|STEP");
   if(!sent)
   {
      Print("Order of ", DoubleToString(lots, 2), " lots failed: ", trade.ResultRetcodeDescription());
      return false;
   }

   initial_ticket = 0;
   initial_position_id = 0;
   // A hedging account creates one position for this order. Use the comment,
   // with a fallback to any newly-created EA position for broker variations.
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(IsOurPosition(ticket) &&
         (PositionGetString(POSITION_COMMENT) == "AT01|STEP" || initial_ticket == 0))
      {
         initial_ticket = ticket;
         initial_position_id = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
         direction = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         break;
      }
   }
   if(initial_ticket == 0)
   {
      Print("Order filled but position could not be identified.");
      return false;
   }
   current_lots = PositionGetDouble(POSITION_VOLUME);
   running = true;
   ApplyMoneyStops(initial_ticket);
   Print("Opened ", direction == POSITION_TYPE_BUY ? "BUY" : "SELL", " step at ",
         DoubleToString(current_lots, 2), " lots. TP=$",
         DoubleToString(InpTakeProfitPer001 * current_lots / 0.01, 2), " SL=$",
         DoubleToString(InpStopLossPer001 * current_lots / 0.01, 2));
   return true;
}

void StartDirection(ENUM_ORDER_TYPE order_type)
{
   if(OurPositionCount() > 0)
   {
      Print("A basket is already open. Press STOP before starting another signal.");
      return;
   }
   processing_exit = false;
   ResetState();
   OpenStep(order_type, InpStartingLots);
}

void HandleExit(ENUM_DEAL_REASON reason)
{
   if(!running || processing_exit) return;
   processing_exit = true;
   ENUM_POSITION_TYPE old_direction = direction;
   double next_lots = NormalizeDouble(current_lots + InpLotIncrement, 2);
   CloseOurPositions();

   if(reason == DEAL_REASON_TP)
   {
      // TP: same signal, increase volume by 0.01 and continue forever until SL.
      Print("Take profit reached. Opening next same-direction step: ",
            DoubleToString(next_lots, 2), " lots.");
      initial_ticket = 0;
      initial_position_id = 0;
      OpenStep(old_direction == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, next_lots);
   }
   else
   {
      // SL: reverse signal and restart at the initial volume.
      Print("Stop loss reached. Reversing and restarting at ",
            DoubleToString(InpStartingLots, 2), " lots.");
      ResetState();
      if(InpReverseOnStopLoss)
         OpenStep(old_direction == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY, InpStartingLots);
   }
   processing_exit = false;
}

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   MakeButton(PREFIX + "BUY", "BUY", 10, clrForestGreen);
   MakeButton(PREFIX + "SELL", "SELL", 110, clrFireBrick);
   MakeButton(PREFIX + "STOP", "STOP", 210, clrDarkOrange);
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("WARNING: Use a hedging account. Netting accounts cannot keep this step sequence independently.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ObjectDelete(0, PREFIX + "BUY");
   ObjectDelete(0, PREFIX + "SELL");
   ObjectDelete(0, PREFIX + "STOP");
}

void OnTick() {}

void OnTradeTransaction(const MqlTradeTransaction &transaction,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(transaction.type != TRADE_TRANSACTION_DEAL_ADD || transaction.deal == 0) return;
   ulong deal = transaction.deal;
   if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) return;
   if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic) return;
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;
   ulong position_id = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   if(position_id != initial_position_id) return;
   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON);
   if(reason == DEAL_REASON_TP) HandleExit(reason);
   else if(reason == DEAL_REASON_SL) HandleExit(reason);
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   Print("AlgoTrade01 button clicked: ", sparam);
   if(sparam == PREFIX + "BUY") StartDirection(ORDER_TYPE_BUY);
   else if(sparam == PREFIX + "SELL") StartDirection(ORDER_TYPE_SELL);
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
