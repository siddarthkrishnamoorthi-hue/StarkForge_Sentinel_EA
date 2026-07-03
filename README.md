# StarkForge Sentinel EA

An **enterprise-grade MetaTrader 5** Expert Advisor for **EURUSD** built around
the London-NY overlap. Strategy is intentionally simple, mechanical and
prop-firm friendly: a range-breakout with retest confirmation on M15, filtered
by H1 trend structure, ATR-based dynamic stops, multi-partial take profits,
and a hard risk manager (daily loss / drawdown / consecutive-loss guards).

> No martingale. No grid. No averaging. One trade at a time (or a max of two
> per day if a second full setup forms).

---

## 1. Strategy Rules (Enforced in Code)

### 1.1 Session Model (broker time)
| Window          | Default (broker) | Purpose                            |
|-----------------|------------------|------------------------------------|
| Range window    | `02:00 - 13:00`  | Records H/L for breakout reference |
| Trade window    | `15:00 - 19:00`  | London-NY overlap (~13-17 GMT)     |
| Force-close     | Friday `>= 20:00`| Flatten before weekend             |

All hours are configurable in the inputs. If your broker's server is on
GMT+2, defaults line up with the London-NY overlap (13:00-17:00 GMT).

### 1.2 Trend Bias (H1)
- `EMA50` above/below `EMA200` **and** current bid on the correct side of `EMA50`
- `ADX(14) >= 22` on H1 (configurable) - no trend, no trade

### 1.3 Signal (M15)
State machine per calendar day:
1. **SETUP_NONE** - wait for an M15 bar to *close* beyond the range while the
   previous bar was inside the range (fresh-breakout gate)
2. **SETUP_*_BREAKOUT** - wait for price to pull back within `RetestAtrMult * ATR`
   of the broken level
3. **SETUP_*_RETEST** - fire on a *bullish* (for long) / *bearish* (for short)
   confirming bar that closes back beyond the breakout level
4. **SETUP_COOLDOWN** - block re-entries for `InpCooldownBars` M15 bars after
   an entry to avoid stacking on the same swing
5. **SETUP_INVALIDATED** - opposite-side break invalidates the setup for the day

RSI extreme filter blocks longs at `RSI >= 72` and shorts at `RSI <= 28`.

### 1.4 Stop / Take-Profit / Runner
| Component | Default                                       |
|-----------|-----------------------------------------------|
| SL        | `ATR(14) * 1.2` (or fixed pips, configurable) |
| TP1       | `+1.5R` -> close `40%` of the position        |
| TP2       | `+2.5R` -> close another `40%`                |
| Break-Even| At `+1.0R` (SL moved to entry + 2p buffer)    |
| Runner    | Trailing SL = `ATR * 1.8` (never below BE)    |

SL is clamped to `[MinSLPips, MaxSLPips]` and additionally to the broker's
minimum stops-level (plus `InpStopLevelBufferP` pips cushion) so orders are
never rejected for "invalid stops".

### 1.5 Risk Manager (all default, all editable)
| Guard                        | Default           | Effect                                      |
|-----------------------------|-------------------|---------------------------------------------|
| Risk per trade              | `0.75 %`          | Position sized so SL = risk %               |
| Daily loss stop             | `-2 % of equity`  | No new trades that day                      |
| Peak-to-equity DD emergency | `8 %`             | Kill-switch: flatten & halt for the session |
| Max trades / day            | `2`               | Hard cap                                    |
| Consecutive losses          | `3`               | Pauses trading for `12 h`                   |
| Spread filter               | `<= 25 points`    | Skip entries in wide-spread ticks           |
| Min ATR (M15)               | `>= 4 pips`       | Skip if market is dead                      |
| News time filter            | opt-in            | Blocks entries around user-supplied times   |
| Weekend / Friday flatten    | on                | Never held over weekend                     |
| Margin pre-check            | on                | Refuses entries without a 5% margin cushion |

### 1.6 No martingale
There is no averaging, doubling, or grid recovery. Each trade risks a fixed
percentage of *current balance*; a loss reduces future position size, a win
grows it (linear compounding), and the DD kill-switch limits total damage.

---

## 2. Enterprise / Institutional Features

| Feature | Description |
|---------|-------------|
| **Broker prefix/suffix support** | `InpSymbolBase="EURUSD"` — validates chart symbol contains that base. Works with `EURUSD`, `EURUSDm`, `EURUSD.a`, `cEURUSD`, `EURUSD_pro`, etc. |
| **Stop-level compliance** | Every SL/TP is clamped to `SYMBOL_TRADE_STOPS_LEVEL + InpStopLevelBufferP` pips so brokers never reject with `TRADE_RETCODE_INVALID_STOPS`. |
| **Auto-fill mode** | `SetTypeFillingBySymbol` picks the right IOC/FOK/RETURN mode per broker. |
| **Millisecond mgmt timer** | `EventSetMillisecondTimer(250)` drives BE / trail / partial-close checks independently of ticks — critical during low-liquidity moments. |
| **Retry-aware modify/close** | `RetryModifyPosition` and `RetryPartialClose` handle transient errors (requote, price-changed, connection blip) with bounded attempts + delay. |
| **Freeze-level aware** | Modify calls skip themselves silently if inside broker's freeze-level to avoid rejected requests. |
| **Margin pre-check** | `OrderCalcMargin` runs before every entry; refuses trade if margin would exceed 95% of free margin. |
| **Indicator cache** | ATR / RSI / EMA / ADX values are cached per-bar in a RAM-resident struct. First call per bar refreshes; subsequent calls are O(1) reads. Pre-allocated `ArraySetAsSeries` buffers avoid per-tick heap allocation. |
| **Trading-context guard** | `OnTick` refuses to act unless `TERMINAL_CONNECTED`, `MQL_TRADE_ALLOWED`, `ACCOUNT_TRADE_ALLOWED`, `ACCOUNT_TRADE_EXPERT` are all true. |
| **Structured logging** | `LogEvt(SFS_LOG_INFO/WARN/ERROR)` with severity filtering via `InpLogLevel`. Emergency stops and consecutive-loss pauses log at WARN/ERROR so they survive `InpVerboseLogging=false`. |
| **Idempotent state** | Local `STradeState` array is synced against terminal positions every tick and every mgmt timer. Manual closes, SL/TP hits, and EA reloads are handled without duplicates. |
| **Adopt-orphan mode** | Positions that predate the EA (or survive a reload) are adopted in trail-only mode: no false BE/partial firing on unknown R distances. |

---

## 3. Installation

1. Copy `StarkForge_Sentinel_EA.mq5` into
   `MetaTrader 5 / MQL5 / Experts / StarkForge_Sentinel_EA/`
2. Open MetaEditor, F7 to compile - **no errors, no warnings** on a stock MT5
   build (uses only standard `<Trade\Trade.mqh>` and `<Trade\SymbolInfo.mqh>`).
3. Copy the `.set` files from `presets/` into
   `MetaTrader 5 / MQL5 / Presets/` (or the same folder as the EA).
4. In MT5, drag the EA onto a **EURUSD M15** chart.
5. In the *Common* tab: enable "Allow Algo Trading".
6. In the *Inputs* tab: click **Load**, pick the appropriate `.set` file:
   - `StarkForge_Sentinel_EA_Funded.set` for prop-firm / funded accounts
   - `StarkForge_Sentinel_EA_Personal.set` for a personal live account
7. Verify the session hours match your broker's timezone (dashboard shows
   broker clock so mis-configuration is immediately visible).

---

## 4. Presets

### 4.1 Funded (`presets/StarkForge_Sentinel_EA_Funded.set`)

Conservative preset tuned for FTMO / Topstep / MFF / The5%ers-style rules:

| Setting                | Value  | Reason                                       |
|-----------------------|--------|----------------------------------------------|
| `InpRiskPercent`      | `0.4`  | Small per-trade drawdown footprint            |
| `InpDailyLossPercent` | `1.5`  | Well inside a 5% daily rule                   |
| `InpMaxDDPercent`     | `4.5`  | Well inside a 10% overall rule                |
| `InpMaxTradesPerDay`  | `1`    | Only the best setup per day                   |
| `InpMaxConsecLoss`    | `2`    | Halts for 24h after 2 losses                  |
| `InpAdxThreshold`     | `25`   | Stricter trend filter                         |
| `InpBreakEven_R`      | `0.8`  | Protect capital sooner                        |
| `InpTP1_R / TP2_R`    | `1.2 / 2.0` | Bank profits faster                      |
| `InpUseNewsFilter`    | `true` | Blocks entries around 08:30 / 12:30 / 14:00   |
| `InpLogLevel`         | `WARN` | Quiet unless something warrants attention     |

### 4.2 Personal (`presets/StarkForge_Sentinel_EA_Personal.set`)

Moderate preset for a personal live account:

| Setting                | Value  | Reason                                       |
|-----------------------|--------|----------------------------------------------|
| `InpRiskPercent`      | `1.0`  | Growth-oriented risk                          |
| `InpDailyLossPercent` | `3.0`  | Room to breathe                               |
| `InpMaxDDPercent`     | `10.0` | Personal-account style DD cap                 |
| `InpMaxTradesPerDay`  | `2`    | Two quality setups per day                    |
| `InpMaxConsecLoss`    | `3`    | 12h pause after 3 losses                      |
| `InpAdxThreshold`     | `22`   | Default trend filter                          |
| `InpBreakEven_R`      | `1.0`  | Standard                                      |
| `InpTP1_R / TP2_R`    | `1.5 / 2.5` | Standard R multiples                     |
| `InpUseNewsFilter`    | `false`| Disabled by default                           |
| `InpLogLevel`         | `INFO` | Full visibility on setups and events          |

---

## 5. Broker Time vs GMT

The EA works exclusively in **broker time** for session windows. Two common
setups:

| Broker Offset | Range Start | Range End | Trade Start | Trade End |
|---------------|-------------|-----------|-------------|-----------|
| GMT+0         | 0           | 11        | 13          | 17        |
| GMT+2 (EU)    | 2           | 13        | 15          | 19        |
| GMT+3 (EEST)  | 3           | 14        | 16          | 20        |

Adjust `InpRangeStartHour`, `InpRangeEndHour`, `InpTradeStartHour`,
`InpTradeEndHour`, `InpForceCloseHour` accordingly. The on-chart dashboard
shows the broker clock and current session status so mis-configuration is
immediately obvious.

---

## 6. On-Chart Dashboard

```
StarkForge Sentinel EA  v1.00
Symbol : EURUSD   Time: 2026.07.03 15:24
Session: - / TRADE
H1 Bias: BULL
Range  : OK  Hi=1.08762 Lo=1.08245
Setup  : LONG retest - awaiting confirm
ATR    : 8.4 pips   Spread: 4 pts
Balance: 100000.00   Equity: 100215.50
Day PnL: 215.50 (0.22%)   Cap: -2.0%
Peak Eq: 100215.50   DD: 0.00% / 8.0%
Trades : Today 1/2   Open 1
Status : ARMED
```

Dashboard colors: green = OK / active, red = warn / halted, gray = idle.
Refresh rate is throttled by `InpDashRefreshMs` (default 1000 ms) so the
250 ms management timer doesn't spam the chart object cache.

---

## 7. Optimization-Friendly Ranges

Only optimize *one or two* parameters at a time to avoid curve-fitting.
Suggested search ranges (from the inline comments in the `.mq5` file):

| Parameter          | Safe range         | Notes                                     |
|--------------------|--------------------|-------------------------------------------|
| `InpEmaFastPeriod` | 30 - 80            | 50 is the industry-classic setting        |
| `InpEmaSlowPeriod` | 150 - 250          | 200 default; keep >= 2x fast              |
| `InpAdxThreshold`  | 18 - 28            | Higher = fewer but stronger setups        |
| `InpAtrSLMult`     | 1.0 - 1.8          | Below 1.0 = too tight                     |
| `InpRetestAtrMult` | 0.20 - 0.60        | Lower = stricter retest                   |
| `InpTP1_R`         | 1.2 - 2.0          | Keep < TP2                                |
| `InpTP2_R`         | 2.0 - 3.5          | Runner does the heavy lifting            |
| `InpTrailAtrMult`  | 1.2 - 2.5          | Tighter = more give-backs prevented       |
| `InpRiskPercent`   | 0.3 - 1.0          | Prop firms usually cap at 1 %             |

Use walk-forward analysis. Never optimize the risk-manager guards (daily
loss %, DD %, max trades) - those are your capital protection, not a knob.

---

## 8. Files

```
StarkForge_Sentinel_EA/
├── StarkForge_Sentinel_EA.mq5     # Expert Advisor (compile with F7)
├── README.md                       # This file
└── presets/
    ├── StarkForge_Sentinel_EA_Funded.set     # Prop-firm conservative preset
    └── StarkForge_Sentinel_EA_Personal.set   # Personal-account moderate preset
```

---

## 9. Safety Checklist Before Going Live

1. Backtest 12+ months of quality tick data on EURUSD M15.
2. Load the appropriate `.set` file (funded vs personal).
3. Match the range/trade hours to your broker's timezone (see dashboard).
4. Confirm `InpSymbolBase` matches your broker's EURUSD symbol root
   (e.g. keep it `EURUSD` — the code strips prefix/suffix automatically).
5. Verify the `SYMBOL_TRADE_TICK_VALUE` reports a sane value for the deposit
   currency of your account (the lot-sizing math depends on it).
6. Run on demo for a full week - confirm entries fire only during the
   configured trade window and the dashboard reflects reality.
7. Enable on a live subaccount only after your prop firm's demo phase.

---

## 10. Disclaimer

This code is provided as-is for educational and research purposes. Live
trading involves substantial risk. Always test thoroughly on demo accounts
first and never risk capital you cannot afford to lose.

