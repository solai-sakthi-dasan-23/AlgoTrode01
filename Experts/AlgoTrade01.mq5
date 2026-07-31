//+------------------------------------------------------------------+
//| AlgoTrade01.mq5                                                  |
//| Button-controlled basket strategy for MetaTrader 5                |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Buy/Sell/Stop button EA with 20-pip scale-in and reversal"

#include <Trade/Trade.mqh>

input double InpLots                 = 0.01;       // Lot size for every order
input int    InpScaleInPips          = 20;         // Add orders at this profit
input int    InpBasketClosePips      = 10;         // Close basket after retrace to this level
input double InpTakeProfitPer001     = 1.0;        // Take profit in account currency per 0.01 lot
input double InpStopLossPer001       = 2.0;        // Stop loss in account currency per 0.01 lot
input int    InpAddOrders            = 9;          // Number of additional orders
input ulong  InpMagic                = 20260731;   // EA magic number
input bool   InpReverseOnStopLoss    = true;       // Reverse after the initial SL
input int    InpDeviationPoints      = 20;         // Maximum price deviation

CTrade trade;
string PREFIX = "AT01_";
ulong  initial_ticket = 0;
ENUM_POSITION_TYPE direction = WRONG_VALUE;
double initial_price = 0.0;
bool   scaled_in = false;
bool   running = false;
bool   intentional_stop = false;
bool   hedging_warning_shown = false;

// One pip is 10 points on the usual 5/3 digit symbols.
double Pip()
{
   return (_Digits == 3 || _Digits == 5) ? 10.0 * _Point : _Point;
}

// Converts an account-currency amount into a price distance for this symbol and volume.
// OrderCalcProfit makes this work for forex, metals, indices and CFDs with different
// tick values. The result is in the account's deposit currency.
double PriceDistanceForMoney(ENUM_ORDER_TYPE order_type, double volume, double money, double entry)
{
   if(money <= 0.0 || volume <= 0.0) return 0.0;
   double low = 0.0;
   double high = 100.0 * _Point;
   double profit = 0.0;
   for(int n = 0; n < 20 && OrderCalcProfit(order_type, _Symbol, volume, entry,
      order_type == ORDER_TYPE_BUY ? entry + high : entry - high, profit) &&
      MathAbs(profit) < money; n++)
      high *= 2.0;

   for(int n = 0; n < 50; n++)
   {
      double middle = (low + high) / 2.0;
      if(!OrderCalcProfit(order_type, _Symbol, volume, entry,
         order_type == ORDER_TYPE_BUY ? entry + middle : entry - middle, profit))
         return 0.0;
      if(MathAbs(profit) < money) low = middle;
      else high = middle;
   }
   return NormalizeDouble((low + high) / 2.0, _Digits);
}

double MoneyStopLoss(ENUM_POSITION_TYPE type, double volume, double entry)
{
   ENUM_ORDER_TYPE order = type == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double d = PriceDistanceForMoney(order, volume, InpStopLossPer001 * volume / 0.01, entry);
   return NormalizeDouble(type == POSITION_TYPE_BUY ? entry - d : entry + d, _Digits);
}

double MoneyTakeProfit(ENUM_POSITION_TYPE type, double volume, double entry)
{
   ENUM_ORDER_TYPE order = type == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double d = PriceDistanceForMoney(order, volume, InpTakeProfitPer001 * volume / 0.01, entry);
   return NormalizeDouble(type == POSITION_TYPE_BUY ? entry + d : entry - d, _Digits);
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
   {
      ulong ticket = PositionGetTicket(i);
      if(IsOurPosition(ticket)) count++;
   }
   return count;
}

void ResetState()
{
   initial_ticket = 0;
   direction = WRONG_VALUE;
   initial_price = 0.0;
   scaled_in = false;
   running = false;
}

void MakeButton(string name, string text, int x, color background)
{
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 20);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, 90);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 30);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, background);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrWhite);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
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

bool OpenInitial(ENUM_ORDER_TYPE order_type)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return false;
   double price = order_type == ORDER_TYPE_BUY ? tick.ask : tick.bid;
   ENUM_POSITION_TYPE position_type = order_type == ORDER_TYPE_BUY ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   double sl = MoneyStopLoss(position_type, InpLots, price);
   double tp = MoneyTakeProfit(position_type, InpLots, price);
   string comment = "AT01|INIT";

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   bool sent = order_type == ORDER_TYPE_BUY
               ? trade.Buy(InpLots, _Symbol, 0.0, sl, tp, comment)
               : trade.Sell(InpLots, _Symbol, 0.0, sl, tp, comment);
   if(!sent)
   {
      Print("Initial order failed: ", trade.ResultRetcodeDescription());
      return false;
   }

   // The position ticket is obtained from the position comment/magic after execution.
   initial_ticket = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(IsOurPosition(ticket) && PositionGetString(POSITION_COMMENT) == comment)
      {
         initial_ticket = ticket;
         initial_price = PositionGetDouble(POSITION_PRICE_OPEN);
         direction = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         break;
      }
   }
   if(initial_ticket == 0)
   {
      Print("Order filled, but its initial position could not be identified.");
      CloseOurPositions();
      return false;
   }
   running = true;
   scaled_in = false;
   Print("Started ", direction == POSITION_TYPE_BUY ? "BUY" : "SELL", " at ", initial_price);
   return true;
}

void StartDirection(ENUM_ORDER_TYPE order_type)
{
   intentional_stop = false;
   if(OurPositionCount() > 0)
   {
      Print("A strategy basket is already open. Press Stop first to replace it.");
      return;
   }
   ResetState();
   OpenInitial(order_type);
}

void ScaleIn()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   for(int i = 0; i < InpAddOrders; i++)
   {
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick)) continue;
      double entry = direction == POSITION_TYPE_BUY ? tick.ask : tick.bid;
      double sl = MoneyStopLoss(direction, InpLots, entry);
      double tp = MoneyTakeProfit(direction, InpLots, entry);
      bool sent = direction == POSITION_TYPE_BUY
                  ? trade.Buy(InpLots, _Symbol, 0.0, sl, tp, "AT01|ADD")
                  : trade.Sell(InpLots, _Symbol, 0.0, sl, tp, "AT01|ADD");
      if(!sent) Print("Scale-in order ", i + 1, " failed: ", trade.ResultRetcodeDescription());
   }
   scaled_in = true;
   Print("Scale-in complete: requested ", InpAddOrders, " additional orders.");
}

void ManageStrategy()
{
   if(!running || initial_ticket == 0) return;

   // If the initial position disappears, its broker-side SL was most likely hit.
   if(!IsOurPosition(initial_ticket))
   {
      if(!intentional_stop)
      {
         // A broker TP can close the initial order before scale-in. Do not
         // mistake that profitable exit for a stop-loss reversal.
         MqlTick exit_tick;
         double exit_profit = -DBL_MAX;
         if(SymbolInfoTick(_Symbol, exit_tick))
         {
            double exit_price = direction == POSITION_TYPE_BUY ? exit_tick.bid : exit_tick.ask;
            double calculated = 0.0;
            ENUM_ORDER_TYPE order = direction == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
            if(OrderCalcProfit(order, _Symbol, InpLots, initial_price, exit_price, calculated))
               exit_profit = calculated;
         }
         // Save the direction before ResetState() clears it.
         ENUM_POSITION_TYPE stopped_direction = direction;
         CloseOurPositions();
         ResetState();
         if(exit_profit >= InpTakeProfitPer001 * InpLots / 0.01 * 0.9)
            Print("Initial order reached its monetary take profit; basket closed without reversal.");
         else
         {
            Print("Initial position closed at a loss (normally its stop loss); reversing.");
            if(InpReverseOnStopLoss)
               OpenInitial(stopped_direction == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
         }
      }
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double favorable = direction == POSITION_TYPE_BUY ? tick.bid - initial_price : initial_price - tick.ask;
   double pips = favorable / Pip();

   if(!scaled_in && pips >= InpScaleInPips)
      ScaleIn();
   else if(scaled_in && pips <= InpBasketClosePips)
   {
      Print("Initial order retraced to ", DoubleToString(pips, 1), " pips; closing basket.");
      CloseOurPositions();
      ResetState();
   }
}

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   MakeButton(PREFIX + "BUY",  "BUY",  10, clrForestGreen);
   MakeButton(PREFIX + "SELL", "SELL", 110, clrFireBrick);
   MakeButton(PREFIX + "STOP", "STOP", 210, clrDarkOrange);
   EventSetTimer(1);
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("WARNING: This strategy requires a hedging account to keep 10 separate positions. Netting accounts aggregate orders.");
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

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   if(sparam == PREFIX + "BUY") StartDirection(ORDER_TYPE_BUY);
   else if(sparam == PREFIX + "SELL") StartDirection(ORDER_TYPE_SELL);
   else if(sparam == PREFIX + "STOP")
   {
      intentional_stop = true;
      CloseOurPositions();
      ResetState();
      Print("AlgoTrade01 stopped by user.");
   }
}
//+------------------------------------------------------------------+
