//+------------------------------------------------------------------+
//|                                                 WakaClone_EA.mq5 |
//|  Faithful rebuild of the reverse-engineered Waka Waka mechanics  |
//|  (per public video dissection of the marketplace EA):            |
//|                                                                  |
//|   ENTRY  : RSI(20) offset 15 from 50 -> buy < 35 / sell > 65,    |
//|            AND close beyond the 35-bar low/high. New bar only.   |
//|   GRID   : step 35 pips x smart multiplier ATR(96)/ATR(672)      |
//|            clamped [1.0 .. 1.5]. Adds on new bar only.           |
//|   LOTS   : ladder x1 (2nd), x2 (3rd-5th), x1.6 (6th+);           |
//|            base lot from deposit-load % / dynamic / fixed.       |
//|   TP     : broker-side, weighted-average price +/- 10 pips,      |
//|            recalculated ONLY when a new level opens.             |
//|            Smart TP option: 10% of BB(35) width, 5% when >=5     |
//|            levels deep (pulls TP closer to escape big grids).    |
//|   SL     : none by default (original uses ~1000 pips).           |
//|                                                                  |
//|  SAFETY LAYER (not in the original — keep it on):                |
//|   basket equity stop %, max total lots, daily halt, spread gate, |
//|   refuses non-DEMO accounts unless AllowLive=true.               |
//|  Omitted vs original: news filter, rollover windows, bookmark    |
//|  "grid level to start", hidden TP/OPO, panel, multi-symbol.      |
//+------------------------------------------------------------------+
#property copyright "Reverse-engineered Waka-Waka architecture, public sources"
#property version   "2.00"

#include <Trade\Trade.mqh>
CTrade trade;

enum ENUM_LOT_METHOD
{
   LOT_DEPOSIT_LOAD = 0,   // Deposit load % (original presets: 0.25/0.5/1/1.5)
   LOT_DYNAMIC      = 1,   // 0.01 per amount of balance
   LOT_FIXED        = 2    // Fixed lots
};

input group "=== Entry (decoded) ==="
input int    InpRsiPeriod   = 20;    // RSI period
input double InpRsiOffset   = 15.0;  // RSI offset from 50 (15 -> buy<35 / sell>65)
input int    InpBBPeriod    = 35;    // BB / extreme-lookback period
input bool   InpExtremeFilt = true;  // Require close beyond N-bar low/high
input bool   InpAllowLong   = true;  // Allow buy grids
input bool   InpAllowShort  = true;  // Allow sell grids (original hedges both)

input group "=== Grid (decoded) ==="
input double InpStepPips    = 35.0;  // Grid step (pips)
input bool   InpSmartDist   = true;  // Smart distance: step x ATR96/ATR672 [1..1.5]
input int    InpAtrFast     = 96;    // Fast ATR period
input int    InpAtrSlow     = 672;   // Slow ATR period
input double InpMult2nd     = 1.0;   // 2nd trade multiplier
input double InpMult3to5    = 2.0;   // 3rd-5th trade multiplier
input double InpMult6plus   = 1.6;   // 6th+ trade multiplier
input int    InpMaxTrades   = 8;     // Max trades per grid

input group "=== Lots (decoded) ==="
input ENUM_LOT_METHOD InpLotMethod = LOT_DEPOSIT_LOAD; // Base lot method
input double InpDepositLoad = 0.25;  // Deposit load % (0.25=low ... 1.5=high risk)
input double InpDynPerAmt   = 2000;  // Dynamic: 0.01 lots per this balance
input double InpFixedLots   = 0.01;  // Fixed lots

input group "=== Exit (decoded) ==="
input double InpTpPips      = 10.0;  // TP distance from weighted average (pips)
input bool   InpSmartTP     = true;  // Smart TP: TpPips% of BB width (10 -> 10%)
input double InpSlPips      = 0;     // Stop-loss pips (0 = none, like original)

input group "=== Safety (NOT in original - keep on) ==="
input double InpEquityStopPct = 25.0; // Basket equity stop (% equity, 0 = off)
input double InpMaxTotalLots  = 1.0;  // Hard cap on summed lots per basket
input double InpMaxDailyLoss  = 30.0; // Daily loss halt (% of day-start equity)
input int    InpMaxSpreadPts  = 30;   // Max spread (points)
input bool   InpAllowLive     = false;// Allow LIVE account (leave false!)
input long   InpMagic         = 777004;// Magic number

int      rsiHandle = INVALID_HANDLE;
int      maHandle  = INVALID_HANDLE;
int      sdHandle  = INVALID_HANDLE;
int      atrFastH  = INVALID_HANDLE;
int      atrSlowH  = INVALID_HANDLE;
int      curDoy      = -1;
double   dayStartEq  = 0;
bool     haltedToday = false;
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   ENUM_ACCOUNT_TRADE_MODE mode = (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(mode != ACCOUNT_TRADE_MODE_DEMO && !InpAllowLive)
   {
      Alert("WakaClone EA: account is NOT demo and AllowLive=false - refusing to start.");
      return INIT_FAILED;
   }
   rsiHandle = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);
   maHandle  = iMA(_Symbol, _Period, InpBBPeriod, 0, MODE_SMA, PRICE_CLOSE);
   sdHandle  = iStdDev(_Symbol, _Period, InpBBPeriod, 0, MODE_SMA, PRICE_CLOSE);
   atrFastH  = iATR(_Symbol, _Period, InpAtrFast);
   atrSlowH  = iATR(_Symbol, _Period, InpAtrSlow);
   if(rsiHandle == INVALID_HANDLE || maHandle == INVALID_HANDLE || sdHandle == INVALID_HANDLE ||
      atrFastH == INVALID_HANDLE || atrSlowH == INVALID_HANDLE)
      return INIT_FAILED;
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);
   PrintFormat("WakaClone EA started on %s %s | demo=%s | RSI(%d) +/-%g, step %g pips smart=%s, ladder x%g/x%g/x%g, TP %g %s",
               _Symbol, EnumToString(_Period), mode == ACCOUNT_TRADE_MODE_DEMO ? "yes" : "NO (LIVE!)",
               InpRsiPeriod, InpRsiOffset, InpStepPips, InpSmartDist ? "on" : "off",
               InpMult2nd, InpMult3to5, InpMult6plus, InpTpPips, InpSmartTP ? "% of BB width" : "pips");
   PrintFormat("trade permissions | terminal algo-trading: %s | this EA allowed: %s",
               TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ? "ON" : "OFF",
               MQLInfoInteger(MQL_TRADE_ALLOWED) ? "YES" : "NO - enable in chart's EA settings");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(maHandle  != INVALID_HANDLE) IndicatorRelease(maHandle);
   if(sdHandle  != INVALID_HANDLE) IndicatorRelease(sdHandle);
   if(atrFastH  != INVALID_HANDLE) IndicatorRelease(atrFastH);
   if(atrSlowH  != INVALID_HANDLE) IndicatorRelease(atrSlowH);
   Comment("");
}

//+------------------------------------------------------------------+
double PipSize() { return _Point * ((_Digits == 3 || _Digits == 5) ? 10.0 : 1.0); }

double NormLots(double lots)
{
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0)
      lots = MathRound(lots / step) * step;
   return MathMax(minL, MathMin(maxL, lots));
}

// ladder from the videos: level 0 = base; x1 for 2nd; x2 each for 3rd-5th; x1.6 each 6th+
double MultForLevel(int level)
{
   double m = 1.0;
   for(int i = 1; i <= level; i++)
   {
      if(i == 1)      m *= InpMult2nd;
      else if(i <= 4) m *= InpMult3to5;
      else            m *= InpMult6plus;
   }
   return m;
}

// deposit-load sizing per the videos: (freeMargin/marginPerLot) x (100/leverage) x load%
double BaseLots()
{
   if(InpLotMethod == LOT_FIXED)
      return NormLots(InpFixedLots);
   if(InpLotMethod == LOT_DYNAMIC)
   {
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      return NormLots(0.01 * MathFloor(bal / MathMax(1.0, InpDynPerAmt)));
   }
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double leverage   = (double)AccountInfoInteger(ACCOUNT_LEVERAGE);
   double m1 = 0;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, ask, m1) || m1 <= 0 || leverage <= 0)
      return NormLots(0.01);
   double lots = (freeMargin / m1) * (100.0 / leverage) * (InpDepositLoad / 100.0);
   return NormLots(lots);
}

// basket snapshot for one direction
void Basket(ENUM_POSITION_TYPE dir, int &count, double &lots, double &wavg,
            double &worst, double &baseLot, double &pl)
{
   count = 0; lots = 0; wavg = 0; worst = 0; baseLot = 0; pl = 0;
   double priceLots = 0;
   datetime earliest = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != dir)
         continue;
      count++;
      double v  = PositionGetDouble(POSITION_VOLUME);
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
      lots += v;
      priceLots += op * v;
      pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(worst == 0 || (dir == POSITION_TYPE_BUY && op < worst) || (dir == POSITION_TYPE_SELL && op > worst))
         worst = op;
      if(earliest == 0 || ot < earliest) { earliest = ot; baseLot = v; }
   }
   if(lots > 0)
      wavg = priceLots / lots;
}

void CloseBasket(ENUM_POSITION_TYPE dir, string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == dir)
         trade.PositionClose(tk);
   }
   PrintFormat("%s basket closed: %s", dir == POSITION_TYPE_BUY ? "BUY" : "SELL", reason);
}

// weighted TP for the whole basket, set on every position (decoded behaviour)
void SetBasketTP(ENUM_POSITION_TYPE dir, double wavg, int levelCount, double bbWidth)
{
   double pip = PipSize();
   double tpDist;
   if(InpSmartTP && bbWidth > 0)
   {
      double pct = InpTpPips / 100.0;          // 10 pips -> 10% of BB width
      if(levelCount >= 5) pct /= 2.0;          // deep grid: pull TP closer (videos: 10% -> 5%)
      tpDist = pct * bbWidth;
   }
   else
      tpDist = InpTpPips * pip;
   double tp = dir == POSITION_TYPE_BUY ? wavg + tpDist : wavg - tpDist;
   tp = NormalizeDouble(tp, _Digits);
   double sl = 0;
   if(InpSlPips > 0)
      sl = NormalizeDouble(dir == POSITION_TYPE_BUY ? wavg - InpSlPips * pip : wavg + InpSlPips * pip, _Digits);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != dir)
         continue;
      double curTP = PositionGetDouble(POSITION_TP);
      double curSL = PositionGetDouble(POSITION_SL);
      if(MathAbs(curTP - tp) > _Point || MathAbs(curSL - sl) > _Point)
         trade.PositionModify(tk, sl, tp);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != curDoy)
   {
      curDoy      = dt.day_of_year;
      dayStartEq  = AccountInfoDouble(ACCOUNT_EQUITY);
      haltedToday = false;
   }

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   // safety: per-basket equity stop + daily circuit breaker (every tick)
   for(int d = 0; d < 2; d++)
   {
      ENUM_POSITION_TYPE dir = d == 0 ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      int count; double lots, wavg, worst, baseLot, pl;
      Basket(dir, count, lots, wavg, worst, baseLot, pl);
      if(count > 0 && InpEquityStopPct > 0 && pl <= -eq * InpEquityStopPct / 100.0)
      {
         CloseBasket(dir, StringFormat("EQUITY STOP %+.2f", pl));
         haltedToday = true;
      }
   }
   if(dayStartEq > 0 && eq <= dayStartEq * (1.0 - InpMaxDailyLoss / 100.0))
      haltedToday = true;

   // decoded behaviour: everything else on NEW BAR only
   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == lastBarTime)
      return;
   lastBarTime = t0;
   ProcessBar();
}

//+------------------------------------------------------------------+
void ProcessBar()
{
   double rsiB[], maB[], sdB[], afB[], asB[];
   ArraySetAsSeries(rsiB, true);
   ArraySetAsSeries(maB, true);
   ArraySetAsSeries(sdB, true);
   ArraySetAsSeries(afB, true);
   ArraySetAsSeries(asB, true);
   if(CopyBuffer(rsiHandle, 0, 0, 3, rsiB) < 3) return;
   if(CopyBuffer(maHandle, 0, 0, 3, maB)   < 3) return;
   if(CopyBuffer(sdHandle, 0, 0, 3, sdB)   < 3) return;
   if(CopyBuffer(atrFastH, 0, 0, 3, afB)   < 3) return;
   if(CopyBuffer(atrSlowH, 0, 0, 3, asB)   < 3) return;

   double rsi     = rsiB[1];
   double bbWidth = 4.0 * sdB[1];            // (MA+2sd)-(MA-2sd)
   double smart   = 1.0;
   if(InpSmartDist && asB[1] > 0)
      smart = MathMax(1.0, MathMin(1.5, afB[1] / asB[1]));   // decoded clamp [1..1.5]

   double pip    = PipSize();
   double stepPx = InpStepPips * pip * smart;
   double c1     = iClose(_Symbol, _Period, 1);
   int    hiBar  = iHighest(_Symbol, _Period, MODE_HIGH, InpBBPeriod, 2);
   int    loBar  = iLowest(_Symbol, _Period, MODE_LOW, InpBBPeriod, 2);
   double recentHi = hiBar >= 0 ? iHigh(_Symbol, _Period, hiBar) : 0;
   double recentLo = loBar >= 0 ? iLow(_Symbol, _Period, loBar) : 0;

   bool spreadOk = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPts;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   string hb = StringFormat("WakaClone | RSI %.1f (buy<%.0f sell>%.0f) | smart dist x%.2f -> %.1f pips | BBw %.5f%s\n",
                            rsi, 50 - InpRsiOffset, 50 + InpRsiOffset, smart, stepPx / pip, bbWidth,
                            haltedToday ? " | HALTED TODAY" : "");

   for(int d = 0; d < 2; d++)
   {
      ENUM_POSITION_TYPE dir = d == 0 ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      if(dir == POSITION_TYPE_BUY && !InpAllowLong)  continue;
      if(dir == POSITION_TYPE_SELL && !InpAllowShort) continue;

      int count; double lots, wavg, worst, baseLot, pl;
      Basket(dir, count, lots, wavg, worst, baseLot, pl);
      hb += StringFormat("%s basket: %d/%d lvls | %.2f lots | float %+.2f\n",
                         dir == POSITION_TYPE_BUY ? "BUY " : "SELL", count, InpMaxTrades, lots, pl);

      if(haltedToday || !spreadOk)
         continue;

      // ---- seed (decoded: RSI offset + close beyond N-bar extreme) ----
      if(count == 0)
      {
         double seed = BaseLots();
         if(seed <= 0) continue;
         if(dir == POSITION_TYPE_BUY && rsi < 50 - InpRsiOffset &&
            (!InpExtremeFilt || (recentLo > 0 && c1 < recentLo)))
         {
            if(trade.Buy(seed, _Symbol, 0.0, 0.0, 0.0, "waka seed B"))
            {
               Basket(dir, count, lots, wavg, worst, baseLot, pl);
               SetBasketTP(dir, wavg, count, bbWidth);
               PrintFormat("SEED BUY %.2f lots (RSI %.1f)", seed, rsi);
            }
         }
         else if(dir == POSITION_TYPE_SELL && rsi > 50 + InpRsiOffset &&
                 (!InpExtremeFilt || (recentHi > 0 && c1 > recentHi)))
         {
            if(trade.Sell(seed, _Symbol, 0.0, 0.0, 0.0, "waka seed S"))
            {
               Basket(dir, count, lots, wavg, worst, baseLot, pl);
               SetBasketTP(dir, wavg, count, bbWidth);
               PrintFormat("SEED SELL %.2f lots (RSI %.1f)", seed, rsi);
            }
         }
      }
      // ---- grid add (decoded: step beyond furthest entry, ladder lots) ----
      else if(count < InpMaxTrades)
      {
         double nextLots = NormLots(baseLot * MultForLevel(count));
         if(lots + nextLots > InpMaxTotalLots)
            continue;
         bool trigger = dir == POSITION_TYPE_BUY ? (ask <= worst - stepPx) : (bid >= worst + stepPx);
         if(!trigger)
            continue;
         bool ok = dir == POSITION_TYPE_BUY
                   ? trade.Buy(nextLots, _Symbol, 0.0, 0.0, 0.0, StringFormat("waka L%d", count))
                   : trade.Sell(nextLots, _Symbol, 0.0, 0.0, 0.0, StringFormat("waka L%d", count));
         if(ok)
         {
            Basket(dir, count, lots, wavg, worst, baseLot, pl);
            SetBasketTP(dir, wavg, count, bbWidth);   // recalc weighted TP only on new level
            PrintFormat("GRID %s L%d %.2f lots (step %.1f pips)",
                        dir == POSITION_TYPE_BUY ? "BUY" : "SELL", count - 1, nextLots, stepPx / pip);
         }
      }
   }
   Comment(hb);
}
//+------------------------------------------------------------------+
