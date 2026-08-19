### Repository URL

https://github.com/gpatkinson/omarchy-trading-view

### Category

Widgets

### Tags

bar, quickshell

### Suggest a missing tag

finance

### Maintainer notes

TradingView watchlist bar widget showing up to 10 stocks/crypto/forex symbols with live prices and daily % change (green/red). Click any symbol to open its TradingView chart in the default browser.

**External dependencies:** curl (for HTTP requests to TradingView's public scanner API), xdg-open (to open browser). Both are standard on Omarchy systems. No API keys, no accounts, no cookies required.

**Data source:** TradingView's public scanner endpoint (POST scanner.tradingview.com/{screener}/scan). No authentication. Symbol resolution is done by trying the scanner against common exchanges until a match is found — no separate search API is used.

**Permissions:** Reads/writes ~/.local/state/omarchy/settings/trading-view.json for watchlist persistence. No other filesystem access. No network access beyond the TradingView scanner API. No sudo, no system modification.

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.