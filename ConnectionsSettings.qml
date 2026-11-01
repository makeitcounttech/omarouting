import QtQuick
import QtQuick.Dialogs
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Settings → Connections. Saved connection providers (WireGuard imports,
// Tailscale/Headscale, proxies) with add/edit/remove — driven entirely
// through the connections IPC contract (docs/connections-ipc-contract.md) via
// the unprivileged client. Nothing here activates a route, changes the
// default connection, reassigns applications, or arms the kill switch:
// saving and importing are persistence only, and every unavailable
// capability renders disabled with the reason — never as mocked success.
Column {
  id: root

  // Panel chrome, injected by the embedding panel.
  property var service: null
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property color urgent: Color.urgent
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property color hoverFill: Style.hoverFillFor(foreground, accent)

  // True while any dropdown in this section owns the keyboard.
  readonly property bool popupOpen: kindDrop.popupOpen || policyDrop.popupOpen
    || protocolDrop.popupOpen

  readonly property bool backendReady: service !== null && service.connectionsState === "ready"
  // Busy covers the whole in-flight window, including a paged listing
  // assembled from several client runs. Falls back to the request-id check
  // for test doubles that do not model connectionsBusy.
  readonly property bool backendBusy: service !== null
    && (service.connectionsBusy === true || service.connectionsRequestId !== "")
  // Mutations need the authoritative CAS revision: until a listing has
  // landed one, saving/importing/removing is disabled — an unknown token
  // never masquerades as a valid zero.
  readonly property bool canMutate: service !== null
    && service.connectionsRevisionKnown !== false
  readonly property var catalog: service ? service.connectionsCatalog : null
  readonly property var capabilities: catalog ? catalog.capabilities : null
  readonly property var saved: catalog ? catalog.connections : []
  // Honesty about what the list IS: a paged listing that is not complete,
  // or a catalog that hit a parse cap, is announced — never drawn as whole.
  readonly property bool listingIncomplete: catalog !== null
    && (catalog.complete === false || catalog.connectionsTruncated === true
        || catalog.locationsTruncated === true)

  // ---- form state ---------------------------------------------------------
  property bool addOpen: false
  property string addKind: "wireguard"
  property string editingId: ""

  // WireGuard import flow.
  property string wgFilePath: ""
  property string wgFileName: ""
  property string wgLabel: ""
  property var wgPreview: null
  property string wgPolicy: "skip"
  property string wgError: ""

  // Tailscale / Headscale / Proxy forms.
  property string tsLabel: ""
  property string tsMode: "enroll"
  property string tsUrl: "https://controlplane.tailscale.com"
  property string tsKey: ""
  property string tsKeyPath: ""
  property string keyFileKind: ""
  property string keyFileEditingId: ""
  // Preserve legacy identity on read; never convert a host-backed record
  // into an embedded identity while editing its label or credentials.
  property string tsStoredMode: ""
  property bool tsClearKey: false
  property string hsLabel: ""
  property string hsUrl: ""
  property string hsKey: ""
  property string hsKeyPath: ""
  property bool hsClearKey: false
  property string hsControlIp: ""
  property string hsPrivateHosts: ""
  property string hsCaPath: ""
  property bool hsCaSet: false
  property bool hsClearCa: false
  property string pxLabel: ""
  property string pxProtocol: "socks5"
  property string pxHost: ""
  property string pxPort: ""
  property string pxUser: ""
  property string pxPassword: ""
  property bool pxClearCredentials: false
  property string saveError: ""
  property string privateCidrs: ""
  property string privateDomains: ""
  property string privateDns: ""
  // A revision conflict refused a mutation: the list refreshes, the edit
  // stays open, and nothing is retried automatically.
  property string conflictNotice: ""
  property string pendingSaveKind: ""

  // Saved-list state.
  property int savedLimit: 6
  property string removeError: ""
  property string removeConfirmId: ""

  function localPath(url) {
    var v = String(url || "")
    if (v.indexOf("file://") === 0) v = decodeURIComponent(v.substring(7))
    return v
  }

  function baseName(path) {
    var v = String(path || "").replace(/\\/g, "/")
    return v.substring(v.lastIndexOf("/") + 1)
  }

  function resetForms() {
    addOpen = false
    editingId = ""
    wgFilePath = ""; wgFileName = ""; wgLabel = ""; wgPreview = null; wgError = ""
    wgPolicy = "skip"
    tsLabel = ""; tsMode = "enroll"; tsUrl = "https://controlplane.tailscale.com"; tsKey = ""
    tsKeyPath = ""; keyFileKind = ""; keyFileEditingId = ""
    tsStoredMode = ""; tsClearKey = false
    hsLabel = ""; hsUrl = ""; hsKey = ""; hsKeyPath = ""
    hsControlIp = ""; hsPrivateHosts = ""; hsCaPath = ""; hsCaSet = false; hsClearCa = false
    hsClearKey = false
    pxLabel = ""; pxProtocol = "socks5"; pxHost = ""; pxPort = ""; pxUser = ""; pxPassword = ""
    pxClearCredentials = false
    saveError = ""; conflictNotice = ""; pendingSaveKind = ""
    privateCidrs = ""; privateDomains = ""; privateDns = ""
    removeError = ""; removeConfirmId = ""
  }

  function openAdd() {
    resetForms()
    addOpen = true
  }

  function startEdit(entry) {
    resetForms()
    addOpen = true
    editingId = String(entry.id)
    addKind = String(entry.kind)
    var preset = entry.private_policy
    if (preset) {
      privateCidrs = preset.private_cidrs.join(", ")
      privateDomains = preset.private_domains.join(", ")
      privateDns = preset.private_dns.join(", ")
    }
    // `entry.settings` comes from Model.parseConnectionsCatalog, which
    // normalizes the backend's nonsecret projection to the form's field
    // names (proxy server→host, control_url→url). Secrets never appear in
    // the projection, so nothing here can echo one.
    if (entry.kind === "proxy") {
      pxLabel = String(entry.label)
      var s = entry.settings || {}
      pxProtocol = Model.safeText(s.protocol, 8) || "socks5"
      pxHost = Model.safeText(s.host, 253)
      pxPort = s.port > 0 ? String(s.port) : ""
    } else if (entry.kind === "headscale") {
      hsLabel = String(entry.label)
      hsUrl = Model.safeText(entry.settings && entry.settings.url, 253)
      hsControlIp = Model.safeText(entry.settings && entry.settings.control_ip, 64)
      hsCaSet = !!(entry.settings && entry.settings.ca_certificate_set)
      var hosts = entry.settings && entry.settings.private_hosts || {}
      hsPrivateHosts = Object.keys(hosts).sort().map(function (name) { return name + "=" + hosts[name] }).join(", ")
    } else if (entry.kind === "tailscale") {
      tsLabel = String(entry.label)
      tsUrl = Model.safeText(entry.settings && entry.settings.url, 253)
      var mode = entry.settings && entry.settings.mode ? String(entry.settings.mode) : ""
      // The stored mode is what the record was saved with; a mode the
      // backend did not project falls back to "enroll" — the backend's own
      // default for mode-absent records (never "reuse" by assumption).
      tsMode = mode === "reuse" ? "reuse" : "enroll"
      tsStoredMode = tsMode
    } else {
      // WireGuard: the imported configuration is immutable (the backend
      // manages its locations by import only). Editing means renaming the
      // display label on the same immutable id — never a silent reimport.
      wgLabel = String(entry.label)
    }
    // Secrets are never echoed into the form; absent credentials keep the
    // stored ones (the backend contract), so saving without retyping them
    // changes nothing secret-bearing.
  }

  // ---- actions (all through the connections client, nothing else) ---------

  function request(action, payload, revision) {
    if (!service) return false
    if (action === "save" && payload.kind !== "wireguard") {
      var preset = Model.privatePolicyFromText(privateCidrs, privateDomains, privateDns)
      if (!preset) { saveError = "Use at most 32 entries per private preset field, with no entry longer than 253 characters."; return false }
      payload.settings = payload.settings || {}
      payload.settings.private_policy = preset
    }
    return service.connectionsRequest(action, payload || {}, revision)
  }

  function refreshList() {
    request("list")
  }

  function chooseWgFile() {
    wgFileDialog.open()
  }

  function chooseTsKeyFile() {
    if (tsMode !== "enroll" || backendBusy) return
    keyFileKind = "tailscale"
    keyFileEditingId = editingId
    keyFileDialog.open()
  }

  function tsKeyFileSelected(url) {
    var path = localPath(url)
    if (path === "" || addKind !== "tailscale" || tsMode !== "enroll") return
    tsKey = ""
    tsKeyPath = path
    tsClearKey = false
  }

  function wgFileSelected(url) {
    if (String(url) === "") return   // cancellation: no change
    wgFilePath = localPath(url)
    wgFileName = baseName(wgFilePath)
    wgPreview = null
    wgError = ""
  }

  function requestPreview() {
    if (!backendReady || wgFilePath === "") return
    wgError = ""
    request("preview_wireguard", { path: wgFilePath, label: wgLabel, filename: wgFileName })
  }

  function requestImport() {
    if (!backendReady) return
    if (!canMutate) { wgError = "The authoritative connection list has not loaded yet — refresh first."; return }
    if (wgPreview === null) return
    var digest = wgPreview && wgPreview.digest ? String(wgPreview.digest) : ""
    request("import_wireguard", {
              path: wgFilePath, label: wgLabel, filename: wgFileName,
              digest: digest, duplicate_policy: wgPolicy
            }, service.connectionsRevision)
  }

  function readonlyHeadscale() {
    return Model.validateHeadscaleUrl(hsUrl)
  }

  // Same URL grammar, applied to whichever control-server field is in play.
  function readonlyHeadscaleUrl(value) {
    return Model.validateHeadscaleUrl(value)
  }

  function proxyError() {
    return Model.validateProxySettings(pxProtocol, pxHost, pxPort)
  }

  function requestSave() {
    if (!backendReady) return
    if (!canMutate) { saveError = "The authoritative connection list has not loaded yet — refresh first."; return }
    saveError = ""
    if (addKind === "wireguard") {
      // A WireGuard provider is created only by the preview → import
      // transaction. Editing an existing one is a label rename on the same
      // immutable id — the backend refuses settings/credentials here, and
      // this form never sends them. No settings key fakes a reimport.
      if (editingId === "") { saveError = "WireGuard connections are added by importing a file."; return }
      if (wgLabel.trim() === "") { saveError = "a display label is required"; return }
      pendingSaveKind = "wireguard"
      request("save", { id: editingId, kind: "wireguard", label: wgLabel },
              service.connectionsRevision)
    } else if (addKind === "proxy") {
      var problem = proxyError()
      if (problem !== "") { saveError = problem; return }
      pendingSaveKind = "proxy"
      // The backend's proxy settings are protocol/server/port; `host` is
      // the form's name for the same endpoint. Only form-owned fields are
      // sent: absent unexposed settings (detours, route options) are
      // retained server-side — omission never means clearing.
      var payload = { label: pxLabel, kind: "proxy",
                     settings: { protocol: pxProtocol, server: pxHost, port: parseInt(pxPort, 10) } }
      var credentials = {}
      if (pxUser !== "") credentials.username = pxUser
      if (pxPassword !== "") credentials.password = pxPassword
      if (Object.keys(credentials).length > 0) {
        payload.credentials = credentials
      } else if (editingId !== "" && pxClearCredentials) {
        // Explicit clearing: a proxy username requires its password, so
        // both go together. Never a masked placeholder — an empty field
        // with the clear box ticked is the deliberate operation.
        payload.credentials = { clear: ["username", "password"] }
      }
      if (editingId !== "") payload.id = editingId
      request("save", payload, service.connectionsRevision)
    } else if (addKind === "headscale") {
      var url = readonlyHeadscale()
      if (!url.ok) { saveError = url.error; return }
      pendingSaveKind = "headscale"
      // The backend's setting is control_url; `url` is the form's name.
      var payload2 = { label: hsLabel, kind: "headscale", settings: { control_url: url.url } }
      var hosts2 = Model.privateHostsFromText(hsPrivateHosts)
      if (hosts2 === null) { saveError = "Use up to 32 unique hostname=IP pairs, separated by commas."; return }
      payload2.settings.control_ip = hsControlIp.trim() || null
      payload2.settings.private_hosts = hosts2
      if (root.hsKey !== "") payload2.credentials = { authKey: root.hsKey }
      else if (root.hsKeyPath !== "") payload2.credentials = { keyFile: root.hsKeyPath }
      else if (editingId !== "" && hsClearKey) payload2.credentials = { clear: ["authKey"] }
      if (hsCaPath !== "" || hsClearCa) {
        payload2.credentials = payload2.credentials || {}
        if (hsCaPath !== "") payload2.credentials.caCertificateFile = hsCaPath
        else { payload2.credentials.clear = payload2.credentials.clear || []; payload2.credentials.clear.push("caCertificate") }
      }
      if (editingId !== "") payload2.id = editingId
      request("save", payload2, service.connectionsRevision)
    } else if (addKind === "tailscale") {
      if (tsMode !== "enroll" || (editingId !== "" && tsStoredMode === "reuse")) {
        saveError = "Host-dependent Tailscale is retired. Use Add connection for embedded Tailscale, then remove the unused legacy connection. Its identity was not changed."
        return
      }
      var ts = readonlyHeadscaleUrl(tsUrl)
      if (!ts.ok) { saveError = ts.error; return }
      pendingSaveKind = "tailscale"
      var payload3 = { label: tsLabel, kind: "tailscale", settings: { mode: "enroll", control_url: ts.url } }
      if (editingId !== "") payload3.id = editingId
      var credentials3 = null
      if (tsMode === "enroll" && tsKey !== "") {
        credentials3 = { authKey: tsKey }
      } else if (tsMode === "enroll" && tsKeyPath !== "") {
        credentials3 = { keyFile: tsKeyPath }
      } else if (tsMode === "enroll" && editingId !== "" && tsClearKey) {
        credentials3 = { clear: ["authKey"] }
      }
      // An empty edit retains the saved key. Reuse never receives a key.
      // The key travels only through the existing private stdin request.
      if (credentials3 !== null) payload3.credentials = credentials3
      request("save", payload3, service.connectionsRevision)
    }
    // WireGuard creation is saved through the preview → import transaction only.
  }

  function requestRemove(id) {
    if (!backendReady) return
    if (!canMutate) { removeError = "The authoritative connection list has not loaded yet — refresh first."; return }
    removeError = ""
    request("remove", { id: id }, service.connectionsRevision)
  }

  Connections {
    target: root.service
    function onConnectionsResponse(action, ok, response) {
      if (!response) return
      // Only MUTATIONS trigger the follow-up refresh: a list response
      // refreshing the list again would loop forever (each cycle spawns
      // the client), and a preview changes nothing to refresh.
      var refreshAfter = action === "import_wireguard" || action === "save" || action === "remove"
      if (action === "preview_wireguard") {
        if (ok) root.wgPreview = response.data
        else root.wgError = response.error !== "" ? response.error : "preview failed"
      } else if (action === "import_wireguard") {
        if (ok) {
          root.wgFilePath = ""; root.wgFileName = ""; root.wgPreview = null
          root.addOpen = false
        } else {
          root.wgError = response.error !== "" ? response.error : "import failed"
        }
      } else if (action === "save") {
        if (ok) {
          var kind = root.pendingSaveKind
          root.resetForms()
          if (kind === "proxy") root.pxLabel = ""
        } else if (response.errorCode === "revision-conflict") {
          // The store moved under the edit: nothing was mutated and
          // nothing is retried. The edit form stays exactly as it was;
          // the refreshed list (below) carries the authoritative state.
          root.conflictNotice
              = "The connection list changed while you were editing. " +
                "Nothing was saved or retried — the list below is reloaded; review and save again."
          root.saveError = ""
        } else {
          root.saveError = response.error !== "" ? response.error : "saving failed"
        }
      } else if (action === "remove") {
        if (ok) {
          root.removeConfirmId = ""
        } else if (response.errorCode === "revision-conflict") {
          root.conflictNotice
              = "The connection list changed while removing. Nothing was removed or retried — the list below is reloaded."
          root.removeError = ""
        } else {
          root.removeError = response.error !== "" ? response.error : "removing failed"
        }
      }
      if (refreshAfter) root.refreshList()
    }
  }

  FileDialog {
    // Local workaround: avoid GTK/GVfs native chooser aborts on this host.
    options: FileDialog.DontUseNativeDialog
    id: wgFileDialog
    nameFilters: ["WireGuard configs and archives (*.conf *.zip)"]
    onAccepted: root.wgFileSelected(selectedFile)
    onRejected: root.wgFileSelected("")
  }

  FileDialog {
    // Local workaround: avoid GTK/GVfs native chooser aborts on this host.
    options: FileDialog.DontUseNativeDialog
    id: keyFileDialog
    nameFilters: ["All files (*)"]
    onAccepted: {
      // The key file is read by the client at save time, never by QML:
      // only the chosen path is remembered here.
      if (root.editingId !== root.keyFileEditingId) return
      if (root.keyFileKind === "tailscale") root.tsKeyFileSelected(selectedFile)
      else if (root.keyFileKind === "headscale") root.hsKeyPath = root.localPath(selectedFile)
      else if (root.keyFileKind === "headscale-ca") { root.hsCaPath = root.localPath(selectedFile); root.hsClearCa = false }
    }
    onRejected: { }   // cancellation: no change
  }

  spacing: Style.space(10)
  width: 1

  // ---- availability -------------------------------------------------------
  Text {
    textFormat: Text.PlainText
    visible: !root.backendReady
    width: parent.width
    text: {
      if (root.service && root.service.connectionsError !== "")
        return "Connections backend unavailable — " + root.service.connectionsError
      return "Connections backend unavailable — the root helper (/usr/local/bin/singbox-connections) is not installed or not authorized yet."
    }
    color: root.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Row {
    width: parent.width
    spacing: Style.space(6)

    Button {
      id: addButton
    objectName: "settings-add"
      text: "Add connection"
      bordered: true
      enabled: root.backendReady && !root.backendBusy
      opacity: enabled ? 1.0 : 0.4
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      onClicked: root.openAdd()
    }

    Button {
      text: "Refresh"
      bordered: true
      enabled: root.backendReady && !root.backendBusy
      opacity: enabled ? 1.0 : 0.4
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      onClicked: root.refreshList()
    }
  }

  // ---- saved connections (bounded) ----------------------------------------
  Column {
    width: parent.width
    spacing: Style.space(4)

    Text {
      textFormat: Text.PlainText
      visible: root.listingIncomplete
      width: parent.width
      text: "This listing is NOT complete — it arrived paged or over an internal bound. What is missing is not shown anywhere; refresh to fetch it whole."
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      visible: root.conflictNotice !== ""
      width: parent.width
      text: root.conflictNotice
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      visible: root.backendReady && root.saved.length === 0
      width: parent.width
      text: "No saved connections yet."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: root.saved.length > root.savedLimit
             ? root.saved.slice(0, root.savedLimit) : root.saved
      delegate: Column {
        required property var modelData
        width: parent.width
        spacing: Style.space(2)

        CursorSurface {
          width: parent.width
          implicitHeight: savedInner.implicitHeight + Style.spacing.xl
          foreground: root.foreground
          fill: root.hoverFill

          Row {
            id: savedInner
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            spacing: Style.space(8)

            Column {
              width: parent.width - actionsRow.implicitWidth - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: modelData ? String(modelData.label) : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: modelData ? Model.connectionStatusText(modelData) : ""
                color: modelData && modelData.active ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Row {
              id: actionsRow
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Button {
                text: "Edit"
                bordered: true
                enabled: root.backendReady && !root.backendBusy && modelData !== null
                opacity: enabled ? 1.0 : 0.4
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: if (modelData) root.startEdit(modelData)
              }

              Button {
                text: root.removeConfirmId === String(modelData ? modelData.id : "") ? "Confirm remove" : "Remove"
                bordered: true
                enabled: root.canMutate && root.backendReady && !root.backendBusy && modelData !== null
                opacity: enabled ? 1.0 : 0.4
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: {
                  if (!modelData) return
                  if (root.removeConfirmId === String(modelData.id)) {
                    root.requestRemove(String(modelData.id))
                    root.removeConfirmId = ""
                  } else {
                    root.removeConfirmId = String(modelData.id)
                    root.removeError = ""
                  }
                }
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.removeConfirmId === String(modelData ? modelData.id : "")
          width: parent.width
          text: "Removing this connection will not silently move anything: if it is in use, the backend names the affected assignments and refuses until they are reassigned."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }

    CursorSurface {
      visible: root.saved.length > root.savedLimit
      width: parent.width
      implicitHeight: moreSaved.implicitHeight + Style.spacing.xl
      foreground: root.foreground
      fill: root.hoverFill

      Text {
        id: moreSaved
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: "Show more (" + (root.saved.length - root.savedLimit) + " more)"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.savedLimit = root.savedLimit + 6
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: root.removeError !== ""
      width: parent.width
      text: root.removeError
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  // ---- add / edit form ----------------------------------------------------
  Column {
    visible: root.addOpen
    width: parent.width
    spacing: Style.space(8)

    PanelSeparator { foreground: root.foreground }

    Dropdown {
      id: kindDrop
      objectName: "settings-kind"
      width: parent.width
      label: "Connection type"
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      enabled: root.editingId === "" && !root.backendBusy
      options: [
        { value: "wireguard", label: "WireGuard (import .conf / .zip)" },
        { value: "tailscale", label: "Tailscale" },
        { value: "headscale", label: "Headscale" },
        { value: "proxy", label: "Proxy (SOCKS5 / HTTP / HTTPS)" }
      ]
      value: root.addKind
      onChanged: (value) => { root.addKind = value; root.saveError = "" }
    }

    // ---- WireGuard --------------------------------------------------------
    // Two honest modes: editing an existing provider renames the display
    // label on its immutable id; adding a provider is the preview → import
    // transaction. The import flow is never presented as "editing".
    Column {
      visible: root.addKind === "wireguard"
      width: parent.width
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        visible: root.editingId !== ""
        width: parent.width
        text: "Editing the saved connection " + root.editingId + " — the imported configuration itself is immutable. Renaming changes only the display label; to connect different servers, import the new file as its own connection."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      TextField {
        width: parent.width
        placeholderText: "Display label (e.g. Mullvad)"
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        text: root.wgLabel
        onTextChanged: if (root.wgLabel !== text) root.wgLabel = text
      }

      Row {
        visible: root.editingId === ""
        width: parent.width
        spacing: Style.space(6)

        Button {
          text: "Browse…"
          bordered: true
          enabled: root.backendReady && !root.backendBusy
          opacity: enabled ? 1.0 : 0.4
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.chooseWgFile()
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width - Style.space(90)
          anchors.verticalCenter: parent.verticalCenter
          text: root.wgFileName !== "" ? root.wgFileName : "No file chosen (.conf or .zip)"
          color: root.wgFileName !== "" ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.editingId === ""
        width: parent.width
        text: "The file is read under your own account and sent to the root helper over local IPC. Key fields never appear in previews, logs or this panel."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Dropdown {
        id: policyDrop
        objectName: "settings-wg-policy"
        visible: root.editingId === ""
        width: parent.width
        label: "Duplicate entries"
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        options: [
          { value: "skip", label: "Skip duplicates" },
          { value: "replace", label: "Replace duplicates" }
        ]
        value: root.wgPolicy
        onChanged: (value) => { root.wgPolicy = value }
      }

      Row {
        visible: root.editingId === ""
        width: parent.width
        spacing: Style.space(6)

        Button {
          text: "Preview"
          bordered: true
          enabled: root.backendReady && !root.backendBusy && root.wgFilePath !== ""
          opacity: enabled ? 1.0 : 0.4
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.requestPreview()
        }

        Button {
          text: "Import"
          bordered: true
          enabled: root.canMutate && root.backendReady && !root.backendBusy && root.wgPreview !== null
          opacity: enabled ? 1.0 : 0.4
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.requestImport()
        }

        Button {
          text: "Cancel"
          bordered: true
          enabled: !root.backendBusy
          opacity: enabled ? 1.0 : 0.4
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.resetForms()
        }
      }

      Row {
        visible: root.editingId !== ""
        width: parent.width
        spacing: Style.space(6)

        Button {
          id: wgSaveButton
          objectName: "settings-wg-save"
          text: "Save changes"
          bordered: true
          enabled: root.canMutate && root.backendReady && !root.backendBusy && root.wgLabel.trim() !== ""
          opacity: enabled ? 1.0 : 0.4
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.requestSave()
        }

        Button {
          text: "Cancel"
          bordered: true
          enabled: !root.backendBusy
          opacity: enabled ? 1.0 : 0.4
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.resetForms()
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.editingId === "" && root.wgPreview !== null
        width: parent.width
        text: root.wgPreview !== null ? Model.wireguardPreviewSummary(root.wgPreview) : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Text {
        textFormat: Text.PlainText
        visible: root.editingId === "" && root.wgPreview === null && root.wgFilePath !== "" && !root.backendBusy
        width: parent.width
        text: "Preview before import — nothing is written until you confirm."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    // ---- Tailscale ----------------------------------------------------------
    Column {
      visible: root.addKind === "tailscale"
      width: parent.width
      spacing: Style.space(8)

      TextField {
        width: parent.width
        placeholderText: "Display label (e.g. Tailscale)"
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        text: root.tsLabel
        onTextChanged: if (root.tsLabel !== text) root.tsLabel = text
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: root.tsMode === "reuse"
          ? "Legacy host-dependent connection: no longer offered for routing. Remove it after its application rules have been moved. It will not be converted or enrolled automatically."
          : "Tailscale runs inside sing-box with its own identity and state. No installed Tailscale app is required."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      TextField {
        id: tsUrlField
        objectName: "settings-ts-url"
        visible: root.tsMode === "enroll"
        width: parent.width
        placeholderText: "Control server URL (https://…)"
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        text: root.tsUrl
        onTextChanged: if (root.tsUrl !== text) root.tsUrl = text
      }

      Text {
        textFormat: Text.PlainText
        visible: root.tsMode === "enroll"
        width: parent.width
        text: {
          var url = root.readonlyHeadscaleUrl(root.tsUrl)
          if (root.tsUrl === "") return "The backend saves a Tailscale connection only with an explicit control-server URL."
          if (url.ok) return "Enrollment credentials would be sent to: " + url.host
          return url.error
        }
        color: root.readonlyHeadscaleUrl(root.tsUrl).ok ? root.dim : root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Text {
        textFormat: Text.PlainText
        visible: root.tsMode === "enroll"
        width: parent.width
        text: "Save stores this connection and its key; it does not connect or verify access. Selecting it for an application starts the independent endpoint. A new identity needs an auth key: browser login is not exposed here. Private access still depends on enrollment and tailnet permissions."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      TextField {
        objectName: "settings-ts-auth-key"
        visible: root.tsMode === "enroll"
        width: parent.width
        placeholderText: root.tsKeyPath !== "" ? "Key file: " + root.baseName(root.tsKeyPath)
          : root.editingId !== "" ? "New auth key (blank keeps saved key)" : "Tailscale auth key (hidden)"
        password: true
        foreground: root.foreground; accent: root.accent; font.family: root.fontFamily
        text: root.tsKey
        onTextChanged: if (root.tsKey !== text) { root.tsKey = text; root.tsKeyPath = ""; if (text !== "") root.tsClearKey = false }
      }
      Button {
        objectName: "settings-ts-browse-key"
        visible: root.tsMode === "enroll"
        text: "Browse auth-key file…"
        bordered: true
        enabled: root.backendReady && !root.backendBusy
        foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
        onClicked: root.chooseTsKeyFile()
      }
      Text {
        visible: root.tsMode === "enroll"
        width: parent.width; textFormat: Text.PlainText; wrapMode: Text.WordWrap
        text: "Choose a plain-text auth-key file or paste a key. File contents are read only when you Save, not displayed here."
        color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
      }
      Toggle {
        objectName: "settings-ts-clear-key"
        visible: root.tsMode === "enroll" && root.editingId !== ""
        width: parent.width
        label: "Clear the saved auth key"
        description: "Removes only the stored enrollment key, not the existing device registration. A new key entered above replaces it instead."
        checked: root.tsClearKey
        foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
        onClicked: {
          root.tsClearKey = !root.tsClearKey
          if (root.tsClearKey) { root.tsKey = ""; root.tsKeyPath = "" }
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        Button {
          objectName: "settings-ts-save"
          text: root.editingId !== "" ? "Save changes" : "Save"
          bordered: true
          enabled: root.canMutate && root.backendReady && !root.backendBusy && root.tsLabel.trim() !== ""
            && root.tsMode === "enroll" && root.tsStoredMode !== "reuse"
          opacity: enabled ? 1.0 : 0.4
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.requestSave()
        }

        Button {
          text: "Cancel"
          bordered: true
          enabled: !root.backendBusy
          opacity: enabled ? 1.0 : 0.4
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.resetForms()
        }
      }
    }

    // ---- Headscale ----------------------------------------------------------
    Column {
      visible: root.addKind === "headscale"
      width: parent.width
      spacing: Style.space(8)

      TextField {
        width: parent.width
        placeholderText: "Display label (e.g. Self-hosted net)"
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        text: root.hsLabel
        onTextChanged: if (root.hsLabel !== text) root.hsLabel = text
      }

      TextField {
        width: parent.width
        placeholderText: "Control server URL (https://…)"
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        text: root.hsUrl
        onTextChanged: if (root.hsUrl !== text) root.hsUrl = text
      }

      TextField {
        width: parent.width
        placeholderText: "Optional control IP (keeps hostname and TLS verification)"
        foreground: root.foreground; accent: root.accent; font.family: root.fontFamily
        text: root.hsControlIp
        onTextChanged: root.hsControlIp = text
      }
      TextField {
        width: parent.width
        placeholderText: "Private hosts: service.example.com=192.0.2.10, other.example.com=198.51.100.11"
        foreground: root.foreground; accent: root.accent; font.family: root.fontFamily
        text: root.hsPrivateHosts
        onTextChanged: root.hsPrivateHosts = text
      }
      Row {
        spacing: Style.space(6)
        Button {
          text: root.hsCaPath !== "" ? "CA: " + root.baseName(root.hsCaPath) : root.hsCaSet ? "Replace saved CA…" : "Choose CA certificate…"
          bordered: true; enabled: root.backendReady && !root.backendBusy
          foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
          onClicked: { root.keyFileKind = "headscale-ca"; root.keyFileEditingId = root.editingId; keyFileDialog.open() }
        }
        Button {
          text: "Clear CA"
          bordered: true; enabled: root.backendReady && !root.backendBusy
          foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
          onClicked: { root.hsCaPath = ""; root.hsClearCa = true; root.hsCaSet = false }
        }
      }
      Text {
        width: parent.width; textFormat: Text.PlainText; wrapMode: Text.WordWrap
        color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
        text: "CA is private to this provider worker, not installed into system or browser trust. Empty fields clear mappings; an unchanged CA is retained."
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: {
          var url = root.readonlyHeadscale()
          if (url.ok) return "Enrollment credentials would be sent to: " + url.host
          return url.error
        }
        color: root.readonlyHeadscale().ok ? root.dim : root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      TextField {
        width: parent.width
        placeholderText: root.hsKeyPath !== "" ? "Key file: " + root.baseName(root.hsKeyPath) : "Enrollment key (hidden)"
        password: true
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        text: root.hsKey
        onTextChanged: if (root.hsKey !== text) { root.hsKey = text; root.hsKeyPath = "" }
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        Button {
          text: "Browse key file…"
          bordered: true
          enabled: root.backendReady && !root.backendBusy
          opacity: enabled ? 1.0 : 0.4
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: { root.keyFileKind = "headscale"; root.keyFileEditingId = root.editingId; keyFileDialog.open() }
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "Only device enrollment keys are accepted here. A server administrative API key is not an enrollment key and is rejected by the backend."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Text {
        textFormat: Text.PlainText
        visible: !(root.capabilities && root.capabilities.headscaleEnroll)
        width: parent.width
        text: "Interactive enrollment is not available from the backend runtime yet — the connection can be saved with a key, but not enrolled, until then."
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Toggle {
        visible: root.editingId !== ""
        width: parent.width
        label: "Clear the saved enrollment key"
        description: "Removing the stored key from this connection. A new key typed or chosen above is saved instead."
        checked: root.hsClearKey
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onClicked: root.hsClearKey = !root.hsClearKey
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        Button {
          text: root.editingId !== "" ? "Save changes" : "Save"
          bordered: true
          enabled: root.canMutate && root.backendReady && !root.backendBusy && root.hsLabel.trim() !== ""
          opacity: enabled ? 1.0 : 0.4
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.requestSave()
        }

        Button {
          text: "Cancel"
          bordered: true
          enabled: !root.backendBusy
          opacity: enabled ? 1.0 : 0.4
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.resetForms()
        }
      }
    }

    // ---- Proxy --------------------------------------------------------------
    Column {
      visible: root.addKind === "proxy"
      width: parent.width
      spacing: Style.space(8)

      TextField {
        width: parent.width
        placeholderText: "Display label (e.g. Work proxy)"
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        text: root.pxLabel
        onTextChanged: if (root.pxLabel !== text) root.pxLabel = text
      }

      Dropdown {
        id: protocolDrop
        objectName: "settings-px-protocol"
        width: parent.width
        label: "Protocol"
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        options: [
          { value: "socks5", label: "SOCKS5" },
          { value: "http", label: "HTTP" },
          { value: "https", label: "HTTPS (TLS verification stays on)" }
        ]
        value: root.pxProtocol
        onChanged: (value) => { root.pxProtocol = value }
      }

      TextField {
        objectName: "settings-px-host"
        width: parent.width
        placeholderText: "Hostname or address"
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        text: root.pxHost
        onTextChanged: if (root.pxHost !== text) root.pxHost = text
      }

      TextField {
        objectName: "settings-px-port"
        width: parent.width
        placeholderText: "Port (1–65535)"
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        text: root.pxPort
        onTextChanged: if (root.pxPort !== text) root.pxPort = text
      }

      TextField {
        width: parent.width
        placeholderText: "Username (optional)"
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        text: root.pxUser
        onTextChanged: if (root.pxUser !== text) root.pxUser = text
      }

      TextField {
        width: parent.width
        placeholderText: "Password (optional, hidden)"
        password: true
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        text: root.pxPassword
        onTextChanged: if (root.pxPassword !== text) root.pxPassword = text
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "UDP over proxies is limited: SOCKS5 without UDP associate and plain HTTP cannot carry it — the backend rejects unsupported combinations. The backend re-validates every value; cyclic proxy/VPN detours are refused there."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      // Explicit credential clearing on an edit. Absent fields retain the
      // stored secrets; clearing is this deliberate operation, never an
      // empty field or a masked placeholder.
      Toggle {
        visible: root.editingId !== ""
        width: parent.width
        label: "Clear saved username and password"
        description: "Removing the stored credentials from this connection. New values typed above are saved instead."
        checked: root.pxClearCredentials
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onClicked: root.pxClearCredentials = !root.pxClearCredentials
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        Button {
          text: root.editingId !== "" ? "Save changes" : "Save"
          bordered: true
          enabled: root.canMutate && root.backendReady && !root.backendBusy && root.pxLabel.trim() !== ""
          opacity: enabled ? 1.0 : 0.4
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.requestSave()
        }

        Button {
          text: "Cancel"
          bordered: true
          enabled: !root.backendBusy
          opacity: enabled ? 1.0 : 0.4
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onClicked: root.resetForms()
        }
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(8)
      visible: root.addKind !== "wireguard" || root.editingId !== ""
      PanelSectionHeader { text: "PRIVATE NETWORK PRESET"; foreground: root.foreground; fontFamily: root.fontFamily }
      Text {
        width: parent.width; textFormat: Text.PlainText; wrapMode: Text.WordWrap
        text: "Optional, saved once for this provider. Separate entries with commas or spaces. Saving changes no active route; Apply later copies a snapshot into the selected app or default policy."
        color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
      }
      TextField {
        objectName: "preset-private-cidrs"; width: parent.width
        placeholderText: "Private networks: canonical CIDRs"
        text: root.privateCidrs; onTextChanged: root.privateCidrs = text
        foreground: root.foreground; accent: root.accent; font.family: root.fontFamily
      }
      TextField {
        objectName: "preset-private-domains"; width: parent.width
        placeholderText: "Private domain suffixes"
        text: root.privateDomains; onTextChanged: root.privateDomains = text
        foreground: root.foreground; accent: root.accent; font.family: root.fontFamily
      }
      TextField {
        objectName: "preset-private-dns"; width: parent.width
        placeholderText: "Private DNS addresses: literal IPs (optional)"
        text: root.privateDns; onTextChanged: root.privateDns = text
        foreground: root.foreground; accent: root.accent; font.family: root.fontFamily
      }
      Text {
        width: parent.width; textFormat: Text.PlainText; wrapMode: Text.WordWrap
        text: "Tailscale or Headscale may supply its own intrinsic private DNS. Leaving this blank does not invent a resolver; Apply validates availability. Public DNS stays with the app/default policy."
        color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
      }
    }
    Text {
      textFormat: Text.PlainText
      visible: root.saveError !== ""
      width: parent.width
      text: root.saveError
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: "Saving never activates anything, never changes the default connection, and never reassigns applications."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }
}
