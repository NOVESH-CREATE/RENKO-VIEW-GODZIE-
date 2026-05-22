//+------------------------------------------------------------------+
//|                                                     Renko_EMA.mq5 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

// Input parameters
input double      BoxSize          = 5.0;
input double      FixedSLBuffer    = 1.0;
input int         NumBricks        = 140;
input double      RiskPercent      = 1.0;

#define EA_MAGIC  234000

// Global variables
double           SymbolPointSize;
double           TickValue;
double           TickSize;
long             LastBarTime = 0;

// Structures
struct SetupInfo
{
   string      type;
   int         c1_num;
   int         c2_num;
   datetime    c1_time;
   datetime    c2_time;
   double      entry;         // = C1 open  (stable Renko price level)
   double      sl;            // = C2 high/low ± buffer (stable price level)
   double      tp;
   double      c2_high;       // stored for invalidation check
   double      c2_low;        // stored for invalidation check
   double      risk;
   string      status;
   string      invalidation_details;
   int         c2_idx;
   string      unique_key;    // "BEAR_entry_sl" or "BULL_entry_sl"
};

//+------------------------------------------------------------------+
//| Build stable unique key from PRICES only                        |
//| entry = C1 open  -> fixed Renko box boundary, never shifts      |
//| sl    = C2 extreme ± buffer -> fixed price, never shifts        |
//| These two prices together uniquely identify any setup           |
//+------------------------------------------------------------------+
string BuildUniqueKey(string dir, double entry, double sl)
{
   // e.g.  "BEAR_1230.00_1242.70"  or  "BULL_1250.00_1237.30"
   return dir + "_" + DoubleToString(entry, 2) + "_" + DoubleToString(sl, 2);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   SymbolPointSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   TickValue       = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   TickSize        = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   Print("Renko EMA EA initialized | Symbol:", _Symbol,
         " BoxSize:", BoxSize, " SLBuf:", FixedSLBuffer,
         " Risk:", RiskPercent, "%");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function - fires on every new M1 bar                |
//+------------------------------------------------------------------+
void OnTick()
{
   MqlRates rates[];
   if(CopyRates(_Symbol, PERIOD_M1, 0, 1, rates) <= 0) return;

   if((datetime)rates[0].time == LastBarTime) return;
   LastBarTime = (long)rates[0].time;

   ProcessTradingLogic();
}

//+------------------------------------------------------------------+
//| Find a pending order whose comment contains the unique key      |
//| Also checks magic number and symbol for safety                  |
//+------------------------------------------------------------------+
ulong FindPendingOrderByKey(string key)
{
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)            continue;
      if(!OrderSelect(ticket))   continue;

      if(OrderGetString(ORDER_SYMBOL)   != _Symbol)  continue;
      if(OrderGetInteger(ORDER_MAGIC)   != EA_MAGIC) continue;

      if(StringFind(OrderGetString(ORDER_COMMENT), key) >= 0)
         return ticket;
   }
   return 0;
}

bool PendingOrderExists(string key)
{
   return FindPendingOrderByKey(key) != 0;
}

//+------------------------------------------------------------------+
//| Delete one pending order by ticket                              |
//+------------------------------------------------------------------+
bool DeletePendingOrder(ulong ticket)
{
   if(ticket == 0) return false;

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action = TRADE_ACTION_REMOVE;
   req.order  = ticket;

   if(!OrderSend(req, res))
   {
      Print("DeletePendingOrder FAILED ticket:", ticket, " err:", GetLastError());
      return false;
   }

   if(res.retcode == TRADE_RETCODE_DONE)
   {
      Print("Pending order DELETED ticket:", ticket);
      return true;
   }

   Print("Delete failed ticket:", ticket, " retcode:", res.retcode);
   return false;
}

//+------------------------------------------------------------------+
//| Main trading logic - called on every new M1 bar                 |
//+------------------------------------------------------------------+
void ProcessTradingLogic()
{
   // ── Step 1: Build Renko bricks ──────────────────────────────────
   double   all_opens[], all_closes[], all_highs[], all_lows[];
   datetime all_times[];
   int      all_trends[], all_src[];
   long     total_bricks;
   int      current_trend;

   if(!GetAllRenkoBricks(_Symbol, PERIOD_M1, BoxSize, NumBricks,
                         all_opens, all_closes, all_highs, all_lows,
                         all_times, all_trends, all_src,
                         total_bricks, current_trend))
   {
      Print("Failed to get Renko bricks"); return;
   }

   // ── Step 2: Collect confirmed bricks ────────────────────────────
   // A brick is confirmed when a NEW M1 candle has opened after it
   // i.e. its source candle index < the last candle index
   int last_src_idx    = ArraySize(all_src) - 1;
   int confirmed_count = 0;

   for(int i = 1; i < ArraySize(all_opens); i++)
      if(all_src[i] < last_src_idx) confirmed_count++;

   if(confirmed_count < 10) return;

   double   c_opens[], c_closes[], c_highs[], c_lows[];
   datetime c_times[];
   int      c_trends[], c_nums[];

   ArrayResize(c_opens,  confirmed_count);
   ArrayResize(c_closes, confirmed_count);
   ArrayResize(c_highs,  confirmed_count);
   ArrayResize(c_lows,   confirmed_count);
   ArrayResize(c_times,  confirmed_count);
   ArrayResize(c_trends, confirmed_count);
   ArrayResize(c_nums,   confirmed_count);

   int ci = 0;
   for(int i = 1; i < ArraySize(all_opens); i++)
   {
      if(all_src[i] < last_src_idx)
      {
         c_opens[ci]  = all_opens[i];
         c_closes[ci] = all_closes[i];
         c_highs[ci]  = all_highs[i];
         c_lows[ci]   = all_lows[i];
         c_times[ci]  = all_times[i];
         c_trends[ci] = all_trends[i];
         c_nums[ci]   = i;
         ci++;
      }
   }

   // ── Step 3: EMA on confirmed closes ─────────────────────────────
   double ema[];
   if(!CalculateEMA(c_closes, 9, ema)) return;

   // ── Step 4: Scan setups ─────────────────────────────────────────
   SetupInfo setups[];
   if(!ScanEntrySetups(c_opens, c_closes, c_highs, c_lows,
                       c_times, c_trends, c_nums,
                       ema, FixedSLBuffer, setups))
      return;

   // ── Step 5: Act on each setup ───────────────────────────────────
   for(int i = 0; i < ArraySize(setups); i++)
   {
      SetupInfo s   = setups[i];
      string    key = s.unique_key;   // stable: "BEAR_entry_sl"

      // ── CANCELED: C3 closed past the SL level ───────────────────
      // BEARISH: C3 closed ABOVE sl  →  price went against us
      // BULLISH: C3 closed BELOW sl  →  price went against us
      // In both cases the pending order must be deleted NOW
      if(StringFind(s.status, "CANCELED") >= 0)
      {
         // Also handle re-entry key in case that was placed first
         string rkey   = "RE_" + key;
         ulong  ticket = FindPendingOrderByKey(key);
         ulong  rtkt   = FindPendingOrderByKey(rkey);

         if(ticket != 0)
         {
            Print("CANCEL: C3 invalidated setup. Deleting order #", ticket,
                  " | Key:", key,
                  " | Reason:", s.invalidation_details);
            DeletePendingOrder(ticket);
         }
         if(rtkt != 0)
         {
            Print("CANCEL: Also deleting re-entry order #", rtkt,
                  " | Key:", rkey);
            DeletePendingOrder(rtkt);
         }
         continue;
      }

      // ── FILLED: broker handled it, nothing to do ─────────────────
      if(StringFind(s.status, "FILLED") >= 0)
         continue;

      // ── STOPPED OUT: place re-entry at same levels ───────────────
      if(StringFind(s.status, "STOPPED OUT") >= 0)
      {
         string rkey = "RE_" + key;
         if(!PendingOrderExists(rkey))
         {
            double lots = CalculateLotSize(RiskPercent,
                                           MathAbs(s.entry - s.sl), _Symbol);
            ENUM_ORDER_TYPE ot = (StringFind(s.type,"BEARISH") >= 0)
                                 ? ORDER_TYPE_SELL_STOP
                                 : ORDER_TYPE_BUY_STOP;
            PlaceStopOrder(_Symbol, ot, s.entry, s.sl, s.tp, lots, rkey);
         }
         continue;
      }

      // ── PENDING: place order once, guard against duplicates ──────
      if(StringFind(s.status, "Pending") >= 0)
      {
         if(PendingOrderExists(key)) continue;   // already live

         double lots = CalculateLotSize(RiskPercent,
                                        MathAbs(s.entry - s.sl), _Symbol);
         ENUM_ORDER_TYPE ot = (StringFind(s.type,"BEARISH") >= 0)
                              ? ORDER_TYPE_SELL_STOP
                              : ORDER_TYPE_BUY_STOP;

         Print("NEW ORDER | Key:", key,
               " Entry:", s.entry, " SL:", s.sl, " TP:", s.tp);
         PlaceStopOrder(_Symbol, ot, s.entry, s.sl, s.tp, lots, key);
      }
   }
}

//+------------------------------------------------------------------+
//| Build all Renko bricks from M1 price data                       |
//+------------------------------------------------------------------+
bool GetAllRenkoBricks(string symbol, ENUM_TIMEFRAMES tf,
                       double box_size, int num_bricks,
                       double &opens[], double &closes[],
                       double &highs[], double &lows[],
                       datetime &times[], int &trends[],
                       int &src_idx[],
                       long &total_bricks, int &current_trend)
{
   MqlRates rates[];
   int copied = CopyRates(symbol, tf, 0, 1000, rates);
   if(copied <= 0) return false;

   double cl = MathFloor(rates[0].close / box_size) * box_size;

   ArrayResize(opens,   1); ArrayResize(closes,  1);
   ArrayResize(highs,   1); ArrayResize(lows,    1);
   ArrayResize(times,   1); ArrayResize(trends,  1);
   ArrayResize(src_idx, 1);

   opens[0]=cl; closes[0]=cl; highs[0]=cl; lows[0]=cl;
   times[0]=rates[0].time; trends[0]=0; src_idx[0]=0;

   total_bricks=0; current_trend=0;

   for(int i = 1; i < copied; i++)
   {
      double   price = rates[i].close;
      datetime t     = rates[i].time;
      double   last  = closes[ArraySize(closes)-1];
      int      n     = (int)(MathAbs(last - price) / box_size);

      if(n <= 0) continue;

      if(current_trend == 0)
      {
         if(n < 2) continue;
         current_trend = (price > last) ? 1 : -1;
         for(int j = 0; j < n; j++)
         {
            double bo = last; last += current_trend*box_size;
            AddBrick(opens,closes,highs,lows,times,trends,src_idx,
                     bo, last, t, current_trend, i);
            total_bricks++;
         }
      }
      else
      {
         if(last * current_trend < price * current_trend)
         {
            // continuation
            for(int j = 0; j < n; j++)
            {
               double bo = last; last += current_trend*box_size;
               AddBrick(opens,closes,highs,lows,times,trends,src_idx,
                        bo, last, t, current_trend, i);
               total_bricks++;
            }
         }
         else if(n >= 2)
         {
            // reversal
            current_trend *= -1;
            last          += current_trend * box_size;
            for(int j = 0; j < n-1; j++)
            {
               double bo = last; last += current_trend*box_size;
               AddBrick(opens,closes,highs,lows,times,trends,src_idx,
                        bo, last, t, current_trend, i);
               total_bricks++;
            }
         }
      }
   }
   return true;
}

//+------------------------------------------------------------------+
//| Append one brick to all arrays                                  |
//+------------------------------------------------------------------+
void AddBrick(double &op[], double &cl[], double &hi[], double &lo[],
              datetime &tm[], int &tr[], int &si[],
              double bopen, double bclose,
              datetime t, int trend, int cidx)
{
   int n = ArraySize(op);
   ArrayResize(op,n+1); ArrayResize(cl,n+1);
   ArrayResize(hi,n+1); ArrayResize(lo,n+1);
   ArrayResize(tm,n+1); ArrayResize(tr,n+1);
   ArrayResize(si,n+1);

   op[n]=bopen;  cl[n]=bclose;
   hi[n]=MathMax(bopen,bclose); lo[n]=MathMin(bopen,bclose);
   tm[n]=t; tr[n]=trend; si[n]=cidx;
}

//+------------------------------------------------------------------+
//| EMA calculation                                                  |
//+------------------------------------------------------------------+
bool CalculateEMA(const double &prices[], int period, double &ema[])
{
   int sz = ArraySize(prices);
   if(sz < period) return false;

   ArrayResize(ema, 0);
   double mult = 2.0/(period+1.0), sum=0;
   for(int i=0;i<period;i++) sum+=prices[i];

   ArrayResize(ema,1); ema[0]=sum/period;
   for(int i=period;i<sz;i++)
   {
      int l=ArraySize(ema)-1;
      double v=(prices[i]-ema[l])*mult+ema[l];
      ArrayResize(ema,l+2); ema[l+1]=v;
   }
   return true;
}

double GetEMAForIdx(const double &ema[], int idx)
{
   int off = idx-8;
   return (off>=0 && off<ArraySize(ema)) ? ema[off] : 0.0;
}

//+------------------------------------------------------------------+
//| Scan for C1+C2 setups and determine C3 outcome                  |
//|                                                                  |
//| INVALIDATION RULE (the fix you asked for):                      |
//|   BEARISH setup: if C3 Renko brick closes ABOVE the SL price    |
//|                  → price moved against us → CANCEL order         |
//|   BULLISH setup: if C3 Renko brick closes BELOW the SL price    |
//|                  → price moved against us → CANCEL order         |
//+------------------------------------------------------------------+
bool ScanEntrySetups(const double &opens[], const double &closes[],
                     const double &highs[], const double &lows[],
                     const datetime &times[], const int &trends[],
                     const int &nums[],
                     const double &ema[], double sl_buf,
                     SetupInfo &setups[])
{
   if(ArraySize(opens) < 10 || ArraySize(ema) == 0) return false;
   ArrayResize(setups, 0);

   int sz = ArraySize(opens);

   for(int i = 9; i < sz; i++)
   {
      // C1 = brick at i-1,  C2 = brick at i
      double c1o=opens[i-1], c1c=closes[i-1];
      double c2o=opens[i],   c2c=closes[i];
      double c2h=highs[i],   c2l=lows[i];
      datetime c1t=times[i-1], c2t=times[i];
      int c1n=nums[i-1], c2n=nums[i];

      double e1=GetEMAForIdx(ema,i-1);
      double e2=GetEMAForIdx(ema,i);
      if(e1==0.0 || e2==0.0) continue;

      // ── BEARISH SETUP ───────────────────────────────────────────
      // C1 bullish, C2 bullish consecutive, C1 open below EMA,
      // C2 close above EMA  → sell stop at C1 open
      if(c1c>c1o && c2c>c2o &&
         MathAbs(c2o-c1c)<1e-7 &&
         c1o<e1 && c2c>e2)
      {
         double entry = c1o;
         double sl    = c2h + sl_buf;   // SL is ABOVE C2 high
         double risk  = sl - entry;
         double tp    = (risk>0) ? entry - 3.0*risk : entry;

         // Unique key: direction + entry price + SL price
         // Both are fixed Renko box boundaries → stable across ticks
         string key = BuildUniqueKey("BEAR", entry, sl);

         string status = "Pending Order Placed";
         string inv    = "C3 not yet formed.";

         if(i+1 < sz)
         {
            // C3 = the very next confirmed Renko brick after C2
            double c3c = closes[i+1];
            double c3h = highs[i+1];
            double c3l = lows[i+1];
            double c3o_val = opens[i+1];

            double c3_lo = MathMin(c3o_val, c3c);
            double c3_hi = MathMax(c3o_val, c3c);

            bool filled = (c3_lo <= entry && entry <= c3_hi);

            if(filled)
            {
               // C3 reached down to our sell-stop entry
               if(c3_hi >= sl)
               {
                  // C3 also touched the SL → stopped out on entry candle
                  status = "STOPPED OUT -> RE-ENTRY PLACED";
                  inv    = "C3 filled entry " + DoubleToString(entry,2) +
                            " and hit SL "    + DoubleToString(sl,2);
               }
               else
               {
                  status = "FILLED";
                  inv    = "C3 filled entry at " + DoubleToString(entry,2);
               }
            }
            else
            {
               // ── THE REAL FIX ────────────────────────────────────
               // C3 did NOT fill our entry.
               // For BEARISH (sell stop below market):
               //   If C3 Renko brick CLOSES ABOVE THE SL PRICE
               //   it means price has moved solidly above our SL,
               //   so the setup is dead → delete the pending order.
               // This is the scenario: c3 closed in a direction
               // that makes our SL meaningless / unreachable safely.
               if(c3c > sl)
               {
                  status = "CANCELED (Invalidated)";
                  inv    = "C3 closed ABOVE SL (" +
                            DoubleToString(c3c,2) + " > SL " +
                            DoubleToString(sl,2)  +
                            "). Order deleted.";
               }
               else if(c3c > c2h)
               {
                  // C3 closed above C2 high but below SL
                  // Still a bullish continuation → setup invalid
                  status = "CANCELED (Invalidated)";
                  inv    = "C3 closed above C2 high (" +
                            DoubleToString(c3c,2) + " > " +
                            DoubleToString(c2h,2) +
                            "). Order deleted.";
               }
               else
               {
                  status = "Pending (Unfilled)";
                  inv    = "C3 did not fill or invalidate. Order stays.";
               }
            }
         }

         int idx=ArraySize(setups);
         ArrayResize(setups,idx+1);
         setups[idx].type                 = "BEARISH (Sell)";
         setups[idx].c1_num               = c1n;
         setups[idx].c2_num               = c2n;
         setups[idx].c1_time              = c1t;
         setups[idx].c2_time              = c2t;
         setups[idx].c2_high              = c2h;
         setups[idx].c2_low               = c2l;
         setups[idx].entry                = entry;
         setups[idx].sl                   = sl;
         setups[idx].tp                   = tp;
         setups[idx].risk                 = risk;
         setups[idx].status               = status;
         setups[idx].invalidation_details = inv;
         setups[idx].c2_idx               = i;
         setups[idx].unique_key           = key;
      }

      // ── BULLISH SETUP ───────────────────────────────────────────
      // C1 bearish, C2 bearish consecutive, C1 open above EMA,
      // C2 close below EMA  → buy stop at C1 open
      if(c1c<c1o && c2c<c2o &&
         MathAbs(c2o-c1c)<1e-7 &&
         c1o>e1 && c2c<e2)
      {
         double entry = c1o;
         double sl    = c2l - sl_buf;   // SL is BELOW C2 low
         double risk  = entry - sl;
         double tp    = (risk>0) ? entry + 3.0*risk : entry;

         // Unique key: direction + entry price + SL price
         string key = BuildUniqueKey("BULL", entry, sl);

         string status = "Pending Order Placed";
         string inv    = "C3 not yet formed.";

         if(i+1 < sz)
         {
            // C3 = the very next confirmed Renko brick after C2
            double c3c = closes[i+1];
            double c3h = highs[i+1];
            double c3l = lows[i+1];
            double c3o_val = opens[i+1];

            double c3_lo = MathMin(c3o_val, c3c);
            double c3_hi = MathMax(c3o_val, c3c);

            bool filled = (c3_lo <= entry && entry <= c3_hi);

            if(filled)
            {
               // C3 reached up to our buy-stop entry
               if(c3_lo <= sl)
               {
                  // C3 also touched the SL → stopped out on entry candle
                  status = "STOPPED OUT -> RE-ENTRY PLACED";
                  inv    = "C3 filled entry " + DoubleToString(entry,2) +
                            " and hit SL "    + DoubleToString(sl,2);
               }
               else
               {
                  status = "FILLED";
                  inv    = "C3 filled entry at " + DoubleToString(entry,2);
               }
            }
            else
            {
               // ── THE REAL FIX ────────────────────────────────────
               // C3 did NOT fill our entry.
               // For BULLISH (buy stop above market):
               //   If C3 Renko brick CLOSES BELOW THE SL PRICE
               //   it means price has moved solidly below our SL,
               //   so the setup is dead → delete the pending order.
               if(c3c < sl)
               {
                  status = "CANCELED (Invalidated)";
                  inv    = "C3 closed BELOW SL (" +
                            DoubleToString(c3c,2) + " < SL " +
                            DoubleToString(sl,2)  +
                            "). Order deleted.";
               }
               else if(c3c < c2l)
               {
                  // C3 closed below C2 low but above SL
                  // Still a bearish continuation → setup invalid
                  status = "CANCELED (Invalidated)";
                  inv    = "C3 closed below C2 low (" +
                            DoubleToString(c3c,2) + " < " +
                            DoubleToString(c2l,2) +
                            "). Order deleted.";
               }
               else
               {
                  status = "Pending (Unfilled)";
                  inv    = "C3 did not fill or invalidate. Order stays.";
               }
            }
         }

         int idx=ArraySize(setups);
         ArrayResize(setups,idx+1);
         setups[idx].type                 = "BULLISH (Buy)";
         setups[idx].c1_num               = c1n;
         setups[idx].c2_num               = c2n;
         setups[idx].c1_time              = c1t;
         setups[idx].c2_time              = c2t;
         setups[idx].c2_high              = c2h;
         setups[idx].c2_low               = c2l;
         setups[idx].entry                = entry;
         setups[idx].sl                   = sl;
         setups[idx].tp                   = tp;
         setups[idx].risk                 = risk;
         setups[idx].status               = status;
         setups[idx].invalidation_details = inv;
         setups[idx].c2_idx               = i;
         setups[idx].unique_key           = key;
      }
   }
   return true;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk %                              |
//+------------------------------------------------------------------+
double CalculateLotSize(double risk_pct, double sl_dist, string sym)
{
   double bal    = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal <= 0)  return 0.01;

   double risk   = bal * (risk_pct/100.0);
   double tv     = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double ts     = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double volmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);

   if(tv<=0 || ts<=0) return volmin;

   double ticks = sl_dist / ts;
   double lots  = (ticks>0) ? risk/(ticks*tv) : volmin;

   lots = MathRound(lots*100.0)/100.0;
   if(lots < volmin) lots = volmin;
   return lots;
}

//+------------------------------------------------------------------+
//| Place a pending stop order                                      |
//+------------------------------------------------------------------+
void PlaceStopOrder(string sym, ENUM_ORDER_TYPE otype,
                    double price, double sl, double tp,
                    double lots, string comment)
{
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req); ZeroMemory(res);

   req.action       = TRADE_ACTION_PENDING;
   req.symbol       = sym;
   req.volume       = lots;
   req.type         = otype;
   req.price        = price;
   req.sl           = sl;
   req.tp           = tp;
   req.deviation    = 10;
   req.magic        = EA_MAGIC;
   req.comment      = comment;
   req.type_time    = ORDER_TIME_GTC;
   req.type_filling = ORDER_FILLING_IOC;

   if(!OrderSend(req, res))
   { Print("OrderSend FAILED err:", GetLastError(), " key:", comment); return; }

   if(res.retcode == TRADE_RETCODE_DONE)
      Print("Order OK | ", comment,
            " | #", res.order,
            " | price:", price, " sl:", sl, " tp:", tp, " lots:", lots);
   else
      Print("Order FAILED | retcode:", res.retcode,
            " | ", res.comment, " | key:", comment);
}
//+------------------------------------------------------------------+
