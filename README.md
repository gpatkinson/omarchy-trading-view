# TradingView Watchlist

An [Omarchy Quattro](https://github.com/basecamp/omarchy) bar widget that puts a compact market watchlist on your desktop bar. Track up to 10 stocks, crypto, forex, and more — with live prices, daily change, and one-click deep-linking to TradingView charts in your default browser.

## Features

- **Line-chart glyph** in the bar (right side by default) — clean nerd-font icon that fits Omarchy's aesthetic
- **Drawer panel** on click — shows your full watchlist (up to 10 symbols) with:
  - Symbol and exchange (e.g., `AAPL` / `NASDAQ`)
  - Current price with thousands separators
  - Daily % change with green ▲ / red ▼ color coding
- **Click any symbol** → opens `https://www.tradingview.com/chart/?symbol=EXCHANGE:SYMBOL` in your default browser via `xdg-open`. If you're logged into TradingView, your full chart setup, indicators, and layout are ready to go.
- **Smart symbol resolution** — type a bare ticker like `AAPL` or `BTCUSD` and hit Enter. The plugin tries common exchanges via the scanner API until it finds a match. No search API needed.
- **Full `EXCHANGE:SYMBOL` format also supported** — type `NASDAQ:TSLA` or `BITSTAMP:BTCUSD` directly for instant resolution.
- **Auto-refresh every 15 minutes** — prices stay current without hammering the API
- **Local watchlist persistence** — your symbols are stored at `~/.local/state/omarchy/settings/trading-view.json` and survive restarts
- **Add/remove symbols** through the panel UI — no config file editing required

## How it works

### Data flow

```
User types "AAPL" + Enter
         │
         ▼
  Build resolve queue
  [NASDAQ, NYSE, AMEX, ...]
         │
         ▼
  POST scanner.tradingview.com/america/scan
  with ticker "NASDAQ:AAPL"
         │
         ├─ data returned → symbol found! add to watchlist
         └─ empty response → try next exchange
```

Prices are fetched in batches grouped by TradingView screener (`america`, `crypto`, `forex`) for efficiency — 10 symbols typically means 1-2 HTTP calls per refresh cycle.

### Symbol type detection

The plugin auto-detects what kind of asset you're looking up based on the ticker pattern:

| Pattern | Detected type | Exchanges tried |
|---------|--------------|-----------------|
| `AAPL`, `TSLA` | Stock | NASDAQ, NYSE, AMEX, TSX, LSE, XETRA, ... |
| `BTCUSD`, `ETHUSDT` | Crypto | BITSTAMP, COINBASE, KRAKEN, BINANCE (with USD→USDT conversion), ... |
| `EURUSD`, `GBPJPY` | Forex | OANDA, FX_IDC |
| `NASDAQ:AAPL` | Explicit | Uses the provided exchange directly |

### Click-to-open behavior

Clicking a symbol row opens the TradingView chart page in your default browser:

```
xdg-open "https://www.tradingview.com/chart/?symbol=NASDAQ:AAPL"
```

This uses your browser's existing TradingView session — if you're logged in, you'll see your chart templates, saved indicators, and drawing tools immediately.

## Data source

All price data comes from **TradingView's public scanner API** — no API key, no login, no cookies required:

- `POST scanner.tradingview.com/{screener}/scan` — batch price quotes (close, change %, change abs, volume)

Symbol resolution uses the same scanner endpoint to validate tickers against common exchanges. No separate search API is needed.

**No TradingView account is required.** The watchlist is local to this plugin, not synced with your TradingView account. The "open in browser" button deep-links to TradingView's chart page, where your account session (if logged in) provides your personalized chart experience.

## Resource usage

- **1-4 curl calls per 15-minute refresh** (grouped by screener — 10 US stocks = 1 call)
- **<5 KB data transferred** per refresh cycle
- **Zero CPU between refreshes** — the timer sleeps
- **~1-2 MB memory** for the hidden panel QML
- Comparable to the built-in weather widget

## Installation

```sh
omarchy plugin add https://github.com/gpatkinson/omarchy-trading-view.git --enable --yes
omarchy-restart-shell
```

The line-chart icon appears on the right side of your bar. Click it to open the watchlist panel.

## Removal

```sh
omarchy plugin remove io.github.gpatkinson.trading-view
omarchy-restart-shell
```

## Configuration

The watchlist is managed entirely through the panel UI — click "+ Add" to search for and add symbols, or click the × next to a symbol to remove it.

### Manual watchlist editing

You can also edit the JSON file directly:

```sh
cat ~/.local/state/omarchy/settings/trading-view.json
```

```json
{
  "symbols": [
    {"symbol": "AAPL", "exchange": "NASDAQ", "screener": "america", "description": "NASDAQ:AAPL"},
    {"symbol": "TSLA", "exchange": "NASDAQ", "screener": "america", "description": "NASDAQ:TSLA"},
    {"symbol": "BTCUSD", "exchange": "BITSTAMP", "screener": "crypto", "description": "BITSTAMP:BTCUSD"}
  ]
}
```

The plugin picks up file changes live (no restart needed).

## Dependencies

| Dependency | Purpose | Pre-installed on Omarchy? |
|-----------|---------|--------------------------|
| `curl` | HTTP requests to TradingView scanner API | Yes |
| `xdg-open` | Open TradingView chart in default browser | Yes |

An internet connection is required. No API keys, no accounts, no cookies.

## Limitations

- Maximum 10 symbols per watchlist
- 15-minute refresh interval (to stay within TradingView's free rate limits)
- No real-time streaming (uses polling, not WebSocket)
- Watchlist is local to this plugin, not synced with your TradingView account
- The `description` field shows `EXCHANGE:SYMBOL` format (e.g., `BITSTAMP:BTCUSD`) rather than a human-readable name like "Apple Inc." — the scanner API doesn't return company names

## Plugin structure

```
io.github.gpatkinson.trading-view/
├── manifest.json    # Plugin metadata, ID, bar-widget config
├── BarWidget.qml    # Bar icon (line-chart glyph), loads Panel.qml
├── Panel.qml        # Watchlist table, symbol resolver, click-to-open, price fetcher
├── Model.js         # Scanner API parsing, formatting, exchange mapping, resolve queue
└── README.md        # This file
```

## Technical details

- **Plugin ID:** `io.github.gpatkinson.trading-view`
- **Kind:** `bar-widget` (pill in the bar with a details panel)
- **Bar section:** Right (configurable via `omarchy bar move`)
- **License:** MIT
- **Author:** [gpatkinson](https://github.com/gpatkinson)

## License

MIT