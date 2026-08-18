// Model.js — pure parsing/formatting helpers for the TradingView watchlist
// plugin. No QML imports; imported via `import "Model.js" as Model`.
//
// Data sources:
//   Symbol search: Yahoo Finance v1/finance/search (no auth, needs User-Agent)
//     GET https://query1.finance.yahoo.com/v1/finance/search?q=AAPL&quotesCount=5
//     Returns: {"quotes":[{"symbol":"AAPL","exchange":"NAS","exchDisp":"NASDAQ",
//               "quoteType":"EQUITY","shortname":"Apple Inc","longname":"Apple Inc."}, ...]}
//
//   Price quotes: TradingView scanner (no auth, needs User-Agent)
//     POST https://scanner.tradingview.com/{screener}/scan
//     Body: {"symbols":{"tickers":["EXCHANGE:SYMBOL",...]},"columns":["name","close","change","change_abs","volume"]}
//     Returns: {"data":[{"s":"NASDAQ:AAPL","d":["AAPL",187.32,1.23,0.66,12345678]}, ...]}

// ---------------------------------------------------------------------------
// Watchlist file I/O
// ---------------------------------------------------------------------------

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
// Yahoo Finance symbol search parsing
// ---------------------------------------------------------------------------

// Parse a Yahoo Finance search response. Returns an array of candidate entries:
//   [{"symbol":"AAPL","exchange":"NASDAQ","screener":"america","description":"Apple Inc."}, ...]
// Returns an empty array on failure.
function parseYahooSearch(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || !Array.isArray(data.quotes)) return []
    var out = []
    for (var i = 0; i < data.quotes.length; i++) {
      var q = data.quotes[i]
      if (!q || typeof q.symbol !== "string") continue

      var exchange = yahooToTvExchange(q.exchange, q.exchDisp, q.quoteType)
      var screener = screenerForExchange(exchange, q.quoteType)
      var description = q.longname || q.shortname || ""

      out.push({
        symbol: q.symbol,
        exchange: exchange,
        screener: screener,
        description: description
      })
    }
    return out
  } catch (e) {
    return []
  }
}

// Map Yahoo Finance exchange codes to TradingView exchange names.
// Yahoo uses short codes like "NAS", "NYQ", "CCC" etc.
// We also accept the exchDisp (display name) as fallback.
function yahooToTvExchange(exchange, exchDisp, quoteType) {
  // Crypto on Yahoo has exchange "CCC" — TradingView uses specific exchanges
  // like "BINANCE", "BITSTAMP", "COINBASE". For the scanner we'll default to
  // a reasonable crypto exchange per symbol.
  if (quoteType === "CRYPTocurrency".substring(0, 6).toUpperCase() || 
      String(quoteType).toUpperCase() === "CRYPTOCURRENCY") {
    // For crypto, the symbol itself tells us the pair. Use a generic exchange
    // that the scanner will resolve. We'll try BINANCE first.
    return "BINANCE"
  }

  // Map Yahoo exchange codes to TradingView exchange names
  var codeMap = {
    "NAS": "NASDAQ",
    "NYQ": "NYSE",
    "ASE": "AMEX",
    "LSE": "LSE",
    "TOR": "TSX",
    "GER": "XETRA",
    "PAR": "Euronext",
    "AMS": "Euronext",
    "BRU": "Euronext",
    "LIS": "Euronext",
    "MIL": "BorsaItaliana",
    "STO": "Stockholmsborsen",
    "OSL": "OsloBors",
    "HEL": "NasdaqHelsinki",
    "CPH": "NasdaqCopenhagen",
    "ICE": "NasdaqIceland",
    "TOK": "TSE",
    "JPX": "TSE",
    "ASX": "ASX",
    "NSE": "NSE",
    "BSE": "BSE",
    "HKG": "HKEX",
    "SHH": "SSE",
    "SHZ": "SZSE",
    "KSC": "KRX",
    "TAI": "TWSE",
    "BUE": "BCBA",
    "SAO": "B3",
    "MEX": "BMV"
  }

  // Try Yahoo exchange code first
  if (exchange && codeMap[exchange]) return codeMap[exchange]

  // Try exchDisp (display name) — already close to TradingView format
  if (exchDisp) {
    var disp = String(exchDisp)
    // Common display names that map directly
    var dispMap = {
      "NASDAQ": "NASDAQ",
      "NYSE": "NYSE",
      "NYSE Arca": "NYSE Arca",
      "AMEX": "AMEX",
      "London": "LSE",
      "Toronto": "TSX",
      "Paris": "Euronext",
      "Amsterdam": "Euronext",
      "German": "XETRA",
      "XETRA": "XETRA",
      "Milan": "BorsaItaliana",
      "Stockholm": "Stockholmsborsen",
      "Oslo": "OsloBors",
      "Helsinki": "NasdaqHelsinki",
      "Copenhagen": "NasdaqCopenhagen",
      "Tokyo": "TSE",
      "Sydney": "ASX",
      "NSE": "NSE",
      "BSE": "BSE",
      "Hong Kong": "HKEX",
      "Shanghai": "SSE",
      "Shenzhen": "SZSE",
      "Seoul": "KRX",
      "Taipei": "TWSE",
      "Buenos Aires": "BCBA",
      "São Paulo": "B3",
      "Mexico City": "BMV"
    }
    if (dispMap[disp]) return dispMap[disp]
    // If exchDisp looks like a proper exchange name, use it
    if (disp.length >= 2 && disp.length <= 20) return disp
  }

  // Forex
  if (String(quoteType).toUpperCase() === "CURRENCY" ||
      String(quoteType).toUpperCase() === "FOREX") {
    return "OANDA"
  }

  // ETFs and funds — default to the exchange they're on
  // If we still don't know, default to NASDAQ for US, empty for others
  return exchange || "NASDAQ"
}

// ---------------------------------------------------------------------------
// Screener mapping
// ---------------------------------------------------------------------------

// Map a TradingView exchange name to the screener used by the scanner API.
function screenerForExchange(exchange, type) {
  exchange = String(exchange || "").toUpperCase()
  type = String(type || "").toUpperCase()

  if (type === "CRYPTOCURRENCY" || type === "CRYPTO") return "crypto"
  if (type === "CURRENCY" || type === "FOREX" || type === "FX") return "forex"
  if (type === "CFD") return "forex"

  var usExchanges = ["NASDAQ", "NYSE", "AMEX", "NYSE ARCA", "BATS", "IEX", "OTC"]
  for (var i = 0; i < usExchanges.length; i++) {
    if (exchange === usExchanges[i]) return "america"
  }

  var euMap = {
    "LSE": "london", "EURONEXT": "euronext", "XETRA": "germany",
    "BORSAITALIANA": "italy", "STOCKHOLMSBORSEN": "sweden",
    "OSLOBORS": "oslo", "NASDAQHELSINKI": "finland",
    "NASDAQCOPENHAGEN": "denmark", "NASDAQICELAND": "iceland"
  }
  if (euMap[exchange]) return euMap[exchange]

  var apacMap = {
    "TSE": "japan", "ASX": "australia", "NSE": "india",
    "BSE": "india", "HKEX": "hongkong", "SSE": "china",
    "SZSE": "china", "KRX": "korea", "TWSE": "taiwan"
  }
  if (apacMap[exchange]) return apacMap[exchange]

  if (type === "EQUITY" || type === "ETF" || type === "MUTUALFUND" || type === "FUND") return "america"

  return "america"
}

// ---------------------------------------------------------------------------
// TradingView scanner response parsing
// ---------------------------------------------------------------------------

function parseScanResponse(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || !Array.isArray(data.data)) return {}

    var result = {}
    for (var i = 0; i < data.data.length; i++) {
      var row = data.data[i]
      if (!row || typeof row.s !== "string" || !Array.isArray(row.d)) continue

      var cols = row.d
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

function formatPrice(price) {
  if (price === null || price === undefined || isNaN(price)) return "--"
  var str = price.toFixed(2)
  var parts = str.split(".")
  parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  return parts.join(".")
}

function formatChangePct(pct) {
  if (pct === null || pct === undefined || isNaN(pct)) return "--"
  var sign = pct > 0 ? "+" : ""
  return sign + pct.toFixed(2) + "%"
}

function formatChangeAbs(abs) {
  if (abs === null || abs === undefined || isNaN(abs)) return "--"
  var sign = abs > 0 ? "+" : ""
  return sign + abs.toFixed(2)
}

function formatVolume(vol) {
  if (vol === null || vol === undefined || isNaN(vol)) return "--"
  if (vol >= 1e9) return (vol / 1e9).toFixed(2) + "B"
  if (vol >= 1e6) return (vol / 1e6).toFixed(2) + "M"
  if (vol >= 1e3) return (vol / 1e3).toFixed(2) + "K"
  return String(Math.round(vol))
}

function changeArrow(pct) {
  if (pct === null || pct === undefined || isNaN(pct)) return "▬"
  if (pct > 0) return "▲"
  if (pct < 0) return "▼"
  return "▬"
}

// ---------------------------------------------------------------------------
// URL generation
// ---------------------------------------------------------------------------

function chartUrl(exchange, symbol) {
  var ex = String(exchange || "").toUpperCase()
  var sym = String(symbol || "").toUpperCase()
  if (ex && sym) return "https://www.tradingview.com/chart/?symbol=" + ex + ":" + sym
  if (sym) return "https://www.tradingview.com/chart/?symbol=" + encodeURIComponent(sym)
  return "https://www.tradingview.com/"
}

function scannerUrl(screener) {
  return "https://scanner.tradingview.com/" + String(screener || "america") + "/scan"
}

function scannerBody(tickers) {
  return JSON.stringify({
    symbols: { tickers: tickers, query: { types: [] } },
    columns: ["name", "close", "change", "change_abs", "volume"]
  })
}

// Yahoo Finance search URL — needs a browser User-Agent to avoid 403/rate-limit.
function yahooSearchUrl(query) {
  return "https://query1.finance.yahoo.com/v1/finance/search?q=" + encodeURIComponent(query) + "&quotesCount=5"
}

// ---------------------------------------------------------------------------
// Grouping helpers
// ---------------------------------------------------------------------------

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

function lookupScanResult(scanResults, exchange, symbol) {
  var ex = exchange ? exchange.toUpperCase() : ""
  var sym = symbol ? symbol.toUpperCase() : ""
  if (ex && scanResults[ex + ":" + sym]) return scanResults[ex + ":" + sym]
  if (scanResults[sym]) return scanResults[sym]
  return null
}