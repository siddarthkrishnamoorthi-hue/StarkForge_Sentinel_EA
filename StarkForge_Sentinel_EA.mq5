//+------------------------------------------------------------------+
//|                                    StarkForge_Sentinel_EA.mq5    |
//|                            Copyright 2026, StarkForge Systems    |
//|                                                                  |
//|   London-NY Overlap Range Breakout & Retest EA for EURUSD        |
//|   -------------------------------------------------------------- |
//|   * M15 execution / H1 trend bias (EMA50/200 + ADX)              |
//|   * Asian/London range breakout + retest confirmation            |
//|   * ATR-based dynamic Stop-Loss                                  |
//|   * Multi-partial Take-Profit + ATR trailing runner              |
//|   * Break-Even at +1R                                            |
//|   * Prop-firm friendly risk manager (daily loss, DD, cons losses)|
//|   * No martingale / No grid / No averaging                       |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, StarkForge Systems"
#property link        "https://starkforge.systems"
#property version     "1.00"
#property description "StarkForge Sentinel EA - London-NY Overlap Range Breakout & Retest"
#property description "M15 execution with H1 trend bias, ATR SL, multi-partial TP, prop-firm risk"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_TREND_BIAS
  {
   TREND_BULL = 1,     // Bullish H1 bias
   TREND_BEAR = -1,    // Bearish H1 bias
   TREND_FLAT = 0      // No clear bias
  };

enum ENUM_SETUP_STATE
  {
   SETUP_NONE = 0,           // Waiting for range breakout
   SETUP_LONG_BREAKOUT = 1,  // Range high broken - waiting for retest
   SETUP_LONG_RETEST   = 2,  // Retest touched - waiting for confirming bar
   SETUP_SHORT_BREAKOUT= 3,  // Range low broken - waiting for retest
   SETUP_SHORT_RETEST  = 4,  // Retest touched - waiting for confirming bar
   SETUP_COOLDOWN      = 5,  // After entry, cooling down
   SETUP_INVALIDATED   = 6   // No valid setup remaining today
  };

enum ENUM_SL_MODE
  {
   SL_ATR    = 0,   // ATR-based dynamic SL
   SL_PIPS   = 1    // Fixed pip SL
  };

enum ENUM_SFS_LOG_LEVEL
  {
   SFS_LOG_DEBUG = 0,   // Verbose debugging
   SFS_LOG_INFO  = 1,   // Normal events
   SFS_LOG_WARN  = 2,   // Warnings
   SFS_LOG_ERROR = 3    // Errors only
  };

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== General ==="
input long   InpMagicNumber      = 20260703;        // Magic Number (unique per EA)
input string InpTradeComment     = "SF_Sentinel";   // Order comment tag
input bool   InpEnableTrading    = true;            // Master trade enable
input bool   InpVerboseLogging   = true;            // Log strategy events

input group "=== Session (Broker Time - hours 0..23) ==="
input int    InpRangeStartHour   = 2;               // Range window START hour (broker time)
input int    InpRangeEndHour     = 13;              // Range window END hour (broker time)
input int    InpTradeStartHour   = 15;              // Trade window START (London-NY overlap ~13:00 GMT)
input int    InpTradeEndHour     = 19;              // Trade window END   (~17:00 GMT)
input int    InpForceCloseHour   = 20;              // Force-close all trades at this broker hour (Fri)
input bool   InpCloseOnFriday    = true;            // Force flatten before weekend
input bool   InpSkipMondayFirstH = false;           // Skip first hour of Monday

input group "=== Trend Bias (H1) ==="
input int    InpEmaFastPeriod    = 50;              // H1 EMA fast period (safe 30..80)
input int    InpEmaSlowPeriod    = 200;             // H1 EMA slow period (safe 150..250)
input int    InpAdxPeriod        = 14;              // H1 ADX period (safe 10..20)
input double InpAdxThreshold     = 22.0;            // ADX min for trend (safe 18..28)

input group "=== Signal (M15 breakout + retest) ==="
input int    InpAtrPeriod        = 14;              // ATR period (M15) (safe 10..21)
input double InpRetestAtrMult    = 0.35;            // Retest tolerance = ATR * this  (safe 0.20..0.60)
input int    InpMaxRetestBars    = 12;              // Max M15 bars to await retest (safe 6..20)
input int    InpRsiPeriod        = 14;              // RSI period
input double InpRsiUpperBlock    = 72.0;            // No longs above this RSI (safe 68..78)
input double InpRsiLowerBlock    = 28.0;            // No shorts below this RSI (safe 22..32)
input int    InpCooldownBars     = 4;               // M15 bars pause after each entry

input group "=== Stop Loss / Take Profit ==="
input ENUM_SL_MODE InpSLMode     = SL_ATR;          // Stop-Loss mode
input double InpAtrSLMult        = 1.2;             // SL = ATR * this (safe 1.0..1.8)
input int    InpFixedSLPips      = 20;              // Fixed SL in pips (used if SL_PIPS)
input double InpMinSLPips        = 8.0;             // Min SL floor (pips)
input double InpMaxSLPips        = 60.0;            // Max SL cap (pips)
input double InpTP1_R            = 1.5;             // TP1 in R multiples (safe 1.2..2.0)
input double InpTP2_R            = 2.5;             // TP2 in R multiples (safe 2.0..3.5)
input double InpPartial1_Percent = 40.0;            // % of position closed at TP1
input double InpPartial2_Percent = 40.0;            // % of position closed at TP2
input double InpBreakEven_R      = 1.0;             // R multiple to move SL to BE
input double InpBreakEvenBufferP = 2.0;             // BE buffer in pips (spread cover)
input double InpTrailAtrMult     = 1.8;             // Trailing stop = ATR * this  (safe 1.2..2.5)

input group "=== Risk Management ==="
input double InpRiskPercent      = 0.75;            // Risk % per trade (safe 0.3..1.0)
input double InpMaxLots          = 10.0;            // Hard lot cap
input int    InpMaxTradesPerDay  = 2;               // Max entries per calendar day (broker)
input double InpDailyLossPercent = 2.0;             // Halt trading if -X% of start-of-day equity
input double InpMaxDDPercent     = 8.0;             // Emergency stop if equity DD >= X% from peak
input int    InpMaxConsecLoss    = 3;               // Consecutive loss count to trigger pause
input int    InpConsecPauseHours = 12;              // Hours to pause after cons losses

input group "=== Execution Filters ==="
input int    InpMaxSpreadPoints  = 25;              // Max allowed spread (points, 5-digit)
input double InpMinAtrPips       = 4.0;             // Skip if ATR(M15) below this (pips)
input int    InpMaxSlippagePts   = 15;              // Deviation for market orders (points)
input bool   InpUseNewsFilter    = false;           // Use naive intraday news time filter
input string InpNewsBlockTimes   = "08:30,12:30,14:00"; // CSV of broker-time HH:MM blocked windows
input int    InpNewsBlockMinutes = 20;              // Minutes around each news timestamp

input group "=== Dashboard ==="
input bool   InpShowDashboard    = true;            // Show info panel on chart
input int    InpDashX            = 12;              // Dashboard X offset (pixels)
input int    InpDashY            = 24;              // Dashboard Y offset (pixels)
input color  InpDashHeaderColor  = clrGold;         // Header text color
input color  InpDashLabelColor   = clrLightGray;    // Label color
input color  InpDashValueColor   = clrWhite;        // Value color
input color  InpDashOKColor      = clrLime;         // Good state
input color  InpDashBadColor     = clrRed;          // Bad state

input group "=== Broker Compatibility ==="
input string InpSymbolBase        = "EURUSD";       // Required base symbol (prefix/suffix auto-detected)
input bool   InpStrictSymbolCheck = true;           // Refuse to init if chart base != InpSymbolBase
input int    InpStopLevelBufferP  = 3;              // Extra pips beyond broker stops-level (safety cushion)
input bool   InpAutoFillingMode   = true;           // Auto-detect broker order filling mode

input group "=== Execution Robustness ==="
input int    InpModifyRetries     = 3;              // Retries for SL/TP modify (BE, trail, partial)
input int    InpModifyRetryDelayMs= 150;            // Delay between modify retries (milliseconds)
input int    InpMgmtTimerMs       = 250;            // Trade-management timer interval (milliseconds)
input int    InpDashRefreshMs     = 1000;           // Dashboard refresh interval (milliseconds)
input bool   InpUseMarginCheck    = true;           // Pre-check free margin before entry
input bool   InpRequireConnection = true;           // Skip trading if terminal not connected
input ENUM_SFS_LOG_LEVEL InpLogLevel = SFS_LOG_INFO; // Minimum log severity

//+------------------------------------------------------------------+
//| Constants                                                        |
//+------------------------------------------------------------------+
#define SF_PREFIX          "SFS_"
#define SF_DASH_BG_NAME    "SFS_DashBG"
#define SF_DASH_TITLE_NAME "SFS_DashTitle"

//+------------------------------------------------------------------+
//| Per-trade state (kept alongside terminal positions)              |
//+------------------------------------------------------------------+
struct STradeState
  {
   ulong    ticket;
   int      direction;      // +1 long, -1 short
   double   entryPrice;
   double   initSL;
   double   initVolume;
   double   rDistance;      // price distance from entry to initSL (abs)
   bool     beDone;
   bool     tp1Done;
   bool     tp2Done;
   datetime openTime;
  };

//+------------------------------------------------------------------+
//| Indicator value cache - refreshed once per new bar                |
//| Eliminates redundant CopyBuffer calls (RAM-resident, O(1) reads).  |
//+------------------------------------------------------------------+
struct SIndicatorCache
  {
   datetime m15BarTime;     // iTime(M15,0) when M15 values were last refreshed
   datetime h1BarTime;      // iTime(H1,0)  when H1  values were last refreshed
   double   atrM15;
   double   rsiM15;
   double   emaFastH1;
   double   emaSlowH1;
   double   adxH1;
   bool     validM15;
   bool     validH1;
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade         g_trade;
CSymbolInfo    g_sym;

// Indicator handles
int      g_hEmaFastH1  = INVALID_HANDLE;
int      g_hEmaSlowH1  = INVALID_HANDLE;
int      g_hAdxH1      = INVALID_HANDLE;
int      g_hAtrM15     = INVALID_HANDLE;
int      g_hRsiM15     = INVALID_HANDLE;

// Symbol-derived
double   g_point       = 0.0;
double   g_pipSize     = 0.0;    // 1 pip in price units (respects 3/5 digit symbols)
int      g_digits      = 0;
double   g_tickValue   = 0.0;
double   g_tickSize    = 0.0;
double   g_volMin      = 0.0;
double   g_volMax      = 0.0;
double   g_volStep     = 0.0;

// Range state (recomputed each new day after range window ends)
int      g_rangeDay        = -1;      // day-of-year for which range is valid
double   g_rangeHigh       = 0.0;
double   g_rangeLow        = 0.0;
bool     g_rangeValid      = false;

// Signal state machine
ENUM_SETUP_STATE g_setupState  = SETUP_NONE;
double           g_breakoutLvl = 0.0;
datetime         g_breakoutBar = 0;
int              g_setupBars   = 0;    // bars since breakout
int              g_cooldownBars= 0;    // bars remaining in cooldown

// Daily book-keeping
int      g_currentDay      = -1;
double   g_dayStartEquity  = 0.0;
double   g_dayPnL          = 0.0;
int      g_dayTradesOpened = 0;
int      g_consecLosses    = 0;
datetime g_pauseUntil      = 0;

// Bar tracker
datetime g_lastM15BarTime  = 0;

// Peak equity tracker (for DD emergency stop)
double   g_peakEquity      = 0.0;
bool     g_emergencyHalt   = false;

// Trade state array
STradeState g_states[];

// Cached news minutes-of-day (parsed once)
int      g_newsMinutes[];  // list of HH*60+MM entries

// --- Enterprise features ------------------------------------------

// Indicator cache (per-bar invalidation, avoids repeated CopyBuffer)
SIndicatorCache g_cache;

// Pre-allocated indicator buffers (avoid per-call heap allocation)
double   g_bufEmaFast[];
double   g_bufEmaSlow[];
double   g_bufAdx[];
double   g_bufAtr[];
double   g_bufRsi[];

// Broker execution limits (cached at init and after symbol events)
double   g_brokerStopDistance   = 0.0;   // Minimum SL/TP distance in price units (incl. buffer)
double   g_brokerFreezeDistance = 0.0;   // Freeze-level distance (no modifies allowed inside)

// Timer-driven dashboard throttling
uint     g_lastDashboardMs = 0;

//+------------------------------------------------------------------+
//| Forward declarations                                             |
//+------------------------------------------------------------------+
void   LogMsg(const string msg);
void   LogEvt(const ENUM_SFS_LOG_LEVEL lvl, const string msg);
void   UpdateDashboard();
void   RemoveDashboard();
bool   IsNewM15Bar();
bool   IsInHourWindow(const int hStart, const int hEnd, const int hourNow);
bool   IsRangeWindow(const MqlDateTime &dt);
bool   IsTradeWindow(const MqlDateTime &dt);
bool   IsForceCloseTime(const MqlDateTime &dt);
bool   IsWeekend(const MqlDateTime &dt);
bool   IsNewsBlocked(const MqlDateTime &dt);
bool   CalcTodayRange(const MqlDateTime &dt);
ENUM_TREND_BIAS GetTrendBias();
double GetATR();
double GetRSI();
bool   FiltersPassed(const int direction);
double NormalizeVolume(const double v);
double CalculateLots(const double slPricePts, double &outRiskAmount);
void   UpdateSignalState();
void   TryEnter();
bool   OpenTrade(const int direction, const double slPrice, const double rDist);
void   ManagePositions();
void   MoveToBreakEven(STradeState &st);
void   DoPartialClose(STradeState &st, const double percent);
void   TrailRunner(STradeState &st);
void   CloseAllMyPositions(const string reason);
void   AddState(const STradeState &st);
void   RemoveState(const ulong ticket);
int    FindStateIdx(const ulong ticket);
void   SyncStatesWithPositions();
int    CountMyPositions();
void   OnDailyReset(const MqlDateTime &dt);
void   ParseNewsTimes();
// --- Enterprise helpers ---
bool   IsSymbolCompatible();
void   RefreshBrokerLimits();
void   RefreshIndicatorCacheM15();
void   RefreshIndicatorCacheH1();
double ClampStopDistance(const int direction, const double refPrice, const double proposedSL);
bool   RetryModifyPosition(const ulong ticket, const double sl, const double tp);
bool   RetryPartialClose(const ulong ticket, const double vol);
bool   PreCheckMargin(const int direction, const double lots, const double refPrice);
bool   IsTradingContextReady();

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   // --- Basic sanity on inputs (fail fast if user configured impossible values) ---
   if(InpRangeStartHour < 0 || InpRangeStartHour > 23 ||
      InpRangeEndHour   < 0 || InpRangeEndHour   > 23 ||
      InpTradeStartHour < 0 || InpTradeStartHour > 23 ||
      InpTradeEndHour   < 0 || InpTradeEndHour   > 23)
     {
      Print("[SFS] FATAL: Session hours must be in 0..23");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpEmaFastPeriod <= 0 || InpEmaSlowPeriod <= 0 || InpEmaFastPeriod >= InpEmaSlowPeriod)
     {
      Print("[SFS] FATAL: EMA periods invalid (fast must be < slow, both > 0)");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpAtrPeriod < 2 || InpRsiPeriod < 2 || InpAdxPeriod < 2)
     {
      Print("[SFS] FATAL: Indicator periods too small");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 5.0)
     {
      Print("[SFS] FATAL: Risk % out of safe range (0..5)");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpPartial1_Percent + InpPartial2_Percent >= 100.0)
     {
      Print("[SFS] FATAL: Partials sum must be < 100 (a runner must remain)");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpTP1_R <= 0.0 || InpTP2_R <= InpTP1_R || InpBreakEven_R <= 0.0)
     {
      Print("[SFS] FATAL: TP/BE R multiples invalid");
      return(INIT_PARAMETERS_INCORRECT);
     }

   // --- Symbol facts ---
   if(!g_sym.Name(_Symbol))
     {
      Print("[SFS] FATAL: Cannot select symbol ", _Symbol);
      return(INIT_FAILED);
     }

   // --- Symbol compatibility (broker prefix/suffix aware) ---
   if(!IsSymbolCompatible())
     {
      if(InpStrictSymbolCheck)
        {
         PrintFormat("[SFS] FATAL: Chart symbol '%s' does not match required base '%s'",
                     _Symbol, InpSymbolBase);
         return(INIT_FAILED);
        }
      PrintFormat("[SFS] WARN: Chart symbol '%s' does not match base '%s' - strict check disabled",
                  _Symbol, InpSymbolBase);
     }

   g_sym.RefreshRates();
   g_point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   g_tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_volMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_volMax    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_volStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // Pip size respects fractional-pip (3/5 digit) brokers
   g_pipSize = (g_digits == 3 || g_digits == 5) ? g_point * 10.0 : g_point;

   if(g_point <= 0.0 || g_tickSize <= 0.0 || g_tickValue <= 0.0)
     {
      Print("[SFS] FATAL: Invalid symbol metrics (point/tick=0)");
      return(INIT_FAILED);
     }

   // --- Trade helper config ---
   g_trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   g_trade.SetDeviationInPoints((ulong)InpMaxSlippagePts);
   if(InpAutoFillingMode)
      g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   // --- Cache broker execution limits (stops-level, freeze-level) ---
   RefreshBrokerLimits();

   // --- Indicator handles (all created once, reused every tick) ---
   g_hEmaFastH1 = iMA(_Symbol, PERIOD_H1, InpEmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaSlowH1 = iMA(_Symbol, PERIOD_H1, InpEmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hAdxH1     = iADX(_Symbol, PERIOD_H1, InpAdxPeriod);
   g_hAtrM15    = iATR(_Symbol, PERIOD_M15, InpAtrPeriod);
   g_hRsiM15    = iRSI(_Symbol, PERIOD_M15, InpRsiPeriod, PRICE_CLOSE);

   if(g_hEmaFastH1 == INVALID_HANDLE || g_hEmaSlowH1 == INVALID_HANDLE ||
      g_hAdxH1     == INVALID_HANDLE || g_hAtrM15    == INVALID_HANDLE ||
      g_hRsiM15    == INVALID_HANDLE)
     {
      Print("[SFS] FATAL: Failed to create one or more indicator handles");
      return(INIT_FAILED);
     }

   // --- Pre-allocate indicator buffers (RAM-resident, no per-tick alloc) ---
   ArrayResize(g_bufEmaFast, 3);
   ArrayResize(g_bufEmaSlow, 3);
   ArrayResize(g_bufAdx,     3);
   ArrayResize(g_bufAtr,     3);
   ArrayResize(g_bufRsi,     3);
   ArraySetAsSeries(g_bufEmaFast, true);
   ArraySetAsSeries(g_bufEmaSlow, true);
   ArraySetAsSeries(g_bufAdx,     true);
   ArraySetAsSeries(g_bufAtr,     true);
   ArraySetAsSeries(g_bufRsi,     true);

   // Initialize indicator cache as "invalid" - forces first-tick refresh
   g_cache.validM15  = false;
   g_cache.validH1   = false;
   g_cache.m15BarTime= 0;
   g_cache.h1BarTime = 0;

   // --- State init ---
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_currentDay      = dt.day_of_year;
   g_dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   g_peakEquity      = MathMax(g_dayStartEquity, AccountInfoDouble(ACCOUNT_BALANCE));
   g_dayPnL          = 0.0;
   g_dayTradesOpened = 0;
   g_consecLosses    = 0;
   g_pauseUntil      = 0;
   g_setupState      = SETUP_NONE;
   g_rangeValid      = false;
   g_rangeDay        = -1;
   g_emergencyHalt   = false;

   ArrayResize(g_states, 0);
   SyncStatesWithPositions(); // adopt any pre-existing positions with our magic

   // Parse news blackout list once
   ParseNewsTimes();

   // Dashboard
   if(InpShowDashboard)
      UpdateDashboard();

   // Priority millisecond timer drives trade management (BE/trail/partial checks).
   // Runs independently of ticks so we stay reactive during low-liquidity moments.
   int mgmtMs = InpMgmtTimerMs;
   if(mgmtMs < 100)   mgmtMs = 100;
   if(mgmtMs > 10000) mgmtMs = 10000;
   EventSetMillisecondTimer(mgmtMs);

   LogEvt(SFS_LOG_INFO, StringFormat(
      "Initialized. Symbol=%s Base=%s Point=%g Pip=%g Digits=%d MinVol=%.2f Step=%.2f StopsLvl=%.1fp",
      _Symbol, InpSymbolBase, g_point, g_pipSize, g_digits, g_volMin, g_volStep,
      g_brokerStopDistance / g_pipSize));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();

   if(g_hEmaFastH1 != INVALID_HANDLE) IndicatorRelease(g_hEmaFastH1);
   if(g_hEmaSlowH1 != INVALID_HANDLE) IndicatorRelease(g_hEmaSlowH1);
   if(g_hAdxH1     != INVALID_HANDLE) IndicatorRelease(g_hAdxH1);
   if(g_hAtrM15    != INVALID_HANDLE) IndicatorRelease(g_hAtrM15);
   if(g_hRsiM15    != INVALID_HANDLE) IndicatorRelease(g_hRsiM15);

   RemoveDashboard();

   LogMsg("Deinit reason=" + IntegerToString(reason));
  }

//+------------------------------------------------------------------+
//| OnTimer - priority trade management + throttled dashboard        |
//| Runs at InpMgmtTimerMs (default 250 ms), independent of ticks.    |
//+------------------------------------------------------------------+
void OnTimer()
  {
   // High-priority: always keep open positions managed even without ticks
   SyncStatesWithPositions();
   ManagePositions();

   // Throttled dashboard refresh (do not spam objects every 250 ms)
   if(InpShowDashboard)
     {
      uint nowMs = GetTickCount();
      uint interval = (uint)InpDashRefreshMs;
      if(interval < 250) interval = 250;
      if(nowMs - g_lastDashboardMs >= interval)
        {
         UpdateDashboard();
         g_lastDashboardMs = nowMs;
        }
     }
  }

//+------------------------------------------------------------------+
//| OnTick - main strategy dispatcher                                |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Refresh market data first
   if(!g_sym.RefreshRates())
      return;

   // Institutional trading-context guard - refuse to act if terminal/account is not ready
   if(!IsTradingContextReady())
     {
      // Still manage existing positions defensively via OnTimer; return here.
      return;
     }

   // Sync internal state array with actual positions (in case of manual close)
   SyncStatesWithPositions();

   // Time context
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);

   // Daily reset when calendar day changes
   if(dt.day_of_year != g_currentDay)
      OnDailyReset(dt);

   // Track equity peak for DD emergency stop
   double eqNow = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eqNow > g_peakEquity) g_peakEquity = eqNow;

   // Emergency DD stop - kill switch (unrecoverable during current session)
   if(!g_emergencyHalt && g_peakEquity > 0.0)
     {
      double ddPct = (g_peakEquity - eqNow) / g_peakEquity * 100.0;
      if(ddPct >= InpMaxDDPercent)
        {
         g_emergencyHalt = true;
         LogEvt(SFS_LOG_ERROR, StringFormat("EMERGENCY STOP - Equity DD %.2f%% >= %.2f%%. Flattening.",
                                            ddPct, InpMaxDDPercent));
         CloseAllMyPositions("Max DD stop");
        }
     }

   // Always try to manage existing trades (BE, partials, trail, force-close)
   ManagePositions();

   if(g_emergencyHalt)
      return;

   // Weekend / friday-close guards
   if(IsWeekend(dt))
      return;

   if(InpCloseOnFriday && dt.day_of_week == 5 && IsForceCloseTime(dt))
     {
      CloseAllMyPositions("Friday force-close");
      return;
     }

   // Only advance signal state machine on NEW M15 bar (avoid intra-bar false signals)
   if(!IsNewM15Bar())
      return;

   // Cooldown countdown
   if(g_setupState == SETUP_COOLDOWN)
     {
      g_cooldownBars--;
      if(g_cooldownBars <= 0)
        {
         g_setupState = SETUP_NONE;
         LogMsg("Cooldown finished - state reset to NONE");
        }
     }

   // Recompute today's range if range window has ended and not yet computed
   if(!g_rangeValid && !IsRangeWindow(dt))
      CalcTodayRange(dt);

   // Advance signal state machine
   if(g_rangeValid && IsTradeWindow(dt))
      UpdateSignalState();

   // Try entry if signal is armed (RETEST state means confirming bar just closed)
   if(!g_emergencyHalt && InpEnableTrading && IsTradeWindow(dt))
      TryEnter();
  }

//+------------------------------------------------------------------+
//| OnTradeTransaction - track closed deals for cons-loss counter    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest    &request,
                        const MqlTradeResult     &result)
  {
   // We only care about deal-add events belonging to our EA
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   long   dealMagic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   string dealSym   = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   long   entry     = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

   if(dealMagic != InpMagicNumber || dealSym != _Symbol)
      return;

   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
     {
      double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                    + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                    + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      g_dayPnL += profit;

      if(profit < 0.0)
        {
         g_consecLosses++;
         if(g_consecLosses >= InpMaxConsecLoss)
           {
            g_pauseUntil = TimeCurrent() + (datetime)(InpConsecPauseHours * 3600);
            LogEvt(SFS_LOG_WARN, StringFormat("Consecutive loss pause armed: %d losses, paused until %s",
                                              g_consecLosses,
                                              TimeToString(g_pauseUntil, TIME_DATE|TIME_MINUTES)));
            g_consecLosses = 0; // reset streak counter
           }
        }
      else if(profit > 0.0)
        {
         g_consecLosses = 0; // any profitable close resets streak
        }
     }
  }

//+------------------------------------------------------------------+
//| OnDailyReset - called when broker date rolls over                |
//+------------------------------------------------------------------+
void OnDailyReset(const MqlDateTime &dt)
  {
   g_currentDay      = dt.day_of_year;
   g_dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayPnL          = 0.0;
   g_dayTradesOpened = 0;
   g_rangeValid      = false;
   g_rangeDay        = -1;
   g_setupState      = SETUP_NONE;
   g_cooldownBars    = 0;
   g_setupBars       = 0;
   // Peak equity is intentionally NOT reset each day - DD stop is session-wide
   LogMsg(StringFormat("Daily reset. StartEquity=%.2f", g_dayStartEquity));
  }

//+------------------------------------------------------------------+
//| Time / Session helpers                                           |
//+------------------------------------------------------------------+
bool IsNewM15Bar()
  {
   datetime t = iTime(_Symbol, PERIOD_M15, 0);
   if(t != g_lastM15BarTime)
     {
      g_lastM15BarTime = t;
      return true;
     }
   return false;
  }

bool IsInHourWindow(const int hStart, const int hEnd, const int hourNow)
  {
   // Supports wrapping windows (e.g. 22..02) although default config never wraps
   if(hStart <= hEnd)
      return (hourNow >= hStart && hourNow < hEnd);
   return (hourNow >= hStart || hourNow < hEnd);
  }

bool IsRangeWindow(const MqlDateTime &dt)
  {
   return IsInHourWindow(InpRangeStartHour, InpRangeEndHour, dt.hour);
  }

bool IsTradeWindow(const MqlDateTime &dt)
  {
   // Optional: skip first hour of Monday to avoid weekend gap noise
   if(InpSkipMondayFirstH && dt.day_of_week == 1 && dt.hour == InpTradeStartHour)
      return false;
   return IsInHourWindow(InpTradeStartHour, InpTradeEndHour, dt.hour);
  }

bool IsForceCloseTime(const MqlDateTime &dt)
  {
   return (dt.hour >= InpForceCloseHour);
  }

bool IsWeekend(const MqlDateTime &dt)
  {
   // 0 = Sunday, 6 = Saturday in MqlDateTime
   return (dt.day_of_week == 0 || dt.day_of_week == 6);
  }

//+------------------------------------------------------------------+
//| Parse InpNewsBlockTimes ("HH:MM,HH:MM,...") into minute-of-day   |
//+------------------------------------------------------------------+
void ParseNewsTimes()
  {
   ArrayResize(g_newsMinutes, 0);
   if(!InpUseNewsFilter) return;

   string parts[];
   int n = StringSplit(InpNewsBlockTimes, ',', parts);
   for(int i = 0; i < n; i++)
     {
      string tok = parts[i];
      StringTrimLeft(tok);
      StringTrimRight(tok);
      if(StringLen(tok) < 4) continue;

      string hm[];
      int cnt = StringSplit(tok, ':', hm);
      if(cnt != 2) continue;

      int hh = (int)StringToInteger(hm[0]);
      int mm = (int)StringToInteger(hm[1]);
      if(hh < 0 || hh > 23 || mm < 0 || mm > 59) continue;

      int mod = hh * 60 + mm;
      int sz  = ArraySize(g_newsMinutes);
      ArrayResize(g_newsMinutes, sz + 1);
      g_newsMinutes[sz] = mod;
     }
  }

bool IsNewsBlocked(const MqlDateTime &dt)
  {
   if(!InpUseNewsFilter) return false;
   int nowMin = dt.hour * 60 + dt.min;
   int total  = ArraySize(g_newsMinutes);
   for(int i = 0; i < total; i++)
     {
      int diff = MathAbs(nowMin - g_newsMinutes[i]);
      if(diff <= InpNewsBlockMinutes)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Range calculation - scans M15 bars inside today's range window   |
//+------------------------------------------------------------------+
bool CalcTodayRange(const MqlDateTime &dtNow)
  {
   // Only compute once per day, after range window ends
   if(g_rangeValid && g_rangeDay == dtNow.day_of_year)
      return true;
   if(IsRangeWindow(dtNow))
      return false;

   // Build [rangeStart, rangeEnd] for today's date
   MqlDateTime dS = dtNow;
   dS.hour = InpRangeStartHour; dS.min = 0; dS.sec = 0;
   MqlDateTime dE = dtNow;
   dE.hour = InpRangeEndHour;   dE.min = 0; dE.sec = 0;

   datetime tStart = StructToTime(dS);
   datetime tEnd   = StructToTime(dE);

   // Handle wrapping window (start > end means window spans midnight)
   if(tStart >= tEnd)
      tStart -= 24 * 3600;

   // Load M15 bars covering the range
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, PERIOD_M15, tStart, tEnd, rates);
   if(copied <= 0)
     {
      LogMsg("Range calc: CopyRates returned 0 - no data yet");
      return false;
     }

   double hi = -DBL_MAX;
   double lo =  DBL_MAX;
   for(int i = 0; i < copied; i++)
     {
      if(rates[i].time < tStart || rates[i].time >= tEnd)
         continue;
      if(rates[i].high > hi) hi = rates[i].high;
      if(rates[i].low  < lo) lo = rates[i].low;
     }

   if(hi == -DBL_MAX || lo == DBL_MAX || hi <= lo)
     {
      LogMsg("Range calc: invalid range boundaries");
      return false;
     }

   g_rangeHigh  = hi;
   g_rangeLow   = lo;
   g_rangeValid = true;
   g_rangeDay   = dtNow.day_of_year;
   g_setupState = SETUP_NONE;

   LogMsg(StringFormat("Range set for day %d: High=%s Low=%s (%.1f pips wide)",
                       dtNow.day_of_year,
                       DoubleToString(g_rangeHigh, g_digits),
                       DoubleToString(g_rangeLow, g_digits),
                       (g_rangeHigh - g_rangeLow) / g_pipSize));
   return true;
  }

//+------------------------------------------------------------------+
//| Trend bias on H1 - EMA structure + ADX gate (cached values)      |
//+------------------------------------------------------------------+
ENUM_TREND_BIAS GetTrendBias()
  {
   datetime bt = iTime(_Symbol, PERIOD_H1, 0);
   if(!g_cache.validH1 || g_cache.h1BarTime != bt)
      RefreshIndicatorCacheH1();
   if(!g_cache.validH1) return TREND_FLAT;

   double last = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(last <= 0.0) return TREND_FLAT;

   if(g_cache.adxH1 < InpAdxThreshold) return TREND_FLAT;
   if(g_cache.emaFastH1 > g_cache.emaSlowH1 && last > g_cache.emaFastH1) return TREND_BULL;
   if(g_cache.emaFastH1 < g_cache.emaSlowH1 && last < g_cache.emaFastH1) return TREND_BEAR;
   return TREND_FLAT;
  }

//+------------------------------------------------------------------+
//| ATR (M15) - returns price distance (not pips), cached per-bar    |
//+------------------------------------------------------------------+
double GetATR()
  {
   datetime bt = iTime(_Symbol, PERIOD_M15, 0);
   if(!g_cache.validM15 || g_cache.m15BarTime != bt)
      RefreshIndicatorCacheM15();
   return g_cache.validM15 ? g_cache.atrM15 : 0.0;
  }

//+------------------------------------------------------------------+
//| RSI (M15) - value of last closed bar, cached per-bar             |
//+------------------------------------------------------------------+
double GetRSI()
  {
   datetime bt = iTime(_Symbol, PERIOD_M15, 0);
   if(!g_cache.validM15 || g_cache.m15BarTime != bt)
      RefreshIndicatorCacheM15();
   return g_cache.validM15 ? g_cache.rsiM15 : 50.0;
  }

//+------------------------------------------------------------------+
//| Aggregate filter check for candidate direction                   |
//+------------------------------------------------------------------+
bool FiltersPassed(const int direction)
  {
   // Spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPoints)
     {
      if(InpVerboseLogging)
         LogMsg(StringFormat("Filter: spread %d > max %d", (int)spread, InpMaxSpreadPoints));
      return false;
     }

   // Volatility floor
   double atr = GetATR();
   double atrPips = atr / g_pipSize;
   if(atrPips < InpMinAtrPips)
     {
      if(InpVerboseLogging)
         LogMsg(StringFormat("Filter: ATR %.1f pips < min %.1f", atrPips, InpMinAtrPips));
      return false;
     }

   // RSI extremes
   double rsi = GetRSI();
   if(direction > 0 && rsi >= InpRsiUpperBlock)
     {
      if(InpVerboseLogging) LogMsg(StringFormat("Filter: RSI %.1f blocks long", rsi));
      return false;
     }
   if(direction < 0 && rsi <= InpRsiLowerBlock)
     {
      if(InpVerboseLogging) LogMsg(StringFormat("Filter: RSI %.1f blocks short", rsi));
      return false;
     }

   // Daily loss cap
   double lossLimit = -g_dayStartEquity * InpDailyLossPercent / 100.0;
   if(g_dayPnL <= lossLimit)
     {
      if(InpVerboseLogging) LogMsg(StringFormat("Filter: daily loss %.2f hit limit %.2f",
                                                g_dayPnL, lossLimit));
      return false;
     }

   // Max trades per day
   if(g_dayTradesOpened >= InpMaxTradesPerDay)
     {
      if(InpVerboseLogging) LogMsg("Filter: max trades/day reached");
      return false;
     }

   // Consecutive loss pause
   if(TimeCurrent() < g_pauseUntil)
     {
      if(InpVerboseLogging) LogMsg("Filter: within cons-loss pause window");
      return false;
     }

   // News blackout
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(IsNewsBlocked(dt))
     {
      if(InpVerboseLogging) LogMsg("Filter: news blackout window active");
      return false;
     }

   // Already 2 (or max) positions open with this magic
   if(CountMyPositions() >= InpMaxTradesPerDay)
      return false;

   return true;
  }

//+------------------------------------------------------------------+
//| Signal state machine - runs on every new M15 bar                 |
//+------------------------------------------------------------------+
void UpdateSignalState()
  {
   // Read the just-closed M15 bar (index 1) plus one prior (index 2)
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_M15, 0, 3, r) < 3) return;

   double barHigh   = r[1].high;
   double barLow    = r[1].low;
   double barClose  = r[1].close;
   double prevClose = r[2].close;

   double atr = GetATR();
   if(atr <= 0.0) return;
   double retestTol = atr * InpRetestAtrMult;

   // "Fresh breakout" gate: only consider a new breakout if the previous bar
   // was inside the range. This prevents chasing when price is already trending
   // outside the range at the moment the trade window opens.
   bool prevInsideRange = (prevClose >= g_rangeLow && prevClose <= g_rangeHigh);

   // Bar counter (progress since breakout)
   if(g_setupState == SETUP_LONG_BREAKOUT || g_setupState == SETUP_LONG_RETEST ||
      g_setupState == SETUP_SHORT_BREAKOUT|| g_setupState == SETUP_SHORT_RETEST)
     {
      g_setupBars++;
      if(g_setupBars > InpMaxRetestBars)
        {
         LogMsg("Signal: setup expired (no retest completion)");
         g_setupState = SETUP_NONE;
         g_setupBars  = 0;
        }
     }

   switch(g_setupState)
     {
      //---------------------------------------------------------------
      case SETUP_NONE:
         // Look for fresh breakout - require prior bar inside the range
         if(prevInsideRange && barClose > g_rangeHigh)
           {
            g_setupState  = SETUP_LONG_BREAKOUT;
            g_breakoutLvl = g_rangeHigh;
            g_breakoutBar = r[1].time;
            g_setupBars   = 0;
            LogMsg(StringFormat("Signal: LONG breakout above %s",
                                DoubleToString(g_rangeHigh, g_digits)));
           }
         else if(prevInsideRange && barClose < g_rangeLow)
           {
            g_setupState  = SETUP_SHORT_BREAKOUT;
            g_breakoutLvl = g_rangeLow;
            g_breakoutBar = r[1].time;
            g_setupBars   = 0;
            LogMsg(StringFormat("Signal: SHORT breakout below %s",
                                DoubleToString(g_rangeLow, g_digits)));
           }
         break;

      //---------------------------------------------------------------
      case SETUP_LONG_BREAKOUT:
         // Await retest: bar low pulls back to (or below) rangeHigh within tolerance
         if(barClose < g_rangeLow)
           {
            g_setupState = SETUP_INVALIDATED;
            LogMsg("Signal: LONG breakout invalidated (closed below range low)");
           }
         else if(barLow <= g_breakoutLvl + retestTol)
           {
            g_setupState = SETUP_LONG_RETEST;
            LogMsg(StringFormat("Signal: LONG retest touched (low=%s tol=%.5f)",
                                DoubleToString(barLow, g_digits), retestTol));
           }
         break;

      //---------------------------------------------------------------
      case SETUP_LONG_RETEST:
         // Confirming bar: bullish close back above breakout level
         if(barClose < g_rangeLow)
           {
            g_setupState = SETUP_INVALIDATED;
            LogMsg("Signal: LONG retest invalidated (broke opposite side)");
           }
         // Fires in TryEnter() - state remains SETUP_LONG_RETEST until TryEnter consumes it
         // If confirming candle failed, we can drop back to BREAKOUT state:
         else if(barClose < g_breakoutLvl)
           {
            g_setupState = SETUP_LONG_BREAKOUT;
            LogMsg("Signal: LONG confirming bar failed - reverted to BREAKOUT wait");
           }
         break;

      //---------------------------------------------------------------
      case SETUP_SHORT_BREAKOUT:
         if(barClose > g_rangeHigh)
           {
            g_setupState = SETUP_INVALIDATED;
            LogMsg("Signal: SHORT breakout invalidated (closed above range high)");
           }
         else if(barHigh >= g_breakoutLvl - retestTol)
           {
            g_setupState = SETUP_SHORT_RETEST;
            LogMsg(StringFormat("Signal: SHORT retest touched (high=%s tol=%.5f)",
                                DoubleToString(barHigh, g_digits), retestTol));
           }
         break;

      //---------------------------------------------------------------
      case SETUP_SHORT_RETEST:
         if(barClose > g_rangeHigh)
           {
            g_setupState = SETUP_INVALIDATED;
            LogMsg("Signal: SHORT retest invalidated (broke opposite side)");
           }
         else if(barClose > g_breakoutLvl)
           {
            g_setupState = SETUP_SHORT_BREAKOUT;
            LogMsg("Signal: SHORT confirming bar failed - reverted to BREAKOUT wait");
           }
         break;

      //---------------------------------------------------------------
      case SETUP_COOLDOWN:
      case SETUP_INVALIDATED:
      default:
         // Handled elsewhere
         break;
     }
  }

//+------------------------------------------------------------------+
//| TryEnter - fires actual order if retest state is confirmed       |
//+------------------------------------------------------------------+
void TryEnter()
  {
   if(g_setupState != SETUP_LONG_RETEST && g_setupState != SETUP_SHORT_RETEST)
      return;

   // Fetch confirming bar (last closed M15)
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_M15, 0, 2, r) < 2) return;

   double barOpen  = r[1].open;
   double barClose = r[1].close;

   int direction = 0;
   if(g_setupState == SETUP_LONG_RETEST)
     {
      // Confirming bar: bullish + close above breakout level
      if(barClose > barOpen && barClose > g_breakoutLvl)
         direction = +1;
     }
   else if(g_setupState == SETUP_SHORT_RETEST)
     {
      if(barClose < barOpen && barClose < g_breakoutLvl)
         direction = -1;
     }

   if(direction == 0) return;

   // H1 trend alignment
   ENUM_TREND_BIAS bias = GetTrendBias();
   if(direction > 0 && bias != TREND_BULL)
     {
      if(InpVerboseLogging) LogMsg("Entry blocked: H1 bias not bullish");
      return;
     }
   if(direction < 0 && bias != TREND_BEAR)
     {
      if(InpVerboseLogging) LogMsg("Entry blocked: H1 bias not bearish");
      return;
     }

   if(!FiltersPassed(direction))
      return;

   // SL price computation
   double atr = GetATR();
   if(atr <= 0.0) return;

   double slDist = 0.0;
   if(InpSLMode == SL_ATR)
      slDist = atr * InpAtrSLMult;
   else
      slDist = InpFixedSLPips * g_pipSize;

   // Clamp SL to safe pip range
   double slPips = slDist / g_pipSize;
   if(slPips < InpMinSLPips) slDist = InpMinSLPips * g_pipSize;
   if(slPips > InpMaxSLPips) slDist = InpMaxSLPips * g_pipSize;

   // Reference price
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;

   double refPrice = (direction > 0) ? ask : bid;
   double slPrice  = (direction > 0) ? (refPrice - slDist) : (refPrice + slDist);
   slPrice = NormalizeDouble(slPrice, g_digits);

   // Institutional guard: enforce broker minimum stops-level + buffer.
   // If ATR-derived SL is too tight, this widens it - producing a *safer* trade
   // (smaller lots for the same risk %) rather than a rejected order.
   slPrice = ClampStopDistance(direction, refPrice, slPrice);
   double actualRDist = MathAbs(refPrice - slPrice);
   if(actualRDist <= 0.0) return;

   if(OpenTrade(direction, slPrice, actualRDist))
     {
      g_setupState   = SETUP_COOLDOWN;
      g_cooldownBars = InpCooldownBars;
     }
  }

//+------------------------------------------------------------------+
//| Volume normalization - respects broker step / min / max          |
//+------------------------------------------------------------------+
double NormalizeVolume(const double v)
  {
   if(g_volStep <= 0.0) return v;
   double lots = MathFloor(v / g_volStep) * g_volStep;
   if(lots < g_volMin) lots = 0.0; // signal caller: too small, skip
   if(lots > g_volMax) lots = g_volMax;
   if(lots > InpMaxLots) lots = InpMaxLots;
   return NormalizeDouble(lots, 2);
  }

//+------------------------------------------------------------------+
//| Lot sizing - risk % of balance across the SL distance            |
//| slPriceDist = absolute price distance from entry to SL           |
//+------------------------------------------------------------------+
double CalculateLots(const double slPriceDist, double &outRiskAmount)
  {
   outRiskAmount = 0.0;
   if(slPriceDist <= 0.0) return 0.0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk    = balance * InpRiskPercent / 100.0;
   outRiskAmount  = risk;

   // Value of 1.0 lot moving 1 point in deposit currency
   double valuePerPoint = g_tickValue * (g_point / g_tickSize);
   if(valuePerPoint <= 0.0) return 0.0;

   // Total points of SL distance
   double slPoints = slPriceDist / g_point;
   if(slPoints <= 0.0) return 0.0;

   double lots = risk / (slPoints * valuePerPoint);
   return NormalizeVolume(lots);
  }

//+------------------------------------------------------------------+
//| OpenTrade - executes market order and registers state            |
//+------------------------------------------------------------------+
bool OpenTrade(const int direction, const double slPrice, const double rDist)
  {
   double lots = 0.0;
   double riskAmt = 0.0;
   lots = CalculateLots(rDist, riskAmt);
   if(lots < g_volMin || lots <= 0.0)
     {
      LogEvt(SFS_LOG_WARN, StringFormat("Entry aborted: computed lots %.2f below min %.2f",
                                        lots, g_volMin));
      return false;
     }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entryPrice = (direction > 0) ? ask : bid;

   // Institutional guard: verify we have free margin for this trade
   if(!PreCheckMargin(direction, lots, entryPrice))
     {
      LogEvt(SFS_LOG_WARN, "Entry aborted: margin pre-check failed");
      return false;
     }

   bool ok = false;
   if(direction > 0)
      ok = g_trade.Buy(lots, _Symbol, ask, slPrice, 0.0, InpTradeComment);
   else
      ok = g_trade.Sell(lots, _Symbol, bid, slPrice, 0.0, InpTradeComment);

   if(!ok || g_trade.ResultRetcode() != TRADE_RETCODE_DONE)
     {
      LogEvt(SFS_LOG_ERROR, StringFormat("Order send FAILED dir=%d ret=%u %s",
                                         direction, g_trade.ResultRetcode(),
                                         g_trade.ResultRetcodeDescription()));
      return false;
     }

   // Retrieve the exact position ticket the deal belongs to.
   // In hedging mode each entry is a separate position; DEAL_POSITION_ID is authoritative.
   ulong dealTicket = g_trade.ResultDeal();
   ulong posTicket  = 0;
   if(dealTicket > 0 && HistoryDealSelect(dealTicket))
      posTicket = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);

   // Fallback: scan for our newest matching position if deal lookup failed
   if(posTicket == 0)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong pt = PositionGetTicket(i);
         if(pt == 0) continue;
         if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         posTicket = pt;
         break;
        }
     }
   if(posTicket == 0)
     {
      LogMsg("OpenTrade: could not resolve position ticket after fill");
      return false;
     }

   STradeState st;
   st.ticket     = posTicket;
   st.direction  = direction;
   st.entryPrice = entryPrice;
   st.initSL     = slPrice;
   st.initVolume = lots;
   st.rDistance  = MathAbs(entryPrice - slPrice);
   st.beDone     = false;
   st.tp1Done    = false;
   st.tp2Done    = false;
   st.openTime   = TimeCurrent();
   AddState(st);

   g_dayTradesOpened++;
   LogMsg(StringFormat("OPENED %s ticket=%I64u lots=%.2f entry=%s SL=%s R=%.1f pips risk=%.2f",
                       (direction > 0 ? "BUY" : "SELL"),
                       (long)posTicket,
                       lots,
                       DoubleToString(entryPrice, g_digits),
                       DoubleToString(slPrice, g_digits),
                       st.rDistance / g_pipSize,
                       riskAmt));
   return true;
  }

//+------------------------------------------------------------------+
//| Manage all open positions belonging to this EA                   |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int idx = FindStateIdx(ticket);
      if(idx < 0)
        {
         // Adopt orphan (e.g. EA reloaded mid-trade).
         // We do NOT know its original R, so mark BE/TP1/TP2 as already done
         // and only apply the ATR trailing stop safeguard.
         STradeState st;
         st.ticket     = ticket;
         st.direction  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? +1 : -1;
         st.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         st.initSL     = PositionGetDouble(POSITION_SL);
         st.initVolume = PositionGetDouble(POSITION_VOLUME);
         st.rDistance  = MathAbs(st.entryPrice - st.initSL);
         st.beDone     = true;
         st.tp1Done    = true;
         st.tp2Done    = true;
         st.openTime   = (datetime)PositionGetInteger(POSITION_TIME);
         AddState(st);
         idx = FindStateIdx(ticket);
         if(idx < 0) continue;
         LogMsg(StringFormat("Adopted orphan position ticket=%I64u (trail-only mode)",
                             (long)ticket));
        }

      // Get a mutable reference
      STradeState st = g_states[idx];

      // Skip if R distance is bogus (shouldn't happen)
      if(st.rDistance <= 0.0) continue;

      // Break-even
      if(!st.beDone) MoveToBreakEven(st);

      // Partial 1
      if(!st.tp1Done) DoPartialClose(st, InpPartial1_Percent /* tp1 */);
      // Note: DoPartialClose handles the tp1 vs tp2 logic based on state flags

      // Partial 2
      if(st.tp1Done && !st.tp2Done) DoPartialClose(st, InpPartial2_Percent);

      // Trail after both partials done
      if(st.tp1Done && st.tp2Done) TrailRunner(st);

      // Write back state
      g_states[idx] = st;
     }
  }

//+------------------------------------------------------------------+
//| Break-even: once price moves +BreakEven_R * R, push SL to entry  |
//+------------------------------------------------------------------+
void MoveToBreakEven(STradeState &st)
  {
   if(!PositionSelectByTicket(st.ticket)) return;
   double curPrice = (st.direction > 0)
                     ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                     : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double favorable = (st.direction > 0)
                      ? (curPrice - st.entryPrice)
                      : (st.entryPrice - curPrice);
   if(favorable < st.rDistance * InpBreakEven_R)
      return;

   double buffer = InpBreakEvenBufferP * g_pipSize;
   double newSL  = (st.direction > 0)
                   ? st.entryPrice + buffer
                   : st.entryPrice - buffer;
   newSL = NormalizeDouble(newSL, g_digits);

   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);

   // Broker stop-level compliance - never place SL closer than allowed
   double refPrice = (st.direction > 0)
                     ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                     : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   newSL = ClampStopDistance(st.direction, refPrice, newSL);

   // Only modify if new SL is a genuine improvement
   if(st.direction > 0 && newSL <= curSL) { st.beDone = true; return; }
   if(st.direction < 0 && newSL >= curSL && curSL > 0.0) { st.beDone = true; return; }

   if(RetryModifyPosition(st.ticket, newSL, curTP))
     {
      st.beDone = true;
      LogEvt(SFS_LOG_INFO, StringFormat("BE armed ticket=%I64u newSL=%s",
                                        (long)st.ticket, DoubleToString(newSL, g_digits)));
     }
   else
     {
      LogEvt(SFS_LOG_WARN, StringFormat("BE modify failed after retries ticket=%I64u ret=%u",
                                        (long)st.ticket, g_trade.ResultRetcode()));
     }
  }

//+------------------------------------------------------------------+
//| Partial close - closes X% of INITIAL volume at TP1 or TP2        |
//+------------------------------------------------------------------+
void DoPartialClose(STradeState &st, const double percent)
  {
   if(!PositionSelectByTicket(st.ticket)) return;

   double curPrice = (st.direction > 0)
                     ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                     : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double favorable = (st.direction > 0)
                      ? (curPrice - st.entryPrice)
                      : (st.entryPrice - curPrice);

   double triggerR = (!st.tp1Done) ? InpTP1_R : InpTP2_R;
   if(favorable < st.rDistance * triggerR)
      return;

   double posVol   = PositionGetDouble(POSITION_VOLUME);
   double closeVol = NormalizeVolume(st.initVolume * percent / 100.0);
   if(closeVol <= 0.0) closeVol = g_volMin;

   // Log stage BEFORE flags are flipped so message is accurate
   string stageStr = (!st.tp1Done) ? "1" : "2";

   // If closing amount >= remaining volume, close everything
   if(closeVol >= posVol - g_volStep * 0.5)
     {
      if(g_trade.PositionClose(st.ticket))
        {
         st.tp1Done = true;
         st.tp2Done = true;
         LogEvt(SFS_LOG_INFO, StringFormat("Full close at TP%s ticket=%I64u",
                                           stageStr, (long)st.ticket));
         return;
        }
     }

   if(closeVol > posVol) closeVol = posVol;

   if(RetryPartialClose(st.ticket, closeVol))
     {
      if(!st.tp1Done)
        {
         st.tp1Done = true;
         LogEvt(SFS_LOG_INFO, StringFormat("Partial TP1 %.2f lots @ %s ticket=%I64u",
                                           closeVol, DoubleToString(curPrice, g_digits),
                                           (long)st.ticket));
        }
      else
        {
         st.tp2Done = true;
         LogEvt(SFS_LOG_INFO, StringFormat("Partial TP2 %.2f lots @ %s ticket=%I64u",
                                           closeVol, DoubleToString(curPrice, g_digits),
                                           (long)st.ticket));
        }
     }
   else
     {
      LogEvt(SFS_LOG_WARN, StringFormat("Partial close failed after retries ticket=%I64u vol=%.2f ret=%u",
                                        (long)st.ticket, closeVol, g_trade.ResultRetcode()));
     }
  }

//+------------------------------------------------------------------+
//| Trailing stop on the runner - ATR trailing (M15)                 |
//+------------------------------------------------------------------+
void TrailRunner(STradeState &st)
  {
   if(!PositionSelectByTicket(st.ticket)) return;

   double atr = GetATR();
   if(atr <= 0.0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);
   double newSL = 0.0;

   if(st.direction > 0)
      newSL = bid - atr * InpTrailAtrMult;
   else
      newSL = ask + atr * InpTrailAtrMult;

   newSL = NormalizeDouble(newSL, g_digits);

   // Broker stop-level compliance
   double refPrice = (st.direction > 0) ? bid : ask;
   newSL = ClampStopDistance(st.direction, refPrice, newSL);

   // Only tighten - never loosen
   if(st.direction > 0)
     {
      if(newSL <= curSL) return;
      if(newSL <= st.entryPrice) return; // never trail below BE
     }
   else
     {
      if(curSL > 0.0 && newSL >= curSL) return;
      if(newSL >= st.entryPrice) return;
     }

   if(RetryModifyPosition(st.ticket, newSL, curTP))
     {
      LogEvt(SFS_LOG_INFO, StringFormat("Trail ticket=%I64u newSL=%s", (long)st.ticket,
                                        DoubleToString(newSL, g_digits)));
     }
  }

//+------------------------------------------------------------------+
//| Close every position tagged with our magic number                |
//+------------------------------------------------------------------+
void CloseAllMyPositions(const string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      if(g_trade.PositionClose(ticket))
         LogMsg(StringFormat("Force close ticket=%I64u reason=%s",
                             (long)ticket, reason));
     }
   ArrayResize(g_states, 0);
  }

//+------------------------------------------------------------------+
//| State array helpers                                              |
//+------------------------------------------------------------------+
void AddState(const STradeState &st)
  {
   if(FindStateIdx(st.ticket) >= 0) return;
   int n = ArraySize(g_states);
   ArrayResize(g_states, n + 1);
   g_states[n] = st;
  }

int FindStateIdx(const ulong ticket)
  {
   int n = ArraySize(g_states);
   for(int i = 0; i < n; i++)
      if(g_states[i].ticket == ticket) return i;
   return -1;
  }

void RemoveState(const ulong ticket)
  {
   int idx = FindStateIdx(ticket);
   if(idx < 0) return;
   int n = ArraySize(g_states);
   for(int i = idx; i < n - 1; i++)
      g_states[i] = g_states[i + 1];
   ArrayResize(g_states, n - 1);
  }

//+------------------------------------------------------------------+
//| Sync local state array with terminal positions                   |
//| - Drop states whose position no longer exists (closed by SL/TP)  |
//+------------------------------------------------------------------+
void SyncStatesWithPositions()
  {
   int i = 0;
   while(i < ArraySize(g_states))
     {
      ulong t = g_states[i].ticket;
      if(!PositionSelectByTicket(t))
         RemoveState(t);
      else
         i++;
     }
  }

int CountMyPositions()
  {
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      cnt++;
     }
   return cnt;
  }

//+------------------------------------------------------------------+
//| Logging wrappers                                                 |
//| LogEvt: severity-tagged structured logger (SFS_LOG_*)            |
//| LogMsg: backwards-compat wrapper - respects InpVerboseLogging     |
//+------------------------------------------------------------------+
void LogEvt(const ENUM_SFS_LOG_LEVEL lvl, const string msg)
  {
   if(lvl < InpLogLevel) return;
   string tag = "???";
   switch(lvl)
     {
      case SFS_LOG_DEBUG: tag = "DBG"; break;
      case SFS_LOG_INFO:  tag = "INF"; break;
      case SFS_LOG_WARN:  tag = "WRN"; break;
      case SFS_LOG_ERROR: tag = "ERR"; break;
      default:            tag = "???"; break;
     }
   PrintFormat("[SFS %s %s] %s",
               TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES), tag, msg);
  }

void LogMsg(const string msg)
  {
   if(!InpVerboseLogging) return;
   LogEvt(SFS_LOG_INFO, msg);
  }

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void CreateOrUpdateLabel(const string name, const int x, const int y,
                        const string text, const color clr, const int fontSize = 9,
                        const string font = "Consolas")
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 100);
     }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString (0, name, OBJPROP_FONT, font);
   ObjectSetString (0, name, OBJPROP_TEXT, text);
  }

void CreateOrUpdateRect(const string name, const int x, const int y,
                        const int w, const int h, const color bgClr)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrGray);
     }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgClr);
  }

string SetupStateStr()
  {
   switch(g_setupState)
     {
      case SETUP_NONE:            return "IDLE - awaiting breakout";
      case SETUP_LONG_BREAKOUT:   return "LONG breakout - awaiting retest";
      case SETUP_LONG_RETEST:     return "LONG retest - awaiting confirm";
      case SETUP_SHORT_BREAKOUT:  return "SHORT breakout - awaiting retest";
      case SETUP_SHORT_RETEST:    return "SHORT retest - awaiting confirm";
      case SETUP_COOLDOWN:        return "COOLDOWN";
      case SETUP_INVALIDATED:     return "INVALIDATED";
      default:                    return "UNKNOWN";
     }
  }

void UpdateDashboard()
  {
   if(!InpShowDashboard) return;

   int x = InpDashX;
   int y = InpDashY;
   int lineH = 16;
   int w = 320;
   int h = lineH * 13 + 12;

   // Background
   CreateOrUpdateRect(SF_DASH_BG_NAME, x - 6, y - 6, w, h, C'20,20,25');

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   bool inTrade = IsTradeWindow(dt);
   bool inRange = IsRangeWindow(dt);

   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double ddPct   = (g_peakEquity > 0.0) ? (g_peakEquity - equity) / g_peakEquity * 100.0 : 0.0;
   double dailyPnLPct = (g_dayStartEquity > 0.0) ? g_dayPnL / g_dayStartEquity * 100.0 : 0.0;

   ENUM_TREND_BIAS bias = GetTrendBias();
   string biasStr = "FLAT";
   color  biasClr = InpDashLabelColor;
   if(bias == TREND_BULL) { biasStr = "BULL"; biasClr = InpDashOKColor; }
   else if(bias == TREND_BEAR) { biasStr = "BEAR"; biasClr = InpDashBadColor; }

   double atrPips = GetATR() / g_pipSize;
   long   spread  = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   int line = 0;
   CreateOrUpdateLabel(SF_DASH_TITLE_NAME, x, y + line * lineH,
                       "StarkForge Sentinel EA  v1.00", InpDashHeaderColor, 11, "Consolas");
   line++;
   CreateOrUpdateLabel(SF_PREFIX + "l_sym", x, y + line * lineH,
                       StringFormat("Symbol : %s   Time: %s", _Symbol,
                                    TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES)),
                       InpDashLabelColor);
   line++;
   CreateOrUpdateLabel(SF_PREFIX + "l_session", x, y + line * lineH,
                       StringFormat("Session: %s / %s",
                                    inRange ? "RANGE" : "-",
                                    inTrade ? "TRADE" : "-"),
                       (inTrade ? InpDashOKColor : InpDashLabelColor));
   line++;
   CreateOrUpdateLabel(SF_PREFIX + "l_bias", x, y + line * lineH,
                       StringFormat("H1 Bias: %s", biasStr), biasClr);
   line++;
   CreateOrUpdateLabel(SF_PREFIX + "l_range", x, y + line * lineH,
                       StringFormat("Range  : %s  Hi=%s Lo=%s",
                                    (g_rangeValid ? "OK" : "--"),
                                    (g_rangeValid ? DoubleToString(g_rangeHigh, g_digits) : "-"),
                                    (g_rangeValid ? DoubleToString(g_rangeLow, g_digits) : "-")),
                       InpDashValueColor);
   line++;
   CreateOrUpdateLabel(SF_PREFIX + "l_setup", x, y + line * lineH,
                       StringFormat("Setup  : %s", SetupStateStr()), InpDashValueColor);
   line++;
   CreateOrUpdateLabel(SF_PREFIX + "l_vol", x, y + line * lineH,
                       StringFormat("ATR    : %.1f pips   Spread: %d pts", atrPips, (int)spread),
                       InpDashValueColor);
   line++;
   CreateOrUpdateLabel(SF_PREFIX + "l_bal", x, y + line * lineH,
                       StringFormat("Balance: %.2f   Equity: %.2f", balance, equity),
                       InpDashValueColor);
   line++;
   CreateOrUpdateLabel(SF_PREFIX + "l_pnl", x, y + line * lineH,
                       StringFormat("Day PnL: %.2f (%.2f%%)   Cap: -%.1f%%",
                                    g_dayPnL, dailyPnLPct, InpDailyLossPercent),
                       (dailyPnLPct < 0 ? InpDashBadColor : InpDashOKColor));
   line++;
   CreateOrUpdateLabel(SF_PREFIX + "l_dd", x, y + line * lineH,
                       StringFormat("Peak Eq: %.2f   DD: %.2f%% / %.1f%%",
                                    g_peakEquity, ddPct, InpMaxDDPercent),
                       (ddPct >= InpMaxDDPercent * 0.8 ? InpDashBadColor : InpDashValueColor));
   line++;
   CreateOrUpdateLabel(SF_PREFIX + "l_trades", x, y + line * lineH,
                       StringFormat("Trades : Today %d/%d   Open %d",
                                    g_dayTradesOpened, InpMaxTradesPerDay, CountMyPositions()),
                       InpDashValueColor);
   line++;
   string haltStr = g_emergencyHalt ? "HALTED (DD)"
                    : (TimeCurrent() < g_pauseUntil ? "PAUSED (cons loss)"
                       : (InpEnableTrading ? "ARMED" : "DISABLED"));
   color  haltClr = g_emergencyHalt ? InpDashBadColor
                    : (TimeCurrent() < g_pauseUntil ? InpDashBadColor
                       : (InpEnableTrading ? InpDashOKColor : InpDashLabelColor));
   CreateOrUpdateLabel(SF_PREFIX + "l_status", x, y + line * lineH,
                       StringFormat("Status : %s", haltStr), haltClr);
  }

void RemoveDashboard()
  {
   ObjectsDeleteAll(0, SF_PREFIX);
   ObjectDelete(0, SF_DASH_BG_NAME);
   ObjectDelete(0, SF_DASH_TITLE_NAME);
  }

//+------------------------------------------------------------------+
//| Enterprise: symbol prefix/suffix compatibility check              |
//| Accepts any broker naming (EURUSD.a, EURUSDm, EURUSD_pro, cEURUSD)|
//| provided the base name is contained in the chart symbol.          |
//+------------------------------------------------------------------+
bool IsSymbolCompatible()
  {
   if(StringLen(InpSymbolBase) == 0) return true; // no filter set
   string chartUp = _Symbol;
   string baseUp  = InpSymbolBase;
   StringToUpper(chartUp);
   StringToUpper(baseUp);
   return (StringFind(chartUp, baseUp) >= 0);
  }

//+------------------------------------------------------------------+
//| Cache broker execution limits (stops-level, freeze-level).        |
//| Adds InpStopLevelBufferP pips of safety above the raw stops-level |
//| so orders are never rejected for "invalid stops".                 |
//+------------------------------------------------------------------+
void RefreshBrokerLimits()
  {
   long stopsLevel  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   g_brokerStopDistance   = (double)stopsLevel  * g_point + InpStopLevelBufferP * g_pipSize;
   g_brokerFreezeDistance = (double)freezeLevel * g_point;
  }

//+------------------------------------------------------------------+
//| Refresh cached M15 indicator values (ATR, RSI)                    |
//+------------------------------------------------------------------+
void RefreshIndicatorCacheM15()
  {
   g_cache.validM15 = false;
   if(CopyBuffer(g_hAtrM15, 0, 0, 2, g_bufAtr) < 2) return;
   if(CopyBuffer(g_hRsiM15, 0, 0, 2, g_bufRsi) < 2) return;
   g_cache.atrM15     = g_bufAtr[1];
   g_cache.rsiM15     = g_bufRsi[1];
   g_cache.m15BarTime = iTime(_Symbol, PERIOD_M15, 0);
   g_cache.validM15   = true;
  }

//+------------------------------------------------------------------+
//| Refresh cached H1 indicator values (EMA fast, EMA slow, ADX)      |
//+------------------------------------------------------------------+
void RefreshIndicatorCacheH1()
  {
   g_cache.validH1 = false;
   if(CopyBuffer(g_hEmaFastH1, 0, 0, 2, g_bufEmaFast) < 2) return;
   if(CopyBuffer(g_hEmaSlowH1, 0, 0, 2, g_bufEmaSlow) < 2) return;
   if(CopyBuffer(g_hAdxH1,     0, 0, 2, g_bufAdx)     < 2) return;
   g_cache.emaFastH1 = g_bufEmaFast[1];
   g_cache.emaSlowH1 = g_bufEmaSlow[1];
   g_cache.adxH1     = g_bufAdx[1];
   g_cache.h1BarTime = iTime(_Symbol, PERIOD_H1, 0);
   g_cache.validH1   = true;
  }

//+------------------------------------------------------------------+
//| Clamp a proposed SL/BE/trail so it respects the broker's minimum  |
//| stops-level distance from the reference price.                    |
//| direction: +1 long, -1 short (SL sits opposite side of trade).    |
//+------------------------------------------------------------------+
double ClampStopDistance(const int direction, const double refPrice, const double proposedSL)
  {
   if(g_brokerStopDistance <= 0.0 || refPrice <= 0.0)
      return NormalizeDouble(proposedSL, g_digits);

   double sl = proposedSL;
   if(direction > 0)
     {
      // For a long, SL must sit >= brokerStopDistance below refPrice (bid).
      double maxAllowedSL = refPrice - g_brokerStopDistance;
      if(sl > maxAllowedSL) sl = maxAllowedSL;
     }
   else
     {
      // For a short, SL must sit >= brokerStopDistance above refPrice (ask).
      double minAllowedSL = refPrice + g_brokerStopDistance;
      if(sl < minAllowedSL) sl = minAllowedSL;
     }
   return NormalizeDouble(sl, g_digits);
  }

//+------------------------------------------------------------------+
//| Retry-aware PositionModify - bounded attempts with brief delay.   |
//| Aborts immediately on non-retryable retcodes (invalid stops, etc.)|
//+------------------------------------------------------------------+
bool RetryModifyPosition(const ulong ticket, const double sl, const double tp)
  {
   int maxAttempts = InpModifyRetries + 1;
   if(maxAttempts < 1) maxAttempts = 1;

   for(int attempt = 0; attempt < maxAttempts; attempt++)
     {
      if(!PositionSelectByTicket(ticket)) return false;

      // Skip if inside broker freeze-level (modify would be rejected anyway)
      if(g_brokerFreezeDistance > 0.0)
        {
         long ptype = PositionGetInteger(POSITION_TYPE);
         double curPrice = (ptype == POSITION_TYPE_BUY)
                           ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                           : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(MathAbs(curPrice - sl) < g_brokerFreezeDistance)
            return false;
        }

      if(g_trade.PositionModify(ticket, sl, tp))
         return true;

      uint ret = g_trade.ResultRetcode();
      // Non-retryable retcodes - stop trying immediately
      if(ret == TRADE_RETCODE_INVALID_STOPS ||
         ret == TRADE_RETCODE_MARKET_CLOSED ||
         ret == TRADE_RETCODE_POSITION_CLOSED ||
         ret == TRADE_RETCODE_INVALID ||
         ret == TRADE_RETCODE_INVALID_VOLUME ||
         ret == TRADE_RETCODE_TRADE_DISABLED)
         return false;

      // Retryable (requote, price changed, connection glitch, etc.)
      if(attempt < maxAttempts - 1)
         Sleep(InpModifyRetryDelayMs);
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Retry-aware PositionClosePartial                                  |
//+------------------------------------------------------------------+
bool RetryPartialClose(const ulong ticket, const double vol)
  {
   int maxAttempts = InpModifyRetries + 1;
   if(maxAttempts < 1) maxAttempts = 1;

   for(int attempt = 0; attempt < maxAttempts; attempt++)
     {
      if(!PositionSelectByTicket(ticket)) return false;

      if(g_trade.PositionClosePartial(ticket, vol))
         return true;

      uint ret = g_trade.ResultRetcode();
      if(ret == TRADE_RETCODE_POSITION_CLOSED ||
         ret == TRADE_RETCODE_MARKET_CLOSED   ||
         ret == TRADE_RETCODE_INVALID_VOLUME  ||
         ret == TRADE_RETCODE_INVALID         ||
         ret == TRADE_RETCODE_TRADE_DISABLED)
         return false;

      if(attempt < maxAttempts - 1)
         Sleep(InpModifyRetryDelayMs);
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Free-margin pre-check before firing a market order.               |
//| Returns true if entry can safely proceed (keeps a 5% cushion).    |
//+------------------------------------------------------------------+
bool PreCheckMargin(const int direction, const double lots, const double refPrice)
  {
   if(!InpUseMarginCheck) return true;
   if(lots <= 0.0 || refPrice <= 0.0) return false;

   double marginNeeded = 0.0;
   ENUM_ORDER_TYPE ot = (direction > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcMargin(ot, _Symbol, lots, refPrice, marginNeeded))
     {
      LogEvt(SFS_LOG_WARN, "OrderCalcMargin failed - allowing entry (fail-open)");
      return true;
     }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   // Require 5% cushion over the strict minimum
   if(marginNeeded > freeMargin * 0.95)
     {
      LogEvt(SFS_LOG_WARN, StringFormat("Insufficient margin: need %.2f, free %.2f (5%% cushion)",
                                        marginNeeded, freeMargin));
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Aggregate trading-context guard - terminal + account + expert     |
//+------------------------------------------------------------------+
bool IsTradingContextReady()
  {
   if(InpRequireConnection && !TerminalInfoInteger(TERMINAL_CONNECTED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//| End of file                                                      |
//+------------------------------------------------------------------+
