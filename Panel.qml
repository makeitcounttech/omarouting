import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The VPN control surface. Three questions, answered top to bottom: is the
// tunnel up, where does it come out, and what is going through it. Everything
// that changes state is a switch rather than a button, because every one of
// them is a thing you turn on and later turn off.
//
// BarWidget.qml owns the bar capsule, the Service instance, and hands this
// panel the button to anchor against.
Panel {
  id: root
  moduleName: "community.singbox-vpn"
  manageIpc: false

  property var anchorItem: null
  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so everything the bar identifies a panel by has to be that
  // widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property var service: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property bool up: service ? service.up : false
  property int tabIndex: 0

  // ---- keyboard handling ---------------------------------------------------
  // Dropdown popups own their own keys (PanelKeyCatcher.blocked), so the
  // panel keeps no separate cursor model for location rows.

  function refresh() {
    if (!service) return
    service.refresh()
    if (service.up) {
      service.lookupIpWithRetry()
    }
  }

  implicitWidth: 1
  implicitHeight: 1

  // The live traffic stream is held open only while its numbers are on screen.
  onOpenedChanged: {
    if (service) {
      service.panelOpen = opened
      if (opened) service.refreshConnections()
    }
    if (opened) {
      if (panelFlick) panelFlick.contentY = 0
      refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: (root.service ? root.service.connectionsRequestId !== "" : false)
        || connectionsSettings.popupOpen || applicationsPanel.popupOpen || defaultVpnRoutes.popupOpen
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (!root.service) return
        var key = String(t || "").toLowerCase()
        if (key === "t") root.service.toggle()
        else if (key === "r") root.refresh()
      }

      // Match the stock Tailscale/Dropbox panel's native flick behavior.
      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        // Wheel scrolling is one guarded function so precision touchpad
        // deltas and classic notched wheels both move real content (the
        // flickable's own wheel translation is far too fine). Drag and touch
        // stay native: the handler owns no target and accepts an event only
        // when content actually moved, and nothing animates or coasts.
        function wheelScroll(pixelY, angleY) {
          var delta = pixelY !== 0 ? pixelY * 2
            : angleY / 120 * Style.space(56)
          var maximum = Math.max(0, contentHeight - height)
          var next = Math.max(0, Math.min(maximum, contentY - delta))
          if (next === contentY) return false
          cancelFlick()
          contentY = next
          return true
        }

        WheelHandler {
          target: null
          acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
          onWheel: (event) => {
            event.accepted = panelFlick.wheelScroll(event.pixelDelta.y, event.angleDelta.y)
          }
        }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // OmaRouting header: mark + name, same compact language as OmaAssist / OmaOpus.
          Row {
            width: parent.width
            spacing: Style.space(8)
            RoutingMark {
              width: Style.space(20); height: Style.space(20)
              anchors.verticalCenter: parent.verticalCenter
              color: root.foreground; accent: "#82b482"; live: root.up
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "OmaRouting"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.letterSpacing: 1.6
              font.weight: Font.DemiBold
            }
          }

          PillSwitch {
            width: parent.width
            foreground: root.foreground
            fontFamily: root.fontFamily
            current: root.tabIndex === 0 ? "status" : "settings"
            options: [{ key: "status", label: "Status" }, { key: "settings", label: "Settings" }]
            onPicked: function(key) { root.tabIndex = key === "status" ? 0 : 1 }
          }

          // ---- Hero: what this tunnel is, and the one switch that matters.
          PanelHero {
            id: hero
            width: parent.width
            title: root.service ? root.service.activeName : "VPN"
            meta: root.service ? root.service.statusLine : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.up ? 1.0 : 0.5
            iconComponent: Component {
              RoutingMark {
                width: Style.font.display * 1.2; height: width
                color: root.up ? root.foreground : root.dim
                accent: "#82b482"; live: root.up
              }
            }

            trailingControl: Component {
              ToggleSwitch {
                id: tunnelSwitch
                checked: root.up
                busy: root.service ? root.service.runtimeMutationBusy : false
                foreground: hero.foreground
                onToggled: if (root.service) root.service.toggle()

                PanelToolTip {
                  visible: tunnelSwitch.containsMouse
                  text: root.service && root.service.captureEngaged ? "Disconnect / recover" : "Connect"
                  fontFamily: hero.fontFamily
                }
              }
            }
          }

          Text {
            visible: root.service && root.service.activeEndpoint !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.service ? root.service.activeEndpoint : ""
            color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          // Desktop egress observation is separate from broker capture health.
          Column {
            visible: root.up && root.tabIndex === 0
            width: parent.width
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: {
                if (!root.service) return "—"
                if (root.service.exitFresh) return root.service.exitIp
                if (root.service.ipLoading) return "Locating…"
                return "—"
              }
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: {
                if (!root.service) return ""
                if (root.service.ipError !== "") return root.service.ipError.toUpperCase()
                if (!root.service.exitFresh) return "HOST EGRESS NOT CHECKED · REFRESH TO CHECK"
                var parts = ["HOST EGRESS OBSERVED · IPV4"]
                if (root.service.exitLocation !== "") parts.push(root.service.exitLocation.toUpperCase())
                return parts.join(" · ")
              }
              color: root.service && root.service.ipError !== "" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
              elide: Text.ElideRight
            }
          }

          // ---- Live numbers, two per row.
          Grid {
            visible: root.up && root.tabIndex === 0
            width: parent.width
            columns: 2
            columnSpacing: Style.space(10)
            rowSpacing: Style.space(10)

            StatCell {
              width: (column.width - Style.space(10)) / 2
              label: "DOWN"
              value: root.service && root.service.runtimeMetricsAvailable && root.service.ratesLoaded ? Model.formatRate(root.service.downRate) : "—"
              detail: root.service && root.service.runtimeMetricsAvailable ? Model.formatBytes(root.service.downloadTotal) + " received" : "Capture counters unavailable"
            }

            StatCell {
              width: (column.width - Style.space(10)) / 2
              label: "UP"
              value: root.service && root.service.runtimeMetricsAvailable && root.service.ratesLoaded ? Model.formatRate(root.service.upRate) : "—"
              detail: root.service && root.service.runtimeMetricsAvailable ? Model.formatBytes(root.service.uploadTotal) + " sent" : "Capture counters unavailable"
            }

            StatCell {
              width: (column.width - Style.space(10)) / 2
              label: "HTTPS LATENCY"
              value: root.service && root.service.exitFresh && root.service.httpsLatencyMs >= 0 ? root.service.httpsLatencyMs + " ms" : "—"
              detail: "DNS, TCP and TLS setup"
            }

            StatCell {
              width: (column.width - Style.space(10)) / 2
              label: "CAPTURE UPTIME"
              value: root.service && root.service.runtimeMetricsAvailable ? Model.formatDuration(root.service.uptimeSec) : "—"
              detail: root.service && root.service.runtimeMetricsAvailable ? "Current capture session" : "Start time unavailable"
            }
          }

          Column {
            visible: root.tabIndex === 0
            width: parent.width
            spacing: Style.space(10)
            PanelSectionHeader { text: "DEFAULT VPN"; foreground: root.foreground; fontFamily: root.fontFamily }
            Text {
              width: parent.width; textFormat: Text.PlainText; wrapMode: Text.WordWrap
              text: "Choose the VPN for all traffic without an application exception. Changing this keeps saved application exceptions."
              color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
            }
            RuntimeScopes {
              id: defaultVpnRoutes
              width: parent.width
              visible: root.service && root.service.applicationDefaultScope !== ""
              service: root.service
              applicationMode: true
              scopeId: root.service ? root.service.applicationDefaultScope : ""
              foreground: root.foreground; dim: root.dim; urgent: root.urgent
              accent: Color.accent; fontFamily: root.fontFamily
            }
          }

          // ---- Transient feedback and errors.
          Text {
            textFormat: Text.PlainText
            visible: root.service && (root.service.actionStatus !== "" || root.service.lastError !== "")
            width: parent.width
            text: root.service ? (root.service.actionStatus !== "" ? root.service.actionStatus : root.service.lastError) : ""
            color: root.service && root.service.lastError !== "" && root.service.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          // ---- Read-only proxy facts. The desktop-routing switch was
          //      retired with the TUN migration: every packet is captured,
          //      so there is nothing left to switch on the desktop side.
          //      The legacy loopback proxy inbound does not run under the
          //      broker architecture, so no address is shown here — only
          //      the honest warning when an old install left a desktop
          //      setting behind.
          Column {
            visible: root.tabIndex === 0
            width: parent.width
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              visible: root.service && root.service.hasLegacyProxyRecord
              width: parent.width
              text: "An old desktop-proxy record from a previous version is still on disk. The explicit cleanup (`qs -c community.singbox-vpn unrouteDesktop`) releases exactly what it claims — nothing else is touched."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator { foreground: root.foreground }

          Applications {
            id: applicationsPanel
            visible: root.tabIndex === 0
            width: parent.width
            service: root.service
            foreground: root.foreground; dim: root.dim; urgent: root.urgent
            accent: Color.accent; fontFamily: root.fontFamily
          }
          PanelSeparator { visible: root.tabIndex === 0; foreground: root.foreground }

          Row {
            visible: root.tabIndex === 0
            spacing: Style.space(6)

            PanelActionButton {
              iconText: "󰑐"
              tooltipText: "Refresh"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.refresh()
            }

            PanelActionButton {
              visible: root.up && root.service && root.service.exitFresh
              iconText: "󰆏"
              tooltipText: "Copy the exit address"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.service.copyExitIp()
            }

            PanelActionButton {
              visible: false  // Explicit Connect/Disconnect controls replace restart.
              iconText: "󰜉"
              tooltipText: "Restart the tunnel"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.service.restart()
            }
          }

  // ---- SETTINGS tab: authoritative host capture and runtime scopes.
          Column {
            visible: root.tabIndex === 1
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "KILL SWITCH"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              width: parent.width
              spacing: Style.space(10)
              Text {
                width: parent.width - killSwitchControl.implicitWidth - parent.spacing
                textFormat: Text.PlainText
                text: !root.service || !root.service.killSwitchKnown ? "Setting unavailable · refresh status"
                  : root.service.killSwitchEnabled ? "On · block traffic if the VPN fails" : "Off · restore normal network if the VPN fails"
                color: root.service && root.service.killSwitchKnown ? root.foreground : root.urgent
                font.family: root.fontFamily; font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              ToggleSwitch {
                id: killSwitchControl
                objectName: "capture-kill-switch"
                checked: root.service && root.service.killSwitchKnown && root.service.killSwitchEnabled
                enabled: root.service && root.service.canSetKillSwitch
                busy: root.service && root.service.runtimeAction === "set_kill_switch"
                foreground: root.foreground
                onToggled: if (root.service) root.service.setKillSwitch(!root.service.killSwitchEnabled)
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "This setting applies while connected. On blocks captured traffic if the VPN process or its guard lease fails; Off restores normal networking after cleanup. Manual Disconnect always releases traffic. It does not detect every unreachable remote server. Control-plane exceptions remain."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            PanelSeparator { foreground: root.foreground }

            // ---- Connections: WireGuard import, Tailscale/Headscale and
            //      proxies, through the connections IPC contract. Saving and
            //      importing never activate anything; unavailable backend
            //      capabilities render disabled with the reason.
            ConnectionsSettings {
              id: connectionsSettings
              width: parent.width
              service: root.service
              foreground: root.foreground
              dim: root.dim
              urgent: root.urgent
              fontFamily: root.fontFamily
              hoverFill: root.hoverFill
            }
          }


        }
      }
    }
  }

  component PanelTab: CursorSurface {
    id: panelTab
    property string label: ""
    property bool active: false
    property int tabIndex: 0

    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    current: active

    implicitHeight: tabText.implicitHeight + Style.space(12)

    Text {
      id: tabText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: panelTab.label
      color: panelTab.active ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
      font.bold: panelTab.active
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.tabIndex = panelTab.tabIndex
    }
  }

  component StatCell: Column {
    property string label: ""
    property string value: "—"
    property string detail: ""
    property bool urgentValue: false

    spacing: Style.space(1)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
      elide: Text.ElideRight
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: parent.value
      color: parent.urgentValue ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      elide: Text.ElideRight
    }

    Text {
      textFormat: Text.PlainText
      visible: parent.detail !== ""
      width: parent.width
      text: parent.detail
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  component SwitchRow: Item {
    id: switchRow
    property string label: ""
    property string detail: ""
    property bool checked: false

    signal toggled()

    implicitHeight: Math.max(switchText.implicitHeight, rowSwitch.implicitHeight)

    Column {
      id: switchText
      anchors.left: parent.left
      anchors.right: rowSwitch.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: switchRow.label
        color: switchRow.enabled ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        visible: switchRow.detail !== ""
        width: parent.width
        text: switchRow.detail
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    ToggleSwitch {
      id: rowSwitch
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: switchRow.checked
      interactive: switchRow.enabled
      opacity: switchRow.enabled ? 1.0 : 0.4
      foreground: root.foreground
      onToggled: if (switchRow.enabled) switchRow.toggled()
    }
  }

}
