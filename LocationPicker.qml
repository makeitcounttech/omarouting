import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Country → City → Server dependent dropdowns over a unified location list
// (Model.mergeLocationSources). Reused identically by the default VPN
// picker and by each application's VPN-location picker.
//
// Interaction contract (docs/settings-and-connections-ui.md): start with countries
// only; city and server become enabled after their parent is chosen;
// changing a parent clears its children; browsing never switches anything.
// The explicit action button is the only way this component requests a
// change, and it stays honest: an imported catalog location is listed but
// not switchable without the backend runtime, and that is shown, not faked.
Item {
  id: root

  // Unified location entries. Rebuilt when the list changes.
  property var locations: []
  // Exact key of the currently active location ("" when none).
  property string currentKey: ""
  // Actual connection state for the summary ("connected" / "off" / …).
  property string stateLabel: ""
  property string switchLabel: "Switch"
  // When false, the action renders disabled with `unavailableReason`.
  property bool actionAvailable: true
  property string unavailableReason: ""
  property bool showSummary: true
  property bool showAction: true
  // Bounded dropdown content: every option array is capped and the popup
  // list is virtualized — a 10000-entry catalog never instantiates at once.
  property int optionLimit: Model.MAX_NODES

  signal switchRequested(string key)

  // Panel chrome, injected by the embedding panel.
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property color hoverFill: Style.hoverFillFor(foreground, accent)

  // True while any of the three dropdowns owns the keyboard; the embedding
  // panel must block its key catcher while this is set.
  readonly property bool popupOpen: countryDrop.popupOpen || cityDrop.popupOpen || serverDrop.popupOpen

  readonly property var hierarchy: Model.buildLocationHierarchy(locations)
  property var selection: ({ country: "", city: "", server: "" })
  onSelectionChanged: {
    countryDrop.value = selection.country
    cityDrop.value = selection.city
    serverDrop.value = selection.server
  }
  readonly property string searchPlaceholder: "Search…"

  // All embeddings resolve the same exact city-local entry at Apply time.
  // Empty server means Automatic; it is not a health/failover policy.
  readonly property var selectedEntry: Model.selectedHierarchyEntry(hierarchy, selection)

  // The current route's place in the hierarchy, resolved from currentKey.
  readonly property var currentPath: Model.hierarchyPathFor(hierarchy, currentKey)
  readonly property string summaryText: {
    if (currentKey === "") return "Current: none"
    if (!currentPath) return "Current: " + Model.elide(currentKey, 48) + " (not in this list)"
    var e = currentPath.entry
    var country = Model.safeText(e.countryName, 64) !== "" ? e.countryName
      : (e.country !== "" ? e.country : "Unknown")
    var city = Model.safeText(e.cityName, 64) !== "" ? e.cityName
      : (e.city !== "" ? e.city : "Unknown")
    var server = Model.safeText(e.name, 64) || String(e.key)
    var parts = [country, city, server]
    if (e.source === "catalog") parts.push("imported")
    return "Current: " + parts.join(" · ") + (stateLabel !== "" ? " — " + stateLabel : "")
  }

  function pick(level, key) {
    selection = Model.updateHierarchySelection(selection, level, key)
  }

  // Preselect the current server's hierarchy when nothing is chosen yet.
  function preselectCurrent() {
    if (selection.country !== "" || selection.server !== "") return
    if (!currentPath) return
    selection = { country: currentPath.country, city: currentPath.city, server: currentPath.server }
  }
  onHierarchyChanged: preselectCurrent()
  onCurrentKeyChanged: preselectCurrent()
  Component.onCompleted: preselectCurrent()

  function clearSelection() {
    selection = { country: "", city: "", server: "" }
  }

  function resetToCurrent() {
    clearSelection()
    preselectCurrent()
  }

  function fireSwitch() {
    var entry = selectedEntry
    if (!entry) return
    if (!actionAvailable) return
    // An imported catalog location is reachable but not switchable without
    // preparation — never fake a switch for it.
    if (entry.source !== "endpoint") return
    switchRequested(entry.key)
  }

  implicitWidth: 1
  implicitHeight: pickerColumn.implicitHeight

  Column {
    id: pickerColumn
    width: parent.width
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      visible: root.showSummary
      width: parent.width
      text: root.summaryText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    SearchableDropdown {
      id: countryDrop
      objectName: "location-country"
      width: parent.width
      label: "Country"
      placeholderText: root.searchPlaceholder
      emptyText: "No countries"
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      options: Model.hierarchyOptions(root.hierarchy, "country", "", "", root.optionLimit)
      value: root.selection.country
      onChanged: (value) => root.pick("country", value)
    }

    SearchableDropdown {
      id: cityDrop
      objectName: "location-city"
      width: parent.width
      label: "City"
      placeholderText: root.selection.country === "" ? "Choose a country first" : root.searchPlaceholder
      emptyText: "No cities"
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      enabled: root.selection.country !== ""
      opacity: enabled ? 1.0 : 0.4
      options: root.selection.country === "" ? [] :
        Model.hierarchyOptions(root.hierarchy, "city", root.selection.country, "", root.optionLimit)
      value: root.selection.city
      onChanged: (value) => root.pick("city", value)
    }

    SearchableDropdown {
      id: serverDrop
      objectName: "location-server"
      width: parent.width
      label: "Server (optional)"
      placeholderText: root.selection.city === "" ? "Choose a city first" : root.searchPlaceholder
      emptyText: "No servers"
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      enabled: root.selection.city !== ""
      opacity: enabled ? 1.0 : 0.4
      options: {
        if (root.selection.city === "") return []
        var rows = Model.hierarchyOptions(root.hierarchy, "server", root.selection.country, root.selection.city, root.optionLimit)
        if (!rows.length) return []
        return [{ value: "", label: "Automatic (first listed server)", description: "Exact listed location; no health or failover guarantee" }]
          .concat(rows.slice(0, Math.max(1, root.optionLimit) - 1))
      }
      value: root.selection.server
      onChanged: (value) => root.pick("server", value)
    }

    CursorSurface {
      id: actionRow
      objectName: "location-action"
      visible: root.showAction
      width: parent.width
      implicitHeight: actionText.implicitHeight + Style.spacing.xl
      foreground: root.foreground
      fill: root.hoverFill
      enabled: root.actionAvailable && root.selectedEntry !== null && root.selectedEntry.source === "endpoint"
      opacity: enabled ? 1.0 : 0.4

      Text {
        id: actionText
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: {
          var entry = root.selectedEntry
          if (!entry) return root.switchLabel + " — choose a country and city above"
          if (entry.source === "catalog")
            return "Imported location — switching needs the backend runtime"
          return root.switchLabel + " to " + Model.elide(String(entry.name), 32)
        }
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      MouseArea {
        anchors.fill: parent
        enabled: actionRow.enabled
        cursorShape: actionRow.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.fireSwitch()
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: !root.actionAvailable && root.unavailableReason !== ""
      width: parent.width
      text: root.unavailableReason
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      visible: root.hierarchy.total > root.optionLimit
      width: parent.width
      text: "Catalog truncated at " + root.optionLimit + " locations"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
