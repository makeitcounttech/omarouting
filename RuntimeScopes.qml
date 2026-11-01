import QtQuick
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
  property string scopeId: ""
  property string privateProvider: ""
  property string publicProvider: ""
  property bool separatePrivateProvider: false
  property bool policyEdited: false
  property bool restoringPolicy: false
  property string loadedScopeId: ""
  property string managedApplication: ""
  property bool applicationMode: false
  property string applicationToken: ""
  property string applicationDesktopId: ""
  property bool needsApplicationBinding: false
  property string pendingApplication: ""
  property string pendingScope: ""
  property string pendingPhase: ""
  property bool routeRequestPending: false
  property int restoreEpoch: 0
  readonly property bool applicationPending: pendingPhase !== ""
  readonly property var scope: service ? service.runtimeScope(scopeId) : null
  readonly property var catalog: service ? service.connectionsCatalog : null
  readonly property bool ready: service && service.runtimeState === "ready"
    && service.runtimeRevisionKnown && !service.runtimeMutationBusy && scope !== null
  readonly property bool popupOpen: scopeDrop.popupOpen || privateDrop.popupOpen
    || publicDrop.popupOpen || privateLocation.popupOpen || publicLocation.popupOpen || appDrop.popupOpen
  readonly property var privateTarget: separatePrivateProvider
    ? Model.runtimeSelectedTarget(catalog, privateProvider, privateLocation.selectedEntry) : publicTarget
  readonly property var publicTarget: Model.runtimeSelectedTarget(catalog, publicProvider, publicLocation.selectedEntry)
  readonly property bool distinctTargets: privateTarget !== null && publicTarget !== null
    && (privateTarget.provider !== publicTarget.provider || (privateTarget.location || "") !== (publicTarget.location || ""))
  readonly property var privatePolicyDraft: Model.runtimePrivatePolicyDraft(catalog, scope, separatePrivateProvider, privateTarget, needsApplicationBinding)
  readonly property var proposedScopePolicy: privatePolicyDraft || (scope ? scope.scope_policy : null)
  readonly property bool privatePolicyMissing: distinctTargets && (!proposedScopePolicy
    || (!proposedScopePolicy.private_cidrs.length && !proposedScopePolicy.private_domains.length))
  readonly property bool active: scope && scope.desired && scope.desired.state === "assigned"
  spacing: Style.space(10)
  // Stock dropdown selection assigns its own value, removing its original binding.
  onPrivateProviderChanged: privateDrop.value = privateProvider
  onPublicProviderChanged: publicDrop.value = publicProvider

  onScopeIdChanged: {
    var epoch = ++root.restoreEpoch
    restoringPolicy = true
    loadedScopeId = ""
    privateProvider = ""
    publicProvider = ""
    separatePrivateProvider = false
    if (privateLocation) privateLocation.clearSelection()
    if (publicLocation) publicLocation.clearSelection()
    Qt.callLater(function() {
      if (root.restoreEpoch !== epoch) return
      root.restoringPolicy = false
      root.policyEdited = false
      root.restorePolicy()
    })
  }
  function restorePolicy() {
    if (needsApplicationBinding) return
    if (policyEdited && loadedScopeId === scopeId) return
    var epoch = root.restoreEpoch
    loadedScopeId = scopeId
    var desired = scope ? scope.desired : null
    if (!desired || desired.state !== "assigned") return
    var pub = desired.public_target || { provider: desired.provider, location: desired.location }
    var priv = desired.private_target || pub
    var restoringScope = scopeId
    var restoringApplication = applicationDesktopId
    restoringPolicy = true
    publicProvider = pub.provider || ""
    privateProvider = priv.provider || ""
    separatePrivateProvider = pub.provider !== priv.provider || (pub.location || "") !== (priv.location || "")
    Qt.callLater(function() {
      if (root.restoreEpoch !== epoch || root.scopeId !== restoringScope
          || root.applicationDesktopId !== restoringApplication) {
        if (root.restoreEpoch === epoch) root.restoringPolicy = false
        return
      }
      if (root.policyEdited) { root.restoringPolicy = false; return }
      var p = Model.hierarchyPathFor(publicLocation.hierarchy, pub.provider + "/" + pub.location)
      var q = Model.hierarchyPathFor(privateLocation.hierarchy, priv.provider + "/" + priv.location)
      if (p) publicLocation.selection = {country:p.country, city:p.city, server:p.server}
      if (q) privateLocation.selection = {country:q.country, city:q.city, server:q.server}
      root.restoringPolicy = false
    })
  }
  onScopeChanged: restorePolicy()
  onCatalogChanged: restorePolicy()
  Component.onCompleted: restorePolicy()
  Connections {
    target: privateLocation
    function onSelectionChanged() { if (!root.restoringPolicy) root.policyEdited = true }
  }
  Connections {
    target: publicLocation
    function onSelectionChanged() { if (!root.restoringPolicy) root.policyEdited = true }
  }
  onApplicationDesktopIdChanged: {
    var epoch = ++root.restoreEpoch
    restoringPolicy = true
    pendingApplication = ""
    pendingScope = ""
    pendingPhase = ""
    routeRequestPending = false
    loadedScopeId = ""
    if (needsApplicationBinding) {
      privateProvider = ""
      publicProvider = ""
      separatePrivateProvider = false
      privateLocation.clearSelection()
      publicLocation.clearSelection()
    }
    Qt.callLater(function() {
      if (root.restoreEpoch !== epoch) return
      root.restoringPolicy = false
      root.policyEdited = false
      root.restorePolicy()
    })
  }

  function locations(providerId) {
    var all = catalog ? catalog.locations : []
    var found = []
    for (var i = 0; i < all.length; i++) if (all[i].providerId === providerId) found.push(all[i])
    return found
  }
  function wireguard(providerId) {
    var all = catalog ? catalog.connections : []
    for (var i = 0; i < all.length; i++) if (all[i].id === providerId) return all[i].kind === "wireguard"
    return false
  }
  function managedScope() {
    var instances = service && service.managedInstances ? service.managedInstances : []
    for (var i = 0; i < instances.length; i++) if (instances[i].scope === scopeId) return instances[i]
    return null
  }
  function canCreate() {
    var templates = service && service.managedTemplates ? service.managedTemplates : []
    for (var i = 0; i < templates.length; i++) if (templates[i].scope === scopeId) return true
    return false
  }
  function refreshPendingApplication() {
    if (root.pendingPhase !== "refresh") return
    if (root.applicationDesktopId !== root.pendingApplication || root.scopeId !== root.pendingScope) {
      root.pendingPhase = ""
      return
    }
    // A routine read can own the shared process between queued save stages.
    // Wait for its response; only the unsubmitted discovery read is resumed.
    if (root.service.runtimeBusy) return
    if (!root.service.runtimeRequest("running_apps", "", null, null)) {
      root.pendingPhase = ""
      root.service.applicationRoutingStatus = "Exception not saved. Refresh apps and apply again."
    }
  }
  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onRuntimeResponse(action, ok, response) {
      if (root.routeRequestPending && (action === "assign" || action === "switch")) {
        root.routeRequestPending = false
        if (!ok && root.applicationMode && root.applicationDesktopId !== "")
          root.service.applicationRoutingStatus = root.service.runtimeError || "Route not saved. Review the selected provider and try again."
      }
      if (root.pendingPhase === "policy" && (action === "assign" || action === "switch")) {
        if (!ok || !response.scope || response.scope.scope !== root.pendingScope) {
          root.pendingPhase = ""
          return
        }
        root.pendingPhase = "refresh"
        root.service.applicationRoutingStatus = "Route prepared. Refreshing this app before saving its exception…"
      } else if (root.pendingPhase === "refresh" && action === "running_apps") {
        var rows = ok ? response.running_applications : []
        var candidate = null
        var free = false
        for (var i = 0; i < rows.length; i++)
          if (rows[i].desktop_id === root.pendingApplication) candidate = rows[i]
        var slots = ok ? response.application_slots : []
        for (var j = 0; j < slots.length; j++)
          if (slots[j].scope === root.pendingScope && !slots[j].bound) free = true
        var scopeId = root.pendingScope
        if (!candidate || !candidate.assignable || !candidate.application || candidate.binding_id !== null
            || !free || root.applicationDesktopId !== root.pendingApplication) {
          root.service.applicationRoutingStatus = "Exception not saved: this app or its available slot changed. Refresh and review."
          root.pendingPhase = ""
          return
        }
        var token = candidate.application
        var revision = response.application_revision
        root.pendingPhase = "binding"
        Qt.callLater(function() {
          if (root.pendingPhase !== "binding") return
          if (root.applicationDesktopId !== root.pendingApplication || root.scopeId !== scopeId) { root.pendingPhase = ""; return }
          var currentToken = ""
          var currentRows = root.service.runningApplications
          for (var k = 0; k < currentRows.length; k++)
            if (currentRows[k].desktop_id === root.pendingApplication) currentToken = currentRows[k].application
          if (root.service.runtimeBusy || root.service.applicationRevision !== revision || currentToken !== token) {
            // A later discovery invalidates opaque tokens even if its revision
            // is unchanged. Re-read before the first binding attempt, never
            // replay an attempted/uncertain application_assign mutation.
            root.pendingPhase = "refresh"
            Qt.callLater(root.refreshPendingApplication)
            return
          }
          if (!root.service.runtimeRequest("application_assign", scopeId, token, null))
            root.service.applicationRoutingStatus = "Exception not saved. Refresh apps and apply again."
          root.pendingPhase = ""
        })
      } else if (ok && root.applicationMode && root.applicationDesktopId !== "" && !root.needsApplicationBinding
                 && (action === "assign" || action === "switch") && response.scope && response.scope.scope === root.scopeId) {
        root.service.applicationRoutingStatus = "Saved route preference. Active routing remains unverified."
      }
      if (root.pendingPhase === "refresh" && action !== "running_apps")
        Qt.callLater(root.refreshPendingApplication)
      if (!root.applicationMode && ok && action === "managed_create") {
        root.scopeId = response.managed.scope
        root.privateProvider = ""
        root.publicProvider = ""
        privateLocation.clearSelection()
        publicLocation.clearSelection()
      }
    }
  }

  PanelSectionHeader { visible: !root.applicationMode; text: "ADVANCED / MANAGED PROFILES"; foreground: root.foreground; fontFamily: root.fontFamily }
  Text {
    visible: !root.applicationMode
    width: parent.width
    textFormat: Text.PlainText
    text: "Choose a configured scope and both routes. Private destinations follow the scope's trusted rules; public traffic uses its separate selection."
    color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
  Button {
    objectName: "runtime-refresh"
    visible: !root.applicationMode
    text: "Refresh runtime scopes"
    bordered: true
    foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
    enabled: root.service && !root.service.runtimeBusy
    onClicked: root.service.listRuntimeScopes()
  }
  Text {
    width: parent.width
    textFormat: Text.PlainText
    text: root.service ? root.service.runtimeError : "Runtime supervisor unavailable."
    visible: text !== ""
    color: root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
  SearchableDropdown {
    id: scopeDrop
    visible: !root.applicationMode
    objectName: "runtime-scope"
    width: parent.width
    label: "Configured scope"
    placeholderText: "Choose a scope"
    emptyText: "No trusted scopes configured"
    foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
    options: {
      var rows = root.service ? root.service.runtimeScopes : []
      var out = []
      for (var i = 0; i < rows.length; i++) out.push({ value: rows[i].scope, label: rows[i].scope })
      return out
    }
    value: root.scopeId
    onChanged: (value) => { root.scopeId = value; root.privateProvider = ""; root.publicProvider = "";
                            privateLocation.clearSelection(); publicLocation.clearSelection() }
  }
  Text {
    width: parent.width
    visible: root.applicationMode
    textFormat: Text.PlainText
    text: root.active ? "Current Internet route: " + Model.runtimeConnectionDisplay(root.scope, root.catalog).name
      : "Choose a provider and location below."
    color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
  Text {
    width: parent.width
    visible: !root.applicationMode && root.scope !== null
    textFormat: Text.PlainText
    text: root.scope ? "Desired: " + Model.runtimeTargetSummary(root.scope.desired)
      + "\nEffective: " + Model.runtimeTargetSummary(root.scope.effective)
      + "\nGeneration: " + (root.scope.generation === null ? "unknown" : root.scope.generation)
      + " · Guarantee: " + root.scope.guarantee + " · Worker: " + root.scope.worker_health
      + "\nReadiness: " + root.scope.readiness + " · Freshness: " + root.scope.freshness
      + (root.scope.pending ? " · Pending" : "") : ""
    color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
  Text {
    objectName: "runtime-scope-telemetry"
    width: parent.width
    visible: !root.applicationMode && root.scope !== null
    textFormat: Text.PlainText
    text: Model.scopeTelemetrySummary(root.scope ? root.scope.telemetry : null)
    color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
  SearchableDropdown {
    id: publicDrop
    objectName: "runtime-public-provider"
    width: parent.width
    label: root.separatePrivateProvider ? "Public / Internet provider" : "Provider"
    placeholderText: "Choose a provider"
    emptyText: "No saved providers"
    foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
    options: Model.runtimeMainProviderOptions(root.catalog, true)
    value: root.publicProvider
    onChanged: (value) => { root.policyEdited = true; root.publicProvider = value; publicLocation.clearSelection() }
  }
  LocationPicker {
    id: publicLocation
    objectName: "runtime-public-location"
    width: parent.width
    visible: root.wireguard(root.publicProvider)
    locations: root.locations(root.publicProvider)
    showSummary: false; showAction: false
    foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
  }
  Row {
    width: parent.width
    spacing: Style.space(10)
    Text {
      width: parent.width - privateOverrideControl.implicitWidth - parent.spacing
      textFormat: Text.PlainText
      text: "Specify a different private provider"
      color: root.foreground
      font.family: root.fontFamily; font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
    ToggleSwitch {
      id: privateOverrideControl
      objectName: "runtime-private-override"
      checked: root.separatePrivateProvider
      foreground: root.foreground
      onToggled: {
        root.separatePrivateProvider = !root.separatePrivateProvider
        root.policyEdited = true
      }
    }
  }
  SearchableDropdown {
    id: privateDrop
    visible: root.separatePrivateProvider
    objectName: "runtime-private-provider"
    width: parent.width
    label: "Private provider"
    placeholderText: "Choose a saved provider"
    emptyText: "No saved providers"
    foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
    options: Model.runtimeProviderOptions(root.catalog, true)
    value: root.privateProvider
    onChanged: (value) => { root.policyEdited = true; root.privateProvider = value; privateLocation.clearSelection() }
  }
  LocationPicker {
    id: privateLocation
    objectName: "runtime-private-location"
    width: parent.width
    visible: root.separatePrivateProvider && root.wireguard(root.privateProvider)
    locations: root.locations(root.privateProvider)
    showSummary: false; showAction: false
    foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
  }
  Text {
    width: parent.width; textFormat: Text.PlainText; wrapMode: Text.WordWrap
    text: "Tailscale and Headscale can be private overrides; Internet exit is not configured here."
    color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
  }
  Text {
    width: parent.width; textFormat: Text.PlainText; wrapMode: Text.WordWrap
    visible: root.privatePolicyMissing
    text: "Add private networks or domain suffixes in Settings → Connections → Edit provider → Private network preset, then select that private provider here."
    color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
  }
  Row {
    spacing: Style.space(8)
    Button {
      objectName: "runtime-apply"
      text: root.routeRequestPending || root.applicationPending ? "Saving…"
        : root.applicationMode ? (root.applicationDesktopId === "" ? "Change connection" : "Save connection") : (root.active ? "Switch routes · new connections" : "Apply routes")
      bordered: true
      foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
      enabled: root.ready && !root.applicationPending && !root.privatePolicyMissing && root.privateTarget !== null && root.publicTarget !== null && !root.scope.pending
      onClicked: {
        root.pendingApplication = root.needsApplicationBinding ? root.applicationDesktopId : ""
        root.pendingScope = root.scopeId
        root.pendingPhase = root.needsApplicationBinding ? "policy" : ""
        var explicitPolicy = root.privatePolicyDraft
        if (!explicitPolicy && root.privateTarget && root.publicTarget
            && root.privateTarget.provider === "direct" && root.publicTarget.provider !== "direct")
          explicitPolicy = root.scope ? root.scope.scope_policy : null
        root.routeRequestPending = root.service.runtimeRequest(root.active ? "switch" : "assign", root.scopeId,
                                         root.privateTarget, root.publicTarget, explicitPolicy)
        if (root.applicationMode && root.applicationDesktopId !== "")
          root.service.applicationRoutingStatus = root.routeRequestPending
            ? "Preparing and checking this app's route…" : root.service.runtimeError
        if (!root.routeRequestPending) { root.pendingApplication = ""; root.pendingPhase = "" }
      }
    }
    Button {
      objectName: "runtime-block"
      visible: !root.applicationMode
      text: "Block selected routes"
      bordered: true
      foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
      enabled: root.ready && !root.applicationPending && !root.scope.pending
      onClicked: root.service.runtimeRequest("block", root.scopeId, null, null)
    }
  }
  Column {
    visible: !root.applicationMode
    width: parent.width
    spacing: root.spacing
  PanelSectionHeader { text: "MANAGED BROWSER"; foreground: root.foreground; fontFamily: root.fontFamily }
  Button {
    objectName: "managed-discover"
    text: "Discover supported browsers"
    bordered: true
    foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
    enabled: root.service && !root.service.runtimeBusy
    onClicked: root.service.runtimeRequest("managed_apps", "", null, null)
  }
  SearchableDropdown {
    id: appDrop
    objectName: "managed-application"
    width: parent.width
    label: "New managed browser"
    placeholderText: "Choose an installed browser"
    emptyText: "Discover installed Firefox, Chromium or Brave"
    foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
    options: {
      var apps = root.service && root.service.managedApplications ? root.service.managedApplications : []
      var out = []
      for (var i = 0; i < apps.length; i++) out.push({ value: apps[i].id, label: apps[i].label })
      return out
    }
    value: root.managedApplication
    onChanged: (value) => root.managedApplication = value
  }
  Row {
    spacing: Style.space(8)
    Button {
      objectName: "managed-create"
      text: "Create separate profile"
      bordered: true
      foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
      enabled: root.ready && root.canCreate() && root.managedApplication !== ""
      onClicked: root.service.runtimeRequest("managed_create", root.scopeId, root.managedApplication, null)
    }
    Button {
      objectName: "managed-launch"
      text: "Launch managed browser"
      bordered: true
      foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
      enabled: root.ready && root.managedScope() !== null
        && root.managedScope().state !== "running" && root.scope.effective.state === "assigned"
      onClicked: root.service.runtimeRequest("managed_launch", root.scopeId, null, null)
    }
  }
  Text {
    width: parent.width
    textFormat: Text.PlainText
    text: root.managedScope() ? root.managedScope().application + " · " + root.managedScope().state : ""
    visible: text !== ""
    color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
  Text {
    width: parent.width
    textFormat: Text.PlainText
    text: "Choose a trusted template before creating a profile. Then select both routes, apply them, and launch. Existing browsers are untouched. The Applications section handles executable-wide routing separately; host capture remains gated."
    color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
  }
}
