//+------------------------------------------------------------------+
//|                                                   OriginalSL.mq5 |
//|                                  Copyright © 2026, EarnForex.com |
//|                 https://www.earnforex.com/indicators/OriginalSL/ |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2026, EarnForex.com"
#property link      "https://www.earnforex.com/indicators/OriginalSL/"
#property version   "1.00"
#property description "Marks the original stop-loss levels of historical trades on the chart."
#property description "Sources the data directly from MT5's deal history: the SL value stored"
#property description "on each position-opening deal is the original SL of that position."

#property indicator_chart_window
#property indicator_plots 0

enum ENUM_DIRECTION_FILTER
{
    DF_BOTH,       // Buys and sells
    DF_BUYS_ONLY,  // Buys only
    DF_SELLS_ONLY  // Sells only
};

enum ENUM_OUTCOME_FILTER
{
    OF_ALL,        // All outcomes
    OF_WINNERS,    // Winners only
    OF_LOSERS,     // Losers only
    OF_SL_HIT      // SL hit only
};

// Trade record built from one historical position's IN/OUT deals. The symbol is implicit (always the current chart's symbol, enforced at load time).
struct TradeRecord
{
    long     ticket;       // Position ID (what users see as the "trade ID" in MT5).
    int      type;         // DEAL_TYPE_BUY (0) or DEAL_TYPE_SELL (1) from the entry deal.
    double   sl;           // Original SL from the entry deal.
    datetime openTime;
    double   openPrice;
    datetime closeTime;    // 0 while the position is still open.
    double   commission;   // Aggregated across all deals for the position.
    double   swap;
    double   profit;
    long     magic;
    bool     closedBySL;   // DEAL_REASON_SL on any closing deal.
};

input string Comment_0 = "======================="; // Filters
input ENUM_DIRECTION_FILTER DirectionFilter = DF_BOTH;    // Direction filter
input ENUM_OUTCOME_FILTER   OutcomeFilter   = OF_ALL;     // Outcome filter
input int                   MagicFilter     = -1;         // Magic number (-1 = any)
input int                   DaysBack        = 0;          // Days back (0 = no limit)

input string Comment_1 = "======================="; // Appearance
input color           BuyLineColor  = clrCrimson;          // Buy SL line color
input color           SellLineColor = clrDodgerBlue;       // Sell SL line color
input int             LineWidth     = 1;                   // Line width (1..5)
input ENUM_LINE_STYLE LineStyle     = STYLE_SOLID;         // Line style
input string TextFont               = "Verdana";           // Price text font
input int    TextFontSize           = 10;                  // Price text font size
input bool   ObjectsInBack          = false;               // Draw behind price action

input string Comment_2 = "======================="; // Misc
input string ObjectPrefix   = "OSL_";                     // Chart object prefix

// Global variables:
TradeRecord Trades[];
bool        NeedFullRedraw = true;
int         LastDealsTotal = -1;  // Change-detector for OnTrade - reloads only when the deal count actually grew.

int OnInit()
{
    // Validate the most error-prone inputs.
    if (LineWidth < 1 || LineWidth > 5)
    {
        Alert("LineWidth must be between 1 and 5.");
    }
    if (TextFontSize < 6)
    {
        Alert("TextFontSize must be at least 6.");
    }

    IndicatorSetString(INDICATOR_SHORTNAME, "Original SL");

    NeedFullRedraw = true;
    LastDealsTotal = -1;
    ArrayResize(Trades, 0);

    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    CleanupObjects();
}

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
    // First-tick draw. Subsequent refreshes are driven by OnTrade.
    if (NeedFullRedraw)
    {
        Reload();
        NeedFullRedraw = false;
    }
    return rates_total;
}

void OnTrade()
{
    // OnTrade fires for every trading event - new orders, modifications, fills, closes.
    // Only an actual new deal can change the original-SL picture (SL modifications don't
    // generate deals), so peek at HistoryDealsTotal first and skip the full reload when
    // nothing relevant has changed.
    HistorySelect(0, TimeCurrent());
    if (HistoryDealsTotal() != LastDealsTotal)
    {
        Reload();
    }
}

// Reload everything: walk deal history, rebuild Trades[], redraw.
void Reload()
{
    CleanupObjects();
    ArrayResize(Trades, 0);

    if (LoadTradesFromHistory())
    {
        DrawAll();
    }

    LastDealsTotal = HistoryDealsTotal();
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Deal-history loader                                              |
//+------------------------------------------------------------------+

// Walk the deal history and populate Trades[] - one record per historical position whose entry deal carries a non-zero SL and matches the current chart's symbol.
bool LoadTradesFromHistory()
{
    if (!HistorySelect(0, TimeCurrent()))
    {
        Print("HistorySelect failed; cannot load original SL data.");
        return false;
    }

    int total = HistoryDealsTotal();

    // Pass 1: collect entry deals. One record per position - subsequent IN deals from a
    // scale-in are skipped so we always keep the *first* SL the position was opened with
    // (the truly original one).
    for (int i = 0; i < total; i++)
    {
        ulong dealTicket = HistoryDealGetTicket(i);
        if (dealTicket == 0) continue;

        long entry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
        if (entry != DEAL_ENTRY_IN) continue;

        string sym = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
        if (!SymbolsMatch(sym, _Symbol)) continue;

        long type = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
        if (type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;

        double sl = HistoryDealGetDouble(dealTicket, DEAL_SL);
        if (sl <= 0) continue;

        long positionId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
        if (FindTradeByPositionId(positionId) >= 0) continue;

        TradeRecord rec;
        rec.ticket     = positionId;
        rec.type       = (int)type;
        rec.sl         = sl;
        rec.openTime   = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
        rec.openPrice  = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
        rec.closeTime  = 0;
        rec.commission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
        rec.swap       = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
        rec.profit     = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
        rec.magic      = (long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
        rec.closedBySL = false;

        int n = ArraySize(Trades);
        ArrayResize(Trades, n + 1);
        Trades[n] = rec;
    }

    // Pass 2: fold every exit deal (OUT / INOUT / OUT_BY) into its position's record:
    // accumulate fees/swap/profit, advance closeTime to the latest exit, and flag SL hits
    // from DEAL_REASON (definitive in MT5 - no comment-marker heuristics needed).
    for (int i = 0; i < total; i++)
    {
        ulong dealTicket = HistoryDealGetTicket(i);
        if (dealTicket == 0) continue;

        long entry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
        if (entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY)
            continue;

        long positionId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
        int idx = FindTradeByPositionId(positionId);
        if (idx < 0) continue;

        Trades[idx].commission += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
        Trades[idx].swap       += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
        Trades[idx].profit     += HistoryDealGetDouble(dealTicket, DEAL_PROFIT);

        datetime dt = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
        if (dt > Trades[idx].closeTime) Trades[idx].closeTime = dt;

        long reason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
        if (reason == DEAL_REASON_SL)
        {
            Trades[idx].closedBySL = true;
        }
    }

    Print("Loaded ", ArraySize(Trades), " historical position(s) for ", _Symbol);
    return true;
}

int FindTradeByPositionId(long positionId)
{
    int n = ArraySize(Trades);
    for (int i = 0; i < n; i++)
    {
        if (Trades[i].ticket == positionId) return i;
    }
    return -1;
}

//+------------------------------------------------------------------+
//| Drawing                                                          |
//+------------------------------------------------------------------+

// Walk the loaded trades, apply filters, draw the qualifying ones.
void DrawAll()
{
    datetime cutoff = (DaysBack > 0) ? (TimeCurrent() - (datetime)DaysBack * 86400) : 0;
    int total = ArraySize(Trades);
    int drawn = 0;

    for (int i = 0; i < total; i++)
    {
        // Skip positions that haven't been (even partially) closed yet - no exit deal
        // means no closeTime. The MQL4 statement-based version only ever saw closed
        // trades, so this keeps the indicator's scope consistent.
        if (Trades[i].closeTime == 0) continue;

        // Magic filter (-1 = any).
        if (MagicFilter != -1 && Trades[i].magic != (long)MagicFilter) continue;

        // Direction filter.
        if (DirectionFilter == DF_BUYS_ONLY  && Trades[i].type != DEAL_TYPE_BUY)  continue;
        if (DirectionFilter == DF_SELLS_ONLY && Trades[i].type != DEAL_TYPE_SELL) continue;

        // Date cutoff (compared against close time).
        if (cutoff > 0 && Trades[i].closeTime < cutoff) continue;

        // Outcome filter.
        double netProfit = Trades[i].profit + Trades[i].swap + Trades[i].commission;
        bool   isWinner  = (netProfit > 0);

        if (OutcomeFilter == OF_WINNERS && !isWinner) continue;
        if (OutcomeFilter == OF_LOSERS  &&  isWinner) continue;
        if (OutcomeFilter == OF_SL_HIT  && !Trades[i].closedBySL) continue;

        DrawSLMarker(i);
        drawn++;
    }

    if (drawn == 0 && total > 0)
    {
        Print("No trades passed the active filters (", total, " loaded for this symbol).");
    }
}

// Draw a text and line objects for the Trades[idx].
void DrawSLMarker(int idx)
{
    long     ticket  = Trades[idx].ticket;
    double   sl      = Trades[idx].sl;
    datetime t       = Trades[idx].openTime;
    color    clr     = (Trades[idx].type == DEAL_TYPE_BUY) ? BuyLineColor : SellLineColor;
    int      sl_pts  = (int)MathRound(MathAbs(Trades[idx].sl - Trades[idx].openPrice) / _Point);
    ENUM_ANCHOR_POINT txt_anchor = (Trades[idx].type == DEAL_TYPE_BUY) ? ANCHOR_RIGHT_UPPER : ANCHOR_RIGHT_LOWER;
    string   tooltip = "Original SL of order #" + IntegerToString(ticket) + " = " + IntegerToString(sl_pts) + " pts";

    int barSecs = PeriodSeconds(_Period);
    int openBar = iBarShift(_Symbol, _Period, t);

    datetime t2 = (openBar >  0) ? iTime(_Symbol, _Period, openBar - 1) : 0;
    if (t2 == 0) t2 = t + barSecs;

    string name = ObjectPrefix + IntegerToString(ticket);
    ObjectCreate(0, name, OBJ_TREND, 0, t, sl, t2, sl);
    ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
    ObjectSetInteger(0, name, OBJPROP_WIDTH,      LineWidth);
    ObjectSetInteger(0, name, OBJPROP_STYLE,      LineStyle);
    ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT,  false);
    ObjectSetInteger(0, name, OBJPROP_RAY_LEFT,   false);
    ObjectSetInteger(0, name, OBJPROP_BACK,       ObjectsInBack);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
    ObjectSetString (0, name, OBJPROP_TOOLTIP,    tooltip);
    
    string textName = ObjectPrefix + "T_" + IntegerToString(ticket);
    ObjectCreate(0, textName, OBJ_TEXT, 0, t, sl);
    ObjectSetString (0, textName, OBJPROP_TEXT,       DoubleToString(sl, _Digits));
    ObjectSetString (0, textName, OBJPROP_FONT,       TextFont);
    ObjectSetInteger(0, textName, OBJPROP_FONTSIZE,   TextFontSize);
    ObjectSetInteger(0, textName, OBJPROP_COLOR,      clr);
    ObjectSetInteger(0, textName, OBJPROP_ANCHOR,     txt_anchor);
    ObjectSetInteger(0, textName, OBJPROP_BACK,       ObjectsInBack);
    ObjectSetInteger(0, textName, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, textName, OBJPROP_HIDDEN,     true);
    ObjectSetString (0, textName, OBJPROP_TOOLTIP,    tooltip);
}

void CleanupObjects()
{
    ObjectsDeleteAll(0, ObjectPrefix);
}

// Case-insensitive symbol comparison. DEAL_SYMBOL normally matches the broker's
// registered casing, but historical deals migrated from older accounts can carry the
// original case - keep this defensive.
bool SymbolsMatch(string a, string b)
{
    StringToLower(a);
    StringToLower(b);
    return (a == b);
}
//+------------------------------------------------------------------+