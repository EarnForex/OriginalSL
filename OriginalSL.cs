// -------------------------------------------------------------------------------
//   Marks the original stop-loss levels of historical trades on the chart.
//   Sources the data directly from cTrader's deal history: the StopLossInPrice property
//   of each position-opening HistoricalOrder is the original SL set when the position
//   was created (regardless of any later modifications).
//
//   Version 1.00
//   Copyright 2026, EarnForex.com
//   https://www.earnforex.com/indicators/OriginalSL/
// -------------------------------------------------------------------------------

using System;
using System.Collections.Generic;
using System.Linq;
using cAlgo.API;

namespace cAlgo
{
    public enum DirectionFilterMode { Both, BuysOnly, SellsOnly }
    public enum OutcomeFilterMode   { All, Winners, Losers }

    [Indicator(IsOverlay = true, TimeZone = TimeZones.UTC, AccessRights = AccessRights.None)]
    public class OriginalSL : Indicator
    {
        [Parameter("Direction filter", DefaultValue = DirectionFilterMode.Both, Group = "Filters")]
        public DirectionFilterMode DirectionFilter { get; set; }

        [Parameter("Outcome filter", DefaultValue = OutcomeFilterMode.All, Group = "Filters")]
        public OutcomeFilterMode OutcomeFilter { get; set; }

        [Parameter("Label filter (empty = any)", DefaultValue = "", Group = "Filters")]
        public string LabelFilter { get; set; }

        [Parameter("Days back (0 = no limit)", DefaultValue = 0, MinValue = 0, Group = "Filters")]
        public int DaysBack { get; set; }

        [Parameter("Buy SL color", DefaultValue = "Crimson", Group = "Appearance")]
        public Color BuyColor { get; set; }

        [Parameter("Sell SL color", DefaultValue = "DodgerBlue", Group = "Appearance")]
        public Color SellColor { get; set; }

        [Parameter("Text font size", DefaultValue = 10, MinValue = 6, MaxValue = 32, Group = "Appearance")]
        public int TextFontSize { get; set; }

        [Parameter("Object name prefix", DefaultValue = "OSL_", Group = "Misc")]
        public string ObjectPrefix { get; set; }

        // -------------------------------------------------------------------------
        // State
        // -------------------------------------------------------------------------

        // Trade record built from one historical position's opening HistoricalOrder plus the matching HistoricalTrade entries.
        private class TradeRecord
        {
            public long      Ticket;       // Position ID - what users see as the "trade ID" in cTrader.
            public TradeType TradeType;    // Buy or Sell.
            public double    Sl;           // Original SL from the opening order.
            public double    SlPips;       // Original SL in pips.
            public DateTime  OpenTime;     // Opening order's FilledTime.
            public DateTime  CloseTime;    // Latest exit deal time.
            public double    ClosePrice;   // Final close price (for the SL-hit heuristic).
            public double    NetProfit;    // Aggregated across all HistoricalTrade entries for this position.
            public string    Label;        // Opening order label (cTrader's analogue of MQL magic).
            public bool      IsClosed;     // True if at least one HistoricalTrade entry exists.
        }

        private readonly List<TradeRecord> _trades = new List<TradeRecord>();

        // -------------------------------------------------------------------------
        // Lifecycle
        // -------------------------------------------------------------------------

        protected override void Initialize()
        {
            // Subscribing here, then doing the initial load - History and HistoricalOrders
            // are already populated by the time Initialize() runs. The Closed event is the
            // only signal that can change the original-SL picture (SL/TP modifications and
            // pending-order tweaks don't add to History).
            Positions.Closed += OnPositionClosed;
            Reload();
        }

        public override void Calculate(int index)
        {
            // Nothing to do per bar - data and drawing are event-driven.
        }

        private void OnPositionClosed(PositionClosedEventArgs args)
        {
            Reload();
        }

        // -------------------------------------------------------------------------
        // Reload + history loader
        // -------------------------------------------------------------------------

        // Wipe our objects, rebuild Trades[], redraw.
        private void Reload()
        {
            CleanupObjects();
            _trades.Clear();
            LoadTrades();
            DrawAll();
        }

        // Build TradeRecords from HistoricalOrders (for original SL + entry data) and History (for outcome/profit info). Only the current chart's symbol is loaded.
        private void LoadTrades()
        {
            // Pass 1: walk History to aggregate net profit per position and capture the
            // latest exit's timestamp + price. A single position can produce multiple
            // HistoricalTrade entries when it's been partially closed.
            var profitByPos   = new Dictionary<long, double>();
            var lastCloseByPos = new Dictionary<long, (DateTime time, double price)>();

            foreach (var ht in History)
            {
                if (!SymbolsMatch(ht.SymbolName, Symbol.Name)) continue;

                long pid = ht.PositionId;
                profitByPos.TryGetValue(pid, out var existing);
                profitByPos[pid] = existing + ht.NetProfit;

                if (!lastCloseByPos.TryGetValue(pid, out var prev) || ht.ClosingTime > prev.time)
                {
                    lastCloseByPos[pid] = (ht.ClosingTime, ht.ClosingPrice);
                }
            }

            // Pass 2: walk HistoricalOrders for opening orders carrying a non-zero SL.
            // Skip StopLossTakeProfit orders - those are the SL/TP-triggered closing
            // orders, not the orders that originally opened the position.
            foreach (var ord in HistoricalOrders)
            {
                if (!SymbolsMatch(ord.SymbolName, Symbol.Name)) continue;
                if (ord.OrderType == HistoricalOrderType.StopLossTakeProfit) continue;
                if (!ord.PositionId.HasValue) continue;
                if (!ord.StopLoss.HasValue || ord.StopLoss.Value <= 0) continue;
                if (!ord.FilledTime.HasValue) continue;

                long pid = ord.PositionId.Value;
                if (_trades.Any(r => r.Ticket == pid)) continue; // Dedupe scale-ins - keep the first.

                var rec = new TradeRecord
                {
                    Ticket    = pid,
                    TradeType = ord.TradeType,
                    Sl        = ord.StopLoss.Value,
                    OpenTime  = ord.FilledTime.Value,
                    Label     = ord.Label ?? string.Empty,
                };

                if (ord.StopLossPips.HasValue) rec.SlPips = ord.StopLossPips.Value;

                if (profitByPos.TryGetValue(pid, out var np))
                {
                    rec.NetProfit = np;
                    rec.IsClosed  = true;
                }
                if (lastCloseByPos.TryGetValue(pid, out var ci))
                {
                    rec.CloseTime  = ci.time;
                    rec.ClosePrice = ci.price;
                }

                _trades.Add(rec);
            }

            Print("Loaded {0} historical position(s) for {1}", _trades.Count, Symbol.Name);
        }

        // -------------------------------------------------------------------------
        // Drawing
        // -------------------------------------------------------------------------

        // Walk the loaded trades, apply filters, draw the qualifying ones.
        private void DrawAll()
        {
            DateTime cutoff = DaysBack > 0 ? Server.Time.AddDays(-DaysBack) : DateTime.MinValue;
            int drawn = 0;

            foreach (var r in _trades)
            {
                // Skip positions that haven't been (even partially) closed yet.
                if (!r.IsClosed) continue;

                // Label filter (empty = any).
                if (!string.IsNullOrEmpty(LabelFilter) && r.Label != LabelFilter) continue;

                // Direction filter.
                if (DirectionFilter == DirectionFilterMode.BuysOnly  && r.TradeType != TradeType.Buy)  continue;
                if (DirectionFilter == DirectionFilterMode.SellsOnly && r.TradeType != TradeType.Sell) continue;

                // Date cutoff (compared against close time).
                if (cutoff != DateTime.MinValue && r.CloseTime < cutoff) continue;

                // Outcome filter.
                bool winner = r.NetProfit > 0;
                if (OutcomeFilter == OutcomeFilterMode.Winners && !winner) continue;
                if (OutcomeFilter == OutcomeFilterMode.Losers  &&  winner) continue;

                DrawSLMarker(r);
                drawn++;
            }

            if (drawn == 0 && _trades.Count > 0)
            {
                Print("No trades passed the active filters ({0} loaded for this symbol).", _trades.Count);
            }
        }

        // Draws the SL text with a dash marker.
        private void DrawSLMarker(TradeRecord r)
        {
            Color  clr        = r.TradeType == TradeType.Buy ? BuyColor : SellColor;
            string tooltip    = string.Format("Original SL of order #{0}", r.Ticket, " = ", r.SlPips, " pips");
            int bar_index     = Bars.OpenTimes.GetIndexByTime(r.OpenTime);
            DateTime openTime = Bars.OpenTimes[bar_index]; // Otherwise, the text might go to the next bar.
            string textName   = ObjectPrefix + "T_" + r.Ticket;
            string text       = r.Sl.ToString("F" + Symbol.Digits) + " (" + r.SlPips.ToString() + "p) -";
            var    label      = Chart.DrawText(textName, text, openTime, r.Sl, clr);
            label.HorizontalAlignment = HorizontalAlignment.Left;
            label.VerticalAlignment   = VerticalAlignment.Center;
            label.FontSize            = TextFontSize;
            label.IsInteractive       = false;
            label.Comment             = tooltip;
        }

        // Remove every chart object whose name starts with ObjectPrefix. Iterating into a list first avoids modifying Chart.Objects while enumerating it.
        private void CleanupObjects()
        {
            var toRemove = Chart.Objects
                .Where(o => o.Name.StartsWith(ObjectPrefix))
                .Select(o => o.Name)
                .ToList();

            foreach (var name in toRemove)
            {
                Chart.RemoveObject(name);
            }
        }

        // -------------------------------------------------------------------------
        // Helpers
        // -------------------------------------------------------------------------

        // Case-insensitive symbol comparison. cTrader normally stores symbol names in a
        // consistent canonical case, but accounts migrated between brokers occasionally
        // carry historical entries with a different case than the live symbol - keep
        // this defensive.
        private static bool SymbolsMatch(string a, string b)
        {
            return string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
        }
    }
}