import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// OmaRouting capsule for the bar (RoutingMark; green dot = connected). The icon is the whole status report: dim means the
// tunnel is off and nothing is being routed, accent means it is up. An
// optional label carries live speed or uptime beside it.
//
// Left click opens the panel, right click toggles the tunnel without opening
// anything, middle click refreshes.
BarWidget {
  id: root
  moduleName: "community.singbox-vpn"

  readonly property bool hideWhenDown: setting("hideWhenDown", false) === true
  readonly property string barLabel: String(setting("barLabel", "Icon only"))
  readonly property bool up: service.up
  readonly property bool busy: service.runtimeMutationBusy

  readonly property string glyph: "󰖂"
  readonly property color glyphColor: root.up ? "#82b482" : service.captureEngaged ? Color.urgent : button.foreground

  readonly property string labelText: {
    if (!root.up || root.vertical) return ""
    if (root.barLabel === "Live speed") return service.runtimeMetricsAvailable && service.ratesLoaded ? Model.formatRate(service.downRate) : "—"
    if (root.barLabel === "Uptime") return service.runtimeMetricsAvailable ? Model.formatDuration(service.uptimeSec) : "—"
    return ""
  }
  readonly property bool showLabel: labelText !== ""

  // The bar reads these off the widget root to size the open-panel indicator
  // under the mark this capsule actually paints.
  readonly property real openPanelIndicatorWidth: capsule.implicitWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  // The tooltip is where the distinction lives that the icon cannot draw:
  // the engine running is not the same as traffic verified. Every value in
  // it was sanitised when parsed (Model.safeText), because the bar's tooltip
  // is not a Text this plugin owns.
  readonly property string tooltipText: {
    if (!root.up || service.runtimeError !== "") return "OmaRouting · " + service.statusLine
    var parts = ["OmaRouting", service.activeName, service.statusLine]
    if (service.exitFresh) {
      parts.push(service.exitLocation !== ""
        ? service.exitIp + " (" + service.exitLocation + ")"
        : service.exitIp)
    } else {
      parts.push("exit not verified yet")
    }
    return parts.join(" · ")
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = service
  }

  function refresh() {
    service.refresh()
    if (service.up) service.lookupIpWithRetry()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  visible: root.up || !root.hideWhenDown
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Service {
    id: service
    settings: root.settings
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "community.singbox-vpn"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.broadcast("refresh") }

    function connect(): string { service.start(); return "ok" }
    function disconnect(): string { service.stop(); return "ok" }
    function toggleTunnel(): string { service.toggle(); return "ok" }
    function restart(): string { service.restart(); return "ok" }
    function killSwitchOn(): string { return service.setKillSwitch(true) ? "requested" : "unavailable" }
    function killSwitchOff(): string { return service.setKillSwitch(false) ? "requested" : "unavailable" }
    // Explicit, ownership-safe cleanup of a legacy desktop-proxy record.
    // There is no activation counterpart: routing the desktop through a
    // loopback proxy is retired behavior this plugin does not do anymore.
    function unrouteDesktop(): string { service.unrouteLegacyDesktopProxy(); return "ok" }
    function status(): string {
      return JSON.stringify({
        up: service.up,
        runtimeState: service.runtimeState,
        captureState: service.captureState,
        captureDeadlineFresh: service.captureDeadlineFresh,
        captureFresh: service.captureFresh,
        killSwitchEnabled: service.killSwitchKnown ? service.killSwitchEnabled : null,
        status: service.statusLine,
        server: service.activeName,
        endpoint: service.activeEndpoint,
        exitIp: service.exitFresh ? service.exitIp : null,
        exitLocation: service.exitFresh ? service.exitLocation : null,
        httpsLatencyMs: service.exitFresh && service.httpsLatencyMs >= 0 ? service.httpsLatencyMs : null,
        uptimeSec: service.runtimeMetricsAvailable ? service.uptimeSec : null,
        downRate: service.runtimeMetricsAvailable && service.ratesLoaded ? service.downRate : null,
        upRate: service.runtimeMetricsAvailable && service.ratesLoaded ? service.upRate : null,
        downloadTotal: service.runtimeMetricsAvailable ? service.downloadTotal : null,
        uploadTotal: service.runtimeMetricsAvailable ? service.uploadTotal : null,
        connections: null
      })
    }
    function debug(): string {
      return JSON.stringify({
        probed: service.probed,
        busy: service.busy,
        queuedActions: service.actionQueue.length,
        bypassState: service.bypassState,
        killSwitch: service.killSwitch,
        configPath: service.configPath,
        apiBase: service.apiBase,
        selector: service.selector,
        nodeCount: service.nodes.length,
        otherTargetCount: service.otherTargets.length,
        legacyProxyRecord: service.hasLegacyProxyRecord,
        sampling: service.sampling,
        lastError: service.lastError
      })
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    dimmed: !root.up
    fixedWidth: root.vertical ? -1 : capsule.implicitWidth + Style.space(17)
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    tooltipText: root.tooltipText

    onPressed: function(b) {
      if (b === Qt.RightButton) service.toggle()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }

    Row {
      id: capsule
      anchors.centerIn: parent
      spacing: Style.space(5)

      Item {
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        anchors.verticalCenter: parent.verticalCenter

        RoutingMark {
          anchors.fill: parent
          anchors.margins: Math.round(parent.width * 0.06)
          color: service.captureEngaged && !root.up ? Color.urgent : button.foreground
          accent: "#82b482"
          live: root.up
          // A connect or disconnect is a request, not an instant: the pulse
          // is what says the click landed while systemd works.
          opacity: root.busy ? 0.45 : 1.0

          SequentialAnimation on opacity {
            running: root.busy
            NumberAnimation { to: 1.0; duration: 420; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 0.45; duration: 420; easing.type: Easing.InOutQuad }
            loops: Animation.Infinite
          }

        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.showLabel
        anchors.verticalCenter: parent.verticalCenter
        text: root.labelText
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering

        Behavior on color {
          enabled: !root.bar || root.bar.foregroundAnimationEnabled
          ColorAnimation { duration: 160 }
        }
      }
    }
  }
}
