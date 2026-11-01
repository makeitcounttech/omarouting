// Pure parsing and formatting helpers for the sing-box VPN plugin.
//
// Two external shapes are parsed here: the sing-box config file (to learn the
// proxy address, the Clash API endpoint, and the outbound list without asking
// the daemon, so the panel is useful while the tunnel is down) and the Clash
// API's JSON responses. Both are treated as untrusted: a malformed or
// unexpected shape degrades to an empty result rather than throwing, because
// the config is hand-edited and the API surface varies between sing-box builds.

function expandHome(path, home) {
  var p = String(path || "")
  if (p.indexOf("~/") === 0) return String(home || "") + p.substring(1)
  return p
}

// Every string that arrives from outside — the config file, the Clash API,
// the exit-address lookup — passes through here before it is stored. Control
// characters go, angle brackets go (a Qt Text in AutoText mode would render
// "<b>" as markup, and not every sink is ours to set to PlainText), and the
// length is capped so a hostile value cannot balloon a label or a model.
var MAX_TEXT = 128
var MAX_TAG = 253
var MAX_NODES = 10000
var MAX_OTHER_TARGETS = 128
var MAX_INBOUNDS = 64

function safeText(value, max) {
  var limit = Number(max) || MAX_TEXT
  var v = String(value === undefined || value === null ? "" : value)
    .replace(/[\x00-\x1f\x7f-\x9f<>]/g, "")
    .replace(/\s+/g, " ")
    .trim()
  return v.length > limit ? v.substring(0, limit) : v
}

// A tag is only ever used exactly as the config and the Clash API spell it.
// A tag with control characters or one longer than 253 bytes cannot match
// what the API reports, so it is rejected outright — never truncated into a
// different tag that looks valid but selects nothing.
function validTag(value) {
  var v = String(value === undefined || value === null ? "" : value)
  return v.length > 0 && v.length <= MAX_TAG && !/[\x00-\x1f\x7f]/.test(v)
}

// The raw form of an untrusted tag: returned byte-for-byte, or "" when it is
// not a valid tag. Never shortened, never cleaned up into a near miss.
function rawTag(value) {
  var v = String(value === undefined || value === null ? "" : value)
  return validTag(v) ? v : ""
}

// A listen address or server name: something curl or Chromium can be handed
// as a host without it doubling as an option or a second line.
function isHostText(value) {
  return /^[A-Za-z0-9.\-:\[\]_]{1,253}$/.test(String(value || ""))
}

function isAbsolutePath(path) {
  return String(path || "").indexOf("/") === 0
}

// JSON.parse in Qt's engine refuses nesting deeper than 1024 levels and throws,
// so depth is bounded before any of this code sees the value; the caps above
// bound the item counts and string lengths that come out of it.
function json(text) {
  try {
    var v = JSON.parse(String(text || ""))
    return v && typeof v === "object" ? v : null
  } catch (e) {
    return null
  }
}

// ---- formatting ---------------------------------------------------------

function formatBytes(value) {
  var b = Number(value)
  if (!isFinite(b) || b < 0) b = 0
  var units = ["B", "KB", "MB", "GB", "TB"]
  var i = 0
  while (b >= 1024 && i < units.length - 1) {
    b /= 1024
    i++
  }
  var digits = i === 0 ? 0 : (b >= 100 ? 0 : (b >= 10 ? 1 : 2))
  return b.toFixed(digits) + " " + units[i]
}

function formatRate(bytesPerSecond) {
  return formatBytes(bytesPerSecond) + "/s"
}

function formatDuration(seconds) {
  var t = Number(seconds)
  if (!isFinite(t) || t < 0) t = 0
  t = Math.floor(t)
  var d = Math.floor(t / 86400)
  var h = Math.floor((t % 86400) / 3600)
  var m = Math.floor((t % 3600) / 60)
  var s = t % 60
  var pad = function(n) { return n < 10 ? "0" + n : String(n) }
  if (d > 0) return d + "d " + h + "h"
  if (h > 0) return h + "h " + pad(m) + "m"
  if (m > 0) return m + "m " + pad(s) + "s"
  return s + "s"
}

// Hiddify writes ordering and visibility markers into outbound tags. They are
// part of the tag (so every API call must use the raw form) but they are noise
// on screen, so display strips them.
function displayName(tag) {
  return safeText(String(tag || "")
    .replace(/§hide§/g, "")
    .replace(/\s*§\s*\d+\s*$/, ""))
}

function isHiddenTag(tag) {
  return String(tag || "").indexOf("§hide§") >= 0
}

function elide(text, max) {
  var value = String(text || "").replace(/\s+/g, " ").trim()
  var limit = Number(max) || 0
  if (limit <= 1 || value.length <= limit) return value
  return value.substring(0, limit - 1) + "…"
}

// ---- sing-box config ----------------------------------------------------

// Outbound types that are plumbing rather than a place traffic can exit from.
var LOCAL_OUTBOUNDS = ["direct", "block", "dns"]
var GROUP_OUTBOUNDS = ["selector", "urltest"]

function normalizeSelectorMembers(list) {
  var out = []
  if (!Array.isArray(list)) return out
  for (var i = 0; i < list.length && out.length < 65536; i++) {
    var value = rawTag(list[i])
    if (value === "") continue
    if (out.indexOf(value) < 0) out.push(value)
  }
  return out
}

// A prototype-less membership set for the selector's members, so a catalog
// of thousands of locations is checked in O(1) and a tag is never
// misclassified for being past any list cap.
function memberSet(members) {
  var set = Object.create(null)
  if (!Array.isArray(members)) return set
  for (var i = 0; i < members.length; i++) set[members[i]] = true
  return set
}

// The VPN selector is the one tagged exactly "vpn", and only when it lists
// its members. An urltest, a group with another name, or "the first group in
// the config" is somebody else's routing decision; picking one arbitrarily
// would aim app rules and connection cleanup at the wrong chain. No match
// means no selector, and the panel says so.
function pickVpnSelector(candidates) {
  if (!Array.isArray(candidates)) return { tag: "", members: [], interrupts: false }
  for (var i = 0; i < candidates.length; i++) {
    var c = candidates[i]
    if (c && c.tag === "vpn" && Array.isArray(c.members) && c.members.length > 0) return c
  }
  return { tag: "", members: [], interrupts: false }
}

function addNode(list, entry, selectorMembers, index) {
  if (!entry || typeof entry !== "object") return false
  var nodeType = safeText(entry.type, 32)
  if (GROUP_OUTBOUNDS.indexOf(nodeType) >= 0) return false
  if (LOCAL_OUTBOUNDS.indexOf(nodeType) >= 0) return false
  var rawTagValue = rawTag(entry.tag)
  if (rawTagValue === "") return false
  if (selectorMembers && selectorMembers.length > 0 && selectorMembers.indexOf(rawTagValue) < 0) return false
  if (isHiddenTag(rawTagValue)) return false

  var serverHost = safeText(entry.server || "", 253)
  var serverPort = parseInt(entry.server_port, 10) || 0
  if (nodeType === "wireguard" || nodeType === "tailscale") {
    if (serverHost === "" && Array.isArray(entry.peers) && entry.peers.length > 0) {
      var peer = entry.peers[0]
      serverHost = safeText(peer && peer.address || "", 253)
      serverPort = parseInt(peer && peer.port, 10) || serverPort
    }
  }

  var metadata = {
    controlServer: safeText(entry.control_server || entry.controlServer || "", 253),
    privateNetwork: safeText(entry.private_network || entry.privateNetwork || "", 253),
    exitNode: entry.exit_node === true || entry.exitNode === true || false
  }
  if (nodeType === "wireguard" && Array.isArray(entry.peers) && entry.peers.length > 0) {
    var peerMeta = entry.peers[0] || {}
    metadata.identity = safeText(peerMeta.public_key || peerMeta.identity || "", 64)
    if (metadata.privateNetwork === "") metadata.privateNetwork = safeText(peerMeta.private_key || peerMeta.privateNetwork || "", 253)
  }
  if (nodeType === "tailscale" && entry.peer !== undefined && entry.peer !== null && typeof entry.peer === "object") {
    metadata.identity = safeText(entry.peer.publicKey || entry.peer.identity || "", 64)
  }

  if (list.length >= MAX_NODES) return false
  list.push({
    tag: rawTagValue,
    name: displayName(rawTagValue),
    type: nodeType,
    server: isHostText(serverHost) ? serverHost : "",
    port: serverPort > 0 && serverPort <= 65535 ? serverPort : 0,
    index: index,
    metadata: metadata
  })
  return true
}

function parseConfig(text) {
  var out = {
    ok: false,
    error: "",
    // Set when the config declares more locations than the bounded catalog
    // keeps. Surfaced as a visible warning — never silently dropped.
    truncationWarning: "",
    proxyHost: "",
    proxyPort: 0,
    controller: "",
    selector: "",
    // Preferred backend shape: the selector itself tears down its old
    // connections on a switch. Detected from the config, and never trusted
    // on its own — the plugin still scopes-closes stale connections itself
    // after a verified switch, because sing-box 1.13.19 selector
    // NewConnectionEx paths can bypass interruptGroup tracking.
    selectorInterrupts: false,
    nodes: [],
    // Standalone outbounds/endpoints outside the selector's member list:
    // wireguard, tailscale, socks, http, … — assignable per app, and drawn
    // in the picker separately from the default selector members.
    otherTargets: [],
    // A config that sets the desktop proxy itself would fight the panel's own
    // system-proxy switch, so the panel surfaces it rather than silently
    // disagreeing about who owns that setting.
    systemProxyInConfig: false
  }

  var raw = String(text || "").trim()
  if (raw === "") {
    out.error = "config file is empty or missing"
    return out
  }
  var cfg = json(raw)
  if (!cfg) {
    out.error = "config file is not valid JSON"
    return out
  }

  var inbounds = Array.isArray(cfg.inbounds) ? cfg.inbounds : []
  var preferred = false
  for (var i = 0; i < inbounds.length && i < MAX_INBOUNDS; i++) {
    var ib = inbounds[i]
    if (!ib || typeof ib !== "object") continue
    var type = String(ib.type || "")
    if (type !== "mixed" && type !== "socks" && type !== "http") continue
    if (ib.set_system_proxy === true) out.systemProxyInConfig = true
    var host = ib.listen === undefined || ib.listen === null || ib.listen === "" ? "127.0.0.1" : String(ib.listen)
    var port = parseInt(ib.listen_port, 10) || 0
    if (port <= 0 || port > 65535 || !isHostText(host)) continue
    // Prefer the IPv4 loopback listener: it is the address every client
    // understands, and "::1" breaks tools that do not bracket IPv6 hosts.
    if (host === "127.0.0.1") {
      out.proxyHost = host
      out.proxyPort = port
      preferred = true
    } else if (!preferred && out.proxyPort === 0) {
      out.proxyHost = host
      out.proxyPort = port
    }
  }

  var experimental = cfg.experimental && typeof cfg.experimental === "object" ? cfg.experimental : {}
  var api = experimental.clash_api && typeof experimental.clash_api === "object" ? experimental.clash_api : {}
  out.controller = safeText(api.external_controller, 64)
  // Control credentials are intentionally omitted from the desktop projection.

  var selectorCandidates = []
  var outbounds = Array.isArray(cfg.outbounds) ? cfg.outbounds : []
  var endpoints = Array.isArray(cfg.endpoints) ? cfg.endpoints : []

  for (var j = 0; j < outbounds.length && selectorCandidates.length < 32; j++) {
    var ob = outbounds[j]
    if (!ob || typeof ob !== "object") continue
    var obType = safeText(ob.type, 32)
    var obTag = rawTag(ob.tag)
    if (obTag === "") continue
    if (GROUP_OUTBOUNDS.indexOf(obType) >= 0) {
      var members = normalizeSelectorMembers(ob.outbounds)
      selectorCandidates.push({ tag: obTag, members: members, interrupts: ob.interrupt_exist_connections === true })
    }
  }
  for (var k = 0; k < endpoints.length && selectorCandidates.length < 64; k++) {
    var ep = endpoints[k]
    if (!ep || typeof ep !== "object") continue
    var epType = safeText(ep.type, 32)
    var epTag = rawTag(ep.tag)
    if (epTag === "") continue
    if (GROUP_OUTBOUNDS.indexOf(epType) >= 0) {
      var epMembers = normalizeSelectorMembers(ep.outbounds)
      selectorCandidates.push({ tag: epTag, members: epMembers, interrupts: ep.interrupt_exist_connections === true })
    }
  }

  var selected = pickVpnSelector(selectorCandidates)
  out.selector = selected.tag
  out.selectorInterrupts = selected.interrupts === true
  if (out.selector === "") {
    out.error = "no selector tagged \"vpn\" with a member list — the config must declare one"
    return out
  }
  var selectorMembers = selected.members
  var inSelector = memberSet(selectorMembers)

  var eligible = 0
  for (var b = 0; b < outbounds.length; b++) {
    var ob2 = outbounds[b]
    if (!ob2 || typeof ob2 !== "object") continue
    var t2 = safeText(ob2.type, 32)
    if (GROUP_OUTBOUNDS.indexOf(t2) >= 0 || LOCAL_OUTBOUNDS.indexOf(t2) >= 0) continue
    var g2 = rawTag(ob2.tag)
    if (g2 === "" || isHiddenTag(g2)) continue
    if (inSelector[g2] === true) {
      eligible++
      if (out.nodes.length < MAX_NODES) addNode(out.nodes, ob2, null, b)
      continue
    }
    // Not a selector member: a standalone endpoint. Assignable per app.
    if (out.otherTargets.length < MAX_OTHER_TARGETS) addNode(out.otherTargets, ob2, null, b)
    else out.truncationWarning = "more than " + MAX_OTHER_TARGETS + " standalone endpoints — the picker list is truncated"
  }
  for (var e = 0; e < endpoints.length; e++) {
    var ep2 = endpoints[e]
    if (!ep2 || typeof ep2 !== "object") continue
    var t3 = safeText(ep2.type, 32)
    if (GROUP_OUTBOUNDS.indexOf(t3) >= 0 || LOCAL_OUTBOUNDS.indexOf(t3) >= 0) continue
    var g3 = rawTag(ep2.tag)
    if (g3 === "" || isHiddenTag(g3)) continue
    if (inSelector[g3] === true) {
      eligible++
      if (out.nodes.length < MAX_NODES) addNode(out.nodes, ep2, null, e)
      continue
    }
    if (out.otherTargets.length < MAX_OTHER_TARGETS) addNode(out.otherTargets, ep2, null, e)
    else out.truncationWarning = "more than " + MAX_OTHER_TARGETS + " standalone endpoints — the picker list is truncated"
  }
  if (out.nodes.length >= MAX_NODES && eligible > MAX_NODES) {
    out.nodesTruncated = true
    out.truncationWarning = "location catalog truncated at " + MAX_NODES
      + " entries — the rest are hidden; use search, but some locations are not selectable"
  }

  out.ok = out.proxyPort > 0 || out.nodes.length > 0
  if (!out.ok) out.error = "no proxy inbound or outbound found in the config"
  return out
}

// A config that cannot be read at all (for example past the 2 MiB read cap)
// must say so visibly rather than presenting an empty catalog as the truth.
function configTooLarge(size, cap) {
  var out = parseConfig("")
  out.error = "config file is " + (size > 0 ? size + " bytes" : "unreadable")
    + " — over the " + Math.round(cap / 1048576) + " MiB read cap; no locations are shown"
  return out
}

// The decision for the capped config read in Service.qml. The reader prints
// the file size on the first line and emits content only when it fits the
// cap; the `&&` chain also means an OVERSIZED file exits nonzero. The size
// line is therefore the authority: an oversized config must be reported as
// too large even when the exit code is nonzero, and never silently parsed
// as "empty or missing". Text is the full collected stdout, exitCode the
// reader process's status, cap the byte cap both sides agree on.
function configReadResult(text, exitCode, cap) {
  var s = String(text || "")
  var nl = s.indexOf("\n")
  var size = nl >= 0 ? parseInt(s.substring(0, nl), 10) : -1
  var body = nl >= 0 ? s.substring(nl + 1) : ""
  if (nl >= 0 && size > 0 && size > cap) return configTooLarge(size, cap)
  if (exitCode !== 0 || size < 0 || (size > 0 && body === "")) return parseConfig("")
  return parseConfig(body)
}

function nodeByTag(nodes, tag) {
  var list = Array.isArray(nodes) ? nodes : []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].tag === tag) return list[i]
  }
  return null
}

// The only places the exit-address lookup is ever sent.
var IP_LOOKUP_SERVICES = {
  "ipinfo.io": "https://ipinfo.io/json",
  "ifconfig.co": "https://ifconfig.co/json",
  "ipwho.is": "https://ipwho.is/",
  "api.ipify.org": "https://api.ipify.org/?format=json"
}

function ipLookupUrl(choice) {
  return IP_LOOKUP_SERVICES[String(choice || "").trim()] || ""
}

function parseIpInfo(text) {
  var d = json(text)
  if (!d) return null
  var ip = safeText(d.ip || d.query, 64)
  if (ip === "") return null
  var city = safeText(d.city, 64)
  var country = safeText(d.country || d.country_code || d.country_iso, 64)
  var parts = []
  if (city !== "") parts.push(city)
  if (country !== "") parts.push(country)
  var connection = d.connection && typeof d.connection === "object" ? d.connection : {}
  return {
    ip: ip,
    location: parts.join(", "),
    org: safeText(d.org || d.asn_org || connection.org || d.asn)
  }
}

// The desktop probe explicitly uses IPv4 and never an engine proxy/API.
function parseHostEgress(text) {
  var info = parseIpInfo(text)
  if (!info || !/^\d{1,3}(\.\d{1,3}){3}$/.test(info.ip)) return null
  var octets = info.ip.split(".")
  for (var i = 0; i < octets.length; i++) if (Number(octets[i]) > 255) return null
  return info
}

function parseHostEgressProbe(text) {
  var marker = "\nSVPN_HTTPS_CONNECT_SECONDS:"
  var offset = text.lastIndexOf(marker)
  if (offset < 0) return null
  var elapsed = text.slice(offset + marker.length).trim()
  if (!/^\d+(\.\d+)?$/.test(elapsed)) return null
  var seconds = Number(elapsed)
  var info = parseHostEgress(text.slice(0, offset))
  if (!info || !isFinite(seconds) || seconds <= 0 || seconds > 6) return null
  info.httpsLatencyMs = Math.round(seconds * 1000)
  return info
}

function parseCaptureTelemetry(raw) {
  if (!raw || typeof raw !== "object" || typeof raw.session_id !== "string" || !/^[0-9a-f]{64}$/.test(raw.session_id)) return null
  var fields = ["sampled_at_ms", "uptime_seconds", "download_bytes", "upload_bytes"]
  for (var i = 0; i < fields.length; i++) if (!isSafeRevision(raw[fields[i]])) return null
  return {session_id:raw.session_id, sampled_at_ms:raw.sampled_at_ms,
    uptime_seconds:raw.uptime_seconds, download_bytes:raw.download_bytes, upload_bytes:raw.upload_bytes}
}

function parseScopeTelemetry(raw) {
  if (raw === null || raw === undefined) return null
  if (!raw || typeof raw !== "object" || ["available", "partial"].indexOf(raw.state) < 0
      || typeof raw.session_id !== "string" || !/^[0-9a-f]{64}$/.test(raw.session_id)
      || ["fresh", "stale", "unavailable", "not-applicable"].indexOf(raw.exit_ip_state) < 0) return null
  var fields = ["sampled_at_ms", "uptime_seconds", "download_bytes", "upload_bytes"]
  for (var i = 0; i < fields.length; i++) if (!isSafeRevision(raw[fields[i]])) return null
  var optionalNumbers = ["download_rate_bps", "upload_rate_bps", "https_latency_ms"]
  for (var j = 0; j < optionalNumbers.length; j++)
    if (raw[optionalNumbers[j]] !== null && !isSafeRevision(raw[optionalNumbers[j]])) return null
  var address = raw.exit_ip === null ? null : safeText(raw.exit_ip, 64)
  if (address !== null && !/^[0-9A-Fa-f:.]{2,64}$/.test(address)) return null
  if ((raw.exit_ip_state === "fresh" || raw.exit_ip_state === "stale") !== (address !== null)) return null
  return {state:raw.state, session_id:raw.session_id, sampled_at_ms:raw.sampled_at_ms,
    uptime_seconds:raw.uptime_seconds, download_bytes:raw.download_bytes,
    upload_bytes:raw.upload_bytes, download_rate_bps:raw.download_rate_bps,
    upload_rate_bps:raw.upload_rate_bps, exit_ip:address,
    exit_ip_state:raw.exit_ip_state, https_latency_ms:raw.https_latency_ms}
}

function scopeTelemetrySummary(telemetry) {
  if (!telemetry) return "Tunnel data unavailable"
  var address = telemetry.exit_ip || (telemetry.exit_ip_state === "not-applicable" ? "not applicable" : "unavailable")
  if (telemetry.exit_ip_state === "stale") address += " (stale)"
  var down = formatBytes(telemetry.download_bytes)
  var up = formatBytes(telemetry.upload_bytes)
  if (telemetry.download_rate_bps !== null) down += " · " + formatRate(telemetry.download_rate_bps)
  if (telemetry.upload_rate_bps !== null) up += " · " + formatRate(telemetry.upload_rate_bps)
  var latency = telemetry.https_latency_ms === null ? "unavailable" : telemetry.https_latency_ms + " ms"
  return "Exit IP: " + address
    + "\nReceived: " + down
    + "\nSent: " + up
    + "\nHTTPS latency: " + latency + " · Uptime: " + formatDuration(telemetry.uptime_seconds)
}

function captureRates(previous, current) {
  if (!previous || !current || previous.session_id !== current.session_id
      || current.sampled_at_ms <= previous.sampled_at_ms
      || current.download_bytes < previous.download_bytes || current.upload_bytes < previous.upload_bytes) return null
  var seconds = (current.sampled_at_ms - previous.sampled_at_ms) / 1000
  return {download:(current.download_bytes - previous.download_bytes) / seconds,
    upload:(current.upload_bytes - previous.upload_bytes) / seconds}
}

function runtimeConnectionDisplay(scope, catalog) {
  var state = scope && (scope.effective || scope.desired)
  if (!state || state.state !== "assigned") return {name:"VPN", endpoint:""}
  var target = state.public_target || {provider:state.provider, location:state.location}
  var provider = safeText(target.provider, 128)
  var connections = catalog && catalog.connections || []
  for (var i = 0; i < connections.length; i++)
    if (connections[i].id === target.provider) { provider = connections[i].label || provider; break }
  var parts = [provider]
  var locations = catalog && catalog.locations || []
  for (var j = 0; j < locations.length; j++) {
    var location = locations[j]
    if (location.providerId !== target.provider || location.id !== target.location) continue
    if (location.countryName) parts.push(location.countryName)
    if (location.cityName) parts.push(location.cityName)
    break
  }
  return {name:parts.join(" · "), endpoint:safeText(target.location || target.provider, 128)}
}

// ---- catalog search and pagination --------------------------------------

// The location catalog can hold up to MAX_NODES entries; the panel draws a
// bounded page of them. Pure, so it is testable without Qt. limit <= 0 means
// "everything that matches" (used to count matches).
function filterNodes(nodes, search, limit) {
  var list = Array.isArray(nodes) ? nodes : []
  var s = String(search || "").toLowerCase()
  var lim = Number(limit) > 0 ? Number(limit) : list.length
  var out = []
  for (var i = 0; i < list.length && out.length < lim; i++) {
    var n = list[i]
    if (!n) continue
    if (s !== ""
        && String(n.name || "").toLowerCase().indexOf(s) < 0
        && String(n.tag || "").toLowerCase().indexOf(s) < 0) continue
    out.push(n)
  }
  return out
}

// ---- connections backend (Settings → Connections) ------------------------
//
// The connections helper is a fixed root-owned binary spoken to through one
// unprivileged client (connections-client.py). Its response contract is
// versioned; every field below is allowlisted, so a secret-shaped key in a
// response can never reach the UI by accident — only the fields named here
// are read, everything else is dropped.

var CONNECTION_KINDS = ["wireguard", "tailscale", "headscale", "proxy"]
var MAX_CONNECTIONS = 256

var _requestCounter = 0

function nextRequestId() {
  _requestCounter = (_requestCounter + 1) % 0xffff
  return "req-" + Date.now().toString(36) + "-" + _requestCounter
}

// One bounded printable identifier (ids, codes): exact characters preserved,
// control bytes rejected, length capped. Never folded into a near miss.
function isCodeText(value, max) {
  var v = String(value === undefined || value === null ? "" : value)
  if (v === "" || v.length > (max || 128)) return false
  return !/[\x00-\x1f\x7f-\x9f]/.test(v)
}

// The authoritative-revision reader. Revision 0 is a REAL store state (an
// empty catalog), so "missing", null or malformed can never be folded into
// a fabricated 0: an unknown revision is carried as null with revisionKnown
// false, and only an exact non-negative safe integer count as known.
// Malformed numeric types — a quoted "7", a bool, a float, NaN, anything
// beyond Number.MAX_SAFE_INTEGER — are rejected as unknown, never parsed
// into a number that merely looks right.
function authoritativeRevision(value) {
  if (typeof value !== "number" || !isFinite(value)) return { revision: null, known: false }
  if (Math.floor(value) !== value || value < 0) return { revision: null, known: false }
  if (value > Number.MAX_SAFE_INTEGER) return { revision: null, known: false }
  return { revision: value, known: true }
}

// The CAS-token validator applied BEFORE any mutation is created — not
// just inside the client subprocess. A token must be an exact
// non-negative JS-safe integer: QML `int` properties would narrow it to
// 32 bits, so the panel stores it as an untyped safe double and validates
// here. Unknown stays separate from a legitimate zero (callers also check
// the known flag).
function isSafeRevision(value) {
  if (typeof value !== "number" || !isFinite(value)) return false
  if (Math.floor(value) !== value || value < 0) return false
  if (value > Number.MAX_SAFE_INTEGER) return false
  return true
}

function parseConnectionsResponse(text, expectedRequestId) {
  // A refusal keeps the envelope's own error identity when it has one, so
  // locally generated client envelopes (which may lack a matching id when
  // the request itself was unreadable) still classify by code.
  function fail(error, code) {
    return { ok: false, requestId: "", revision: null, revisionKnown: false,
             data: null, error: error, errorCode: code || "" }
  }
  var d = json(text)
  if (!d || typeof d !== "object" || Array.isArray(d))
    return fail("connections response is not valid JSON", "contract")
  if (d.version !== 1)
    return fail("connections backend version mismatch", "contract")
  var rid = String(d.request_id || "")
  if (expectedRequestId !== undefined && expectedRequestId !== null &&
      expectedRequestId !== "" && rid !== String(expectedRequestId))
    return fail("connections response does not match the request", "contract")
  var rev = authoritativeRevision(d.revision)
  var out = { ok: d.ok === true, requestId: rid,
              revision: rev.revision, revisionKnown: rev.known,
              data: null, error: "", errorCode: "" }
  if (out.ok) {
    // A SUCCESS envelope is only usable with an authoritative revision: a
    // malformed or missing one would otherwise make the panel's unknown
    // CAS state look like a valid zero. Malformed success envelopes are
    // rejected whole. Error envelopes may explicitly carry null.
    if (!rev.known)
      return fail("connections success carries no usable revision", "contract")
    if (!d.data || typeof d.data !== "object" || Array.isArray(d.data))
      return fail("connections response carries no data", "contract")
    out.data = d.data
  } else {
    var err = d.error && typeof d.error === "object" ? d.error : {}
    out.error = safeText(err.message, 200)
    out.errorCode = safeText(err.code, 64)
    if (out.error === "") out.error = "connections request failed"
  }
  return out
}

// Type-specific allowlisted NONSECRET settings for the edit forms. Only the
// fields named here can ever reach a connection entry — anything else in a
// backend projection (credentials, secret references, auth keys) is dropped
// by construction, never by filtering after the fact. Backend field names
// are normalized to the UI form's names: the proxy's endpoint is projected
// as `server` and edited as `host`; a control server is projected as
// `control_url` and edited as `url`.
function parseProxySettings(raw) {
  var s = raw && typeof raw === "object" ? raw : {}
  var protocol = safeText(s.protocol, 8).toLowerCase()
  if (["socks5", "http", "https"].indexOf(protocol) < 0) protocol = ""
  var host = safeText(s.server !== undefined && s.server !== null ? s.server : s.host, 253)
  if (!isHostText(host)) host = ""
  var port = parseInt(s.port, 10)
  if (!isFinite(port) || String(port) !== String(parseInt(s.port, 10)) || port < 1 || port > 65535) port = 0
  return { protocol: protocol, host: host, port: port }
}

function parseControlUrlSettings(raw) {
  var s = raw && typeof raw === "object" ? raw : {}
  var url = safeText(s.control_url !== undefined && s.control_url !== null ? s.control_url : s.url, 253)
  // Display/prefill only — the backend re-validates the URL on save, and
  // the form shows the parse result live via validateHeadscaleUrl.
  return { url: url }
}

function parseTailscaleSettings(raw) {
  var s = parseControlUrlSettings(raw)
  var src = raw && typeof raw === "object" ? raw : {}
  // The backend models every Tailscale provider with its own control URL;
  // the reuse/enroll choice is a UI-level intent it may project explicitly.
  // Exact words only — no control-byte cleaning that could turn junk into
  // a valid mode. Only these two are ever kept, so nothing else leaks.
  var mode = String(src.mode === undefined || src.mode === null ? "" : src.mode).toLowerCase()
  s.mode = mode === "reuse" || mode === "enroll" ? mode : ""
  return s
}

function parseHeadscaleSettings(raw) {
  var s = parseControlUrlSettings(raw)
  raw = raw && typeof raw === "object" ? raw : {}
  s.control_ip = safeText(raw.control_ip, 64)
  s.ca_certificate_set = raw.ca_certificate_set === true
  s.private_hosts = {}
  var hosts = raw.private_hosts
  if (hosts && typeof hosts === "object" && !Array.isArray(hosts)) {
    Object.keys(hosts).slice(0, 32).forEach(function (name) {
      if (/^[a-z0-9.-]+$/.test(name) && name.length <= 253 && typeof hosts[name] === "string")
        s.private_hosts[name] = safeText(hosts[name], 64)
    })
  }
  return s
}

function privateHostsFromText(text) {
  var result = {}
  var entries = String(text || "").split(/[\n,]+/).filter(function (v) { return v.trim() !== "" })
  if (entries.length > 32) return null
  for (var i = 0; i < entries.length; i++) {
    var pair = entries[i].trim().split(/\s*=\s*/)
    if (pair.length !== 2 || !/^[a-z0-9.-]+$/.test(pair[0]) || pair[0].length > 253
        || !pair[1] || pair[1].length > 64 || Object.prototype.hasOwnProperty.call(result, pair[0])) return null
    result[pair[0]] = pair[1]
  }
  return result
}

// Authentication is true/false/unknown/not-applicable — never folded into
// one another. The backend's documented not-applicable representation is
// the exact word "n/a" (a protocol with nothing to authenticate, e.g. a
// stored WireGuard key or a credential-less proxy): n/a is NOT a failure
// and NOT a success. Saved credentials are never authentication proof, so
// anything unmeasured stays "unknown".
function parseAuthenticated(value) {
  if (value === true) return true
  if (value === false) return false
  if (value === "n/a") return "n/a"
  return "unknown"
}

// Bounded nonsecret policy projection; canonical network/IP validation belongs
// to the authoritative backend. Never derive public DNS from a provider preset.
function parseNetworkPolicy(raw, includePublic) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null
  var keys = ["private_cidrs", "private_domains", "private_dns"]
  if (includePublic) keys.push("public_dns")
  if (Object.keys(raw).length !== keys.length) return null
  var out = {}
  for (var i = 0; i < keys.length; i++) {
    var values = raw[keys[i]]
    if (!Array.isArray(values) || values.length > 32) return null
    out[keys[i]] = []
    for (var j = 0; j < values.length; j++) {
      if (typeof values[j] !== "string" || !values[j] || values[j].length > 253 || /\s/.test(values[j])) return null
      out[keys[i]].push(values[j])
    }
  }
  return out
}
function privatePolicyFromText(cidrs, domains, dns) {
  function split(value) { return String(value || "").trim().split(/[\s,]+/).filter(function(x) { return x !== "" }) }
  return parseNetworkPolicy({private_cidrs:split(cidrs), private_domains:split(domains).map(function(x) { return x.toLowerCase().replace(/\.$/, "") }), private_dns:split(dns)}, false)
}
function providerScopeSnapshot(catalog, providerId, committed) {
  var baseline = parseNetworkPolicy(committed, true)
  if (!baseline) return null
  var rows = catalog ? catalog.connections : []
  for (var i = 0; i < rows.length; i++) if (rows[i].id === providerId) {
    var preset = parseNetworkPolicy(rows[i].private_policy, false)
    if (!preset) return null
    preset.public_dns = baseline.public_dns.slice()
    return preset
  }
  return null
}
function runtimePrivatePolicyDraft(catalog, scope, separate, target, newApplication) {
  if (!scope || !target) return null
  var desired = scope.desired || {}
  var prior = desired.private_target || { provider: desired.provider }
  // A free slot is storage, not the new app's prior policy. Retain only its
  // trusted public DNS; private fields come from the selected provider.
  // Likewise a switch away from a private provider to VPN-only must not
  // carry its intrinsic-DNS domain rules into an unrelated transport.
  if (newApplication || (!separate && prior.provider !== target.provider)) {
    var baseline = parseNetworkPolicy(scope.scope_policy, true)
    if (!baseline) return null
    return providerScopeSnapshot(catalog, target.provider, baseline)
      || { private_cidrs: [], private_domains: [], private_dns: [], public_dns: baseline.public_dns.slice() }
  }
  if (!separate) return null
  // A public-server switch must not replace a scope's custom private rules
  // with a preset that may have changed since its last explicit selection.
  if (prior.provider === target.provider) return null
  var draft = providerScopeSnapshot(catalog, target.provider, scope.scope_policy)
  return draft && (draft.private_cidrs.length || draft.private_domains.length) ? draft : null
}
function parseConnectionsCatalog(data) {
  if (!data || typeof data !== "object" || Array.isArray(data)) return null
  if (!Array.isArray(data.connections)) return null
  var caps = data.capabilities && typeof data.capabilities === "object" ? data.capabilities : {}
  var capabilities = {
    wireguardImport: caps.wireguardImport === true,
    tailscaleReuse: caps.tailscaleReuse === true,
    tailscaleEnroll: caps.tailscaleEnroll === true,
    headscaleEnroll: caps.headscaleEnroll === true,
    proxy: caps.proxy === true
  }
  var connections = []
  var locations = []
  var list = Array.isArray(data.connections) ? data.connections : []
  // Honesty about bounds: a catalog that hit a cap is flagged, never
  // silently short — the caller surfaces it instead of presenting a
  // truncated list as the whole truth.
  var connectionsTruncated = false
  var locationsTruncated = false
  for (var i = 0; i < list.length; i++) {
    if (connections.length >= MAX_CONNECTIONS) { connectionsTruncated = true; break }
    var raw = list[i]
    if (!raw || typeof raw !== "object") continue
    var id = String(raw.id || "")
    if (!isCodeText(id, 128)) continue
    var kind = String(raw.kind || "")
    if (CONNECTION_KINDS.indexOf(kind) < 0) kind = "unknown"
    var entry = {
      id: id,
      label: safeText(raw.label, 64) || id,
      kind: kind,
      configured: raw.configured === true,
      authenticated: parseAuthenticated(raw.authenticated),
      active: raw.active === true,
      status: safeText(raw.status, 64),
      private_policy: parseNetworkPolicy(raw.private_policy, false),
      error: safeText(raw.error, 160),
      // Nonsecret, type-specific settings for the edit form. WireGuard has
      // none: its locations are the data, and the backend manages them by
      // import only.
      settings: kind === "proxy" ? parseProxySettings(raw.settings)
        : kind === "headscale" ? parseHeadscaleSettings(raw.settings)
        : kind === "tailscale" ? parseTailscaleSettings(raw.settings)
        : {},
      locations: []
    }
    var locs = Array.isArray(raw.locations) ? raw.locations : []
    for (var j = 0; j < locs.length; j++) {
      if (locations.length >= MAX_NODES) { locationsTruncated = true; break }
      var loc = locs[j]
      if (!loc || typeof loc !== "object") continue
      var locId = String(loc.id || "")
      if (!isCodeText(locId, 128)) continue
      var locEntry = {
        key: id + "/" + locId,
        tag: "",
        name: safeText(loc.name, 64) || locId,
        source: "catalog",
        kind: "wireguard",
        providerId: id,
        id: locId,
        serverId: isCodeText(loc.server_id, 128) ? String(loc.server_id) : "",
        country: isCodeText(loc.country_code, 8) ? String(loc.country_code) : "",
        countryName: safeText(loc.country_name, 64),
        city: isCodeText(loc.city_code, 64) ? String(loc.city_code) : "",
        cityName: safeText(loc.city_name, 64)
      }
      entry.locations.push(locEntry)
      locations.push(locEntry)
    }
    connections.push(entry)
  }
  // Paged-listing honesty (the documented scalable protocol): a page that
  // says it is not complete is carried through as incomplete, and the
  // claimed total is kept so the panel can prove what it has seen.
  var complete = data.complete === undefined ? true : data.complete === true
  var total = -1
  if (typeof data.total === "number" && isFinite(data.total)
      && Math.floor(data.total) === data.total && data.total >= 0) total = data.total
  return {
    capabilities: capabilities,
    connections: connections,
    locations: locations,
    complete: complete,
    total: total,
    connectionsTruncated: connectionsTruncated,
    locationsTruncated: locationsTruncated
  }
}

// Merge the data objects of a paged listing (in fetch order) into one
// complete catalog data object. Pages are {capabilities, connections,
// total, offset, complete}; every page must carry consistent totals and
// capabilities, each page's offset must continue the previous one without
// gap or overlap, every page but the last must say complete:false and the
// last must say complete:true. Any gap, overlap, duplicate row, capability
// mismatch or short total is refused with null — never a silently partial
// "whole". Null means the caller must fail the listing, not draw it.
function mergeCatalogPages(pages) {
  if (!Array.isArray(pages) || pages.length === 0) return null
  var capabilities = null
  var total = -1
  var rows = []
  var seen = Object.create(null)
  for (var p = 0; p < pages.length; p++) {
    var page = pages[p]
    if (!page || typeof page !== "object" || Array.isArray(page)) return null
    if (!Array.isArray(page.connections)) return null
    if (p < pages.length - 1) {
      if (page.complete !== false) return null
    } else if (page.complete !== true) {
      return null
    }
    if (typeof page.total !== "number" || !isFinite(page.total)
        || Math.floor(page.total) !== page.total || page.total < 0) return null
    if (typeof page.offset !== "number" || !isFinite(page.offset)
        || Math.floor(page.offset) !== page.offset || page.offset < 0) return null
    if (total === -1) {
      total = page.total
      capabilities = page.capabilities && typeof page.capabilities === "object"
        && !Array.isArray(page.capabilities) ? page.capabilities : {}
    } else {
      if (page.total !== total) return null
      var capsB = page.capabilities && typeof page.capabilities === "object"
        && !Array.isArray(page.capabilities) ? page.capabilities : {}
      if (JSON.stringify(capsB) !== JSON.stringify(capabilities)) return null
    }
    if (page.offset !== rows.length) return null   // strict order, no gaps, no overlaps
    for (var r = 0; r < page.connections.length; r++) {
      var row = page.connections[r]
      if (!row || typeof row !== "object" || Array.isArray(row)) return null
      var rid = String(row.id || "")
      if (rid !== "" && seen[rid] === true) return null   // duplicate row across pages
      if (rid !== "") seen[rid] = true
      rows.push(row)
    }
    if (rows.length > total) return null
  }
  if (total === -1 || rows.length !== total) return null
  return { capabilities: capabilities, connections: rows }
}

// ---- paged-listing planner (pure; node-testable) ---------------------------
//
// One decision point for EVERY page of the documented scalable protocol.
// `state` is the caller's live paging state:
//   { pageSize, offset, revision (null until pinned), total (-1 until
//     pinned), rows, pages (accumulated page data), pagesFetched }
// and `outcome` carries the completed child result:
//   { exitOk (child exit code was 0), exitCode, parsed (the parsed
//     response envelope) }
// The plan is one of:
//   { action: "fail", message }            — fail the WHOLE listing
//   { action: "refetch", pageSize }        — retry the SAME page smaller
//   { action: "fetch", offset, pageSize }  — fetch the next slice
//   { action: "complete", data }           — merged, provably whole catalog
// Every validation happens BEFORE the next page is requested; a mutated
// state is only consumed when the plan is followed. No path retries a
// mutation or hides a partial listing.

var PAGED_MAX_PAGES = 4096
var PAGED_MAX_ROWS = 100000

function planPagedListing(state, outcome) {
  function fail(message) { return { action: "fail", message: message } }
  if (!state || typeof state !== "object") return fail("no paging state to continue")
  // A failed child owns the outcome however its stdout looks.
  if (outcome === null || typeof outcome !== "object") return fail("no page outcome to continue")
  if (outcome.exitOk !== true)
    return fail("the connections client failed (exit " + outcome.exitCode + ")")
  var parsed = outcome.parsed
  if (!parsed || typeof parsed !== "object") return fail("no parsable page response")
  if (!parsed.ok) {
    if (parsed.errorCode === "response-too-large") {
      // The page does not fit the serialized budget: halve and retry the
      // SAME offset. A page size that cannot shrink below one row means
      // no page can ever fit — stop honestly instead of looping.
      var smaller = Math.ceil(state.pageSize / 2)
      if (smaller >= 1 && smaller < state.pageSize)
        return { action: "refetch", pageSize: smaller }
      return fail("the connection list cannot be paged small enough to serialize")
    }
    return fail(parsed.error !== "" ? parsed.error : "the paged connection list failed")
  }
  // The parser already rejects malformed success envelopes: a page that
  // says ok carries an authoritative revision by construction.
  if (!parsed.revisionKnown) return fail("a page answered without an authoritative revision")
  // One revision pins the WHOLE listing: same totals and capabilities do
  // not prove a consistent catalog, so a changed revision fails it whole.
  if (state.revision === null) {
    state.revision = parsed.revision
  } else if (state.revision !== parsed.revision) {
    return fail("the connection list changed mid-listing (revision "
      + state.revision + " → " + parsed.revision + ") — refused, nothing retried")
  }
  var data = parsed.data
  if (!data || typeof data !== "object" || Array.isArray(data) || !Array.isArray(data.connections))
    return fail("a page is not in the paged shape")
  var total = data.total
  var offset = data.offset
  if (typeof total !== "number" || !isFinite(total) || Math.floor(total) !== total || total < 0)
    return fail("a page claims no usable total")
  if (typeof offset !== "number" || !isFinite(offset) || Math.floor(offset) !== offset || offset < 0)
    return fail("a page claims no usable offset")
  // Strict position: each page must start exactly where the listing stands.
  if (offset !== state.offset)
    return fail("a page arrived out of order (wanted offset " + state.offset
      + ", got " + offset + ")")
  if (state.pages.length === 0) {
    state.total = total
  } else if (total !== state.total) {
    return fail("the paged total changed mid-listing (" + state.total + " → " + total + ")")
  }
  var complete = data.complete === true
  var rows = data.connections.length
  // Zero progress can never finish a non-final page: refuse instead of
  // looping on the same offset forever.
  if (!complete && rows === 0)
    return fail("a non-final page made no progress (offset " + offset + ")")
  if (state.pagesFetched >= PAGED_MAX_PAGES)
    return fail("the paged listing exceeded " + PAGED_MAX_PAGES + " pages")
  if (state.rows + rows > PAGED_MAX_ROWS)
    return fail("the paged listing exceeded " + PAGED_MAX_ROWS + " rows")
  state.pagesFetched++
  state.pages.push(data)
  state.rows += rows
  if (state.rows > total)
    return fail("the listing returned more rows than its own total (" + state.rows + " > " + total + ")")
  if (complete) {
    if (state.rows !== total)
      return fail("the final page ended before the claimed total (" + state.rows + " of " + total + ")")
    var merged = mergeCatalogPages(state.pages)
    if (merged === null)
      return fail("the paged listing does not tile a complete catalog")
    return { action: "complete", data: merged }
  }
  return { action: "fetch", offset: state.offset + rows, pageSize: state.pageSize }
}

// WireGuard preview summary: sanitized counts and the preview digest only.
// Key fields never reach a preview, so nothing here can leak one — only
// the named count fields are read, everything else is ignored.
function wireguardPreviewSummary(data) {
  if (!data || typeof data !== "object") return ""
  var counts = data.counts && typeof data.counts === "object" ? data.counts : {}
  var parts = []
  function push(label, value) {
    var n = parseInt(value, 10)
    if (!isFinite(n) || String(n) !== String(parseInt(value, 10))) return
    parts.push(label + " " + n)
  }
  push("providers", counts.providers)
  push("locations", counts.locations)
  push("duplicates", counts.duplicates)
  push("invalid", counts.invalid)
  push("errors", counts.errors)
  if (parts.length === 0) return "The preview returned no counts"
  var text = parts.join(" · ")
  var digest = safeText(data.digest, 32)
  if (digest !== "") text += "\ndigest " + digest
  return text
}

// One saved connection's status line: a saved configuration is distinct
// from a connected, usable route — never folded into one word. The
// authentication word keeps the true/false/unknown/not-applicable
// distinction: "n/a" means the protocol has nothing to authenticate, so it
// is never drawn as a failure, and "unknown" is never drawn as success.
function connectionStatusText(entry) {
  if (!entry || typeof entry !== "object") return ""
  var parts = [entry.configured ? "saved" : "not configured"]
  if (entry.kind === "wireguard") {
    var n = entry.locations ? entry.locations.length : 0
    parts.push(n + " location" + (n === 1 ? "" : "s"))
  }
  if (entry.authenticated === true) parts.push("authenticated")
  else if (entry.authenticated === false) parts.push("unauthenticated")
  else if (entry.authenticated === "n/a") parts.push("no auth for this kind")
  else parts.push("auth unknown")
  parts.push(entry.active ? "connected" : "not connected")
  return parts.join(" · ")
}

// ---- forms: Headscale URL and proxy validation ----------------------------
// Returns { ok: bool, host: string, url: string, error: string }. The host
// is what the panel shows as the recipient of an enrollment credential.
// Userinfo, query strings and fragments are refused; a base path is kept
// (self-hosted Headscale may live under a prefix), never sent anywhere by
// this file itself.
function validateHeadscaleUrl(url) {
  var raw = String(url || "").trim()
  if (raw === "") return { ok: false, host: "", url: "", error: "a control-server URL is required" }
  var schemeEnd = raw.indexOf("://")
  if (schemeEnd <= 0) return { ok: false, host: "", url: "", error: "URL must start with http:// or https://" }
  var scheme = raw.substring(0, schemeEnd).toLowerCase()
  if (scheme !== "http" && scheme !== "https")
    return { ok: false, host: "", url: "", error: "URL must start with http:// or https://" }
  var rest = raw.substring(schemeEnd + 3)
  if (rest.indexOf("@") >= 0)
    return { ok: false, host: "", url: "", error: "URL must not carry userinfo" }
  if (rest.indexOf("#") >= 0)
    return { ok: false, host: "", url: "", error: "URL must not carry a fragment" }
  var query = rest.indexOf("?")
  if (query >= 0)
    return { ok: false, host: "", url: "", error: "URL must not carry a query string" }
  var slash = rest.indexOf("/")
  var authority = slash >= 0 ? rest.substring(0, slash) : rest
  var path = slash >= 0 ? rest.substring(slash) : ""
  if (authority === "") return { ok: false, host: "", url: "", error: "URL has no host" }
  var host = authority
  var port = ""
  var v6 = /^\[[0-9A-Fa-f:.]+\]/.exec(authority)
  if (v6) {
    host = v6[0]
    var after = authority.substring(host.length)
    if (after !== "" && after.charAt(0) === ":") port = after.substring(1)
  } else {
    var colon = authority.lastIndexOf(":")
    if (colon >= 0) {
      host = authority.substring(0, colon)
      port = authority.substring(colon + 1)
    }
  }
  if (!isHostText(host) || host === "")
    return { ok: false, host: "", url: "", error: "URL host is not a valid server name or address" }
  if (port !== "" && (port.length > 5 || !/^[0-9]+$/.test(port) || parseInt(port, 10) < 1 || parseInt(port, 10) > 65535))
    return { ok: false, host: "", url: "", error: "URL port is out of range" }
  var normalized = scheme + "://" + host + (port !== "" ? ":" + port : "") + path.replace(/\/+$/, "")
  return { ok: true, host: host, url: normalized, error: "" }
}

// Client-side mirror of the backend's proxy validation: UX only, never a
// substitute — the backend re-validates and rejects independently.
function validateProxySettings(protocol, host, port) {
  var p = String(protocol || "").toLowerCase()
  if (["socks5", "http", "https"].indexOf(p) < 0) return "unsupported proxy protocol"
  var h = String(host || "").trim()
  if (!isHostText(h)) return "host must be a server name or address"
  var n = parseInt(port, 10)
  if (!isFinite(n) || String(n) !== String(parseInt(port, 10)) || n < 1 || n > 65535)
    return "port must be a number between 1 and 65535"
  return ""
}

// ---- location hierarchy (Country → City → Server) -------------------------
//
// User contract (docs/settings-and-connections-ui.md): no flat 541-row list. Countries
// first, then a city dropdown for the chosen country, then servers for that
// city. Geography is shown only when verified metadata exists — anything
// else lands in the explicit Unknown/Custom group under its exact code or
// tag, never under an invented name.

var UNKNOWN_KEY = "__unknown__"
var UNKNOWN_LABEL = "Unknown / Custom"
var HIERARCHY_PAGE = 200

function naturalCompare(a, b) {
  var x = String(a === undefined || a === null ? "" : a)
  var y = String(b === undefined || b === null ? "" : b)
  var xi = 0, yi = 0
  while (xi < x.length && yi < y.length) {
    var cx = x.charAt(xi), cy = y.charAt(yi)
    var dx = cx >= "0" && cx <= "9", dy = cy >= "0" && cy <= "9"
    if (dx && dy) {
      var nx = xi, ny = yi
      while (nx < x.length && x.charAt(nx) >= "0" && x.charAt(nx) <= "9") nx++
      while (ny < y.length && y.charAt(ny) >= "0" && y.charAt(ny) <= "9") ny++
      var vx = parseInt(x.substring(xi, nx), 10)
      var vy = parseInt(y.substring(yi, ny), 10)
      if (vx !== vy) return vx < vy ? -1 : 1
      if (nx - xi !== ny - yi) return (nx - xi) < (ny - yi) ? -1 : 1
      xi = nx; yi = ny
      continue
    }
    var lx = cx.toLowerCase(), ly = cy.toLowerCase()
    if (lx !== ly) return lx < ly ? -1 : 1
    xi++; yi++
  }
  if (x.length !== y.length) return x.length < y.length ? -1 : 1
  return x < y ? -1 : (x > y ? 1 : 0)
}

// Unified location entries: config endpoints (exact tags, no invented
// geography) plus imported catalog locations (verified metadata). Both stay
// distinct: `source` says which, and a catalog location is never presented
// as switchable just because it is listed.
function mergeLocationSources(endpoints, catalogLocations) {
  var out = []
  var list = Array.isArray(endpoints) ? endpoints : []
  for (var i = 0; i < list.length && out.length < MAX_NODES; i++) {
    var node = list[i]
    if (!node || typeof node !== "object") continue
    var tag = rawTag(node.tag)
    if (tag === "") continue
    out.push({
      key: tag,
      tag: tag,
      name: displayName(tag),
      source: "endpoint",
      kind: safeText(node.type, 32) || "endpoint",
      providerId: "",
      id: tag,
      serverId: "",
      country: "",
      countryName: "",
      city: "",
      cityName: ""
    })
  }
  var cats = Array.isArray(catalogLocations) ? catalogLocations : []
  for (var j = 0; j < cats.length && out.length < MAX_NODES; j++) {
    var c = cats[j]
    if (!c || typeof c !== "object") continue
    if (!isCodeText(c.key, 320)) continue
    out.push({
      key: String(c.key),
      tag: "",
      name: safeText(c.name, 64) || String(c.key),
      source: "catalog",
      kind: "wireguard",
      providerId: safeText(c.providerId, 128),
      id: safeText(c.id, 128),
      serverId: safeText(c.serverId, 128),
      country: isCodeText(c.country, 8) ? String(c.country) : "",
      countryName: safeText(c.countryName, 64),
      city: isCodeText(c.city, 64) ? String(c.city) : "",
      cityName: safeText(c.cityName, 64)
    })
  }
  return out
}

// The hierarchy itself: countries → cities → servers, deduplicated by code
// (distinct servers never collapse), deterministically natural-sorted, with
// the Unknown/Custom group kept explicitly last at every level.
function buildLocationHierarchy(locations) {
  var countries = Object.create(null)
  var list = Array.isArray(locations) ? locations : []
  var total = 0
  for (var i = 0; i < list.length && total < MAX_NODES; i++) {
    var e = list[i]
    if (!e || typeof e !== "object" || !isCodeText(e.key, 320)) continue
    var cKey = isCodeText(e.country, 8) ? String(e.country) : UNKNOWN_KEY
    var cName = safeText(e.countryName, 64) || (cKey === UNKNOWN_KEY ? UNKNOWN_LABEL : cKey)
    var yKey = isCodeText(e.city, 64) ? String(e.city) : UNKNOWN_KEY
    var yName = safeText(e.cityName, 64) || (yKey === UNKNOWN_KEY ? UNKNOWN_LABEL : yKey)
    var country = countries[cKey]
    if (!country) country = countries[cKey] = { key: cKey, code: cKey === UNKNOWN_KEY ? "" : cKey, name: cName, unknown: cKey === UNKNOWN_KEY, cities: Object.create(null) }
    else if (cName !== UNKNOWN_LABEL && country.name === cKey) country.name = cName
    var city = country.cities[yKey]
    if (!city) city = country.cities[yKey] = { key: yKey, code: yKey === UNKNOWN_KEY ? "" : yKey, name: yName, unknown: yKey === UNKNOWN_KEY, servers: [] }
    else if (yName !== UNKNOWN_LABEL && city.name === yKey) city.name = yName
    city.servers.push(e)
    total++
  }
  var countryList = []
  for (var ck in countries) {
    var c = countries[ck]
    var cityList = []
    for (var yk in c.cities) {
      var y = c.cities[yk]
      y.servers.sort(function(a, b) {
        var an = safeText(a.name, 64), bn = safeText(b.name, 64)
        var byName = naturalCompare(an, bn)
        if (byName !== 0) return byName
        return naturalCompare(a.key, b.key)
      })
      cityList.push(y)
    }
    cityList.sort(function(a, b) {
      if (a.unknown !== b.unknown) return a.unknown ? 1 : -1
      var byName = naturalCompare(a.name, b.name)
      if (byName !== 0) return byName
      return naturalCompare(a.key, b.key)
    })
    c.cities = cityList
    countryList.push(c)
  }
  countryList.sort(function(a, b) {
    if (a.unknown !== b.unknown) return a.unknown ? 1 : -1
    var byName = naturalCompare(a.name, b.name)
    if (byName !== 0) return byName
    return naturalCompare(a.key, b.key)
  })
  return { countries: countryList, total: total }
}

// The path of a location key in the hierarchy — what "preselect the current
// server's country, city and server" means. Null when the key is unknown
// (removed or foreign), which callers surface explicitly.
function hierarchyPathFor(hierarchy, key) {
  if (!hierarchy || !Array.isArray(hierarchy.countries)) return null
  var wanted = String(key || "")
  if (wanted === "") return null
  var countries = hierarchy.countries
  for (var i = 0; i < countries.length; i++) {
    var cities = countries[i].cities || []
    for (var j = 0; j < cities.length; j++) {
      var servers = cities[j].servers || []
      for (var k = 0; k < servers.length; k++) {
        if (String(servers[k].key) === wanted) {
          return { country: countries[i].key, city: cities[j].key, server: wanted, entry: servers[k] }
        }
      }
    }
  }
  return null
}

// Resolve within the selected city only. Empty server means the first row
// in the same deterministic ordering shown by the server dropdown. A stale
// explicit override never silently falls back to Automatic or another city.
function selectedHierarchyEntry(hierarchy, selection) {
  if (!selection || !selection.country || !selection.city) return null
  var key = selection.server
  if (!key) {
    var options = hierarchyOptions(hierarchy, "server", selection.country, selection.city, 1)
    if (!options.length) return null
    key = options[0].value
  }
  var path = hierarchyPathFor(hierarchy, key)
  return path && path.country === selection.country && path.city === selection.city ? path.entry : null
}

// Selection state transitions with parent resets: choosing a parent clears
// the children; nothing here ever switches a connection.
function updateHierarchySelection(state, level, key) {
  var current = state && typeof state === "object" ? state : { country: "", city: "", server: "" }
  var k = String(key || "")
  if (level === "country") return { country: k, city: "", server: "" }
  if (level === "city") {
    if (current.country === "" || k === "") return { country: current.country, city: "", server: "" }
    return { country: current.country, city: k, server: "" }
  }
  if (level === "server") {
    if (current.country === "" || current.city === "" || k === "")
      return { country: current.country, city: current.city, server: "" }
    return { country: current.country, city: current.city, server: k }
  }
  return { country: current.country, city: current.city, server: current.server }
}

// Dropdown options for one level, bounded and naturally sorted (the build
// already sorted; this only projects). description carries the exact code
// or tag so a display name can never displace the real identifier.
function hierarchyOptions(hierarchy, level, countryKey, cityKey, limit) {
  var cap = Number(limit) > 0 ? Number(limit) : HIERARCHY_PAGE
  var out = []
  if (!hierarchy || !Array.isArray(hierarchy.countries)) return out
  if (level === "country") {
    var cs = hierarchy.countries
    for (var i = 0; i < cs.length && out.length < cap; i++) {
      out.push({ value: cs[i].key, label: cs[i].name,
                 description: cs[i].unknown ? "no verified geography" : cs[i].code })
    }
    return out
  }
  var country = null
  var countries = hierarchy.countries
  for (var a = 0; a < countries.length; a++) {
    if (String(countries[a].key) === String(countryKey)) { country = countries[a]; break }
  }
  if (!country) return out
  if (level === "city") {
    var ys = country.cities || []
    for (var b = 0; b < ys.length && out.length < cap; b++) {
      out.push({ value: ys[b].key, label: ys[b].name,
                 description: ys[b].unknown ? "no verified geography" : ys[b].code })
    }
    return out
  }
  if (level === "server") {
    var city = null
    var cityList = country.cities || []
    for (var c = 0; c < cityList.length; c++) {
      if (String(cityList[c].key) === String(cityKey)) { city = cityList[c]; break }
    }
    if (!city) return out
    var ss = city.servers || []
    for (var d = 0; d < ss.length && out.length < cap; d++) {
      var s = ss[d]
      out.push({
        value: s.key,
        label: safeText(s.name, 64) || String(s.key),
        description: (s.source === "catalog" ? "imported" : s.kind)
          + (s.serverId !== "" && s.serverId !== s.key ? " · " + s.serverId : "")
      })
    }
  }
  return out
}

// ---- authenticated runtime supervisor ----------------------------------
function runtimeTarget(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)
      || !isCodeText(raw.provider, 64)) return null
  var out = { provider: raw.provider }
  if (raw.location !== undefined) {
    if (!isCodeText(raw.location, 128)) return null
    out.location = raw.location
  }
  return out
}

function runtimeEnvelope(action, requestId, scope, revision, generation, privateTarget, publicTarget, scopePolicy) {
  if (["status", "list_scopes", "assign", "switch", "block", "connect", "disconnect", "capture_status", "set_kill_switch"].indexOf(action) < 0
      || !/^[A-Za-z0-9._-]{1,64}$/.test(requestId)) return null
  var req = { action: action, request_id: requestId }
  if (action === "list_scopes") return { version: 1, request: req }
  if (action === "status" || action === "capture_status") {
    if (!isSafeRevision(revision)) return null
    req.catalog_revision = revision
    return { version: 1, request: req }
  }
  if (action === "connect" || action === "disconnect" || action === "set_kill_switch") {
    if (!isSafeRevision(revision) || !isSafeRevision(generation)) return null
    if (action === "set_kill_switch") {
      if (typeof privateTarget !== "boolean") return null
      req.enabled = privateTarget
    }
    req.catalog_revision = revision
    req.runtime_generation = generation
    return { version: 1, request: req }
  }
  if (!/^[a-z][a-z0-9_-]{0,31}$/.test(scope)
      || !isSafeRevision(revision) || !isSafeRevision(generation)) return null
  req.scope = scope
  req.catalog_revision = revision
  req.runtime_generation = generation
  if (action !== "block") {
    var priv = runtimeTarget(privateTarget), pub = runtimeTarget(publicTarget)
    if (!priv || !pub) return null
    req.policy_version = 2
    req.private_target = priv
    req.public_target = pub
    if (scopePolicy !== undefined && scopePolicy !== null) {
      var policy = parseNetworkPolicy(scopePolicy, true)
      if (!policy) return null
      req.scope_policy = policy
    }
  }
  return { version: 1, request: req }
}

function applicationEnvelope(action, requestId, scope, revision, generation, application, applicationRevision) {
  if (!isCodeText(requestId, 64) || !isSafeRevision(revision) || ["running_apps", "application_assign", "application_default"].indexOf(action) < 0) return null
  var request = { action: action, request_id: requestId, catalog_revision: revision }
  if (action !== "running_apps") {
    if (!/^[0-9a-f]{64}$/.test(String(applicationRevision)) || !isSafeRevision(generation)) return null
    request.application_revision = applicationRevision
    request.runtime_generation = generation
  }
  if (action === "application_assign") {
    if (!/^[0-9a-f]{32}$/.test(String(application)) || !isCodeText(scope, 32)
        || !isSafeRevision(revision) || !isSafeRevision(generation)) return null
    request.application = application; request.scope = scope
    request.catalog_revision = revision; request.runtime_generation = generation
  }
  if (action === "application_default") {
    if (!/^b-[0-9a-f]{32}$/.test(String(application))) return null
    request.binding_id = application
  }
  return { version: 1, request: request }
}

function applicationRowKey(row) {
  return row.desktop_id ? "desktop:" + row.desktop_id : "binding:" + row.binding_id
}

function applicationDisplay(row) {
  var name = safeText(row && row.name, 128)
  var profile = safeText(row && row.profile_label, 128)
  var split = profile.indexOf(" · includes ")
  var role = split < 0 ? profile : profile.slice(0, split)
  var included = split < 0 ? "" : profile.slice(split + " · includes ".length)
  var lower = name.toLowerCase(), roleLower = role.toLowerCase()
  var duplicate = roleLower !== "" && (lower === roleLower || lower.slice(-(roleLower.length + 1)) === " " + roleLower)
  var details = []
  if (role !== "" && !duplicate) details.push(role)
  if (included !== "") details.push("Includes " + included)
  return {name:name, detail:details.join(" · ")}
}

function applicationRouteDisplay(scope, catalog) {
  var state = scope && (scope.desired || scope.effective)
  if (!state || state.state !== "assigned")
    return {internet:state && state.state === "blocked" ? "Blocked" : "Unavailable", privateRoute:""}
  var pub = state.public_target || {provider:state.provider, location:state.location}
  var priv = state.private_target || pub
  function label(target) {
    var display = runtimeConnectionDisplay({effective:{state:"assigned",public_target:target}}, catalog)
    return display.name + (target.location ? " · " + display.endpoint : "")
  }
  var different = pub.provider !== priv.provider || (pub.location || "") !== (priv.location || "")
  return {internet:label(pub), privateRoute:different ? label(priv) : ""}
}

function applicationLimitation(row) {
  var messages = { "not-running": "Refresh installed apps to check routing support.",
    "shared-executable": "These profiles share one browser process identity and cannot be routed separately yet.",
    "unsupported-launcher": "This app's launcher is not supported for separate routing.",
    "terminal-wrapper": "This app shares its terminal's connection identity and cannot be routed separately yet.",
    "launcher-changed": "The saved launcher is missing or changed. Remove this exception before choosing a replacement.",
    "legacy-executable-wide": "This older exception covers a shared application identity. It can be removed, not relabeled as a separate profile." }
  return messages[row.limitation] || ""
}

function managedEnvelope(action, requestId, scope, revision, generation, application) {
  if (["managed_apps", "managed_create", "managed_launch"].indexOf(action) < 0
      || !/^[A-Za-z0-9._-]{1,64}$/.test(requestId)) return null
  var req = { action: action, request_id: requestId }
  if (action === "managed_apps") return { version: 1, request: req }
  if (!/^[a-z][a-z0-9_-]{0,31}$/.test(scope) || !isSafeRevision(revision) || !isSafeRevision(generation)) return null
  req.catalog_revision = revision
  req.runtime_generation = generation
  if (action === "managed_create") {
    if (["firefox", "chromium", "brave"].indexOf(application) < 0) return null
    req.template_scope = scope
    req.application = application
  } else req.scope = scope
  return { version: 1, request: req }
}

function runtimeStateTarget(raw) {
  if (!raw || typeof raw !== "object" || ["assigned", "unassigned", "blocked", "pending"].indexOf(raw.state) < 0) return null
  var out = { state: raw.state }
  if (raw.policy_version !== undefined) {
    if (raw.policy_version !== 1 && raw.policy_version !== 2) return null
    out.policy_version = raw.policy_version
  }
  if (raw.state !== "assigned") return out
  var primary = runtimeTarget(raw)
  if (!primary) return null
  out.provider = primary.provider
  if (primary.location !== undefined) out.location = primary.location
  if (raw.policy_version === 2) {
    out.private_target = runtimeTarget(raw.private_target)
    out.public_target = runtimeTarget(raw.public_target)
    if (!out.private_target || !out.public_target) return null
  }
  return out
}

function parseRuntimeResponse(text, requestId, action) {
  if (typeof text !== "string" || text.length > 65536) return null
  var raw = json(text)
  if (!raw || raw.version !== 1 || typeof raw.ok !== "boolean" || raw.request_id !== requestId) return null
  if (raw.catalog_revision !== null && !isSafeRevision(raw.catalog_revision)) return null
  if (raw.runtime_generation !== null && !isSafeRevision(raw.runtime_generation)) return null
  var out = { ok: raw.ok, request_id: requestId, catalog_revision: raw.catalog_revision,
              runtime_generation: raw.runtime_generation }
  if (!raw.ok) {
    if (!raw.error || !isCodeText(raw.error.code, 48)) return null
    out.error = { code: raw.error.code, message: safeText(raw.error.message, 256) || "Runtime request refused." }
    return out
  }
  if (["connect", "disconnect", "capture_status", "set_kill_switch"].indexOf(action) >= 0) {
    var capture = raw.capture
    if (!capture || ["unprepared", "preparing", "active", "degraded-blocked", "degraded-unknown", "disconnecting", "rollback-required"].indexOf(capture.state) < 0
        || !isSafeRevision(capture.guard_generation) || typeof capture.deadline_fresh !== "boolean") return null
    out.capture = { state: capture.state, guard_generation: capture.guard_generation, deadline_fresh: capture.deadline_fresh,
      lease_remaining_ms: null,
      telemetry:parseCaptureTelemetry(capture.telemetry),
      kill_switch_enabled:typeof capture.kill_switch_enabled === "boolean" ? capture.kill_switch_enabled : null,
      kill_switch_setting_verified:typeof capture.kill_switch_enabled === "boolean" && capture.kill_switch_setting_verified === true }
    if (capture.state === "active" && capture.deadline_fresh === true) {
      // An active claim must carry exact bounded remaining lease evidence;
      // without it a local deadline would be invented. Missing, fractional,
      // or out-of-range values fail closed (the whole response is refused).
      var remaining = capture.lease_remaining_ms
      if (typeof remaining !== "number" || !isFinite(remaining) || Math.floor(remaining) !== remaining
          || remaining < 0 || remaining > 10000) return null
      out.capture.lease_remaining_ms = remaining
    }
    return out
  }
  if (action === "running_apps") {
    if (!Array.isArray(raw.running_applications) || raw.running_applications.length > 128
        || !Array.isArray(raw.application_slots) || raw.application_slots.length > 16
        || raw.capture_status !== "unverified" || !/^[0-9a-f]{64}$/.test(String(raw.application_revision))
        || typeof raw.discovery_complete !== "boolean" || typeof raw.discovery_warning !== "string") return null
    out.application_revision = raw.application_revision
    out.discovery_complete = raw.discovery_complete
    out.discovery_warning = safeText(raw.discovery_warning, 256)
    out.running_applications = []
    out.application_slots = []
    var seenApplications = Object.create(null)
    for (var ri = 0; ri < raw.running_applications.length; ri++) {
      var app = raw.running_applications[ri]
      if (!app || (app.application !== null && !/^[0-9a-f]{32}$/.test(String(app.application)))
          || (app.desktop_id !== null && !isCodeText(app.desktop_id, 256))
          || (app.binding_id !== null && !/^b-[0-9a-f]{32}$/.test(String(app.binding_id)))
          || (app.desktop_id === null && app.binding_id === null)
          || typeof app.name !== "string" || typeof app.profile_label !== "string"
          || typeof app.running !== "boolean" || typeof app.assignable !== "boolean" || typeof app.legacy_shared !== "boolean"
          || ["", "not-running", "shared-executable", "unsupported-launcher", "terminal-wrapper", "launcher-changed", "legacy-executable-wide"].indexOf(app.limitation) < 0
          || ["unbound", "requested-unverified", "saved"].indexOf(app.publication) < 0
          || app.application_wide !== true || app.new_connections_only !== true
          || (app.scope !== null && !isCodeText(app.scope, 32))
          || ((app.scope === null) !== (app.binding_id === null))) return null
      var key = applicationRowKey(app)
      if (seenApplications[key]) return null
      seenApplications[key] = true
      out.running_applications.push({ application: app.application, desktop_id: app.desktop_id, binding_id: app.binding_id,
        name: safeText(app.name, 128), profile_label: safeText(app.profile_label, 128), scope: app.scope,
        running: app.running, assignable: app.assignable, limitation: app.limitation,
        publication: app.publication, legacy_shared: app.legacy_shared })
    }
    for (var si = 0; si < raw.application_slots.length; si++) {
      var slot = raw.application_slots[si]
      if (!isCodeText(slot.scope, 32) || typeof slot.bound !== "boolean") return null
      out.application_slots.push({ scope: slot.scope, bound: slot.bound })
    }
    out.capture_status = "unverified"
    if (raw.application_default_scope !== null && !isCodeText(raw.application_default_scope, 32)) return null
    out.application_default_scope = raw.application_default_scope
    return out
  }
  if (action === "application_assign" || action === "application_default") {
    if (!/^b-[0-9a-f]{32}$/.test(String(raw.binding_id)) || !/^[0-9a-f]{64}$/.test(String(raw.application_revision))
        || raw.publication !== "requested-unverified" || raw.application_wide !== true
        || raw.new_connections_only !== true) return null
    if (action === "application_assign" && (!/^[0-9a-f]{32}$/.test(String(raw.application))
        || !isCodeText(raw.scope, 32) || !isCodeText(raw.desktop_id, 256))) return null
    if (action === "application_default" && (raw.scope !== null || raw.desktop_id !== null)) return null
    out.application = raw.application; out.scope = raw.scope; out.desktop_id = raw.desktop_id
    out.binding_id = raw.binding_id; out.application_revision = raw.application_revision; out.publication = raw.publication
    return out
  }
  if (action === "managed_apps") {
    if (!Array.isArray(raw.applications) || raw.applications.length > 3
        || !Array.isArray(raw.managed_scopes) || raw.managed_scopes.length > 16
        || !Array.isArray(raw.templates) || raw.templates.length > 16) return null
    out.applications = []
    out.managed_scopes = []
    out.templates = []
    for (var a = 0; a < raw.applications.length; a++) {
      if (["firefox", "chromium", "brave"].indexOf(raw.applications[a].id) < 0) return null
      out.applications.push({ id: raw.applications[a].id, label: safeText(raw.applications[a].label, 64) })
    }
    for (var b = 0; b < raw.managed_scopes.length; b++) {
      var instance = raw.managed_scopes[b]
      if (!isCodeText(instance.scope, 32) || ["firefox", "chromium", "brave"].indexOf(instance.application) < 0
          || ["running", "not-running", "created"].indexOf(instance.state) < 0) return null
      out.managed_scopes.push({ scope: instance.scope, application: instance.application, state: instance.state })
    }
    for (var t = 0; t < raw.templates.length; t++) {
      if (!isCodeText(raw.templates[t].scope, 32)) return null
      out.templates.push({ scope: raw.templates[t].scope })
    }
    return out
  }
  if (action === "managed_create" || action === "managed_launch") {
    if (!isSafeRevision(raw.catalog_revision) || !isSafeRevision(raw.runtime_generation)
        || !raw.managed || !isCodeText(raw.managed.scope, 32)
        || ["firefox", "chromium", "brave"].indexOf(raw.managed.application) < 0
        || ["created", "running"].indexOf(raw.managed.state) < 0) return null
    out.managed = { scope: raw.managed.scope, application: raw.managed.application, state: raw.managed.state }
    return out
  }
  if (action !== "list_scopes" && (!isSafeRevision(raw.catalog_revision) || !isSafeRevision(raw.runtime_generation))) return null
  var rows = action === "status" || action === "list_scopes" ? raw.scopes : [raw.scope]
  if (!Array.isArray(rows) || rows.length > 16) return null
  var result = [], seen = Object.create(null)
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!row || typeof row.scope !== "string" || !/^[a-z][a-z0-9_-]{0,31}$/.test(row.scope)
        || seen[row.scope] || !isCodeText(row.owner, 128)) return null
    seen[row.scope] = true
    var item = { scope: row.scope, owner: row.owner }
    if (action !== "list_scopes") {
      item.desired = runtimeStateTarget(row.desired)
      item.effective = runtimeStateTarget(row.effective)
      if (!item.desired || !item.effective || typeof row.pending !== "boolean"
          || (row.generation !== null && !isSafeRevision(row.generation))) return null
      item.generation = row.generation
      item.pending = row.pending
      item.guarantee = safeText(row.guarantee, 32)
      item.worker_health = safeText(row.worker_health, 32)
      item.private_policy_configured = row.private_policy_configured === true
      item.scope_policy = parseNetworkPolicy(row.scope_policy, true)
      item.private_cidr_count = isSafeRevision(row.private_cidr_count) ? row.private_cidr_count : 0
      item.private_domain_count = isSafeRevision(row.private_domain_count) ? row.private_domain_count : 0
      item.readiness = safeText(row.readiness, 32)
      item.freshness = safeText(row.freshness, 32)
      item.error = row.error === null ? null : "Runtime operation failed."
      item.worker = row.worker ? { worker_id: safeText(row.worker.worker_id, 128),
                                  role: safeText(row.worker.role, 128), pid: row.worker.pid } : null
      item.telemetry = parseScopeTelemetry(row.telemetry)
    }
    result.push(item)
  }
  if (action === "status" || action === "list_scopes") out.scopes = result
  else out.scope = result[0]
  return out
}

function runtimeTargetSummary(state) {
  if (!state || state.state !== "assigned") return state ? state.state : "unknown"
  function label(target) { return target.provider + (target.location ? " / " + target.location : "") }
  if (state.policy_version === 2)
    return "Private: " + label(state.private_target) + " · Public: " + label(state.public_target)
  return "All selected destinations: " + label(state)
}

function runtimeProviderOptions(catalog, allowDirect) {
  var out = allowDirect ? [{ value: "direct", label: "Bypass VPN" }] : []
  var providers = catalog && Array.isArray(catalog.connections) ? catalog.connections : []
  for (var i = 0; i < providers.length; i++) {
    if (providers[i].kind === "tailscale" && providers[i].settings && providers[i].settings.mode === "reuse") continue
    out.push({ value: providers[i].id, label: providers[i].label + " (" + providers[i].kind + ")" })
  }
  return out
}

function runtimeMainProviderOptions(catalog, allowDirect) {
  var eligible = catalog && Array.isArray(catalog.connections) ? catalog.connections.filter(function(p) {
    return p.kind === "wireguard" || p.kind === "proxy"
  }) : []
  return runtimeProviderOptions({connections:eligible}, allowDirect)
}

function runtimeSelectedTarget(catalog, providerId, locationEntry) {
  if (providerId === "direct") return { provider: "direct" }
  var providers = catalog && Array.isArray(catalog.connections) ? catalog.connections : []
  for (var i = 0; i < providers.length; i++) {
    var provider = providers[i]
    if (provider.id !== providerId) continue
    if (provider.kind === "tailscale" && provider.settings && provider.settings.mode === "reuse") return null
    if (provider.kind !== "wireguard") return { provider: providerId }
    if (!locationEntry || locationEntry.providerId !== providerId) return null
    for (var j = 0; j < provider.locations.length; j++)
      if (provider.locations[j].id === locationEntry.id)
        return { provider: providerId, location: locationEntry.id }
    return null
  }
  return null
}
