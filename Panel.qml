import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.gpatkinson.trading-view"
  ipcTarget: "io.github.gpatkinson.trading-view"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Panel lifecycle (mirrors weather plugin) ----

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    setCenterHoverRevealSuppressed(true)
    root.refresh()
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (addingSymbol) cancelAddSymbol()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- State ----

  // Watchlist entries: [{"symbol":"AAPL","exchange":"NASDAQ","screener":"america","description":"Apple Inc."}, ...]
  property var watchlist: []
  // Scan results keyed by "EXCHANGE:SYMBOL": {"NASDAQ:AAPL": {"price":187.32,"changePct":1.23,...}, ...}
  property var scanResults: ({})
  // Pending screener fetches — when all complete, results merge into scanResults
  property int pendingFetches: 0
  property int fetchRetries: 0
  // Symbol search state
  property bool addingSymbol: false
  property var searchResults: []
  property int selectedResultIndex: 0
  property string searchQuery: ""
  property bool enterPendingSearch: false  // true when user hit Enter before results arrived
  // UI state
  property bool loading: false
  readonly property int maxSymbols: 10
  readonly property color greenColor: "#22c55e"
  readonly property color redColor: "#ef4444"
  readonly property color mutedColor: Color.muted

  // ---- Watchlist file persistence ----

  property FileView watchlistFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/trading-view.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.watchlist = Model.parseWatchlistFile(text())
      Qt.callLater(root.refresh)
    }
    onLoadFailed: {
      root.watchlist = Model.parseWatchlistFile("")
    }
  }

  // Catch startup race where first read happens before FS is ready
  Timer {
    interval: 1500
    running: true
    onTriggered: watchlistFile.reload()
  }

  function persistWatchlist() {
    var json = Model.serializeWatchlist(watchlist)
    watchlistSaveProc.command = ["sh", "-c",
      "mkdir -p \"" + Quickshell.env("HOME") + "/.local/state/omarchy/settings\""
      + " && printf '%s' '" + json.replace(/'/g, "'\\''") + "'"
      + " > \"" + Quickshell.env("HOME") + "/.local/state/omarchy/settings/trading-view.json\""
    ]
    watchlistSaveProc.running = true
  }

  Process { id: watchlistSaveProc }

  // ---- Data fetching ----

  function refresh() {
    if (watchlist.length === 0) return
    fetchRetries = 0
    loading = true

    var groups = Model.groupByScreener(watchlist)
    pendingFetches = 0
    var screenerList = Object.keys(groups)

    if (screenerList.length === 0) {
      loading = false
      return
    }

    // We reuse a single Process per screener group. Since QML doesn't allow
    // dynamic Process creation easily, we fetch screener groups sequentially
    // using a queue. For the common case (1-3 screeners), this is fast.
    fetchQueue = screenerList
    fetchResultsAccumulator = []
    startNextFetch()
  }

  property var fetchQueue: []
  property var fetchResultsAccumulator: []

  function startNextFetch() {
    if (fetchQueue.length === 0) {
      // All fetches complete — merge results
      scanResults = Model.mergeScanResults(fetchResultsAccumulator)
      loading = false
      fetchResultsAccumulator = []
      return
    }

    var screener = fetchQueue[0]
    fetchQueue = fetchQueue.slice(1)
    pendingFetches++

    // Build curl command: POST to scanner endpoint with JSON body
    var tickers = Model.groupByScreener(watchlist)[screener]
    if (!tickers || tickers.length === 0) {
      startNextFetch()
      return
    }
    var body = Model.scannerBody(tickers)
    var url = Model.scannerUrl(screener)

    fetchProc.command = [
      "curl", "-sS", "--max-time", "10",
      "-X", "POST",
      "-H", "Content-Type: application/json",
      "-d", body,
      url
    ]
    fetchProc.running = true
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          root.scheduleFetchRetry()
          return
        }
        try {
          var parsed = Model.parseScanResponse(raw)
          fetchResultsAccumulator.push(parsed)
          fetchRetries = 0
          startNextFetch()
        } catch (e) {
          scheduleFetchRetry()
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && !fetchResultsAccumulator.length) {
        scheduleFetchRetry()
      }
    }
  }

  function scheduleFetchRetry() {
    loading = false
    if (fetchRetries >= 3) return
    fetchRetries++
    retryTimer.restart()
  }

  Timer {
    id: retryTimer
    interval: 5000
    onTriggered: if (watchlist.length > 0) root.refresh()
  }

  // Auto-refresh every 15 minutes
  Timer {
    id: refreshTimer
    interval: 15 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- Symbol search ----

  function startAddSymbol() {
    addingSymbol = true
    searchResults = []
    selectedResultIndex = 0
    searchQuery = ""
    Qt.callLater(function() {
      searchField.text = ""
      searchField.forceActiveFocus()
    })
  }

  function cancelAddSymbol() {
    addingSymbol = false
    searchResults = []
    selectedResultIndex = 0
    searchQuery = ""
    enterPendingSearch = false
    searchDebounce.stop()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function requestSearch() {
    var query = searchField.text.trim()
    if (query.length < 1) {
      searchResults = []
      return
    }
    searchQuery = query
    if (!searchProc.running) startSearch()
  }

  function startSearch() {
    var query = searchField.text.trim()
    searchProc.command = ["curl", "-sS", "--max-time", "5",
      Model.searchUrl(query, "")]
    searchProc.running = true
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        searchResults = Model.parseSymbolSearch(text)
        selectedResultIndex = 0
        // If user pressed Enter while search was in flight, auto-add first result
        if (root.enterPendingSearch && searchResults.length > 0) {
          root.enterPendingSearch = false
          root.addSymbolFromSearch(0)
        } else {
          root.enterPendingSearch = false
        }
      }
    }
  }

  Timer {
    id: searchDebounce
    interval: 300
    onTriggered: root.requestSearch()
  }

  function addSymbolFromSearch(index) {
    if (index < 0 || index >= searchResults.length) return
    var entry = searchResults[index]
    if (watchlist.length >= maxSymbols) return

    // Check for duplicates
    for (var i = 0; i < watchlist.length; i++) {
      if (watchlist[i].symbol.toUpperCase() === entry.symbol.toUpperCase() &&
          watchlist[i].exchange.toUpperCase() === entry.exchange.toUpperCase()) {
        cancelAddSymbol()
        return
      }
    }

    var newEntry = {
      symbol: entry.symbol,
      exchange: entry.exchange,
      screener: entry.screener,
      description: entry.description
    }
    watchlist = watchlist.concat([newEntry])
    persistWatchlist()
    cancelAddSymbol()
    Qt.callLater(refresh)
  }

  function removeSymbol(index) {
    if (index < 0 || index >= watchlist.length) return
    var newList = []
    for (var i = 0; i < watchlist.length; i++) {
      if (i !== index) newList.push(watchlist[i])
    }
    watchlist = newList
    persistWatchlist()
  }

  // ---- Open in browser ----

  function openInBrowser(exchange, symbol) {
    var url = Model.chartUrl(exchange, symbol)
    openBrowserProc.command = ["xdg-open", url]
    openBrowserProc.running = true
  }

  Process { id: openBrowserProc }

  // ---- IPC ----

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  // ---- Panel UI ----

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.addingSymbol
      onReturnRequested: {
        if (root.addingSymbol && root.searchResults.length > 0)
          root.addSymbolFromSearch(root.selectedResultIndex)
        else if (root.addingSymbol)
          root.cancelAddSymbol()
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: scroll.width
          spacing: Style.space(8)

          // ---- Header row ----
          Item {
            width: parent.width
            height: headerRow.height

            Row {
              id: headerRow
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                text: "TradingView"
                color: root.barForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: root.loading ? " ⟳" : ""
                color: Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // Add symbol button (top-right)
            Text {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              text: root.watchlist.length < root.maxSymbols ? "+ Add" : ""
              color: root.watchlist.length < root.maxSymbols ? root.barForeground : Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (root.addingSymbol) root.cancelAddSymbol()
                  else root.startAddSymbol()
                }
              }
            }
          }

          // ---- Add symbol search bar ----
          Item {
            width: parent.width
            height: root.addingSymbol ? (searchField.height + Style.space(8) + searchResultsColumn.height) : 0
            visible: root.addingSymbol

            Column {
              width: parent.width
              spacing: Style.space(4)

              TextField {
                id: searchField
                width: parent.width - Style.space(32)
                anchors.horizontalCenter: parent.horizontalCenter
                placeholderText: "Search symbol (e.g. AAPL, BTCUSD, EURUSD)..."
                onTextChanged: searchDebounce.restart()
                onAccepted: {
                  if (root.searchResults.length > 0) {
                    root.addSymbolFromSearch(root.selectedResultIndex)
                  } else {
                    // No results yet — fire search immediately, auto-add
                    // first result when search completes
                    searchDebounce.stop()
                    root.enterPendingSearch = true
                    root.requestSearch()
                  }
                }
                Keys.onDownPressed: {
                  if (root.selectedResultIndex < root.searchResults.length - 1)
                    root.selectedResultIndex++
                }
                Keys.onUpPressed: {
                  if (root.selectedResultIndex > 0)
                    root.selectedResultIndex--
                }
                Keys.onEscapePressed: root.cancelAddSymbol()
              }

              Column {
                id: searchResultsColumn
                width: parent.width - Style.space(32)
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 1
                visible: root.searchResults.length > 0

                Repeater {
                  model: root.searchResults.length > 5 ? 5 : root.searchResults.length

                  Rectangle {
                    width: parent.width
                    height: Style.space(36)
                    color: index === root.selectedResultIndex ? Color.bar.active : "transparent"

                    Row {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(8)
                      spacing: Style.space(6)

                      Text {
                        text: modelData < root.searchResults.length ? root.searchResults[modelData].symbol : ""
                        color: root.barForeground
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Text {
                        text: modelData < root.searchResults.length
                          ? (root.searchResults[modelData].exchange ? root.searchResults[modelData].exchange : "")
                          : ""
                        color: Color.muted
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Text {
                        text: modelData < root.searchResults.length
                          ? (root.searchResults[modelData].description ? root.searchResults[modelData].description : "")
                          : ""
                        color: Color.muted
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                        width: parent.width - Style.space(100)
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.addSymbolFromSearch(modelData)
                    }
                  }
                }
              }
            }
          }

          // ---- Watchlist rows ----
          Repeater {
            model: root.watchlist.length

            Column {
              width: scroll.width
              spacing: 0

              Rectangle {
                width: parent.width
                height: Style.space(44)
                color: "transparent"

                // Background click handler — opens TradingView chart.
                // Placed FIRST so it's the bottom z-layer; the × button
                // on top still receives its own clicks.
                MouseArea {
                  anchors.fill: parent
                  acceptedButtons: Qt.LeftButton
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (root.watchlist[index]) {
                      var entry = root.watchlist[index]
                      root.openInBrowser(entry.exchange, entry.symbol)
                    }
                  }
                }

                Row {
                  id: row
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(16)
                  anchors.rightMargin: Style.space(16)
                  spacing: Style.space(8)

                  // Symbol + description
                  Column {
                    width: Style.space(120)
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      text: root.watchlist[index] ? root.watchlist[index].symbol : ""
                      color: root.barForeground
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }

                    Text {
                      text: root.watchlist[index] ? root.watchlist[index].description : ""
                      color: Color.muted
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                      width: parent.width
                    }
                  }

                  // Spacer
                  Item { width: parent.width - Style.space(120) - Style.space(140) - Style.space(28); height: 1 }

                  // Price
                  Text {
                    text: {
                      if (!root.watchlist[index]) return "--"
                      var entry = root.watchlist[index]
                      var result = Model.lookupScanResult(root.scanResults, entry.exchange, entry.symbol)
                      return result && result.price !== null ? Model.formatPrice(result.price) : "--"
                    }
                    color: root.barForeground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  // Change %
                  Text {
                    text: {
                      if (!root.watchlist[index]) return "▬ --"
                      var entry = root.watchlist[index]
                      var result = Model.lookupScanResult(root.scanResults, entry.exchange, entry.symbol)
                      if (!result || result.changePct === null) return "▬ --"
                      return Model.changeArrow(result.changePct) + " " + Model.formatChangePct(result.changePct)
                    }
                    color: {
                      if (!root.watchlist[index]) return Color.muted
                      var entry = root.watchlist[index]
                      var result = Model.lookupScanResult(root.scanResults, entry.exchange, entry.symbol)
                      if (!result || result.changePct === null) return Color.muted
                      if (result.changePct > 0) return root.greenColor
                      if (result.changePct < 0) return root.redColor
                      return Color.muted
                    }
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  // Remove button (×) — on top z-layer, gets clicks first
                  Text {
                    text: "×"
                    color: Color.muted
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.subtitle
                    anchors.verticalCenter: parent.verticalCenter

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeSymbol(index)
                    }
                  }
                }
              }

              // Separator line
              Rectangle {
                width: parent.width
                height: 1
                color: Color.muted
                opacity: 0.15
                visible: index < root.watchlist.length - 1
              }
            }
          }

          // ---- Empty state ----
          Item {
            width: parent.width
            height: Style.space(80)
            visible: root.watchlist.length === 0 && !root.addingSymbol

            Text {
              anchors.centerIn: parent
              text: "No symbols yet.\nClick \"+ Add\" to build your watchlist."
              color: Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }

          // ---- Footer hint ----
          Text {
            width: parent.width
            text: "Click a symbol to open its chart in your browser · 15-min refresh"
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            opacity: 0.6
            topPadding: Style.space(4)
            bottomPadding: Style.space(8)
          }
        }
      }
    }
  }
}