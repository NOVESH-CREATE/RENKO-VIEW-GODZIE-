//+------------------------------------------------------------------+
//|                                                     Renko_EMA.mq5 |
//|                        Copyright 2026, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

// Input parameters
input double      BoxSize          = 5.0;           // Brick Size ($)
input double      FixedSLBuffer    = 1.0;           // Fixed SL Buffer ($0.70 - $2.00)
input int         NumBricks        = 140;           // Number of Bricks
input double      RiskPercent      = 1.0;           // Risk per trade (%)

// Global variables
double           SymbolPointSize;    // Symbol point size
double           TickValue;
double           TickSize;
long             LastBarTime = 0;

// Structures
struct SetupInfo
{
   string      type;      // BEARISH or BULLISH
   int         c1_num;    // C1 brick number
   int         c2_num;    // C2 brick number
   datetime    c1_time;
   datetime    c2_time;
   double      entry;     // Entry price
   double      sl;        // Stop loss price
   double      tp;        // Take profit price
   double      risk;      // Risk amount
   string      status;    // Current status
   string      invalidation_details; // Details about invalidation
   int         c2_idx;    // Index in confirmed bricks array
};

// Global arrays
double           BrickOpens[];
double           BrickCloses[];
double           BrickHighs[];
double           BrickLows[];
datetime         BrickTimes[];
int              BrickTrends[];
int              BrickSourceCandleIdx[];
int              BrickNumbers[];
bool             BrickConfirmed[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Get symbol info
   SymbolPointSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   TickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   TickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   // Initialize arrays
   ArrayResize(BrickOpens, 0);
   ArrayResize(BrickCloses, 0);
   ArrayResize(BrickHighs, 0);
   ArrayResize(BrickLows, 0);
   ArrayResize(BrickTimes, 0);
   ArrayResize(BrickTrends, 0);
   ArrayResize(BrickSourceCandleIdx, 0);
   ArrayResize(BrickNumbers, 0);
   ArrayResize(BrickConfirmed, 0);
   
   Print("Renko EMA Trading EA initialized");
   Print("Symbol: ", _Symbol);
   Print("Box Size: ", BoxSize);
   Print("Fixed SL Buffer: ", FixedSLBuffer);
   Print("Risk Percent: ", RiskPercent, "%");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("Renko EMA Trading EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Only process on new bar to avoid excessive calculations
   MqlRates rates[];
   if(CopyRates(_Symbol, PERIOD_M1, 0, 1, rates) <= 0)
   {
      Print("Failed to get rates");
      return;
   }
   
   // Check if new bar
   if((datetime)rates[0].time == LastBarTime)
      return;
      
   LastBarTime = (long)rates[0].time;
   
   // Process trading logic
   ProcessTradingLogic();
}

//+------------------------------------------------------------------+
//| Main trading logic function                                      |
//+------------------------------------------------------------------+
void ProcessTradingLogic()
{
   // Get all Renko bricks
   double all_bricks_closes[];
   double all_bricks_opens[];
   double all_bricks_highs[];
   double all_bricks_lows[];
   datetime all_bricks_times[];
   int all_bricks_trends[];
   int all_bricks_source_candle_idx[];
   long total_bricks;
   int current_trend;
   
   if(!GetAllRenkoBricks(_Symbol, PERIOD_M1, BoxSize, 140, 
                         all_bricks_opens, all_bricks_closes, all_bricks_highs, all_bricks_lows,
                         all_bricks_times, all_bricks_trends, all_bricks_source_candle_idx,
                         total_bricks, current_trend))
   {
      Print("Failed to get Renko bricks");
      return;
   }
   
   // Identify confirmed bricks
   int confirmed_count = 0;
   int last_mt5_candle_idx = (int)ArraySize(all_bricks_source_candle_idx) - 1;
   
   // Count confirmed bricks first
   for(int i = 1; i < total_bricks; i++)
   {
      if(all_bricks_source_candle_idx[i] < last_mt5_candle_idx)
         confirmed_count++;
   }
   
   if(confirmed_count < 10) // Need at least 10 confirmed bricks for EMA calculation
      return;
   
   // Create arrays for confirmed bricks only
   double confirmed_opens[];
   double confirmed_closes[];
   double confirmed_highs[];
   double confirmed_lows[];
   datetime confirmed_times[];
   int confirmed_trends[];
   int confirmed_brick_nums[];
   bool confirmed_flags[];
   
   ArrayResize(confirmed_opens, confirmed_count);
   ArrayResize(confirmed_closes, confirmed_count);
   ArrayResize(confirmed_highs, confirmed_count);
   ArrayResize(confirmed_lows, confirmed_count);
   ArrayResize(confirmed_times, confirmed_count);
   ArrayResize(confirmed_trends, confirmed_count);
   ArrayResize(confirmed_brick_nums, confirmed_count);
   ArrayResize(confirmed_flags, confirmed_count);
   
   int confirmed_idx = 0;
   for(int i = 1; i < total_bricks; i++)
   {
      if(all_bricks_source_candle_idx[i] < last_mt5_candle_idx) // Confirmed brick
      {
         confirmed_opens[confirmed_idx] = all_bricks_opens[i];
         confirmed_closes[confirmed_idx] = all_bricks_closes[i];
         confirmed_highs[confirmed_idx] = all_bricks_highs[i];
         confirmed_lows[confirmed_idx] = all_bricks_lows[i];
         confirmed_times[confirmed_idx] = all_bricks_times[i];
         confirmed_trends[confirmed_idx] = all_bricks_trends[i];
         confirmed_brick_nums[confirmed_idx] = i; // Sequential numbering
         confirmed_flags[confirmed_idx] = true;
         confirmed_idx++;
      }
   }
   
   // Calculate EMA on confirmed close prices
   double ema_values[];
   if(!CalculateEMA(confirmed_closes, 9, ema_values))
      return;
   
   // Scan for entry setups
   SetupInfo setups[];
   if(!ScanEntrySetups(confirmed_opens, confirmed_closes, confirmed_highs, confirmed_lows,
                      confirmed_times, confirmed_trends, confirmed_brick_nums,
                      ema_values, FixedSLBuffer, setups))
   {
      Print("Failed to scan entry setups");
      return;
   }
   
   // Process each setup for trading
   for(int i = 0; i < ArraySize(setups); i++)
   {
      SetupInfo setup = setups[i];
      
      // Create a unique ID for this setup
      string setup_id = setup.type + "_" + IntegerToString(setup.c1_num) + "_" + IntegerToString(setup.c2_num);
      
      // --- HANDLE CANCELED/INVALIDATED ORDERS ---
      if(StringFind(setup.status, "CANCELED") >= 0)
      {
         Print("Setup invalidated: ", setup_id, " - ", setup.invalidation_details);
         
         // Cancel any pending orders for this setup
         CancelOrdersByComment(setup_id);
         
         // Close any filled positions for this setup
         ClosePositionsByComment(setup_id);
         
         continue; // Skip to next setup
      }
      
      // --- HANDLE FILLED POSITIONS (Manage active trades) ---
      if(StringFind(setup.status, "FILLED") >= 0)
      {
         // Position is active, no new action needed
         // (SL/TP are already set on the position)
         Print("Setup FILLED: ", setup_id, " - Trade is active");
         continue;
      }
      
      // --- HANDLE STOPPED OUT -> RE-ENTRY PLACED ---
      if(StringFind(setup.status, "STOPPED OUT -> RE-ENTRY PLACED") >= 0)
      {
         Print("Setup stopped out: ", setup_id, " - ", setup.invalidation_details);
         
         // Check if we already have a re-entry order
         if(!HasOrderWithComment(setup_id + "_REENTRY"))
         {
            double entry_price = setup.entry;
            double sl_price = setup.sl;
            double tp_price = setup.tp;
            
            // Calculate SL distance for lot sizing
            double sl_distance = MathAbs(entry_price - sl_price);
            
            // Calculate lot size based on 1% risk
            double lot_size = CalculateLotSize(RiskPercent, sl_distance, _Symbol);
            
            // Determine order type based on setup
            if(StringFind(setup.type, "BEARISH") >= 0)
            {
               // Sell stop order for re-entry
               PlaceStopOrder(_Symbol, ORDER_TYPE_SELL_STOP, entry_price, sl_price, tp_price, lot_size, 
                             setup_id + "_REENTRY");
            }
            else
            {
               // Buy stop order for re-entry
               PlaceStopOrder(_Symbol, ORDER_TYPE_BUY_STOP, entry_price, sl_price, tp_price, lot_size, 
                             setup_id + "_REENTRY");
            }
         }
         continue;
      }
      
      // --- HANDLE PENDING/UNFILLED ORDERS ---
      if(StringFind(setup.status, "Pending") >= 0)
      {
         // Check if we already have a pending order for this setup
         if(!HasOrderWithComment(setup_id))
         {
            double entry_price = setup.entry;
            double sl_price = setup.sl;
            double tp_price = setup.tp;
            
            // Calculate SL distance for lot sizing
            double sl_distance = MathAbs(entry_price - sl_price);
            
            // Calculate lot size based on 1% risk
            double lot_size = CalculateLotSize(RiskPercent, sl_distance, _Symbol);
            
            // Determine order type based on setup
            if(StringFind(setup.type, "BEARISH") >= 0)
            {
               // Sell stop order
               PlaceStopOrder(_Symbol, ORDER_TYPE_SELL_STOP, entry_price, sl_price, tp_price, lot_size, 
                             setup_id);
            }
            else
            {
               // Buy stop order
               PlaceStopOrder(_Symbol, ORDER_TYPE_BUY_STOP, entry_price, sl_price, tp_price, lot_size, 
                             setup_id);
            }
         }
         continue;
      }
   }
}

//+------------------------------------------------------------------+
//| Check if order exists with comment                               |
//+------------------------------------------------------------------+
bool HasOrderWithComment(string comment)
{
   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      if(OrderGetTicket(i) > 0)
      {
         if(StringFind(OrderGetString(ORDER_COMMENT), comment) >= 0)
            return(true);
      }
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Cancel orders by comment                                         |
//+------------------------------------------------------------------+
void CancelOrdersByComment(string comment)
{
   int total = OrdersTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      if(OrderGetTicket(i) > 0)
      {
         string order_comment = OrderGetString(ORDER_COMMENT);
         if(StringFind(order_comment, comment) >= 0)
         {
            if(OrderGetInteger(ORDER_STATE) == ORDER_STATE_PLACED)
            {
               MqlTradeRequest request;
               MqlTradeResult result;
               
               ZeroMemory(request);
               ZeroMemory(result);
               
               request.action = TRADE_ACTION_REMOVE;
               request.order = OrderGetTicket(i);
               
               if(OrderSend(request, result))
               {
                  Print("Order cancelled: ", order_comment, " Ticket: ", OrderGetTicket(i));
               }
               else
               {
                  Print("Failed to cancel order: ", order_comment, " Error: ", GetLastError());
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close positions by comment                                       |
//+------------------------------------------------------------------+
void ClosePositionsByComment(string comment)
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) > 0)
      {
         string position_comment = PositionGetString(POSITION_COMMENT);
         if(StringFind(position_comment, comment) >= 0)
         {
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
            {
               // Sell to close
               MqlTradeRequest request;
               MqlTradeResult result;
               
               ZeroMemory(request);
               ZeroMemory(result);
               
               request.action = TRADE_ACTION_DEAL;
               request.symbol = _Symbol;
               request.volume = PositionGetDouble(POSITION_VOLUME);
               request.type = ORDER_TYPE_SELL;
               request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
               request.deviation = 10;
               request.magic = 234000;
               request.comment = "CLOSE_" + position_comment;
               
               if(OrderSend(request, result))
               {
                  Print("BUY position closed: ", position_comment, " Ticket: ", PositionGetTicket(i));
               }
               else
               {
                  Print("Failed to close BUY position: ", position_comment, " Error: ", GetLastError());
               }
            }
            else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
            {
               // Buy to close
               MqlTradeRequest request;
               MqlTradeResult result;
               
               ZeroMemory(request);
               ZeroMemory(result);
               
               request.action = TRADE_ACTION_DEAL;
               request.symbol = _Symbol;
               request.volume = PositionGetDouble(POSITION_VOLUME);
               request.type = ORDER_TYPE_BUY;
               request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               request.deviation = 10;
               request.magic = 234000;
               request.comment = "CLOSE_" + position_comment;
               
               if(OrderSend(request, result))
               {
                  Print("SELL position closed: ", position_comment, " Ticket: ", PositionGetTicket(i));
               }
               else
               {
                  Print("Failed to close SELL position: ", position_comment, " Error: ", GetLastError());
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Get all Renko bricks function                                    |
//+------------------------------------------------------------------+
bool GetAllRenkoBricks(string symbol, ENUM_TIMEFRAMES chart_timeframe, double box_size, int num_bricks,
                       double &opens[], double &closes[], double &highs[], double &lows[],
                       datetime &times[], int &trends[], int &source_candle_idx[],
                       long &total_bricks, int &current_trend)
{
   // Get price data
   MqlRates rates[];
   int copied = CopyRates(symbol, chart_timeframe, 0, 1000, rates);
   if(copied <= 0)
      return(false);
   
   // Initialize like Pine script: start with first close price adjusted to box boundary
   double first_close = rates[0].close;
   double close_level = MathFloor(first_close / box_size) * box_size;
   
   // Arrays to store ALL brick data
   ArrayResize(opens, 0);
   ArrayResize(closes, 0);
   ArrayResize(highs, 0);
   ArrayResize(lows, 0);
   ArrayResize(times, 0);
   ArrayResize(trends, 0);
   ArrayResize(source_candle_idx, 0);
   
   // Initialize with first brick
   ArrayResize(opens, 1);
   ArrayResize(closes, 1);
   ArrayResize(highs, 1);
   ArrayResize(lows, 1);
   ArrayResize(times, 1);
   ArrayResize(trends, 1);
   ArrayResize(source_candle_idx, 1);
   
   opens[0] = close_level;
   closes[0] = close_level;
   highs[0] = close_level;
   lows[0] = close_level;
   times[0] = rates[0].time;
   trends[0] = 0;
   source_candle_idx[0] = 0;
   
   total_bricks = 0;
   current_trend = 0;
   
   // Process each price bar (MT5 candle)
   for(int i = 0; i < copied; i++)
   {
      double current_price = rates[i].close;
      datetime current_time = rates[i].time;
      
      // Skip the first iteration since we already initialized with candle 0's close
      if(i == 0 && ArraySize(closes) == 1 && closes[0] == close_level)
         continue;
      
      double last_close = closes[ArraySize(closes)-1];
      int numcell = (int)(MathAbs(last_close - current_price) / box_size);
      
      if(numcell > 0)
      {
         if(current_trend == 0)
         {
            // No established trend yet, need at least 2 boxes to establish trend
            if(numcell >= 2)
            {
               // Establish trend: 1 if price is going up, -1 if going down
               current_trend = (current_price > last_close) ? 1 : -1;
               
               // Add numcell bricks
               for(int j = 0; j < numcell; j++)
               {
                  double brick_open = last_close;
                  last_close += current_trend * box_size;
                  double brick_close = last_close;
                  
                  // Add brick data
                  int idx = ArraySize(opens);
                  ArrayResize(opens, idx+1);
                  ArrayResize(closes, idx+1);
                  ArrayResize(highs, idx+1);
                  ArrayResize(lows, idx+1);
                  ArrayResize(times, idx+1);
                  ArrayResize(trends, idx+1);
                  ArrayResize(source_candle_idx, idx+1);
                  
                  opens[idx] = brick_open;
                  closes[idx] = brick_close;
                  highs[idx] = MathMax(brick_open, brick_close);
                  lows[idx] = MathMin(brick_open, brick_close);
                  times[idx] = current_time;
                  trends[idx] = current_trend;
                  source_candle_idx[idx] = i;
                  
                  total_bricks++;
               }
            }
         }
         else
         {
            // We have an established trend
            if(last_close * current_trend < current_price * current_trend)
            {
               // Price is still moving in the same direction as the trend
               // Add numcell bricks
               for(int j = 0; j < numcell; j++)
               {
                  double brick_open = last_close;
                  last_close += current_trend * box_size;
                  double brick_close = last_close;
                  
                  // Add brick data
                  int idx = ArraySize(opens);
                  ArrayResize(opens, idx+1);
                  ArrayResize(closes, idx+1);
                  ArrayResize(highs, idx+1);
                  ArrayResize(lows, idx+1);
                  ArrayResize(times, idx+1);
                  ArrayResize(trends, idx+1);
                  ArrayResize(source_candle_idx, idx+1);
                  
                  opens[idx] = brick_open;
                  closes[idx] = brick_close;
                  highs[idx] = MathMax(brick_open, brick_close);
                  lows[idx] = MathMin(brick_open, brick_close);
                  times[idx] = current_time;
                  trends[idx] = current_trend;
                  source_candle_idx[idx] = i;
                  
                  total_bricks++;
               }
            }
            else if(numcell >= 2)
            {
               // Price has reversed by at least 2 box sizes, change trend
               current_trend = current_trend * -1;
               
               // Start from one box size in the new trend direction from last_close
               last_close = last_close + current_trend * box_size;
               
               // Add numcell-1 bricks (we already moved one box size above)
               for(int j = 0; j < numcell - 1; j++)
               {
                  double brick_open = last_close;
                  last_close += current_trend * box_size;
                  double brick_close = last_close;
                  
                  // Add brick data
                  int idx = ArraySize(opens);
                  ArrayResize(opens, idx+1);
                  ArrayResize(closes, idx+1);
                  ArrayResize(highs, idx+1);
                  ArrayResize(lows, idx+1);
                  ArrayResize(times, idx+1);
                  ArrayResize(trends, idx+1);
                  ArrayResize(source_candle_idx, idx+1);
                  
                  opens[idx] = brick_open;
                  closes[idx] = brick_close;
                  highs[idx] = MathMax(brick_open, brick_close);
                  lows[idx] = MathMin(brick_open, brick_close);
                  times[idx] = current_time;
                  trends[idx] = current_trend;
                  source_candle_idx[idx] = i;
                  
                  total_bricks++;
               }
            }
         }
      }
   }
   
   return(true);
}

//+------------------------------------------------------------------+
//| Calculate EMA function                                           |
//+------------------------------------------------------------------+
bool CalculateEMA(const double &prices[], int period, double &ema_values[])
{
   if(ArraySize(prices) < period)
      return(false);
   
   ArrayResize(ema_values, 0);
   
   double multiplier = 2.0 / (period + 1.0);
   
   // First EMA value is SMA of first 'period' prices
   double sum = 0.0;
   for(int i = 0; i < period; i++)
      sum += prices[i];
   double first_ema = sum / period;
   
   ArrayResize(ema_values, 1);
   ema_values[0] = first_ema;
   
   // Calculate remaining EMA values
   for(int i = period; i < ArraySize(prices); i++)
   {
      double ema = (prices[i] - ema_values[ArraySize(ema_values)-1]) * multiplier + ema_values[ArraySize(ema_values)-1];
      ArrayResize(ema_values, ArraySize(ema_values)+1);
      ema_values[ArraySize(ema_values)-1] = ema;
   }
   
   return(true);
}

//+------------------------------------------------------------------+
//| Get EMA value for confirmed brick index                          |
//+------------------------------------------------------------------+
double GetEMAForIdx(const double &ema_values[], int idx)
{
   int ema_offset = idx - 8; // Since EMA begins at index 8
   if(ema_offset >= 0 && ema_offset < ArraySize(ema_values))
      return ema_values[ema_offset];
   return 0.0;
}

//+------------------------------------------------------------------+
//| Scan entry setups function                                       |
//+------------------------------------------------------------------+
bool ScanEntrySetups(const double &opens[], const double &closes[], const double &highs[], const double &lows[],
                     const datetime &times[], const int &trends[], const int &brick_nums[],
                     const double &ema_values[], double fixed_sl_buffer, SetupInfo &setups[])
{
   if(ArraySize(opens) < 10 || ArraySize(ema_values) == 0)
      return(false);
   
   ArrayResize(setups, 0);
   
   // Loop through confirmed bricks looking for candle 2 (C2)
   // C2 starts from index 9 since we need C1 at index-1 and some historical buffer for EMA
   for(int i = 9; i < ArraySize(opens); i++)
   {
      double c2_open = opens[i];
      double c2_close = closes[i];
      double c2_high = highs[i];
      double c2_low = lows[i];
      datetime c2_time = times[i];
      int c2_brick_num = brick_nums[i];
      
      double c1_open = opens[i-1];
      double c1_close = closes[i-1];
      double c1_high = highs[i-1];
      double c1_low = lows[i-1];
      datetime c1_time = times[i-1];
      int c1_brick_num = brick_nums[i-1];
      
      double ema_c1 = GetEMAForIdx(ema_values, i-1);
      double ema_c2 = GetEMAForIdx(ema_values, i);
      
      if(ema_c1 == 0.0 || ema_c2 == 0.0)
         continue;
   
      // --- BEARISH SETUP DETECTION (Sell Limit/Stop Setup) ---
      // C1: Bullish Renko, C1 Open < EMA
      // C2: Immediate next Bullish Renko (no gap), C2 Close > EMA
      bool c1_bullish = (c1_close > c1_open);
      bool c2_bullish = (c2_close > c2_open);
      bool no_gap_bullish = MathAbs(c2_open - c1_close) < 1e-7; // Consecutive upward brick
      
      if(c1_bullish && c2_bullish && no_gap_bullish)
      {
         if(c1_open < ema_c1 && c2_close > ema_c2)
         {
            // Valid Bearish Setup Found!
            double entry_price = c1_open;
            // SL has fixed_sl_buffer directly incorporated "in risk" calculations
            double sl_price = c2_high + fixed_sl_buffer;
            double risk = sl_price - entry_price;
            double tp_price = (risk > 0) ? entry_price - (3 * risk) : entry_price;
            
            // Check Invalidation / Filled / Stopped Out state by Candle 3 (C3)
            string status = "Pending Order Placed";
            string invalidation_details = "Waiting for Candle 3 (C3) to form or close.";
            
            if(i + 1 < ArraySize(opens))
            {
               double c3_open = opens[i+1];
               double c3_close = closes[i+1];
               double c3_high = highs[i+1];
               double c3_low = lows[i+1];
               
               double c3_low_val = MathMin(c3_open, c3_close);
               double c3_high_val = MathMax(c3_open, c3_close);
               
               // 1. Did Candle 3 fill our entry?
               bool is_filled = (c3_low_val <= entry_price && entry_price <= c3_high_val);
               
               if(is_filled)
               {
                  // Did it also hit SL in the SAME candle C3?
                  bool is_stopped_out = (c3_high_val >= sl_price);
                  if(is_stopped_out)
                  {
                     status = "STOPPED OUT -> RE-ENTRY PLACED";
                     invalidation_details = "C3 filled entry at "+DoubleToString(entry_price,2)+" and hit SL at "+DoubleToString(sl_price,2)+". "+
                                           "New trade immediately placed at same entry with "+DoubleToString(fixed_sl_buffer,2)+" buffer.";
                  }
                  else
                  {
                     status = "FILLED";
                     invalidation_details = "C3 filled the trade at "+DoubleToString(entry_price,2)+". Trade is active!";
                  }
               }
               else
               {
                  // 2. If NOT filled, check if C3 closed above C2 High (Invalidation)
                  if(c3_close > c2_high)
                  {
                     status = "CANCELED (Invalidated)";
                     invalidation_details = "C3 closed above C2 high ("+DoubleToString(c3_close,2)+" > "+DoubleToString(c2_high,2)+") without filling. Order deleted.";
                  }
                  else
                  {
                     status = "Pending (Unfilled)";
                     invalidation_details = "C3 did not fill Entry nor close above C2 High. Order remains pending.";
                  }
               }
            }
            
            // Add setup to array
            int idx = ArraySize(setups);
            ArrayResize(setups, idx+1);
            setups[idx].type = "BEARISH (Sell)";
            setups[idx].c1_num = c1_brick_num;
            setups[idx].c2_num = c2_brick_num;
            setups[idx].c1_time = c1_time;
            setups[idx].c2_time = c2_time;
            setups[idx].entry = entry_price;
            setups[idx].sl = sl_price;
            setups[idx].tp = tp_price;
            setups[idx].risk = risk;
            setups[idx].status = status;
            setups[idx].invalidation_details = invalidation_details;
            setups[idx].c2_idx = i;
         }
      }
   
      // --- BULLISH SETUP DETECTION (Buy Limit/Stop Setup) ---
      // C1: Bearish Renko, C1 Open > EMA
      // C2: Immediate next Bearish Renko (no gap), C2 Close < EMA
      bool c1_bearish = (c1_close < c1_open);
      bool c2_bearish = (c2_close < c2_open);
      bool no_gap_bearish = MathAbs(c2_open - c1_close) < 1e-7; // Consecutive downward brick
      
      if(c1_bearish && c2_bearish && no_gap_bearish)
      {
         if(c1_open > ema_c1 && c2_close < ema_c2)
         {
            // Valid Bullish Setup Found!
            double entry_price = c1_open;
            // SL has fixed_sl_buffer directly incorporated "in risk" calculations
            double sl_price = c2_low - fixed_sl_buffer;
            double risk = entry_price - sl_price;
            double tp_price = (risk > 0) ? entry_price + (3 * risk) : entry_price;
            
            // Check Invalidation / Filled / Stopped Out state by Candle 3 (C3)
            string status = "Pending Order Placed";
            string invalidation_details = "Waiting for Candle 3 (C3) to form or close.";
            
            if(i + 1 < ArraySize(opens))
            {
               double c3_open = opens[i+1];
               double c3_close = closes[i+1];
               double c3_high = highs[i+1];
               double c3_low = lows[i+1];
               
               double c3_low_val = MathMin(c3_open, c3_close);
               double c3_high_val = MathMax(c3_open, c3_close);
               
               // 1. Did Candle 3 fill our entry?
               bool is_filled = (c3_low_val <= entry_price && entry_price <= c3_high_val);
               
               if(is_filled)
               {
                  // Did it also hit SL in the SAME candle C3?
                  bool is_stopped_out = (c3_low_val <= sl_price);
                  if(is_stopped_out)
                  {
                     status = "STOPPED OUT -> RE-ENTRY PLACED";
                     invalidation_details = "C3 filled entry at "+DoubleToString(entry_price,2)+" and hit SL at "+DoubleToString(sl_price,2)+". "+
                                           "New trade immediately placed at same entry with "+DoubleToString(fixed_sl_buffer,2)+" buffer.";
                  }
                  else
                  {
                     status = "FILLED";
                     invalidation_details = "C3 filled the trade at "+DoubleToString(entry_price,2)+". Trade is active!";
                  }
               }
               else
               {
                  // 2. If NOT filled, check if C3 closed below C2 Low (Invalidation)
                  if(c3_close < c2_low)
                  {
                     status = "CANCELED (Invalidated)";
                     invalidation_details = "C3 closed below C2 low ("+DoubleToString(c3_close,2)+" < "+DoubleToString(c2_low,2)+") without filling. Order deleted.";
                  }
                  else
                  {
                     status = "Pending (Unfilled)";
                     invalidation_details = "C3 did not fill Entry nor close below C2 Low. Order remains pending.";
                  }
               }
            }
            
            // Add setup to array
            int idx = ArraySize(setups);
            ArrayResize(setups, idx+1);
            setups[idx].type = "BULLISH (Buy)";
            setups[idx].c1_num = c1_brick_num;
            setups[idx].c2_num = c2_brick_num;
            setups[idx].c1_time = c1_time;
            setups[idx].c2_time = c2_time;
            setups[idx].entry = entry_price;
            setups[idx].sl = sl_price;
            setups[idx].tp = tp_price;
            setups[idx].risk = risk;
            setups[idx].status = status;
            setups[idx].invalidation_details = invalidation_details;
            setups[idx].c2_idx = i;
         }
      }
   }
   
   return(true);
}

//+------------------------------------------------------------------+
//| Calculate lot size function                                      |
//+------------------------------------------------------------------+
double CalculateLotSize(double risk_percent, double sl_distance, string symbol)
{
   // Get account info
   double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(account_balance <= 0)
      return 0.01; // Minimum lot size
   
   // Calculate risk amount
   double risk_amount = account_balance * (risk_percent / 100.0);
   
   // Get symbol info
   double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double volume_min = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   
   if(tick_value <= 0 || tick_size <= 0)
      return volume_min;
   
   // Convert SL distance to ticks
   double sl_ticks = sl_distance / tick_size;
   
   // Calculate lot size: risk_amount / (sl_ticks * tick_value)
   double lot_size = 0.01; // Default minimum
   if(sl_ticks > 0 && tick_value > 0)
   {
      lot_size = risk_amount / (sl_ticks * tick_value);
   }
   
   // Round to nearest 0.01 multiple
   lot_size = MathRound(lot_size * 100) / 100;
   
   // Ensure minimum lot size
   if(lot_size < volume_min)
      lot_size = volume_min;
   
   return lot_size;
}

//+------------------------------------------------------------------+
//| Place stop order function                                        |
//+------------------------------------------------------------------+
void PlaceStopOrder(string symbol, ENUM_ORDER_TYPE order_type, double price, double sl, double tp, double lot_size, string comment)
{
   MqlTradeRequest request;
   MqlTradeResult result;
   
   ZeroMemory(request);
   ZeroMemory(result);
   
   request.action = TRADE_ACTION_PENDING;
   request.symbol = symbol;
   request.volume = lot_size;
   request.type = order_type;
   request.price = price;
   request.sl = sl;
   request.tp = tp;
   request.deviation = 10;
   request.magic = 234000;
   request.comment = comment;
   request.type_time = ORDER_TIME_GTC; // Good till cancelled
   request.type_filling = ORDER_FILLING_IOC;
   
   if(!OrderSend(request, result))
   {
      Print("OrderSend failed. Error: ", GetLastError());
      return;
   }
   
   if(result.retcode == TRADE_RETCODE_DONE)
   {
      Print("Order placed successfully: ", comment, 
            ", Ticket: ", result.order,
            ", Volume: ", lot_size,
            ", Price: ", price,
            ", SL: ", sl,
            ", TP: ", tp);
   }
   else
   {
      Print("Order placement failed: ", result.comment, 
            ", Retcode: ", result.retcode);
   }
}
//+------------------------------------------------------------------+
