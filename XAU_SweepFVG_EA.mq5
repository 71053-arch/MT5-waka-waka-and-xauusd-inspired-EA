//+------------------------------------------------------------------+
//|                                            XAU_SweepFVG_EA.mq5  |
//|  Native MT5 port of the PA·LIQ·FVG A+ playbook (zero discretion)|
//|                                                                  |
//|  1. Liquidity SWEEP (wick through swing H/L, close back) = arm   |
//|  2. Structure agreement (bullish trend->longs, bearish->shorts)  |
//|  3. Optional: discount/premium (50% eq) + TREND regime (ER)      |
//|  4. ENTRY on tap of a valid FVG midline (CE) while armed         |
//|  5. Bracket: SL beyond sweep wick + ATR buffer, TP at R multiple |
//|                                                                  |
//|  Guards: max trades/day, daily loss halt (flattens), cooldown    |
//|  after loss, session hours, max spread, hard lot cap.            |
//|  SAFETY: refuses to run on a non-DEMO account unless AllowLive.  |
//+------------------------------------------------------------------+
#property copyright "PA-LIQ-FVG playbook port"
#property version   "1.00"

#include <Trade\Trade.mqh>
CTrade trade;

input group "=== Setup ==="
input int    InpSwingLen     = 8;     // Swing/pivot length (1m:5-6, 15m:8-9)
input int    InpSweepValid   = 20;    // Sweep stays armed (bars)
input double InpFvgMinAtr    = 0.25;  // Min FVG size (x ATR)
input int    InpFvgMaxAge    = 120;   // Max FVG age (bars)

input group "=== Filters ==="
input bool   InpAllowLong    = true;  // Allow longs
input bool   InpAllowShort   = true;  // Allow shorts
input bool   InpUseEqFilter  = true;  // Require discount(long)/premium(short)
input bool   InpUseErFilter  = true;  // Require TREND regime (Efficiency Ratio)
input int    InpErLen        = 20;    // ER length
input double InpErMin        = 0.30;  // ER threshold
input int    InpSessStartHr  = 10;    // Session start hour (server time) — London open
input int    InpSessEndHr    = 23;    // Session end hour (server time) — NY close
input int    InpMaxSpreadPts = 60;    // Max spread (points) to allow entry

input group "=== Risk ==="
input double InpRiskPct      = 0.5;   // Risk per trade (% equity)
input double InpSlAtrBuf     = 0.5;   // SL buffer beyond sweep wick (x ATR)
input double InpTpR          = 2.0;   // Take profit (R multiple)
input double InpBreakEvenR   = 0.0;   // Move SL to entry at this R multiple (0 = off)
input double InpMaxLots      = 1.0;   // Hard cap on lots per order

input group "=== Guards ==="
input int    InpMaxTradesDay = 3;     // Max trades per day
input double InpMaxDailyLoss = 2.0;   // Daily loss halt (% equity)
input int    InpCooldownBars = 10;    // Cooldown after a losing trade (bars)
input bool   InpAllowLive    = false; // Allow LIVE account (leave false!)
input long   InpMagic        = 777001;// Magic number

//--- state
int      atrHandle   = INVALID_HANDLE;
double   rngH = 0, rngL = 0;
bool     hasH = false, hasL = false;
bool     hSwept = true, lSwept = true;
int      msTrend = 0;
bool     armL = false, armS = false;
double   sweepLo = 0, sweepHi = 0;
long     armLBar = 0, armSBar = 0;

double   bullBtm[], bullCE[];
long     bullBorn[];
double   bearTop[], bearCE[];
long     bearBorn[];

int      tradesToday = 0;
int      curDoy      = -1;
double   dayStartEq  = 0;
long     lastLossBar = -1000000;
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   ENUM_ACCOUNT_TRADE_MODE mode = (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(mode != ACCOUNT_TRADE_MODE_DEMO && !InpAllowLive)
   {
      Alert("XAU SweepFVG EA: account is NOT demo and AllowLive=false - refusing to start.");
      return INIT_FAILED;
   }
   atrHandle = iATR(_Symbol, _Period, 14);
   if(atrHandle == INVALID_HANDLE)
      return INIT_FAILED;
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);
   PrintFormat("XAU SweepFVG EA started on %s %s | demo=%s risk=%.2f%%",
               _Symbol, EnumToString(_Period),
               mode == ACCOUNT_TRADE_MODE_DEMO ? "yes" : "NO (LIVE!)", InpRiskPct);
   PrintFormat("trade permissions | terminal algo-trading: %s | this EA allowed: %s",
               TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ? "ON" : "OFF",
               MQLInfoInteger(MQL_TRADE_ALLOWED) ? "YES" : "NO - enable in chart's EA settings");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| helpers                                                          |
//+------------------------------------------------------------------+
void PushD(double &a[], double v) { int n = ArraySize(a); ArrayResize(a, n + 1); a[n] = v; }
void PushL(long &a[], long v)     { int n = ArraySize(a); ArrayResize(a, n + 1); a[n] = v; }
void RemD(double &a[], int idx)   { int n = ArraySize(a); for(int i = idx; i < n - 1; i++) a[i] = a[i + 1]; ArrayResize(a, n - 1); }
void RemL(long &a[], int idx)     { int n = ArraySize(a); for(int i = idx; i < n - 1; i++) a[i] = a[i + 1]; ArrayResize(a, n - 1); }

bool HavePosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
   }
   return false;
}

void CloseAllOurs()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         trade.PositionClose(tk);
   }
}

bool DailyHalted()
{
   if(dayStartEq <= 0)
      return false;
   return AccountInfoDouble(ACCOUNT_EQUITY) <= dayStartEq * (1.0 - InpMaxDailyLoss / 100.0);
}

void ManageBreakEven()
{
   if(InpBreakEvenR <= 0)
      return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      long   type  = PositionGetInteger(POSITION_TYPE);
      if(sl == 0)
         continue;
      double risk = type == POSITION_TYPE_BUY ? entry - sl : sl - entry;
      if(risk <= 0)
         continue;   // SL already at/past entry
      double cur  = type == POSITION_TYPE_BUY ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                              : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double prog = type == POSITION_TYPE_BUY ? cur - entry : entry - cur;
      if(prog >= InpBreakEvenR * risk)
         trade.PositionModify(tk, NormalizeDouble(entry, _Digits), PositionGetDouble(POSITION_TP));
   }
}

bool SessionOk(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   if(InpSessStartHr <= InpSessEndHr)
      return dt.hour >= InpSessStartHr && dt.hour < InpSessEndHr;
   return dt.hour >= InpSessStartHr || dt.hour < InpSessEndHr; // overnight wrap
}

double CalcLots(double slDist, bool isBuy, double refPrice)
{
   double eq        = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = eq * InpRiskPct / 100.0;
   if(slDist <= 0)
      return 0;
   // broker-proof: ask the terminal what 1.0 lot actually loses over slDist
   // (some servers misreport SYMBOL_TRADE_TICK_VALUE — live trades showed 10x oversizing)
   double lossPerLot = 0.0;
   double p = 0.0;
   double slPrice = isBuy ? refPrice - slDist : refPrice + slDist;
   if(OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, refPrice, slPrice, p) && p < 0)
      lossPerLot = -p;
   else
   {
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0 || tickVal <= 0)
         return 0;
      lossPerLot = slDist / tickSize * tickVal;
   }
   if(lossPerLot <= 0)
      return 0;
   double lots = riskMoney / lossPerLot;
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0)
      lots = MathFloor(lots / step) * step;
   lots = MathMax(minL, MathMin(maxL, lots));
   lots = MathMin(lots, InpMaxLots);
   return lots;
}

//+------------------------------------------------------------------+
void OnTick()
{
   // day rollover
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != curDoy)
   {
      curDoy      = dt.day_of_year;
      tradesToday = 0;
      dayStartEq  = AccountInfoDouble(ACCOUNT_EQUITY);
   }

   // daily halt: flatten immediately, every tick
   if(DailyHalted() && HavePosition())
      CloseAllOurs();

   // break-even management (every tick)
   ManageBreakEven();

   // act once per bar
   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == lastBarTime)
      return;
   lastBarTime = t0;
   ProcessBar();
}

//+------------------------------------------------------------------+
void ProcessBar()
{
   int need = MathMax(2 * InpSwingLen + 3, InpErLen + 3) + 5;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, _Period, 0, MathMax(need, 300), r) < need)
      return;

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(atrHandle, 0, 0, 3, atrBuf) < 3)
      return;
   double atr = atrBuf[1];
   if(atr <= 0)
      return;

   long barNum = Bars(_Symbol, _Period);

   //--- confirmed pivots (candidate = shift SwingLen+1)
   int p = InpSwingLen + 1;
   bool isPH = true, isPL = true;
   for(int i = 1; i <= InpSwingLen; i++)
   {
      if(r[p].high <= r[p + i].high || r[p].high <= r[p - i].high) isPH = false;
      if(r[p].low  >= r[p + i].low  || r[p].low  >= r[p - i].low)  isPL = false;
      if(!isPH && !isPL) break;
   }
   if(isPH) { rngH = r[p].high; hasH = true; hSwept = false; }
   if(isPL) { rngL = r[p].low;  hasL = true; lSwept = false; }

   //--- structure (close cross of range levels on the just-closed bar)
   if(hasH && r[2].close <= rngH && r[1].close > rngH) { msTrend = 1;  hSwept = true; }
   if(hasL && r[2].close >= rngL && r[1].close < rngL) { msTrend = -1; lSwept = true; }

   //--- sweeps (wick through + close back)
   bool bslSweep = hasH && !hSwept && r[1].high > rngH && r[1].close < rngH;
   bool sslSweep = hasL && !lSwept && r[1].low  < rngL && r[1].close > rngL;
   if(bslSweep) { hSwept = true; armS = true; sweepHi = r[1].high; armSBar = barNum; }
   if(sslSweep) { lSwept = true; armL = true; sweepLo = r[1].low;  armLBar = barNum; }
   if(armL && barNum - armLBar > InpSweepValid) armL = false;
   if(armS && barNum - armSBar > InpSweepValid) armS = false;

   //--- FVG detection on closed bars (bull: low[2] > high[4])
   if(r[2].low > r[4].high && (r[2].low - r[4].high) >= InpFvgMinAtr * atr)
   {
      PushD(bullBtm, r[4].high);
      PushD(bullCE, (r[2].low + r[4].high) / 2.0);
      PushL(bullBorn, barNum);
      if(ArraySize(bullBtm) > 10) { RemD(bullBtm, 0); RemD(bullCE, 0); RemL(bullBorn, 0); }
   }
   if(r[2].high < r[4].low && (r[4].low - r[2].high) >= InpFvgMinAtr * atr)
   {
      PushD(bearTop, r[4].low);
      PushD(bearCE, (r[4].low + r[2].high) / 2.0);
      PushL(bearBorn, barNum);
      if(ArraySize(bearTop) > 10) { RemD(bearTop, 0); RemD(bearCE, 0); RemL(bearBorn, 0); }
   }

   //--- purge violated/expired FVGs, detect CE taps on the just-closed bar
   bool bullTap = false, bearTap = false;
   for(int i = ArraySize(bullBtm) - 1; i >= 0; i--)
   {
      if(r[1].close < bullBtm[i] || barNum - bullBorn[i] > InpFvgMaxAge)
      { RemD(bullBtm, i); RemD(bullCE, i); RemL(bullBorn, i); }
      else if(r[1].low <= bullCE[i])
         bullTap = true;
   }
   for(int i = ArraySize(bearTop) - 1; i >= 0; i--)
   {
      if(r[1].close > bearTop[i] || barNum - bearBorn[i] > InpFvgMaxAge)
      { RemD(bearTop, i); RemD(bearCE, i); RemL(bearBorn, i); }
      else if(r[1].high >= bearCE[i])
         bearTap = true;
   }

   //--- Efficiency Ratio (regime)
   double num = MathAbs(r[1].close - r[1 + InpErLen].close);
   double den = 0;
   for(int i = 1; i <= InpErLen; i++)
      den += MathAbs(r[i].close - r[i + 1].close);
   double er = den == 0 ? 0 : num / den;

   //--- equilibrium
   bool   eqOk  = hasH && hasL && rngH > rngL;
   double eqLvl = eqOk ? (rngH + rngL) / 2.0 : 0;

   //--- guards
   bool spreadOk = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPts;
   bool guards = SessionOk(r[0].time) && spreadOk && !DailyHalted() &&
                 tradesToday < InpMaxTradesDay &&
                 (barNum - lastLossBar > InpCooldownBars) && !HavePosition();

   //--- heartbeat: live gate checklist on the chart (proof of life)
   string hb = StringFormat("XAU SweepFVG A+ bot  |  scanning every bar  |  trades today %d/%d%s\n",
                            tradesToday, InpMaxTradesDay, DailyHalted() ? "  |  DAILY HALT" : "");
   hb += StringFormat("LONG : sweep %s | structure %s | FVG tap %s | discount %s | ER %.2f (need %.2f)\n",
                      armL ? "YES" : "no", msTrend == 1 ? "YES" : "no", bullTap ? "YES" : "no",
                      (eqOk && r[1].close < eqLvl) ? "YES" : "no", er, InpErMin);
   hb += StringFormat("SHORT: sweep %s | structure %s | FVG tap %s | premium %s | spread %d pts (max %d)",
                      armS ? "YES" : "no", msTrend == -1 ? "YES" : "no", bearTap ? "YES" : "no",
                      (eqOk && r[1].close > eqLvl) ? "YES" : "no",
                      (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), InpMaxSpreadPts);
   Comment(hb);

   //--- LONG: sweep armed + bullish structure + FVG tap (+ filters)
   if(InpAllowLong && guards && armL && msTrend == 1 && bullTap &&
      (!InpUseEqFilter || (eqOk && r[1].close < eqLvl)) &&
      (!InpUseErFilter || er >= InpErMin))
   {
      double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl   = MathMin(sweepLo, r[1].low) - InpSlAtrBuf * atr;
      double dist = ask - sl;
      if(dist > 10 * _Point)
      {
         double tp   = ask + InpTpR * dist;
         double lots = CalcLots(dist, true, ask);
         if(lots > 0 && trade.Buy(lots, _Symbol, 0.0,
                                  NormalizeDouble(sl, _Digits),
                                  NormalizeDouble(tp, _Digits), "sweep+fvg L"))
         {
            tradesToday++;
            armL = false;
            PrintFormat("LONG %.2f lots @ %.2f sl=%.2f tp=%.2f (er=%.2f)", lots, ask, sl, tp, er);
         }
      }
   }

   //--- SHORT: mirrored
   if(InpAllowShort && guards && armS && msTrend == -1 && bearTap &&
      (!InpUseEqFilter || (eqOk && r[1].close > eqLvl)) &&
      (!InpUseErFilter || er >= InpErMin))
   {
      double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl   = MathMax(sweepHi, r[1].high) + InpSlAtrBuf * atr;
      double dist = sl - bid;
      if(dist > 10 * _Point)
      {
         double tp   = bid - InpTpR * dist;
         double lots = CalcLots(dist, false, bid);
         if(lots > 0 && trade.Sell(lots, _Symbol, 0.0,
                                   NormalizeDouble(sl, _Digits),
                                   NormalizeDouble(tp, _Digits), "sweep+fvg S"))
         {
            tradesToday++;
            armS = false;
            PrintFormat("SHORT %.2f lots @ %.2f sl=%.2f tp=%.2f (er=%.2f)", lots, bid, sl, tp, er);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| track losing closes for the cooldown guard                       |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;
   if(HistoryDealGetDouble(trans.deal, DEAL_PROFIT) < 0)
      lastLossBar = Bars(_Symbol, _Period);
}
//+------------------------------------------------------------------+
