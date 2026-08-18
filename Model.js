// Model.js — pure parsing/formatting helpers for the TradingView watchlist
// plugin. No QML imports; imported via `import "Model.js" as Model`.
//
// TradingView public endpoints used:
//   POST https://scanner.tradingview.com/{screener}/scan
//     Body: {"symbols":{"tickers":["EXCHANGE:SYMBOL",...]},"columns":["name","close","change","change_abs","volume"]}
//     Returns: {"data":[{"s":"NASDAQ:AAPL","d":["AAPL",187.32,1.23,0.66,12345678]}, ...]}
//
//   GET  https://symbol-search.tradingview.com/symbol_search/?text=AAPL&type=stock
//     Returns: [{"symbol":"AAPL","exchange":"NASDAQ","type":"stock","description":"Apple Inc.",...}, ...]
//
// No auth, no API key, no cookies required for either endpoint.

// ---------------------------------------------------------------------------
// Watchlist file I/O
// ---------------------------------------------------------------------------

// Parse the watchlist JSON state file. Returns an array of symbol entries:
//   [{"symbol":"AAPL","exchange":"NASDAQ","screener":"america","description":"Apple Inc."}, ...]
// Returns an empty array on any failure (missing file, invalid JSON, etc).
function parseWatchlistFile(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || !Array.isArray(data.symbols)) return []
    var out = []
    for (var i = 0; i < data.symbols.length; i++) {
      var s = data.symbols[i]
      if (!s || typeof s.symbol !== "string") continue
      out.push({
        symbol: s.symbol,
        exchange: typeof s.exchange === "string" ? s.exchange : "",
        screener: typeof s.screener === "string" ? s.screener : "",
        description: typeof s.description === "string" ? s.description : ""
      })
    }
    return out
  } catch (e) {
    return []
  }
}

// Serialize a watchlist array into the JSON string to persist.
function serializeWatchlist(watchlist) {
  var symbols = []
  for (var i = 0; i < watchlist.length; i++) {
    var s = watchlist[i]
    symbols.push({
      symbol: s.symbol,
      exchange: s.exchange,
      screener: s.screener,
      description: s.description
    })
  }
  return JSON.stringify({ symbols: symbols })
}

// ---------------------------------------------------------------------------
// Symbol search
// ---------------------------------------------------------------------------

// Parse a symbol_search response. Returns an array of candidate entries:
//   [{"symbol":"AAPL","exchange":"NASDAQ","screener":"america","type":"stock","description":"Apple Inc."}, ...]
// Returns an empty array on failure.
function parseSymbolSearch(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!Array.isArray(data)) return []
    var out = []
    for (var i = 0; i < data.length; i++) {
      var r = data[i]
      if (!r || typeof r.symbol !== "string") continue
      out.push({
        symbol: r.symbol,
        exchange: typeof r.exchange === "string" ? r.exchange : "",
        screener: screenerForExchange(r.exchange, r.type),
        type: typeof r.type === "string" ? r.type : "",
        description: typeof r.description === "string" ? r.description : ""
      })
    }
    return out
  } catch (e) {
    return []
  }
}

// Map a TradingView exchange name to the screener used by the scanner API.
// The scanner endpoint groups symbols by screener region (e.g. "america",
// "crypto", "forex"). This mapping covers the most common cases.
function screenerForExchange(exchange, type) {
  exchange = String(exchange || "").toUpperCase()
  type = String(type || "").toLowerCase()

  // Crypto and forex have dedicated screeners
  if (type === "cryptocurrency" || type === "crypto") return "crypto"
  if (type === "forex" || type === "cfd") return "forex"

  // Major US exchanges
  var usExchanges = ["NASDAQ", "NYSE", "AMEX", "NYSE ARCA", "BATS", "IEX", "OTC"]
  for (var i = 0; i < usExchanges.length; i++) {
    if (exchange === usExchanges[i]) return "america"
  }

  // European exchanges
  var euMap = {
    "LSE": "london", "Euronext": "euronext", "XETRA": "germany",
    "SBF": "france", "BME": "spain", "SIX": "swiss",
    "BorsaItaliana": "italy", "OMX": "sweden", "OB": "oslo"
  }
  if (euMap[exchange]) return euMap[exchange]

  // Asia-Pacific exchanges
  var apacMap = {
    "TSE": "japan", "JPX": "japan", "ASX": "australia", "NSE": "india",
    "BSE": "india", "HKEX": "hongkong", "SSE": "china", "SZSE": "china",
    "KRX": "korea", "SET": "thailand", "SGX": "singapore", "TWSE": "taiwan"
  }
  if (apacMap[exchange]) return apacMap[exchange]

  // Default to america for unknown stock exchanges (most common for US users)
  if (type === "stock" || type === "equity" || type === "etf" || type === "fund") return "america"

  // Last resort
  return "america"
}

// ---------------------------------------------------------------------------
// Scanner response parsing
// ---------------------------------------------------------------------------

// Parse a scanner.tradingview.com/{screener}/scan response.
// Returns a map of "EXCHANGE:SYMBOL" -> {symbol, price, change, changePct, volume}
//   {"NASDAQ:AAPL": {"symbol":"AAPL","price":187.32,"change":1.23,"changePct":0.66,"volume":12345678}, ...}
// Returns an empty object on failure.
function parseScanResponse(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || !Array.isArray(data.data)) return {}

    var result = {}
    for (var i = 0; i < data.data.length; i++) {
      var row = data.data[i]
      if (!row || typeof row.s !== "string" || !Array.isArray(row.d)) continue

      var cols = row.d
      // Column order matches our request: ["name","close","change","change_abs","volume"]
      // BUT the actual response order depends on what we request. We parse by index
      // according to our standard column list defined in Panel.qml.
      // cols[0] = name (symbol without exchange prefix)
      // cols[1] = close (last price)
      // cols[2] = change (percentage)
      // cols[3] = change_abs (absolute change)
      // cols[4] = volume

      result[row.s] = {
        symbol: cols.length > 0 ? String(cols[0]) : "",
        price: cols.length > 1 ? parseFloat(cols[1]) : null,
        changePct: cols.length > 2 ? parseFloat(cols[2]) : null,
        changeAbs: cols.length > 3 ? parseFloat(cols[3]) : null,
        volume: cols.length > 4 ? parseFloat(cols[4]) : null
      }
    }
    return result
  } catch (e) {
    return {}
  }
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

// Format a price with appropriate decimal places.
//   187.32  -> "187.32"
//   0.56    -> "0.56"
//   1234.56 -> "1,234.56"
function formatPrice(price) {
  if (price === null || price === undefined || isNaN(price)) return "--"
  // Use up to 2 decimal places, stripping trailing zeros for clean display
  var str = price.toFixed(2)
  // Add thousands separators
  var parts = str.split(".")
  parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  return parts.join(".")
}

// Format a percentage change with sign and arrow.
//   1.23  -> "+1.23%"
//   -0.5  -> "-0.50%"
//   0.0   -> "0.00%"
function formatChangePct(pct) {
  if (pct === null || pct === undefined || isNaN(pct)) return "--"
  var sign = pct > 0 ? "+" : ""
  return sign + pct.toFixed(2) + "%"
}

// Format absolute price change with sign.
//   1.23  -> "+1.23"
//   -0.50 -> "-0.50"
function formatChangeAbs(abs) {
  if (abs === null || abs === undefined || isNaN(abs)) return "--"
  var sign = abs > 0 ? "+" : ""
  return sign + abs.toFixed(2)
}

// Format volume with K/M/B suffixes.
//   12345678  -> "12.35M"
//   1234      -> "1.23K"
//   1234567890 -> "1.23B"
function formatVolume(vol) {
  if (vol === null || vol === undefined || isNaN(vol)) return "--"
  if (vol >= 1e9) return (vol / 1e9).toFixed(2) + "B"
  if (vol >= 1e6) return (vol / 1e6).toFixed(2) + "M"
  if (vol >= 1e3) return (vol / 1e3).toFixed(2) + "K"
  return String(Math.round(vol))
}

// Get arrow glyph based on change direction.
//   positive -> "▲"  negative -> "▼"  zero/unknown -> "▬"
function changeArrow(pct) {
  if (pct === null || pct === undefined || isNaN(pct)) return "▬"
  if (pct > 0) return "▲"
  if (pct < 0) return "▼"
  return "▬"
}

// ---------------------------------------------------------------------------
// URL generation
// ---------------------------------------------------------------------------

// Build the TradingView chart URL for a symbol.
//   ("NASDAQ", "AAPL") -> "https://www.tradingview.com/chart/?symbol=NASDAQ:AAPL"
function chartUrl(exchange, symbol) {
  var ex = String(exchange || "").toUpperCase()
  var sym = String(symbol || "").toUpperCase()
  if (ex && sym) return "https://www.tradingview.com/chart/?symbol=" + ex + ":" + sym
  if (sym) return "https://www.tradingview.com/chart/?symbol=" + encodeURIComponent(sym)
  return "https://www.tradingview.com/"
}

// Build the scanner API URL for a given screener.
//   "america" -> "https://scanner.tradingview.com/america/scan"
function scannerUrl(screener) {
  return "https://scanner.tradingview.com/" + String(screener || "america") + "/scan"
}

// Build the JSON body for a scanner POST request.
//   ["NASDAQ:AAPL", "NYSE:JPM"] -> '{"symbols":{"tickers":["NASDAQ:AAPL","NYSE:JPM"],"query":{"types":[]}},"columns":["name","close","change","change_abs","volume"]}'
function scannerBody(tickers) {
  return JSON.stringify({
    symbols: { tickers: tickers, query: { types: [] } },
    columns: ["name", "close", "change", "change_abs", "volume"]
  })
}

// Build the symbol search URL.
//   ("AAPL", "stock") -> "https://symbol-search.tradingview.com/symbol_search/?text=AAPL&type=stock"
function searchUrl(query, type) {
  var url = "https://symbol-search.tradingview.com/symbol_search/?text=" + encodeURIComponent(query)
  if (type && type !== "") url += "&type=" + encodeURIComponent(type)
  return url
}

// ---------------------------------------------------------------------------
// Grouping helpers
// ---------------------------------------------------------------------------

// Group watchlist entries by their screener, returning a map:
//   {"america": ["NASDAQ:AAPL", "NYSE:JPM"], "crypto": ["BINANCE:BTCUSDT"]}
function groupByScreener(watchlist) {
  var groups = {}
  for (var i = 0; i < watchlist.length; i++) {
    var s = watchlist[i]
    var key = s.screener || "america"
    if (!groups[key]) groups[key] = []
    var ticker = (s.exchange ? s.exchange.toUpperCase() + ":" : "") + s.symbol.toUpperCase()
    groups[key].push(ticker)
  }
  return groups
}

// Merge scan results from multiple screener responses into a single map.
// Each response is the raw output of parseScanResponse().
function mergeScanResults(results) {
  var merged = {}
  for (var i = 0; i < results.length; i++) {
    var r = results[i]
    for (var key in r) {
      if (r.hasOwnProperty(key)) merged[key] = r[key]
    }
  }
  return merged
}

// Look up a scan result for a watchlist entry, trying multiple key formats.
// Some scanner responses use "EXCHANGE:SYMBOL" while others just use "SYMBOL".
function lookupScanResult(scanResults, exchange, symbol) {
  var ex = exchange ? exchange.toUpperCase() : ""
  var sym = symbol ? symbol.toUpperCase() : ""
  // Try "EXCHANGE:SYMBOL" first
  if (ex && scanResults[ex + ":" + sym]) return scanResults[ex + ":" + sym]
  // Try just "SYMBOL"
  if (scanResults[sym]) return scanResults[sym]
  return null
}