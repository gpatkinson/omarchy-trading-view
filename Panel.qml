import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
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
    if (addingSymbol) cancelAddSymbol(true)
    // Drop Qt focus from the search field before the surface hides: a
    // focused TextField holds a Wayland text-input (IME) session, and
    // letting the surface die with that session active can wedge the
    // seat's keyboard routing compositor-wide (frozen workspace bug).
    if (searchField) searchField.focus = false
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

  property var watchlist: []
  property var scanResults: ({})
  property int pendingFetches: 0
  property int fetchRetries: 0
  // Symbol add state
  property bool addingSymbol: false
  property bool resolvingSymbol: false
  property string resolveError: ""
  // UI state
  property bool loading: false
  readonly property int maxSymbols: 10
  readonly property int rowHeight: Style.space(44)
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

  // ---- Data fetching (price quotes) ----

  // Header button: fetch right now instead of waiting out the 15-minute timer.
  // Guarded because refresh() drives a single Process through a queue, so a
  // second run started mid-flight would stomp the first one's command.
  function refreshNow() {
    if (loading || watchlist.length === 0) return
    refresh()
  }

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

    fetchQueue = screenerList
    fetchResultsAccumulator = []
    startNextFetch()
  }

  property var fetchQueue: []
  property var fetchResultsAccumulator: []

  function startNextFetch() {
    if (fetchQueue.length === 0) {
      // All fetches complete — merge NEW data INTO existing scanResults
      // so symbols whose fetch failed keep their last-known price
      // instead of going blank.
      var fresh = Model.mergeScanResults(fetchResultsAccumulator)
      var merged = {}
      for (var k in root.scanResults) {
        if (root.scanResults.hasOwnProperty(k)) merged[k] = root.scanResults[k]
      }
      for (var k2 in fresh) {
        if (fresh.hasOwnProperty(k2)) merged[k2] = fresh[k2]
      }
      root.scanResults = merged
      loading = false
      fetchResultsAccumulator = []
      return
    }

    var screener = fetchQueue[0]
    fetchQueue = fetchQueue.slice(1)
    pendingFetches++

    var tickers = Model.groupByScreener(watchlist)[screener]
    if (!tickers || tickers.length === 0) {
      startNextFetch()
      return
    }
    var body = Model.scannerBody(tickers)
    var url = Model.scannerUrl(screener)

    fetchProc.command = [
      "curl", "-sS", "--max-time", "10", "--max-filesize", "1048576",
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

  Timer {
    id: refreshTimer
    interval: 15 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- Symbol resolution via scanner ----
  // Instead of a search API, we try the scanner directly with common exchanges.
  // User types "AAPL" -> we try NASDAQ:AAPL, NYSE:AAPL, AMEX:AAPL on the
  // america screener. For crypto we try BINANCE:, BITSTAMP: on crypto screener.

  property var resolveQueue: []
  property string resolveSymbol: ""
  property string resolveType: ""
  property string resolveScreener: ""  // screener from the successful candidate

  function startAddSymbol() {
    addingSymbol = true
    resolvingSymbol = false
    resolveError = ""
    Qt.callLater(function() {
      searchField.text = ""
      searchField.forceActiveFocus()
    })
  }

  function cancelAddSymbol(closing) {
    addingSymbol = false
    resolvingSymbol = false
    resolveError = ""
    resolveQueue = []
    resolveScreener = ""
    searchDebounce.stop()
    // Do NOT re-grab keyboard focus while the panel is closing: the
    // Qt.callLater lands after controller.hide() and re-focuses an item
    // inside the dying window, which pins the layer-shell surface mapped
    // and starves every other window of input (the "frozen workspace" bug).
    if (closing) return
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // Called when user hits Enter in the search field
  function resolveSymbolFromInput() {
    var input = searchField.text.trim()
    if (input.length < 1) return

    // Check if user typed a full EXCHANGE:SYMBOL format
    var colonIdx = input.indexOf(":")
    if (colonIdx > 0) {
      var exch = input.substring(0, colonIdx).toUpperCase()
      var sym = input.substring(colonIdx + 1).toUpperCase()
      resolveQueue = [{ exchange: exch, symbol: sym, screener: Model.screenerForExchange(exch, "") }]
      resolveSymbol = sym
      resolveType = ""
    } else {
      // Build a list of exchange candidates to try
      resolveSymbol = input.toUpperCase()
      resolveType = ""
      resolveQueue = Model.buildResolveQueue(input.toUpperCase())
    }

    resolveError = ""
    resolvingSymbol = true
    tryNextResolve()
  }

  function tryNextResolve() {
    if (resolveQueue.length === 0) {
      resolvingSymbol = false
      resolveError = "Symbol not found: " + resolveSymbol
      return
    }

    var candidate = resolveQueue[0]
    resolveQueue = resolveQueue.slice(1)
    // Store the current candidate so onStreamFinished can access its screener
    resolveScreener = candidate.screener

    var ticker = candidate.exchange + ":" + candidate.symbol
    var body = Model.scannerBody([ticker])
    var url = Model.scannerUrl(candidate.screener)

    resolveProc.command = [
      "curl", "-sS", "--max-time", "5", "--max-filesize", "1048576",
      "-X", "POST",
      "-H", "Content-Type: application/json",
      "-d", body,
      url
    ]
    resolveProc.running = true
  }

  Process {
    id: resolveProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          tryNextResolve()
          return
        }
        try {
          var parsed = Model.parseScanResponse(raw)
          var key = resolveQueue.length > 0
            ? (resolveQueue[0 - 1] ? "" : "") // placeholder
            : ""
          // Check if we got data for any ticker
          var found = false
          var foundKey = ""
          for (var k in parsed) {
            if (parsed.hasOwnProperty(k)) {
              found = true
              foundKey = k
              break
            }
          }

          if (found) {
            // Extract exchange from the key (EXCHANGE:SYMBOL)
            var parts = foundKey.split(":")
            var exchange = parts.length > 1 ? parts[0] : ""
            var symbol = parts.length > 1 ? parts[1] : resolveSymbol

            // Get the result data (has price, changePct, etc.)
            var result = parsed[foundKey]
            var description = exchange + ":" + symbol
            var screener = root.resolveScreener

            // Merge the resolve response into scanResults so the price
            // shows immediately without waiting for the next refresh cycle.
            var merged = {}
            for (var mk in root.scanResults) {
              if (root.scanResults.hasOwnProperty(mk)) merged[mk] = root.scanResults[mk]
            }
            merged[foundKey] = result
            root.scanResults = merged

            addResolvedSymbol(exchange, symbol, screener, description)
          } else {
            // This exchange didn't have it — try next
            tryNextResolve()
          }
        } catch (e) {
          tryNextResolve()
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        tryNextResolve()
      }
    }
  }

  function addResolvedSymbol(exchange, symbol, screener, description) {
    if (watchlist.length >= maxSymbols) {
      resolvingSymbol = false
      resolveError = "Watchlist full (max " + maxSymbols + ")"
      return
    }

    // Check for duplicates
    for (var i = 0; i < watchlist.length; i++) {
      if (watchlist[i].symbol.toUpperCase() === symbol.toUpperCase() &&
          watchlist[i].exchange.toUpperCase() === exchange.toUpperCase()) {
        cancelAddSymbol()
        return
      }
    }

    var newEntry = {
      symbol: symbol,
      exchange: exchange,
      screener: screener,
      description: description
    }
    watchlist = watchlist.concat([newEntry])
    persistWatchlist()
    cancelAddSymbol()
    Qt.callLater(refresh)
  }

  Timer {
    id: searchDebounce
    interval: 300
    onTriggered: {
      // No-op — we only resolve on Enter now, not on type
    }
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

  // ---- Drag reordering ----
  // dragIndex is the watchlist index the pointer picked up; dropIndex is the
  // slot it would land in if released now. Rows derive their visual position
  // from the pair, so nothing is written to the watchlist until the drop.

  property int dragIndex: -1
  property int dropIndex: -1
  property real dragY: 0

  function beginDrag(index, startY) {
    if (watchlist.length < 2) return
    if (index < 0 || index >= watchlist.length) return
    dragIndex = index
    dropIndex = index
    dragY = startY
  }

  function updateDrag(y) {
    if (dragIndex < 0) return
    var maxY = (watchlist.length - 1) * rowHeight
    dragY = Math.max(0, Math.min(y, maxY))
    var slot = Math.round(dragY / rowHeight)
    dropIndex = Math.max(0, Math.min(slot, watchlist.length - 1))
  }

  function endDrag() {
    if (dragIndex < 0) return
    var from = dragIndex
    var to = dropIndex
    dragIndex = -1
    dropIndex = -1
    moveSymbol(from, to)
  }

  function cancelDrag() {
    dragIndex = -1
    dropIndex = -1
  }

  function moveSymbol(from, to) {
    if (from === to) return
    if (from < 0 || from >= watchlist.length) return
    to = Math.max(0, Math.min(to, watchlist.length - 1))
    var list = watchlist.slice()
    var moved = list.splice(from, 1)[0]
    list.splice(to, 0, moved)
    watchlist = list
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

    // WORKAROUND: bypass the Exclusive->OnDemand keyboard-focus prime.
    // The prime exists for hotkey-summon (SUPER+CTRL+W) support, but when it
    // wedges (observed on multi-window workspaces), the full-screen overlay
    // surface stays mapped holding an input grab and the session appears
    // frozen until the shell restarts. Trading the keyboard prime for
    // OnDemand-when-open keeps outside-click dismissal working and removes
    // the grab entirely. Cost: keyboard nav (Esc/arrows) in the panel no
    // longer receives focus — acceptable for a mouse-driven watchlist.
    WlrLayershell.keyboardFocus: root.opened
      ? WlrKeyboardFocus.OnDemand
      : WlrKeyboardFocus.None

    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.addingSymbol
      onReturnRequested: {
        if (root.addingSymbol && !root.resolvingSymbol)
          root.resolveSymbolFromInput()
        else if (root.addingSymbol && root.resolvingSymbol)
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
        interactive: contentHeight > height && root.dragIndex < 0

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

              // Refresh now. Disabled while a fetch is in flight, which also
              // clears the hover fill, so the spin below reads as just the
              // glyph turning rather than the whole button.
              PanelActionButton {
                id: refreshButton
                iconText: "\uf021"
                tooltipText: root.loading ? "Refreshing…" : "Refresh prices now"
                foreground: root.barForeground
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                fontSize: Style.font.caption
                enabled: !root.loading && root.watchlist.length > 0
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.refreshNow()

                RotationAnimation on rotation {
                  running: root.loading
                  loops: Animation.Infinite
                  from: 0
                  to: 360
                  duration: 900
                  onStopped: refreshButton.rotation = 0
                }
              }
            }

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

          // ---- Add symbol input ----
          Item {
            width: parent.width
            height: root.addingSymbol ? (searchField.height + Style.space(6) + resolveStatusText.height) : 0
            visible: root.addingSymbol

            Column {
              width: parent.width
              spacing: Style.space(4)

              TextField {
                id: searchField
                width: parent.width - Style.space(32)
                anchors.horizontalCenter: parent.horizontalCenter
                placeholderText: "Type ticker (e.g. AAPL, TSLA, BTCUSD) and press Enter..."
                enabled: !root.resolvingSymbol
                onAccepted: root.resolveSymbolFromInput()
                Keys.onEscapePressed: root.cancelAddSymbol()
              }

              Text {
                id: resolveStatusText
                width: parent.width - Style.space(32)
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.resolvingSymbol ? "Resolving " + root.resolveSymbol + "..."
                    : root.resolveError ? root.resolveError
                    : ""
                color: root.resolveError ? root.redColor : Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
                visible: root.resolvingSymbol || root.resolveError !== ""
              }
            }
          }

          // ---- Watchlist rows ----
          // Rows are positioned by index inside a fixed-height container rather
          // than stacked in a Column, so a dragged row can travel past its
          // neighbours while they slide into the slot it left behind.
          Item {
            id: listContainer
            width: parent.width
            height: root.watchlist.length * root.rowHeight
            visible: root.watchlist.length > 0

            Repeater {
              model: root.watchlist.length

              Item {
                id: rowItem
                width: listContainer.width
                height: root.rowHeight
                z: dragging ? 2 : 1

                // Named so nested components can test it without reaching for
                // `index`, which an inner Repeater shadows.
                readonly property bool dragging: root.dragIndex === index

                // Slot this row occupies right now: unchanged when idle, and
                // during a drag shifted by one to open a gap at dropIndex.
                readonly property int slot: {
                  if (root.dragIndex < 0) return index
                  if (index === root.dragIndex) return root.dropIndex
                  if (root.dragIndex < root.dropIndex)
                    return (index > root.dragIndex && index <= root.dropIndex) ? index - 1 : index
                  return (index >= root.dropIndex && index < root.dragIndex) ? index + 1 : index
                }

                y: dragging ? root.dragY : slot * root.rowHeight
                // Only the neighbours animate, and only mid-drag: on drop every
                // row snaps straight to its final slot instead of animating a
                // row that now holds different data back to the old position.
                Behavior on y {
                  enabled: root.dragIndex >= 0 && !rowItem.dragging
                  NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                }

                // Lift the dragged row off the list
                Rectangle {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  radius: Style.space(6)
                  color: Color.foreground
                  opacity: rowItem.dragging ? 0.1 : 0
                  Behavior on opacity { NumberAnimation { duration: 120 } }
                }

                // Background click — opens TradingView chart
                MouseArea {
                  anchors.fill: parent
                  acceptedButtons: Qt.LeftButton
                  cursorShape: Qt.PointingHandCursor
                  enabled: root.dragIndex < 0
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

                  // Drag handle — press and drag to reorder. The six dots are
                  // drawn rather than typed so the gap between the two columns
                  // is an exact spacing token instead of a font glyph advance.
                  Item {
                    id: dragHandle
                    width: dots.implicitWidth + Style.space(6)
                    height: parent.height
                    opacity: root.watchlist.length < 2 ? 0.15
                           : (handleArea.containsMouse || rowItem.dragging) ? 1.0 : 0.45

                    Grid {
                      id: dots
                      anchors.centerIn: parent
                      columns: 2
                      rowSpacing: Style.space(3)
                      columnSpacing: Style.space(2)

                      readonly property int dotSize: Style.space(2)

                      Repeater {
                        model: 6

                        Rectangle {
                          width: dots.dotSize
                          height: dots.dotSize
                          radius: width / 2
                          color: rowItem.dragging ? root.barForeground : Color.muted
                        }
                      }
                    }

                    MouseArea {
                      id: handleArea
                      anchors.fill: parent
                      hoverEnabled: true
                      enabled: root.watchlist.length > 1
                      cursorShape: rowItem.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                      // Distance from the pointer to the top of the grabbed row,
                      // so the row keeps its position under the cursor.
                      property real grabOffset: 0

                      onPressed: function (mouse) {
                        grabOffset = mapToItem(listContainer, mouse.x, mouse.y).y - rowItem.y
                        root.beginDrag(index, rowItem.y)
                      }
                      onPositionChanged: function (mouse) {
                        if (!rowItem.dragging) return
                        root.updateDrag(mapToItem(listContainer, mouse.x, mouse.y).y - grabOffset)
                      }
                      onReleased: root.endDrag()
                      onCanceled: root.cancelDrag()
                    }
                  }

                  Column {
                    id: nameColumn
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
                  Item {
                    height: 1
                    width: Math.max(0, row.width - dragHandle.width - nameColumn.width
                                       - priceText.width - changeText.width - removeText.width
                                       - 5 * row.spacing)
                  }

                  // Price
                  Text {
                    id: priceText
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
                    id: changeText
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

                  // Remove button (×)
                  Text {
                    id: removeText
                    text: "×"
                    color: Color.muted
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.subtitle
                    anchors.verticalCenter: parent.verticalCenter

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      enabled: root.dragIndex < 0
                      onClicked: root.removeSymbol(index)
                    }
                  }
                }

                // Separator line
                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  height: 1
                  color: Color.muted
                  opacity: root.dragIndex < 0 && rowItem.slot < root.watchlist.length - 1 ? 0.15 : 0
                }
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
        }
      }
    }
  }
}
