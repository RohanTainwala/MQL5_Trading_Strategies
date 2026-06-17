//+------------------------------------------------------------------+
//|  Martingale_Single_v2.mq5                                        |
//|  Attach to any one of: XAUUSD, EURUSD, EURJPY, AUDUSD, XTIUSD  |
//|  Entry : 5 consecutive M5 candles → opposite trade on 6th open  |
//|  Lots  : 0.01 → 0.08 → 1.0 → 8.0                              |
//|  Exit  : Shared TP above weighted average breakeven             |
//|  SL    : None (pure martingale)                                 |
//+------------------------------------------------------------------+
#property copyright "Rohan | Finingale"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== General ==="
input int    MagicNumber        = 303002;
input string TradeComment       = "Martingale";
input int    ConsecutiveCandles = 5;

input group "=== Lot Sizes ==="
input double Lot1 = 0.01;
input double Lot2 = 0.08;
input double Lot3 = 1.0;
input double Lot4 = 8.0;

input group "=== XAUUSD Settings (price-based) ==="
input double XAU_Step2 = 6.0;
input double XAU_Step3 = 25.0;
input double XAU_Step4 = 75.0;
input double XAU_TP    = 5.0;

input group "=== EURUSD Settings (pips) ==="
input double EUR_Step2 = 80.0;
input double EUR_Step3 = 250.0;
input double EUR_Step4 = 600.0;
input double EUR_TP    = 30.0;

input group "=== EURJPY Settings (pips) ==="
input double EJ_Step2  = 100.0;
input double EJ_Step3  = 300.0;
input double EJ_Step4  = 750.0;
input double EJ_TP     = 35.0;

input group "=== AUDUSD Settings (pips) ==="
input double AUD_Step2 = 70.0;
input double AUD_Step3 = 220.0;
input double AUD_Step4 = 550.0;
input double AUD_TP    = 28.0;

input group "=== XTIUSD Settings (price-based) ==="
input double XTI_Step2 = 2.0;
input double XTI_Step3 = 7.0;
input double XTI_Step4 = 20.0;
input double XTI_TP    = 1.5;

//+------------------------------------------------------------------+
//| Runtime config (resolved in OnInit)                              |
//+------------------------------------------------------------------+
double gSteps[3];
double gTP;
bool   gIsPips;

//+------------------------------------------------------------------+
//| Sequence state                                                   |
//+------------------------------------------------------------------+
bool     gActive         = false;
int      gLevel          = 0;      // current highest level open (1–4)
int      gDirection      = 0;      // 1=buy, -1=sell
double   gEntryPrices[4];
double   gLots[4];
ulong    gTickets[4];
int      gOpenLegs       = 0;
datetime gLastBar        = 0;

//+------------------------------------------------------------------+
//| Resolve symbol config                                            |
//+------------------------------------------------------------------+
bool ResolveConfig()
  {
   string sym = _Symbol;
   if(StringFind(sym, "XAUUSD") >= 0)
     { gSteps[0]=XAU_Step2; gSteps[1]=XAU_Step3; gSteps[2]=XAU_Step4; gTP=XAU_TP; gIsPips=false; }
   else if(StringFind(sym, "EURUSD") >= 0)
     { gSteps[0]=EUR_Step2; gSteps[1]=EUR_Step3; gSteps[2]=EUR_Step4; gTP=EUR_TP; gIsPips=true; }
   else if(StringFind(sym, "EURJPY") >= 0)
     { gSteps[0]=EJ_Step2;  gSteps[1]=EJ_Step3;  gSteps[2]=EJ_Step4;  gTP=EJ_TP;  gIsPips=true; }
   else if(StringFind(sym, "AUDUSD") >= 0)
     { gSteps[0]=AUD_Step2; gSteps[1]=AUD_Step3; gSteps[2]=AUD_Step4; gTP=AUD_TP; gIsPips=true; }
   else if(StringFind(sym,"XTIUSD")>=0 || StringFind(sym,"USOIL")>=0 || StringFind(sym,"WTI")>=0)
     { gSteps[0]=XTI_Step2; gSteps[1]=XTI_Step3; gSteps[2]=XTI_Step4; gTP=XTI_TP; gIsPips=false; }
   else
     {
      PrintFormat("ERROR: %s not supported. Use XAUUSD/EURUSD/EURJPY/AUDUSD/XTIUSD.", sym);
      return false;
     }
   PrintFormat("Config OK for %s | Steps: %.2f / %.2f / %.2f | TP: %.2f | Pips: %s",
               sym, gSteps[0], gSteps[1], gSteps[2], gTP, gIsPips ? "yes" : "no");
   return true;
  }

//+------------------------------------------------------------------+
//| Convert pip or price value to actual price distance              |
//+------------------------------------------------------------------+
double ToPrice(double val)
  {
   if(!gIsPips) return val;
   double pip = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5) pip *= 10;
   return val * pip;
  }

//+------------------------------------------------------------------+
//| Reset sequence                                                   |
//+------------------------------------------------------------------+
void ResetSequence()
  {
   gActive    = false;
   gLevel     = 0;
   gDirection = 0;
   gOpenLegs  = 0;
   ArrayInitialize(gEntryPrices, 0);
   ArrayInitialize(gLots,        0);
   ArrayInitialize(gTickets,     0);
  }

//+------------------------------------------------------------------+
//| Detect filling mode supported by broker                          |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillMode()
  {
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   if((filling & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
//| Count consecutive candles                                        |
//| +1 = 5 bullish closed → SELL signal                             |
//| -1 = 5 bearish closed → BUY  signal                             |
//|  0 = no signal                                                  |
//+------------------------------------------------------------------+
int CountConsecutive()
  {
   double closes[], opens[];
   ArraySetAsSeries(closes, true);
   ArraySetAsSeries(opens,  true);
   int needed = ConsecutiveCandles + 1;
   if(CopyClose(_Symbol, PERIOD_M5, 1, needed, closes) < needed) return 0;
   if(CopyOpen(_Symbol,  PERIOD_M5, 1, needed, opens)  < needed) return 0;

   bool allBull = true, allBear = true;
   for(int i = 0; i < ConsecutiveCandles; i++)
     {
      if(closes[i] <= opens[i]) allBull = false;
      if(closes[i] >= opens[i]) allBear = false;
     }
   if(allBull) return  1;
   if(allBear) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| Weighted average entry across all open legs                      |
//+------------------------------------------------------------------+
double WeightedAvg()
  {
   double cost = 0, lots = 0;
   for(int i = 0; i < gOpenLegs; i++)
     { cost += gEntryPrices[i] * gLots[i]; lots += gLots[i]; }
   return lots > 0 ? cost / lots : 0;
  }

//+------------------------------------------------------------------+
//| Open a single leg and record it                                  |
//+------------------------------------------------------------------+
bool OpenLeg(int direction, double lotSize)
  {
   trade.SetTypeFilling(GetFillMode());   // FIX: auto-detect fill mode

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool   result;

   if(direction == 1)
      result = trade.Buy(lotSize,  _Symbol, ask, 0, 0, TradeComment);
   else
      result = trade.Sell(lotSize, _Symbol, bid, 0, 0, TradeComment);

   if(result)
     {
      double price            = (direction == 1) ? ask : bid;
      gEntryPrices[gOpenLegs] = price;
      gLots[gOpenLegs]        = lotSize;
      gTickets[gOpenLegs]     = trade.ResultOrder();
      gOpenLegs++;
      PrintFormat("[%s] Leg %d | %s | Lot: %.2f | Price: %.5f",
                  _Symbol, gOpenLegs, direction==1?"BUY":"SELL", lotSize, price);
     }
   else
      PrintFormat("[%s] Leg open FAILED | Error: %d | Retcode: %d",
                  _Symbol, GetLastError(), trade.ResultRetcode());
   return result;
  }

//+------------------------------------------------------------------+
//| Close all legs                                                   |
//+------------------------------------------------------------------+
void CloseAll()
  {
   for(int i = 0; i < gOpenLegs; i++)
      if(gTickets[i] > 0) trade.PositionClose(gTickets[i]);
   PrintFormat("[%s] Sequence closed — all %d legs exited.", _Symbol, gOpenLegs);
   ResetSequence();
  }

//+------------------------------------------------------------------+
//| Check if TP is hit against weighted average entry               |
//+------------------------------------------------------------------+
bool IsTPHit()
  {
   if(gOpenLegs == 0) return false;
   double avg    = WeightedAvg();
   double tpDist = ToPrice(gTP);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(gDirection ==  1) return bid >= avg + tpDist;
   if(gDirection == -1) return ask <= avg - tpDist;
   return false;
  }

//+------------------------------------------------------------------+
//| Check if next martingale level should open                       |
//| FIX: each step measured cumulatively from L1 entry price        |
//+------------------------------------------------------------------+
void CheckNextLevel()
  {
   if(gLevel >= 4) return;

   // Cumulative distances from L1 entry: Step2, Step2+Step3, Step2+Step3+Step4
   double cumDist = 0;
   for(int i = 0; i < gLevel; i++)
      cumDist += ToPrice(gSteps[i]);

   double refPrice = gEntryPrices[0];   // always measured from L1
   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lots[4]  = {Lot1, Lot2, Lot3, Lot4};

   if(gDirection == 1 && ask <= refPrice - cumDist)
     {
      gLevel++;
      OpenLeg(1, lots[gLevel - 1]);
     }
   else if(gDirection == -1 && bid >= refPrice + cumDist)
     {
      gLevel++;
      OpenLeg(-1, lots[gLevel - 1]);
     }
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(50);
   if(!ResolveConfig()) return INIT_FAILED;
   ResetSequence();
   gLastBar = 0;
   PrintFormat("Martingale_Single_v2 ready on %s", _Symbol);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  { PrintFormat("Martingale_Single_v2 removed from %s", _Symbol); }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- Active sequence: check TP every tick, check next level every tick
   if(gActive)
     {
      if(IsTPHit()) { CloseAll(); return; }
      CheckNextLevel();
      return;
     }

   //--- No active sequence: only check for entry on new M5 bar
   datetime curBar = iTime(_Symbol, PERIOD_M5, 0);
   if(curBar == gLastBar) return;
   gLastBar = curBar;

   int signal = CountConsecutive();
   if(signal == 0) return;

   ResetSequence();
   gActive    = true;
   gLevel     = 1;
   gDirection = -signal;   // 5 bullish → sell, 5 bearish → buy
   OpenLeg(gDirection, Lot1);
  }
//+------------------------------------------------------------------+