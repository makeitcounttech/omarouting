import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

Column {
  id: root
  property var service: null
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property color urgent: Color.urgent
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property string selectedId: ""
  readonly property var rows: service ? service.runningApplications : []
  readonly property var selected: {
    for (var i = 0; i < rows.length; i++) if (Model.applicationRowKey(rows[i]) === selectedId) return rows[i]
    return null
  }
  readonly property string routeScope: {
    if (!selected) return ""
    if (selected.scope) return selected.scope
    if (!selected.assignable || !selected.application) return ""
    var slots = service ? service.applicationSlots : []
    for (var i = 0; i < slots.length; i++) if (!slots[i].bound) return slots[i].scope
    return ""
  }
  readonly property bool popupOpen: appDrop.popupOpen || appRoutes.popupOpen
  readonly property bool canEdit: selected && !selected.legacy_shared
    && (selected.assignable || (selected.binding_id && selected.desktop_id && ["", "not-running"].indexOf(selected.limitation) >= 0))
  readonly property bool choosingBusy: appRoutes.applicationPending || (service
    && (service.runtimeMutationBusy === true || (service.runtimeBusy
      && ["assign", "switch", "block", "application_assign", "application_default",
        "connect", "disconnect", "set_kill_switch", "managed_create", "managed_launch"].indexOf(service.runtimeAction) >= 0)))
  spacing: Style.space(10)
  onSelectedIdChanged: appDrop.value = selectedId

  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onRuntimeResponse(action, ok, response) {
      if (action !== "running_apps" || !ok) return
      // Selection is durable identity, never a refreshed token or label.
      if (root.selected === null && !appRoutes.applicationPending) root.selectedId = ""
    }
  }

  PanelSectionHeader { text: "APPLICATION EXCEPTIONS"; foreground: root.foreground; fontFamily: root.fontFamily }
  Button {
    objectName: "applications-refresh"
    text: root.service && root.service.runtimeBusy && root.service.runtimeAction === "running_apps"
      ? "Refreshing apps…" : "Refresh apps and saved exceptions"
    bordered: true
    foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
    enabled: root.service && root.service.runtimeRevisionKnown && !root.choosingBusy
    onClicked: root.service.refreshApplications()
  }
  SearchableDropdown {
    id: appDrop
    objectName: "observed-application"
    width: parent.width
    label: "Installed application"
    placeholderText: "Choose an application"
    emptyText: "Refresh to discover desktop apps"
    enabled: !root.choosingBusy
    foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
    options: {
      var result = []
      for (var i = 0; i < root.rows.length; i++) {
        var row = root.rows[i]
        if (!row.assignable && !row.binding_id) continue
        result.push({ value: Model.applicationRowKey(row), label: row.name + (row.profile_label ? " · " + row.profile_label : "")
          + (row.binding_id ? " · Saved" : ""), description: row.running ? (row.limitation === "shared-executable" ? "Shared browser identity" : "Running") : (row.binding_id ? "Closed · saved exception" : "Closed") })
      }
      return result
    }
    value: root.selectedId
    onChanged: (value) => root.selectedId = value
    onPopupOpenChanged: if (popupOpen && root.service) Qt.callLater(root.service.refreshApplications)
  }
  Text {
    width: parent.width
    visible: root.selected !== null
    textFormat: Text.PlainText
    text: root.selected ? Model.applicationLimitation(root.selected) : ""
    wrapMode: Text.WordWrap
    color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
  }
  PanelSectionHeader { text: "SAVED EXCEPTIONS"; foreground: root.foreground; fontFamily: root.fontFamily }
  Repeater {
    model: root.rows.filter(function(row) { return !!row.binding_id })
    delegate: Rectangle {
      required property var modelData
      readonly property var appDisplay: Model.applicationDisplay(modelData)
      readonly property var routeDisplay: Model.applicationRouteDisplay(
        root.service ? root.service.runtimeScope(modelData.scope) : null,
        root.service ? root.service.connectionsCatalog : null)
      readonly property var routeScope: root.service
        ? root.service.runtimeScope(modelData.scope) : null
      width: root.width
      implicitHeight: ruleContent.implicitHeight + Style.space(20)
      radius: Style.space(8)
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
      border.width: 1
      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
      Column {
        id: ruleContent
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        anchors.margins: Style.space(10)
        spacing: Style.space(6)
        Text {
          objectName: "application-saved-name"
          width: parent.width; textFormat: Text.PlainText; wrapMode: Text.WordWrap
          text: appDisplay.name
          color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body
          font.bold: true
        }
        Text {
          width: parent.width; textFormat: Text.PlainText; wrapMode: Text.WordWrap
          text: (modelData.running ? "Running" : "Closed") + (appDisplay.detail ? " · " + appDisplay.detail : "")
          color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
        }
        Text {
          objectName: "application-saved-public"
          width: parent.width; textFormat: Text.PlainText; wrapMode: Text.WordWrap
          text: "Internet: " + routeDisplay.internet
          color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption
        }
        Text {
          objectName: "application-saved-private"
          width: parent.width; textFormat: Text.PlainText; wrapMode: Text.WordWrap
          visible: routeDisplay.privateRoute !== ""
          text: "Private networks: " + routeDisplay.privateRoute
          color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption
        }
        Text {
          objectName: "application-saved-telemetry"
          width: parent.width; textFormat: Text.PlainText; wrapMode: Text.WordWrap
          text: Model.scopeTelemetrySummary(routeScope ? routeScope.telemetry : null)
          color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
        }
        Row {
          spacing: Style.space(8)
          Button {
            objectName: "application-saved-select"
            text: "Edit"
            foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
            enabled: !root.choosingBusy
            onClicked: root.selectedId = Model.applicationRowKey(modelData)
          }
          Button {
            objectName: "application-use-default"
            text: root.service && root.service.runtimePendingAction === "application_default"
              ? "Removing…" : "Use default VPN"
            foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
            enabled: root.service && root.service.runtimeRevisionKnown && !root.choosingBusy
            onClicked: root.service.runtimeRequest("application_default", modelData.scope || "", modelData.binding_id, null)
          }
        }
      }
    }
  }
  Text {
    width: parent.width; textFormat: Text.PlainText; wrapMode: Text.WordWrap
    visible: root.rows.some(function(row) { return !!row.binding_id })
    text: "Use default VPN removes only that app's override. Saved providers are unchanged."
    color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
  }
  Text {
    width: parent.width; textFormat: Text.PlainText; wrapMode: Text.WordWrap
    text: root.service ? root.service.applicationDiscoveryWarning : ""
    visible: text !== ""
    color: root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption
  }
  Text {
    width: parent.width
    textFormat: Text.PlainText
    text: root.service ? root.service.applicationRoutingStatus : "Runtime supervisor unavailable."
    color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
  Text {
    width: parent.width
    textFormat: Text.PlainText
    text: "Choose an installed app, even when closed. Saved exceptions persist; everything else follows Default VPN. Changes affect new connections. Web apps follow their associated browser; unsupported shared browser identities cannot be separated here."
    color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
  Text {
    width: parent.width
    visible: root.selected !== null && root.selected.assignable && root.routeScope === ""
    textFormat: Text.PlainText
    text: "The configured application exception limit is reached. Remove an unused saved exception before adding another."
    color: root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
  Text {
    objectName: "application-editing-title"
    width: parent.width; textFormat: Text.PlainText; wrapMode: Text.WordWrap
    visible: root.canEdit && root.routeScope !== ""
    text: root.selected ? "Editing " + Model.applicationDisplay(root.selected).name : ""
    color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body
    font.bold: true
  }
  RuntimeScopes {
    id: appRoutes
    objectName: "application-runtime-scopes"
    width: parent.width
    visible: root.canEdit && root.routeScope !== ""
    service: root.service
    applicationMode: true
    applicationDesktopId: root.selected ? root.selected.desktop_id || "" : ""
    needsApplicationBinding: root.selected !== null && !root.selected.binding_id
    scopeId: root.routeScope
    foreground: root.foreground; dim: root.dim; urgent: root.urgent; accent: root.accent; fontFamily: root.fontFamily
  }
}
