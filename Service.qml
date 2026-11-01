import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Host VPN state and changes belong to the runtime broker and independent
// capture guard. Legacy engine/config fields are not capture evidence.
Item {
  id: root

  property var settings: ({})
  // Test seam for the hermetic runtime entrypoint (tests/ui/runtime/): when
  // true, startup skips every host-facing probe (systemctl, ss, hyprctl,
  // kill-switch/bypass/profile helpers — all sudo paths) so loading the
  // REAL Service under test exercises only the connections client boundary
  // against a fake transport. Default false: zero change to production
  // behavior, which always probes.
  property bool passiveMode: false

  // ---- configuration ------------------------------------------------------
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string configPath: Model.expandHome(setting("configPath", "~/.config/sing-box/config.json"), home)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 5, 2, 300)
  readonly property string ipLookupUrl: Model.ipLookupUrl(setting("ipLookupService", "ifconfig.co"))

  // Nothing this plugin runs is allowed to hand QML an unbounded stream, so
  // every process goes through one wrapper that caps both of its streams at
  // the producer: stdout through head(1), which closes the pipe and stops the
  // writer with SIGPIPE past the cap, and stderr through a process
  // substitution doing the same. Truncating in an exit handler would be far
  // too late — by then this process has already buffered everything the
  // command chose to write. The wrapped command's own status is what the
  // wrapper exits with, so timeout(1)'s 124 and every real failure still
  // reach onExited unchanged.
  //
  // timeout(1) signals the whole process group on expiry, so the wrapper, the
  // command, its pipeline children and both caps die together.
  readonly property string capScript:
    'out="$1"; err="$2"; shift 2\n' +
    'exec 2> >(exec head -c "$err" >&2)\n' +
    '"$@" | head -c "$out"\n' +
    'exit "${PIPESTATUS[0]}"\n'

  // Error text is elided to a line before it is shown, so the cap only has to
  // be small enough to be harmless and large enough to hold a real message.
  readonly property int stderrCap: 4096
  readonly property int actionCap: 4096
  readonly property int actionTimeout: 120

  function capped(seconds, outCap, command) {
    return ["timeout", "-k", "2", String(seconds), "bash", "-c", capScript, "_",
            String(outCap), String(stderrCap)].concat(command)
  }

  // ---- capture/action state ------------------------------------------------
  property bool probed: false
  // "Up" is an authenticated broker/guard fact (capture state, deadline
  // freshness and lease currency), not proof that traffic is flowing — the
  // exit lookup owns that verification, and the panel words it that way.
  // The lease claim is an exact anchored deadline: bounded remaining-lease
  // evidence from the guard record, anchored to the start of the request
  // that carried it so the whole round trip is subtracted. Past that
  // deadline the evidence itself describes an expired window, so the state
  // fails closed instead of claiming protection.
  readonly property bool up: captureState === "active" && captureDeadlineFresh && captureLeaseCurrent && runtimeState === "ready"
  onUpChanged: {
    if (passiveMode) return
    if (up) onWentUp()
    else { ipGen++; onWentDown() }
  }
  property string bypassState: "unknown"    // verified only by the root helper; no UI boolean can set it
  property string lastActionKind: ""
  // A start/stop/restart in flight. Set by the action, cleared by the
  // action's completion (or its watchdog) — never by an early poll.
  property bool busy: false
  onBusyChanged: if (busy) busyWatchdog.restart(); else busyWatchdog.stop()
  property string lastError: ""
  property string actionStatus: ""

  readonly property double uptimeSec: runtimeMetricsAvailable ? telemetryUptime : 0

  // ---- desktop proxy (legacy cleanup only) --------------------------------
  // The desktop-routing activation paths are retired: under TUN the desktop
  // is never pointed at a loopback proxy by this plugin. What survives is
  // one explicit, ownership-safe cleanup for machines where an earlier
  // version left a desktop-proxy record behind. Nothing reads a proxy
  // setting into state, nothing is released automatically, and nothing
  // foreign is ever touched: the release only acts when this plugin's own
  // ownership record still says an endpoint belongs to it.
  property string ownedProxyEndpoint: ""
  readonly property bool hasLegacyProxyRecord: ownedProxyEndpoint !== ""

  // ---- config file --------------------------------------------------------
  property var config: null
  readonly property string configError: config ? String(config.error || "") : ""
  readonly property string controller: config ? String(config.controller || "") : ""
  readonly property string selector: config ? String(config.selector || "") : ""
  readonly property var nodes: config && config.nodes ? config.nodes : []
  // Standalone endpoints outside the selector (wireguard, tailscale, socks,
  // http, …) — assignable per app, shown in the picker separately from the
  // default selector members.
  readonly property var otherTargets: config && config.otherTargets ? config.otherTargets : []
  // A catalog that hit a bound says so visibly; it is never silently short.
  readonly property string truncationWarning: config ? String(config.truncationWarning || "") : ""
  // Whether the config's selector declares interrupt_exist_connections.
  // Recorded and shown, never trusted alone: the verified switch still
  // scopes-closes leftover connections itself.
  readonly property bool selectorInterrupts: config ? config.selectorInterrupts === true : false
  // Private engine API access is retired from the desktop. The legacy proxy
  // inbound (proxyHost/proxyPort/proxyUrl) no longer runs under the broker
  // architecture, so it is not surfaced here — showing an address that isn't
  // listening would be misleading.
  readonly property string apiBase: ""
  readonly property string apiError: "Engine API access is private. Use Settings → Runtime scopes."

  // Authoritative state from the privileged helper: "on", "off" or
  // "unknown". Never set optimistically; "off" and "unknown" are both
  // surfaced as warnings by the panel.
  property bool killSwitchEnabled: true
  property bool killSwitchSettingVerified: false
  readonly property bool killSwitchKnown: killSwitchSettingVerified && captureFresh && runtimeState === "ready"
  readonly property string killSwitch: killSwitchKnown ? (killSwitchEnabled ? "on" : "off") : "unknown"
  readonly property bool canSetKillSwitch: killSwitchKnown && !runtimeMutationBusy
    && (killSwitchEnabled || ["preparing", "disconnecting", "rollback-required"].indexOf(captureState) < 0)

  // Generation counter: bumped whenever the exit changes under a lookup, so
  // an answer that arrives after the fact is recognised as stale and dropped
  // instead of drawn.
  property int ipGen: 0
  readonly property var runtimeConnection: Model.runtimeConnectionDisplay(
    runtimeScope(applicationDefaultScope), connectionsCatalog)
  readonly property string activeName: runtimeConnection.name
  readonly property string activeEndpoint: runtimeConnection.endpoint
  readonly property bool runtimeMetricsAvailable: up && statsLoaded
    && captureClock - telemetryObservedAt < 5000
  property var captureTelemetrySample: null
  property bool ratesLoaded: false
  property double telemetryObservedAt: 0
  property double telemetryUptime: 0

  // ---- statistics ---------------------------------------------------------
  property double downloadTotal: 0
  property double uploadTotal: 0
  property double downRate: 0
  property double upRate: 0
  property bool statsLoaded: false

  property string exitIp: ""
  property string exitLocation: ""
  property string exitOrg: ""
  property bool ipLoading: false
  property string ipError: ""
  property double exitObservedAt: 0
  property double exitLastAttemptAt: 0
  property bool egressRefreshPending: false
  property int httpsLatencyMs: -1
  property string connectionTestMessage: ""
  property string connectionTestProvider: ""
  property string connectionTestLocation: ""
  property var connectionTestGeneration: null
  property bool connectionTestPending: false
  readonly property bool exitFresh: up && exitObservedAt > 0 && captureClock - exitObservedAt < 60000

  // ---- connections backend (Settings → Connections) ------------------------
  // Saved connection providers (WireGuard imports, Tailscale/Headscale,
  // proxies) are spoken to through one unprivileged client
  // (connections-client.py) that carries bounded requests to the root-owned
  // connections helper. When the helper is missing or unauthorized, state
  // is "unavailable" and the panel says so — never a mocked success. No
  // action here activates anything: the contract's verbs are catalog and
  // persistence only. The list is NOT polled on a timer — the client
  // invokes sudo per request — it is refreshed when the panel opens and
  // after each completed action.
  readonly property string connectionsClientPath: localPath(Qt.resolvedUrl("connections-client.py"))
  property string connectionsState: "unavailable"   // ready | unavailable | error
  property string connectionsError: ""
  property var connectionsCatalog: null
  // The CAS token is an UNTYPED safe integer: a QML `int` property would
  // narrow revisions to signed 32 bits, silently wrapping anything beyond
  // 2147483647. Stored as a JS double (exact to 2^53), validated by
  // Model.isSafeRevision before any mutation is created. Unknown is
  // tracked separately and never masquerades as a valid zero.
  property var connectionsRevision: 0
  property bool connectionsRevisionKnown: false
  property string connectionsRequestId: ""
  property string connectionsAction: ""
  property string connectionsPendingInput: ""
  // True while a paged listing is being assembled (several client runs,
  // one per page). connectionsBusy below covers the gaps between pages so
  // no action can interleave with a partial listing.
  property bool connectionsPaging: false
  // Planner state for the paged protocol (Model.planPagedListing owns the
  // decision rules): { pageSize, offset, revision, total, rows, pages,
  // pagesFetched }. Null whenever no listing is in flight.
  property var connectionsPagingState: null
  // Set when a mutation was refused as a revision conflict: the panel
  // refreshes the authoritative list but NEVER auto-retries the mutation.
  // The flag holds until the refresh acknowledges it (or the user starts
  // the next explicit mutation).
  property bool connectionsConflict: false
  // Starting page size for the paged protocol; halved on a page that does
  // not fit the serialized budget (never below one row, at which point the
  // listing fails honestly).
  readonly property int connectionsPageSize: 128
  readonly property bool connectionsBusy: connectionsRequestId !== "" || connectionsPaging
  signal connectionsResponse(string action, bool ok, var response)

  function connectionsRequest(action, payload, revision) {
    if (connectionsProcess.running || connectionsPaging) {
      note("A connections request is already running")
      return false
    }
    if (!Model.isCodeText(action, 32)) return false
    var mutating = action === "save" || action === "import_wireguard" || action === "remove"
    if (mutating) {
      // The revision is validated HERE, before the mutation is created —
      // not just inside the client subprocess: unknown tokens, non-safe
      // integers and missing arguments never reach a mutation request.
      if (!connectionsRevisionKnown || !Model.isSafeRevision(connectionsRevision)
          || !Model.isSafeRevision(revision)) {
        note("Saving needs the current authoritative revision — refresh the connection list first")
        return false
      }
    }
    connectionsRequestId = Model.nextRequestId()
    connectionsAction = action
    // An explicit user mutation starts a fresh chapter; the scheduled
    // conflict refresh (a read) must NOT clear the flag on its way out.
    if (mutating) connectionsConflict = false
    var input = { action: action, requestId: connectionsRequestId, payload: payload || {} }
    if (typeof revision === "number" && isFinite(revision) && revision >= 0) input.revision = revision
    connectionsPendingInput = JSON.stringify(input) + "\n"
    connectionsProcess.stdinEnabled = true
    connectionsProcess.command = capped(45, 2097152, ["python3", connectionsClientPath])
    connectionsProcess.running = true
    return true
  }

  function refreshConnections() {
    if (connectionsBusy) return
    connectionsRequest("list")
  }

  // ---- paged listing (the documented scalable protocol) --------------------
  // Started ONLY on the backend's explicit `response-too-large` refusal of
  // a plain list. Model.planPagedListing owns every rule: one pinned
  // revision for the whole listing, strict page order/totals/completeness
  // validated BEFORE the next fetch, halving on an over-budget page, caps
  // on pages and rows, and a whole-listing failure for anything else — a
  // partial catalog is never drawn and no page is ever retried on its own.

  function startPagedList() {
    connectionsPagingState = { pageSize: connectionsPageSize, offset: 0,
                               revision: null, total: -1, rows: 0,
                               pages: [], pagesFetched: 0 }
    connectionsPaging = true
    fetchListPage()
  }

  // An unpaged reply that claims incomplete data enters the SAME bounded
  // revision-pinned planner as any other first page — never a hand-seeded
  // state that could bypass shape/offset/zero-progress/size checks.
  function startPagedFromFirstPage(parsed, exitOk, exitCode) {
    connectionsPagingState = { pageSize: connectionsPageSize, offset: 0,
                               revision: null, total: -1, rows: 0,
                               pages: [], pagesFetched: 0 }
    connectionsPaging = true
    applyPagedOutcome(parsed, exitOk, exitCode)
  }

  function fetchListPage() {
    var st = connectionsPagingState
    if (!connectionsPaging || st === null) return
    connectionsRequestId = Model.nextRequestId()
    connectionsAction = "list"
    var input = { action: "list", requestId: connectionsRequestId,
                  payload: { offset: st.offset, limit: st.pageSize } }
    connectionsPendingInput = JSON.stringify(input) + "\n"
    connectionsProcess.stdinEnabled = true
    connectionsProcess.command = capped(45, 2097152, ["python3", connectionsClientPath])
    connectionsProcess.running = true
  }

  function applyPagedOutcome(parsed, exitOk, exitCode) {
    var plan = Model.planPagedListing(connectionsPagingState,
      { exitOk: exitOk, exitCode: exitCode, parsed: parsed })
    if (plan.action === "fetch") {
      connectionsPagingState.offset = plan.offset
      fetchListPage()
      return
    }
    if (plan.action === "refetch") {
      // Same offset, smaller page: the previous slice did not serialize.
      connectionsPagingState.pageSize = plan.pageSize
      fetchListPage()
      return
    }
    finishPagedList(plan)
  }

  function finishPagedList(plan) {
    connectionsPaging = false
    var st = connectionsPagingState
    connectionsPagingState = null
    if (plan.action === "complete") {
      var catalog = Model.parseConnectionsCatalog(plan.data)
      if (catalog !== null) {
        connectionsState = "ready"
        connectionsError = ""
        // The paged listing landed whole AND parsed: any conflict chapter
        // is acknowledged by this authoritative result. A malformed merge
        // is not an acknowledgment.
        connectionsCatalog = catalog
        connectionsConflict = false
        connectionsResponse("list", true,
                            { ok: true, requestId: "", revision: st.revision,
                              revisionKnown: true, data: plan.data, error: "", errorCode: "" })
        return
      }
      plan = { action: "fail", message: "the paged connection list is not in the expected shape" }
    }
    // A failed page fails the whole listing: partial data is discarded,
    // paging/busy state is cleared, and the failure is surfaced (never a
    // silent short list, never an automatic retry).
    connectionsState = "error"
    connectionsError = plan.message
    connectionsCatalog = null
    connectionsResponse("list", false,
                        { ok: false, requestId: "", revision: null, revisionKnown: false,
                          data: null, error: plan.message, errorCode: "listing" })
  }

  // Authenticated runtime supervisor; the desktop never sees engine secrets.
  property string runtimeState: "loading"
  property string captureState: "unavailable"
  property bool captureDeadlineFresh: false
  property double captureObservedAt: 0
  property double captureClock: Date.now()
  readonly property int captureFreshWindowMs: 5000
  readonly property bool captureFresh: captureObservedAt > 0 && captureClock - captureObservedAt < captureFreshWindowMs
  // Exact bounded remaining lease evidence, anchored to the start timestamp
  // of the request that carried it (the whole round trip is subtracted,
  // never re-anchored at receipt). 0 means no live anchored evidence.
  // ACTIVE_LEASE_SECONDS in the independent guard bounds the TTL at 10000.
  property double captureValidUntil: 0
  readonly property bool captureLeaseCurrent: captureValidUntil > 0 && captureClock < captureValidUntil
  // Verification delayed: the lease evidence is still inside its exact
  // validity window but no fresh proof landed in the ordinary window.
  // Represented honestly (the status line says re-verifying); up is NOT
  // toggled off.
  readonly property bool captureVerifying: captureState === "active" && captureDeadlineFresh && captureLeaseCurrent && !captureFresh
  // Deadline-driven expiry: evidence with sub-second remaining validity must
  // not survive until the next one-second tick.
  Timer {
    id: captureExpiryTimer
    interval: 1
    repeat: false
    onTriggered: {
      if (root.captureValidUntil > 0 && Date.now() >= root.captureValidUntil) {
        root.captureDeadlineFresh = false
        root.requestCaptureStatus()
      }
    }
  }
  function armCaptureExpiry() {
    if (captureValidUntil > 0) {
      captureExpiryTimer.interval = Math.max(1, captureValidUntil - Date.now())
      captureExpiryTimer.restart()
    }
  }
  // Anchor bounded remaining-lease evidence to the corresponding request's
  // start timestamp. Evidence already expired at receipt is refused (fail
  // closed) until a fresh focused probe lands.
  function applyCaptureLease(anchor, remainingMs) {
    var validUntil = anchor + remainingMs
    if (Date.now() >= validUntil) {
      // The newest measurement supersedes any older claim: its lease is
      // already dead, so nothing may be claimed until a fresh probe lands.
      captureValidUntil = 0
      captureDeadlineFresh = false
      return false
    }
    captureValidUntil = validUntil
    captureDeadlineFresh = true
    armCaptureExpiry()
    return true
  }
  function clearCaptureLease() {
    captureValidUntil = 0
    captureDeadlineFresh = false
    captureExpiryTimer.stop()
  }
  Timer {
    interval: 1000; repeat: true; running: true
    onTriggered: {
      root.captureClock = Date.now()
      // The lease probe owns its own process: client-side it no longer
      // queues behind broad reads on the shared runtime process. (The
      // broker still answers sequentially, so a probe may wait behind an
      // in-flight broad read; the backend lightweight path bounds that.)
      root.requestCaptureStatus()
    }
  }
  readonly property bool captureEngaged: ["active", "preparing", "degraded-blocked", "degraded-unknown", "disconnecting", "rollback-required"].indexOf(captureState) >= 0
  property string runtimeError: ""
  property string runtimeErrorAction: ""
  property bool runtimeErrorMutation: false
  property var runtimeScopes: []
  property var runtimeScopeCatalog: []
  property var runtimeCatalogRevision: null
  property var runtimeGeneration: null
  onRuntimeGenerationChanged: {
    if (connectionTestMessage !== "") {
      connectionTestPending = false
      connectionTestMessage = "Connection changed. Test again for the current route."
    }
    ipGen++
    exitObservedAt = 0
    exitIp = ""
    if (!passiveMode && up) { egressRefreshPending = true; ipRefreshTimer.restart() }
  }
  property string runtimeRequestId: ""
  property string runtimeAction: ""
  property int runtimeSerial: 0
  property string runtimeInput: ""
  // Request-start timestamps: bounded lease evidence is anchored here so the
  // entire request round trip is subtracted from the remaining TTL.
  property double runtimeRequestStartedAt: 0
  // A click made while a read-only status request owns the single broker
  // process is retained exactly once. This is an unsubmitted intent, not a
  // retry: once a mutation reaches the broker it is never replayed here.
  property var queuedRuntimeMutation: null
  readonly property bool runtimeBusy: runtimeProcess.running || runtimeRequestId !== ""
  readonly property string runtimePendingAction: queuedRuntimeMutation
    ? queuedRuntimeMutation.action : runtimeAction
  readonly property bool runtimeMutationBusy: queuedRuntimeMutation !== null
    || (runtimeBusy && ["assign", "switch", "block", "application_assign", "application_default",
      "connect", "disconnect", "set_kill_switch", "managed_create", "managed_launch"].indexOf(runtimeAction) >= 0)
  // Routine status polling does not change a route. It must not starve the
  // independent HTTPS probe or discard its otherwise fresh result.
  readonly property bool egressTransitionBusy: runtimeMutationBusy
  readonly property bool runtimeRevisionKnown: Model.isSafeRevision(runtimeCatalogRevision)
    && Model.isSafeRevision(runtimeGeneration)
  property var managedApplications: []
  property var managedInstances: []
  property var managedTemplates: []
  property var runningApplications: []
  property var applicationSlots: []
  property string applicationRevision: ""
  property bool applicationDiscoveryComplete: false
  property string applicationDiscoveryWarning: "Refresh to discover apps and saved exceptions."
  property string applicationDefaultScope: ""
  property bool applicationDefaultRequested: false
  property string applicationRoutingStatus: up
    ? "VPN is connected. Choose an application to save a separate route."
    : statusLine
  property bool managedControlAvailable: false
  readonly property bool managedLaunchAvailable: managedControlAvailable && runtimeState === "ready"
  signal runtimeResponse(string action, bool ok, var response)

  function runtimeScope(scopeId) {
    for (var i = 0; i < runtimeScopes.length; i++)
      if (runtimeScopes[i].scope === scopeId) return runtimeScopes[i]
    return null
  }

  function dispatchQueuedRuntimeMutation() {
    if (runtimeBusy || queuedRuntimeMutation === null) return false
    var queued = queuedRuntimeMutation
    queuedRuntimeMutation = null
    if (runtimeRequest(queued.action, queued.scopeId, queued.privateTarget,
                       queued.publicTarget, queued.scopePolicy)) return true
    // The intent was never submitted. Complete its local pending state as a
    // refusal; do not manufacture success and do not retry it.
    runtimeResponse(queued.action, false, {})
    return false
  }

  function runtimeRequest(action, scopeId, privateTarget, publicTarget, scopePolicy) {
    var hostMutation = action === "connect" || action === "disconnect" || action === "set_kill_switch"
    var managedCreate = action === "managed_create"
    var mutation = action === "assign" || action === "switch" || action === "block"
      || hostMutation || managedCreate || action === "managed_launch" || action === "application_assign" || action === "application_default"
    if (mutation && ((runtimeState !== "ready" && action !== "disconnect") || !runtimeRevisionKnown
        || (!hostMutation && action !== "application_default" && !runtimeScope(scopeId)))) {
      runtimeError = "Refresh runtime status and choose a configured scope before changing its route."
      runtimeErrorAction = action
      runtimeErrorMutation = true
      return false
    }
    if (runtimeBusy) {
      // Read-only polling must not eat a user's click. Keep at most one
      // mutation and submit it immediately after that read completes.
      if (!mutation || queuedRuntimeMutation !== null
          || ["assign", "switch", "block", "application_assign", "application_default",
            "connect", "disconnect", "set_kill_switch", "managed_create", "managed_launch"].indexOf(runtimeAction) >= 0) return false
      queuedRuntimeMutation = { action: action, scopeId: scopeId,
        privateTarget: privateTarget, publicTarget: publicTarget,
        scopePolicy: scopePolicy }
      runtimeError = ""
      runtimeErrorAction = ""
      runtimeErrorMutation = false
      if (action === "application_assign" || action === "application_default") {
        applicationDefaultRequested = false
        applicationRoutingStatus = action === "application_default"
          ? "Waiting to remove this app's exception…" : "Waiting to save this app's exception…"
      }
      return true
    }
    if (action === "status" && !Model.isSafeRevision(runtimeCatalogRevision)) {
      if (!connectionsRevisionKnown) return false
      runtimeCatalogRevision = connectionsRevision
    }
    var id = "ui-runtime-" + Date.now() + "-" + (++runtimeSerial)
    var envelope = action === "running_apps" || action === "application_assign" || action === "application_default"
      ? Model.applicationEnvelope(action, id, scopeId, runtimeCatalogRevision, runtimeGeneration, privateTarget, applicationRevision)
      : action.indexOf("managed_") === 0
      ? Model.managedEnvelope(action, id, scopeId, runtimeCatalogRevision, runtimeGeneration, privateTarget)
      : Model.runtimeEnvelope(action, id, scopeId, runtimeCatalogRevision,
                              runtimeGeneration, privateTarget, publicTarget, scopePolicy)
    if (!envelope) { runtimeError = "Choose a provider and any required WireGuard location, or refresh status."; runtimeErrorAction = action; runtimeErrorMutation = mutation; return false }
    runtimeRequestId = id
    runtimeAction = action
    runtimeInput = JSON.stringify(envelope)
    runtimeRequestStartedAt = Date.now()
    if (mutation) { runtimeError = ""; runtimeErrorAction = ""; runtimeErrorMutation = false }
    if (action === "application_assign" || action === "application_default") {
      applicationDefaultRequested = false
      applicationRoutingStatus = action === "application_default"
        ? "Removing this app's exception…" : "Saving this app's exception…"
    }
    runtimeProcess.stdinEnabled = true
    runtimeProcess.command = capped(200, 65536, ["/usr/local/bin/singbox-runtime"])
    runtimeProcess.running = true
    return true
  }

  function refreshRuntime() {
    if (!runtimeBusy) runtimeRequest("status", "", null, null)
  }

  // ---- dedicated capture lease probe ---------------------------------------
  // The one-second lease proof owns its OWN process: client-side it no longer
  // queues behind broad scope/status or discovery reads on the shared
  // runtimeProcess (the OFF flicker when the evidence clock expired while
  // systemd services, the lease and nftables were stable). The broker still
  // answers sequentially, so an accepted probe can wait behind an in-flight
  // broad read; the backend lightweight path keeps that wait short. The
  // probe is read-only: it never queues behind or displaces a mutation, it
  // is not submitted while a mutation is in flight, and a probe that crossed
  // a completed route change is dropped on arrival instead of overwriting
  // newer committed truth.
  property string captureRequestId: ""
  property int captureSerial: 0
  property string captureInput: ""
  property double captureRequestStartedAt: 0
  readonly property bool captureBusy: captureRequestId !== ""

  function requestCaptureStatus() {
    if (captureBusy || runtimeMutationBusy || !runtimeRevisionKnown) return false
    var id = "ui-capture-" + Date.now() + "-" + (++captureSerial)
    var envelope = Model.runtimeEnvelope("capture_status", id, "", runtimeCatalogRevision,
                                         runtimeGeneration, null, null, null)
    if (!envelope) return false
    captureRequestId = id
    captureRequestStartedAt = Date.now()
    captureInput = JSON.stringify(envelope)
    captureProcess.stdinEnabled = true
    captureProcess.command = capped(60, 65536, ["/usr/local/bin/singbox-runtime"])
    captureProcess.running = true
    return true
  }

  function refreshApplications() {
    if (runtimeBusy) { applicationDefaultRequested = false; return false }
    return runtimeRequest("running_apps", "", null, null)
  }

  function listRuntimeScopes() {
    return runtimeRequest("list_scopes", "", null, null)
  }

  Process {
    id: runtimeProcess
    running: false
    command: []
    stdout: StdioCollector { id: runtimeStdout; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      runtimeProcess.write(root.runtimeInput + "\n")
      runtimeProcess.stdinEnabled = false
      root.runtimeInput = ""
    }
    onExited: function(exitCode) {
      var action = root.runtimeAction
      var mutation = ["connect", "disconnect", "set_kill_switch", "assign", "switch", "block", "managed_create", "managed_launch", "application_assign", "application_default"].indexOf(action) >= 0
      var response = Model.parseRuntimeResponse(String(runtimeStdout.text || ""), root.runtimeRequestId, action)
      root.runtimeRequestId = ""
      root.runtimeAction = ""
      root.runtimeInput = ""
      var ok = response !== null && response.ok && exitCode === 0
      if (action === "application_assign" || action === "application_default") {
        root.applicationDefaultRequested = false
        if (!ok) root.applicationRoutingStatus = "Change not confirmed. Refreshing apps; review the result before retrying."
      }
      if (response === null || (response.ok && exitCode !== 0)) {
        root.runtimeState = "unavailable"
        root.clearCaptureLease()
        if (mutation || !root.runtimeErrorMutation) {
          root.runtimeError = "Runtime supervisor unavailable or response incomplete. Refresh status before retrying."
          root.runtimeErrorAction = action
          root.runtimeErrorMutation = mutation
        }
        root.runtimeCatalogRevision = null
        root.runtimeGeneration = null
        if (action.indexOf("managed_") === 0) root.managedControlAvailable = false
      } else {
        if (action !== "list_scopes" && action !== "managed_apps") {
          root.runtimeCatalogRevision = response.catalog_revision
          root.runtimeGeneration = response.runtime_generation
        }
        if (!ok) {
          if (["connect", "disconnect", "capture_status", "set_kill_switch"].indexOf(action) >= 0)
            root.clearCaptureLease()
          if (mutation || !root.runtimeErrorMutation) {
            root.runtimeError = (mutation ? "Last change failed: " : "") + response.error.message + " (" + response.error.code + ")"
            root.runtimeErrorAction = action
            root.runtimeErrorMutation = mutation
          }
          root.runtimeState = "error"
          if (action === "application_assign" || action === "application_default")
            root.applicationRoutingStatus = root.runtimeError + " Refreshing apps; review before trying again."
        } else {
          root.runtimeState = "ready"
          if (action === "status") root.runtimeScopes = response.scopes
          else if (["connect", "disconnect", "capture_status", "set_kill_switch"].indexOf(action) >= 0) {
            root.captureState = response.capture.state
            root.killSwitchSettingVerified = response.capture.kill_switch_setting_verified
            if (response.capture.kill_switch_enabled !== null) root.killSwitchEnabled = response.capture.kill_switch_enabled
            root.captureObservedAt = Date.now()
            root.captureClock = root.captureObservedAt
            if (response.capture.state === "active" && response.capture.deadline_fresh)
              root.applyCaptureLease(root.runtimeRequestStartedAt, response.capture.lease_remaining_ms)
            else
              root.clearCaptureLease()
            root.applyCaptureTelemetry(response.capture.telemetry)
          }
          else if (action === "list_scopes") root.runtimeScopeCatalog = response.scopes
          else if (action === "running_apps") {
            root.runningApplications = response.running_applications
            root.applicationSlots = response.application_slots
            root.applicationDefaultScope = response.application_default_scope || ""
            root.applicationRevision = response.application_revision
            root.applicationDefaultRequested = true
            root.applicationDiscoveryComplete = response.discovery_complete
            root.applicationDiscoveryWarning = response.discovery_warning
          } else if (action === "application_assign" || action === "application_default") {
            root.applicationRevision = response.application_revision
            root.applicationRoutingStatus = action === "application_default"
              ? "Saved: exception removed. This app follows the default tunnel; active routing remains unverified."
              : "Saved: this app's route preference persists until changed. Active routing remains unverified."
          }
          else if (action === "managed_apps") {
            root.managedApplications = response.applications
            root.managedInstances = response.managed_scopes
            root.managedTemplates = response.templates
            root.managedControlAvailable = true
          } else if (action === "managed_create" || action === "managed_launch") {
            var instances = root.managedInstances.slice()
            var found = false
            for (var m = 0; m < instances.length; m++) {
              if (instances[m].scope === response.managed.scope) { instances[m] = response.managed; found = true }
            }
            if (!found) instances.push(response.managed)
            root.managedInstances = instances
          }
          else {
            var updated = root.runtimeScopes.slice()
            for (var i = 0; i < updated.length; i++)
              if (updated[i].scope === response.scope.scope) updated[i] = response.scope
            root.runtimeScopes = updated
          }
          if (!root.runtimeErrorMutation && (action === "status" || action === root.runtimeErrorAction)) {
            root.runtimeError = ""
            root.runtimeErrorAction = ""
          }
        }
      }
      root.runtimeResponse(action, ok, response)
      if (root.queuedRuntimeMutation) {
        // Give response handlers a chance to commit the completed read, then
        // prioritize the captured click over routine follow-up polling.
        Qt.callLater(root.dispatchQueuedRuntimeMutation)
        return
      }
      // Only read-only follow-up; never automatically repeat a mutation.
      if (ok && (action === "application_assign" || action === "application_default")) Qt.callLater(root.refreshApplications)
      else if (action === "status" && ok) Qt.callLater(root.requestCaptureStatus)
      else if (action === "capture_status" && ok && !root.applicationDefaultRequested) {
        root.applicationDefaultRequested = true
        Qt.callLater(root.refreshApplications)
      }
      else if (action !== "status" && action !== "capture_status") Qt.callLater(root.refreshRuntime)
    }
  }

  // The dedicated lease probe transport: one bounded request on stdin, one
  // bounded response on stdout, exactly like the shared broker process but
  // independent of it, so broad reads can never queue ahead of the probe
  // client-side. (The broker still answers sequentially, so an accepted
  // probe can wait behind an in-flight broad read; the backend lightweight
  // path bounds that wait and the exact anchored lease absorbs the rest.)
  Process {
    id: captureProcess
    running: false
    command: []
    stdout: StdioCollector { id: captureStdout; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      captureProcess.write(root.captureInput + "\n")
      captureProcess.stdinEnabled = false
      root.captureInput = ""
    }
    onExited: function(exitCode) {
      var expected = root.captureRequestId
      root.captureRequestId = ""
      var response = Model.parseRuntimeResponse(String(captureStdout.text || ""), expected, "capture_status")
      // A probe that crossed a completed route change describes an exit that
      // no longer exists: the committed mutation already owns the truth, so
      // the stale answer is dropped (the next tick re-probes). Nothing here
      // touches state and no response is emitted for a dropped probe.
      if (response !== null && Model.isSafeRevision(root.runtimeGeneration)
          && response.runtime_generation !== root.runtimeGeneration) return
      var ok = response !== null && response.ok && exitCode === 0
      if (response === null || (response.ok && exitCode !== 0)) {
        root.runtimeState = "unavailable"
        root.clearCaptureLease()
        if (!root.runtimeErrorMutation) {
          root.runtimeError = "Runtime supervisor unavailable or response incomplete. Refresh status before retrying."
          root.runtimeErrorAction = "capture_status"
          root.runtimeErrorMutation = false
        }
        root.runtimeCatalogRevision = null
        root.runtimeGeneration = null
      } else if (!ok) {
        root.clearCaptureLease()
        if (!root.runtimeErrorMutation) {
          root.runtimeError = response.error.message + " (" + response.error.code + ")"
          root.runtimeErrorAction = "capture_status"
        }
        root.runtimeState = "error"
      } else {
        root.runtimeState = "ready"
        root.runtimeCatalogRevision = response.catalog_revision
        root.runtimeGeneration = response.runtime_generation
        root.captureState = response.capture.state
        root.killSwitchSettingVerified = response.capture.kill_switch_setting_verified
        if (response.capture.kill_switch_enabled !== null) root.killSwitchEnabled = response.capture.kill_switch_enabled
        root.captureObservedAt = Date.now()
        root.captureClock = root.captureObservedAt
        if (response.capture.state === "active" && response.capture.deadline_fresh)
          root.applyCaptureLease(root.captureRequestStartedAt, response.capture.lease_remaining_ms)
        else
          root.clearCaptureLease()
        root.applyCaptureTelemetry(response.capture.telemetry)
        if (!root.runtimeErrorMutation && root.runtimeErrorAction === "capture_status") {
          root.runtimeError = ""
          root.runtimeErrorAction = ""
        }
      }
      root.runtimeResponse("capture_status", ok, response)
      if (ok && !root.applicationDefaultRequested) {
        root.applicationDefaultRequested = true
        Qt.callLater(root.refreshApplications)
      }
    }
  }

  property bool panelOpen: false
  // Byte-rate sampling needed the private engine API (hasApi), now retired;
  // live rates come from the broker's capture telemetry instead (see
  // applyCaptureTelemetry). Kept false for the debug IPC snapshot.
  readonly property bool sampling: false

  readonly property string statusLine: {
    if (runtimeError !== "") return runtimeError
    if (runtimeAction === "connect") return "Connecting · awaiting verified broker state"
    if (runtimeAction === "disconnect") return "Disconnecting · awaiting owned cleanup"
    if (runtimeState !== "ready") return "VPN status unavailable · refresh runtime status"
    if (up) return captureFresh ? "VPN active · independent guard lease current"
                                : "VPN active · re-verifying guard lease…"
    if (captureState === "preparing") return "Preparing VPN · not connected yet"
    if (captureState === "disconnecting") return "Disconnecting · cleanup pending"
    if (captureState === "degraded-blocked") return "VPN degraded · captured traffic blocked"
    if (captureState === "degraded-unknown" || captureState === "rollback-required") return "VPN recovery required · routing state not confirmed"
    if (captureState === "active") return "VPN lease not current · refresh status"
    return "VPN off · choose the default tunnel before connecting"
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function localPath(value) {
    var v = String(value || "")
    if (v.indexOf("file://") === 0) v = decodeURIComponent(v.substring(7))
    return v
  }

  function note(text) {
    actionStatus = String(text || "")
    if (actionStatus !== "") noteTimer.restart()
  }

  // ---- polling ------------------------------------------------------------

  function refresh() {
    if (passiveMode) return
    // Status needs the catalog revision even before the panel is opened.
    // Retry failed initial reads only on this existing refresh cadence.
    if (!connectionsRevisionKnown && !connectionsBusy) refreshConnections()
    // A failed discovery must not leave the default selector blank forever.
    // Retry on the normal refresh cadence, not on every guard lease poll.
    if (applicationDefaultScope === "" && !runtimeBusy) applicationDefaultRequested = false
    refreshRuntime()
    // Authenticated Applications owns discovery now. Do not poll the retired
    // process-name editor's files, sockets, windows and profile helper.
    probe()
  }

  function probe() {
    if (probeProcess.running) return
    probeProcess.command = capped(15, 8192, ["sh", "-c", probeScript])
    probeProcess.running = true
  }

  // One shell round-trip for the plugin's own ownership record: any legacy
  // desktop-proxy ownership record an earlier version could still be asked
  // to release. Read through its own byte cap, because it comes from
  // somewhere this plugin does not control.
  readonly property string probeScript:
    proxyStatePath +
    'owned=\n' +
    'if [ -f "$statefile" ] && [ ! -L "$statefile" ]; then\n' +
    '  raw=$(head -c 4096 -- "$statefile" 2>/dev/null)\n' +
    '  if [ "$(printf "%s\\n" "$raw" | sed -n 1p)" = 1 ]; then\n' +
    '    owned=$(printf "%s\\n" "$raw" | sed -n 2p | base64 -d 2>/dev/null | tr -dc "][A-Za-z0-9.:_-" | head -c 80)\n' +
    '  fi\n' +
    'fi\n' +
    'printf "%s\\n" "${owned:-}"\n'

  // A failed probe owns the state it could not read: never a stale answer.
  function applyProbe(text, exitCode) {
    var previousUp = up
    if (exitCode !== 0) {
      probed = true
      return
    }
    ownedProxyEndpoint = Model.safeText(String(text || "").split("\n")[0], 80)
    probed = true

    // No automatic releases here. Under TUN the desktop never points at a
    // loopback proxy, and silently rewriting the user's proxy environment on
    // a tunnel failure is legacy behavior this plugin no longer does: if an
    // old desktop-proxy record exists, the only way it is touched is the
    // explicit legacy cleanup (`unrouteDesktop` IPC).

    if (up && !previousUp) onWentUp()
    if (!up && previousUp) onWentDown()
    if (!up) resetLiveState()
  }

  function onWentUp() {
    lastError = ""
    ipGen++
    lookupIpWithRetry()
  }

  // Nothing is auto-released when the tunnel drops: the desktop proxy
  // environment is legacy surface that this plugin only cleans up when asked.
  // Stale stats and process rows, on the other hand, are cleared at once —
  // a down tunnel exposes no available measurements from the old session.
  function onWentDown() {
    resetLiveState()
  }

  function applyCaptureTelemetry(sample) {
    if (!sample || captureState !== "active" || !captureDeadlineFresh) {
      captureTelemetrySample = null
      statsLoaded = false
      ratesLoaded = false
      return
    }
    if (captureTelemetrySample && sample.session_id === captureTelemetrySample.session_id
        && sample.sampled_at_ms <= captureTelemetrySample.sampled_at_ms) return
    var rates = Model.captureRates(captureTelemetrySample, sample)
    captureTelemetrySample = sample
    downloadTotal = sample.download_bytes
    uploadTotal = sample.upload_bytes
    telemetryUptime = sample.uptime_seconds
    telemetryObservedAt = Date.now()
    downRate = rates ? rates.download : 0
    upRate = rates ? rates.upload : 0
    ratesLoaded = rates !== null
    statsLoaded = true
  }

  function resetLiveState() {
    downRate = 0
    upRate = 0
    exitIp = ""
    exitLocation = ""
    exitOrg = ""
    exitObservedAt = 0
    exitLastAttemptAt = 0
    egressRefreshPending = false
    httpsLatencyMs = -1
    ipError = ""
    statsLoaded = false
    captureTelemetrySample = null
    ratesLoaded = false
  }

  // ---- actions ------------------------------------------------------------

  function start() {
    return runtimeRequest("connect", "", null, null)
  }

  function stop() {
    return runtimeRequest("disconnect", "", null, null)
  }

  function toggle() {
    if (runtimeMutationBusy) return
    captureEngaged ? stop() : start()
  }

  function restart() {
    note("Disconnect first, then explicitly Connect again after cleanup completes.")
    return false
  }

  // Persist the guard's failure behavior through the authenticated broker.
  // Never change the displayed value before authoritative acknowledgement.
  function setKillSwitch(on) {
    if (typeof on !== "boolean" || !canSetKillSwitch) return false
    return runtimeRequest("set_kill_switch", "", on, null)
  }

  // Explicit, ownership-safe legacy cleanup — the only desktop-proxy surface
  // left. It releases exactly what this plugin's own ownership record still
  // claims, puts the displaced settings back, never auto-runs, and never
  // touches a proxy another tool set. There is no activation path anymore.
  function unrouteLegacyDesktopProxy() {
    if (!hasLegacyProxyRecord) {
      note("No legacy desktop-proxy record to clean up")
      return
    }
    runAction(capped(20, actionCap, ["bash", "-c", systemProxyOffScript, "_", "", ""]),
              "proxy-off")
  }

  // ---- desktop proxy ownership (legacy cleanup only) -----------------------

  // What gives the explicit cleanup the right to touch anything is a record
  // an older version of this plugin wrote: an ownership file naming the
  // endpoint it pointed everything at and holding, verbatim, the settings it
  // displaced. This plugin no longer writes that record — it only reads it
  // to know what, if anything, is still its to release.
  readonly property string proxyStatePath:
    'statedir="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-sing-box"\n' +
    'statefile="$statedir/desktop-proxy"\n'

  // Shared by the cleanup direction only: reading the record and putting
  // the displaced settings back. Values are stored base64-encoded, so a proxy
  // string containing anything at all still round-trips through a
  // line-oriented file unharmed.
  readonly property string proxyStateScript:
    'haveg=0\n' +
    'gsettings writable org.gnome.system.proxy mode >/dev/null 2>&1 && haveg=1\n' +
    'unb64() { printf %s "$1" | base64 -d 2>/dev/null; }\n' +
    'readenv() { envtext=$(systemctl --user show-environment 2>/dev/null | head -c 65536); }\n' +
    'envget() {\n' +
    '  printf \'%s\\n\' "$envtext" | sed -n "s/^$1=//p" | head -1 | head -c 512 \\\n' +
    '    | sed -e "s/^\'\\(.*\\)\'\\$/\\1/" -e \'s/^"\\(.*\\)"$/\\1/\'\n' +
    '}\n' +
    'envhas() { printf \'%s\\n\' "$envtext" | grep -q "^$1="; }\n' +
    'readstate() {\n' +
    '  [ -f "$statefile" ] || return 1\n' +
    '  local raw\n' +
    '  raw=$(head -c 4096 -- "$statefile" 2>/dev/null) || return 1\n' +
    '  [ "$(printf \'%s\\n\' "$raw" | sed -n 1p)" = 1 ] || return 1\n' +
    '  s_endpoint=$(unb64 "$(printf \'%s\\n\' "$raw" | sed -n 2p)")\n' +
    '  s_mode=$(unb64 "$(printf \'%s\\n\' "$raw" | sed -n 3p)")\n' +
    '  s_host=$(unb64 "$(printf \'%s\\n\' "$raw" | sed -n 4p)")\n' +
    '  s_port=$(unb64 "$(printf \'%s\\n\' "$raw" | sed -n 5p)")\n' +
    '  s_ignore=$(unb64 "$(printf \'%s\\n\' "$raw" | sed -n 6p)")\n' +
    '  s_np=$(printf \'%s\\n\' "$raw" | sed -n 7p)\n' +
    '  s_NP=$(printf \'%s\\n\' "$raw" | sed -n 8p)\n' +
    '  [ -n "$s_endpoint" ] || return 1\n' +
    '  return 0\n' +
    '}\n' +
    'restore_gsettings() {\n' +
    '  [ "$haveg" = 1 ] || return 0\n' +
    '  [ -n "$s_host" ] && gsettings set org.gnome.system.proxy.socks host "$s_host" 2>/dev/null\n' +
    '  [ -n "$s_port" ] && gsettings set org.gnome.system.proxy.socks port "$s_port" 2>/dev/null\n' +
    '  [ -n "$s_ignore" ] && gsettings set org.gnome.system.proxy ignore-hosts "$s_ignore" 2>/dev/null\n' +
    '  gsettings set org.gnome.system.proxy mode "${s_mode:-none}" 2>/dev/null\n' +
    '  return 0\n' +
    '}\n' +
    'restore_env() {\n' +
    '  local keep=() drop=(all_proxy ALL_PROXY http_proxy HTTP_PROXY https_proxy HTTPS_PROXY)\n' +
    '  case "$s_np" in "1 "*) keep+=("no_proxy=$(unb64 "${s_np#1 }")");; *) drop+=(no_proxy);; esac\n' +
    '  case "$s_NP" in "1 "*) keep+=("NO_PROXY=$(unb64 "${s_NP#1 }")");; *) drop+=(NO_PROXY);; esac\n' +
    '  command -v dbus-update-activation-environment >/dev/null 2>&1 &&\n' +
    '    dbus-update-activation-environment --systemd all_proxy= ALL_PROXY= http_proxy= HTTP_PROXY= \\\n' +
    '      https_proxy= HTTPS_PROXY= no_proxy= NO_PROXY= >/dev/null 2>&1\n' +
    '  systemctl --user unset-environment "${drop[@]}" || return 1\n' +
    '  if [ ${#keep[@]} -gt 0 ]; then\n' +
    '    systemctl --user set-environment "${keep[@]}" || return 1\n' +
    '    export "${keep[@]}"\n' +
    '    command -v dbus-update-activation-environment >/dev/null 2>&1 &&\n' +
    '      dbus-update-activation-environment --systemd no_proxy NO_PROXY >/dev/null 2>&1\n' +
    '  fi\n' +
    '  return 0\n' +
    '}\n'

  // Releasing what the record claims. Only what still matches the record is
  // released: a proxy setting someone else has since taken over is left
  // exactly as it is, and what this plugin displaced goes back the way it
  // was found.
  readonly property string systemProxyOffScript:
    proxyStatePath + proxyStateScript +
    'readstate || exit 0\n' +
    'readenv\n' +
    'ourhost=${s_endpoint%:*}; ourport=${s_endpoint##*:}\n' +
    'bare=${ourhost#[}; bare=${bare%]}\n' +
    'if [ "$haveg" = 1 ]; then\n' +
    '  cmode=$(gsettings get org.gnome.system.proxy mode 2>/dev/null | tr -d "\'")\n' +
    '  chost=$(gsettings get org.gnome.system.proxy.socks host 2>/dev/null | tr -d "\'")\n' +
    '  cport=$(gsettings get org.gnome.system.proxy.socks port 2>/dev/null)\n' +
    '  if [ "$cmode" = manual ] && [ "$chost" = "$bare" ] && [ "$cport" = "$ourport" ]; then\n' +
    '    restore_gsettings || { echo "could not put the desktop proxy setting back" >&2; exit 1; }\n' +
    '  elif [ "$cmode" != none ]; then\n' +
    '    echo "the desktop proxy setting is no longer the one this plugin made; left alone" >&2\n' +
    '  fi\n' +
    'fi\n' +
    'socks="socks5h://$ourhost:$ourport"; web="http://$ourhost:$ourport"\n' +
    'mine=1\n' +
    'for pair in "all_proxy $socks" "ALL_PROXY $socks" "http_proxy $web" "HTTP_PROXY $web" "https_proxy $web" "HTTPS_PROXY $web"; do\n' +
    '  v=${pair%% *}; want=${pair#* }; cur=$(envget "$v")\n' +
    '  [ -z "$cur" ] || [ "$cur" = "$want" ] || mine=0\n' +
    'done\n' +
    'if [ "$mine" = 1 ]; then\n' +
    '  restore_env || { echo "could not put the proxy environment back" >&2; exit 1; }\n' +
    'else\n' +
    '  echo "the proxy environment is no longer the one this plugin set; left alone" >&2\n' +
    'fi\n' +
    'rm -f -- "$statefile"\n' +
    'sync -- "$statedir" 2>/dev/null\n' +
    'exit 0\n'

  // Observe desktop host egress, not a private engine proxy. Curl config and
  // inherited proxies are disabled. Admission checks the runtime generation
  // and fresh capture state again after this bounded HTTPS request.
  function lookupIp() {
    if (ipProcess.running || !up || egressTransitionBusy || ipLookupUrl === "") return
    ipLoading = true
    ipError = ""
    egressRefreshPending = false
    exitLastAttemptAt = Date.now()
    ipProcess.gen = ipGen
    ipProcess.runtimeGeneration = runtimeGeneration
    ipProcess.command = capped(10, 65536, ["/usr/bin/curl", "-q", "-4", "-sS", "--fail", "--noproxy", "*", "--proxy", "",
                                           "--connect-timeout", "2", "--max-time", "4",
                                           "--proto", "=https", "--max-redirs", "0", "--max-filesize", "65536",
                                           "--write-out", "\nSVPN_HTTPS_CONNECT_SECONDS:%{time_appconnect}\n",
                                           ipLookupUrl])
    ipProcess.running = true
  }

  // A lookup fired right after connect can lose the race against the tunnel
  // bring-up (handshake still completing, routes not yet in place). Bounded
  // retry: two more attempts after one then three seconds.
  property int ipRetries: 0
  function lookupIpWithRetry() {
    ipRetries = 0
    egressRefreshPending = true
    ipRefreshTimer.restart()
  }

  function testSavedConnection(entry) {
    if (!entry || connectionTestPending) return
    if (entry.kind === "tailscale" || entry.kind === "headscale") {
      connectionTestMessage = "Private network test requires an authenticated connection and a reachable private service assigned to an application. A public IP check cannot verify this provider."
      return
    }
    var scope = runtimeScope(applicationDefaultScope)
    var state = scope && scope.effective
    var target = state && state.state === "assigned" ? (state.public_target || state) : null
    if (!up || !target || target.provider !== entry.id) {
      connectionTestMessage = "Select this provider and a server as Default VPN, then Connect to test. Test never changes your route."
      return
    }
    if (egressTransitionBusy || ipProcess.running) {
      connectionTestMessage = "A route change or IP check is running. Try Test again in a moment."
      return
    }
    if (ipLookupUrl === "") { connectionTestMessage = "Choose a supported HTTPS IP lookup service in plugin settings before testing."; return }
    connectionTestProvider = target.provider
    connectionTestLocation = target.location || ""
    connectionTestGeneration = runtimeGeneration
    connectionTestPending = true
    connectionTestMessage = "Testing " + activeName + (connectionTestLocation ? " · " + connectionTestLocation : "") + "…"
    ipRetries = 2  // One explicit test; no implicit retry or route change.
    lookupIp()
  }

  function finishConnectionTest(info) {
    if (!connectionTestPending) return
    connectionTestPending = false
    var scope = runtimeScope(applicationDefaultScope)
    var state = scope && scope.effective
    var target = state && state.state === "assigned" ? (state.public_target || state) : null
    if (!up || runtimeGeneration !== connectionTestGeneration || !target
        || target.provider !== connectionTestProvider || (target.location || "") !== connectionTestLocation) {
      connectionTestMessage = "Connection changed during the test. No result accepted."
      return
    }
    connectionTestMessage = info ? "HTTPS reached through " + activeName + (connectionTestLocation ? " · " + connectionTestLocation : "") + ": " + info.ip + " · " + info.httpsLatencyMs + " ms DNS/TCP/TLS setup. This does not test private services."
                                 : "HTTPS egress test did not complete for the selected default route. No route was changed."
  }

  function refreshHostEgress() {
    if (!panelOpen || !up || egressTransitionBusy || ipProcess.running) return
    if (egressRefreshPending || Date.now() - exitLastAttemptAt >= 30000) lookupIp()
  }

  function copyExitIp() {
    if (exitIp === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(exitIp) + " | wl-copy"])
    note("Copied " + exitIp)
  }

  // The queue holds state transitions, not a log of clicks, so a new
  // transition replaces any pending one that it makes obsolete rather than
  // stacking behind it: hammering a switch must not leave changes queued up
  // to replay a state the last click already abandoned. One entry per group
  // is all that can ever be waiting, and the hard cap makes that bound a
  // property of the code rather than a consequence of the grouping table
  // being complete.
  readonly property var actionGroups: ({
    "proxy-off": "proxy"
  })
  readonly property int maxQueuedActions: 8

  property var actionQueue: []

  function actionGroup(kind) {
    var group = actionGroups[String(kind)]
    return group === undefined ? String(kind) : group
  }

  function runAction(command, kind) {
    var group = actionGroup(kind)
    var queue = []
    for (var i = 0; i < actionQueue.length; i++) {
      if (actionGroup(actionQueue[i].kind) !== group) queue.push(actionQueue[i])
    }
    queue.push({ command: command, kind: kind })
    while (queue.length > maxQueuedActions) queue.shift()
    actionQueue = queue
    drainActions()
  }

  function drainActions() {
    if (actionProcess.running || actionQueue.length === 0) return
    var queue = actionQueue.slice()
    var next = queue.shift()
    actionQueue = queue
    actionProcess.kind = next.kind
    actionProcess.command = next.command
    actionProcess.running = true
  }

  // ---- wiring -------------------------------------------------------------

  Component.onCompleted: {
    // passiveMode (tests/ui/runtime) loads this REAL service against a fake
    // transport only: no host probe, no systemctl, no sudo helper call, no
    // window scan — nothing host-facing is ever touched from a test.
    if (passiveMode) return
    refresh()
  }

  function readConfig() {
    if (configProcess.running) {
      configDebounce.restart()
      return
    }
    if (!Model.isAbsolutePath(configPath)) {
      var invalid = Model.parseConfig("")
      invalid.error = "config path must be absolute"
      config = invalid
      return
    }
    // First line: the file size (or -1). Content follows only when the file
    // fits the read cap, so a too-large config is reported as such instead
    // of parsing truncated JSON into a silently short catalog.
    configProcess.command = capped(10, 2097200, ["bash", "-c",
      'size=$(stat -c %s -- "$1" 2>/dev/null) || size=-1\n' +
      'printf "%s\\n" "$size"\n' +
      '[ "$size" -ge 0 ] && [ "$size" -le 2097152 ] && head -c 2097152 -- "$1"\n',
      "_", configPath])
    configProcess.running = true
  }

  Timer {
    id: configDebounce
    interval: 200
    repeat: false
    onTriggered: root.readConfig()
  }

  Process {
    id: configProcess
    running: false
    command: []
    stdout: StdioCollector { id: configStdout; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      // The read emits the file size on the first line, so a config past the
      // byte cap is reported as such — a truncated JSON parse must never be
      // mistaken for "no locations". The size line is the authority: the
      // reader exits nonzero precisely when the file is oversized (the `&&`
      // chain fails after printing the size), so the exit code alone must
      // never downgrade an oversized config to "empty or missing".
      root.config = Model.configReadResult(String(configStdout.text || ""), exitCode, 2097152)
    }
  }

  // The Timer below handles the ordinary refresh cadence.
  Timer {
    interval: root.refreshIntervalSec * 1000
    running: !root.passiveMode
    repeat: true
    triggeredOnStart: false
    onTriggered: root.refresh()
  }

  // The action deadline owns the busy flag as a last resort: the completion
  // path clears it first, this only bounds a wedged action.
  Timer {
    id: busyWatchdog
    interval: (root.actionTimeout + 15) * 1000
    repeat: false
    onTriggered: if (root.busy) {
      root.busy = false
      root.actionQueue = []
      root.lastError = "The last operation did not finish in time."
    }
  }

  Timer {
    id: noteTimer
    interval: 4000
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  // After switching nodes the tunnel needs a moment to rebuild before the new
  // exit address is answerable.
  Timer {
    id: ipRefreshTimer
    interval: 350
    repeat: false
    onTriggered: {
      root.lookupIp()
    }
  }

  Timer {
    interval: 1700  // Avoid lockstep with the one-second guard status poll.
    repeat: true
    running: root.panelOpen && root.up && !root.passiveMode
    onTriggered: root.refreshHostEgress()
  }

  Process {
    id: probeProcess
    running: false
    command: []
    stdout: StdioCollector { id: probeStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.applyProbe(String(probeStdout.text || ""), exitCode)
    }
  }

  Process {
    id: ipProcess
    property int gen: 0
    property var runtimeGeneration: null
    running: false
    command: []
    stdout: StdioCollector { id: ipStdout; waitForEnd: true }
    stderr: StdioCollector { id: ipStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.ipLoading = false
      // A switch or a reconnect bumped the generation since this lookup was
      // launched: the answer describes an exit that is no longer selected,
      // so it is dropped instead of drawn.
      if (gen !== root.ipGen || runtimeGeneration !== root.runtimeGeneration || !root.up) { root.finishConnectionTest(null); return }
      if (root.egressTransitionBusy) { root.egressRefreshPending = true; root.finishConnectionTest(null); return }
      var info = exitCode === 0 ? Model.parseHostEgressProbe(String(ipStdout.text || "")) : null
      root.finishConnectionTest(info)
      if (info) {
        root.exitIp = info.ip
        root.exitLocation = info.location
        root.exitOrg = info.org
        root.ipError = ""
        root.exitObservedAt = Date.now()
        root.httpsLatencyMs = info.httpsLatencyMs
      } else {
        root.exitIp = ""
        root.exitLocation = ""
        root.exitOrg = ""
        root.exitObservedAt = 0
        root.httpsLatencyMs = -1
        root.ipError = exitCode === 0 ? "Exit address lookup returned nothing"
                                      : "Host egress check failed; capture status is separate"
        if (root.up && root.ipRetries < 2) {
          root.ipRetries++
          ipRetryTimer.interval = root.ipRetries === 1 ? 1000 : 3000
          ipRetryTimer.restart()
        }
      }
    }
  }

  // Exit lookup retry: one then three seconds after failure, if still up.
  Timer {
    id: ipRetryTimer
    interval: 1000
    repeat: false
    onTriggered: if (root.up) { root.egressRefreshPending = true; root.lookupIp() }
  }

  // The connections client: one bounded request JSON on its stdin (never
  // argv), one bounded response on stdout. Exit codes: 0 the helper
  // answered, 2 unreachable (not installed / not authorized), 3 bad input,
  // 4 contract violation. The client's own JSON error envelopes carry the
  // same meaning, so the response parse is authoritative either way.
  Process {
    id: connectionsProcess
    running: false
    command: []
    stdout: StdioCollector { id: connectionsStdout; waitForEnd: true }
    stderr: StdioCollector { id: connectionsStderr; waitForEnd: true }
    onStarted: {
      if (connectionsPendingInput !== "") {
        connectionsProcess.write(connectionsPendingInput)
        connectionsPendingInput = ""
      }
      connectionsProcess.stdinEnabled = false
    }
    onExited: function(exitCode) {
      var action = root.connectionsAction
      var expected = root.connectionsRequestId
      root.connectionsAction = ""
      root.connectionsRequestId = ""
      var parsed = Model.parseConnectionsResponse(String(connectionsStdout.text || ""), expected)
      // The process outcome owns completion: a nonzero child exit is never
      // ignored just because its stdout carried an ok body. Exit codes are
      // the client contract: 2 unreachable, 3 bad input, 4 contract.
      var exitOk = exitCode === 0
      if (!exitOk) {
        var code = exitCode === 2 ? "helper-unavailable" : (exitCode === 3 ? "input" : "contract")
        var message = parsed.ok
          ? "the connections client exited nonzero with a success body — refused"
          : (parsed.error !== "" ? parsed.error
             : "the connections client failed (exit " + exitCode + ")")
        if (root.connectionsPaging) {
          root.finishPagedList({ action: "fail", message: message })
          return
        }
        root.connectionsState = code === "helper-unavailable" ? "unavailable" : "error"
        root.connectionsError = message
        if (code === "helper-unavailable") root.connectionsCatalog = null
        root.connectionsResponse(action, false,
                                 { ok: false, requestId: expected, revision: parsed.revision,
                                   revisionKnown: parsed.revisionKnown, data: null,
                                   error: message, errorCode: code })
        return
      }
      // A completed (exit-zero) response with an authoritative revision
      // refreshes the CAS token — including a genuine reset to 0 for an
      // empty store. Unknown revisions leave the last known value alone.
      if (parsed.revisionKnown) {
        root.connectionsRevision = parsed.revision
        root.connectionsRevisionKnown = true
        root.runtimeCatalogRevision = parsed.revision
        Qt.callLater(root.refreshRuntime)
      }
      if (action === "list") {
        if (root.connectionsPaging) {
          root.applyPagedOutcome(parsed, true, exitCode)
          return
        }
        if (parsed.ok) {
          var data = parsed.data
          if (data && data.complete === false) {
            // Defensive: an unpaged reply that claims incompleteness enters
            // the same bounded planner as any first page (its rows are part
            // of the catalog and must not be dropped, and its shape,
            // offset and progress claims are validated like any page's).
            root.startPagedFromFirstPage(parsed, true, exitCode)
            return
          }
          // An authoritative listing has landed and PARSED: the conflict
          // chapter is acknowledged (the flag held from the refused
          // mutation until exactly this refresh). A malformed catalog is
          // not an acknowledgment.
          root.connectionsCatalog = Model.parseConnectionsCatalog(data)
          if (root.connectionsCatalog === null) {
            // A malformed catalog is a FAILED listing: it emits failure
            // instead of masquerading as a successful completion, so the
            // panel never draws junk and the UI sees the error.
            root.connectionsState = "error"
            root.connectionsError = "the connections list is not in the expected shape"
            root.connectionsCatalog = null
            root.connectionsResponse(action, false,
                                     { ok: false, requestId: expected, revision: parsed.revision,
                                       revisionKnown: parsed.revisionKnown, data: null,
                                       error: root.connectionsError, errorCode: "listing" })
            return
          }
          root.connectionsConflict = false
          // Schema-valid successful completion owns the ordinary state:
          // ready, with any prior error cleared.
          root.connectionsState = "ready"
          root.connectionsError = ""
        } else if (parsed.errorCode === "response-too-large") {
          // The documented scalable protocol: fetch the catalog in
          // explicit pages instead of one over-cap response.
          root.startPagedList()
          return
        } else {
          root.connectionsState = "error"
          root.connectionsError = parsed.error
        }
      } else if (!parsed.ok) {
        root.connectionsState = parsed.errorCode === "helper-unavailable" ? "unavailable" : "error"
        root.connectionsError = parsed.error
        // A revision conflict on a mutation: record it and schedule ONE
        // authoritative refresh. The scheduled read cannot interleave this
        // handler, and the mutation itself is NEVER retried automatically.
        if (parsed.errorCode === "revision-conflict") {
          root.connectionsConflict = true
          Qt.callLater(function() { root.refreshConnections() })
        }
      } else {
        // A successful mutation: the conflict chapter is over.
        root.connectionsConflict = false
      }
      root.connectionsResponse(action, parsed.ok, parsed)
    }
  }

  // systemctl and the scripts, one at a time. Nothing that runs here ever
  // sees the API secret. A failed step cancels everything queued behind it —
  // queued actions depend on their predecessor having happened.
  Process {
    id: actionProcess
    property string kind: ""
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var kind = actionProcess.kind
      if (exitCode !== 0) {
        var message = Model.elide(String(actionStderr.text || ""), 160).trim()
        if (exitCode === 124) message = "Timed out: " + kind
        root.lastError = message !== "" ? message : ("Command failed: " + kind)
        // The completion of this action — not any poll — owns the state.
        root.busy = false
        root.actionQueue = []
      } else {
        if (kind === "start" || kind === "stop" || kind === "restart") {
          root.busy = false
          root.lastError = ""
          if (kind !== "stop" && root.up) root.lookupIpWithRetry()
        }
      }
      root.probe()
      if (exitCode === 0) root.drainActions()
    }
  }

}
