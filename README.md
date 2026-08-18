# TradingView Watchlist — Omarchy Quattro Plugin

A bar widget for the Omarchy Quattro desktop shell that shows a compact watchlist of stocks, crypto, forex, and more — right in your bar. Click any symbol to open its TradingView chart in your default browser.

## Features

- 📈 Chart icon in the bar (right side by default)
- Click the icon to open a drawer panel with your full watchlist (up to 10 symbols)
- Each symbol shows: ticker, description, price, and daily % change (green/red)
- Click any symbol row → opens `https://www.tradingview.com/chart/?symbol=EXCHANGE:SYMBOL` in your default browser
- Search and add symbols by name (auto-resolves exchange and screener)
- Remove symbols with the × button
- Auto-refreshes every 15 minutes
- Watchlist persisted to `~/.local/state/omarchy/settings/trading-view.json`

## Data source

Uses TradingView's public (no-auth, no-API-key) endpoints:

- `POST scanner.tradingview.com/{screener}/scan` — batch price quotes
- `GET symbol-search.tradingview.com/symbol_search/` — symbol lookup

No TradingView login or API key required. The plugin maintains its own local watchlist (separate from your TradingView account).

## Installation

```sh
omarchy plugin add https://github.com/gpatkinson/omarchy-trading-view.git --enable --yes
omarchy-restart-shell
```

## Removal

```sh
omarchy plugin remove io.github.gpatkinson.trading-view
omarchy-restart-shell
```

## Configuration

The watchlist is managed entirely through the plugin panel UI — click "+ Add" to search for and add symbols, or click the × next to a symbol to remove it. Settings are stored at `~/.local/state/omarchy/settings/trading-view.json`.

### Manual watchlist editing

You can also edit the JSON file directly:

```json
{
  "symbols": [
    {"symbol": "AAPL", "exchange": "NASDAQ", "screener": "america", "description": "Apple Inc."},
    {"symbol": "TSLA", "exchange": "NASDAQ", "screener": "america", "description": "Tesla Inc."},
    {"symbol": "BTCUSD", "exchange": "BITSTAMP", "screener": "crypto", "description": "Bitcoin / U.S. Dollar"}
  ]
}
```

The plugin picks up file changes live (no restart needed).

## Dependencies

- `curl` (for HTTP requests — standard on Omarchy systems)
- `xdg-open` (for opening browser — standard on Linux desktops)
- An internet connection

## Limitations

- Maximum 10 symbols per watchlist
- 15-minute refresh interval (to stay within TradingView's free rate limits)
- No real-time streaming (uses polling, not WebSocket)
- Watchlist is local to this plugin, not synced with your TradingView account

## License

MIT