import Foundation

// Pure logic: parsing the usage reply, formatting it, and deciding when to fetch.
// No AppKit, so Tests/ can compile it alone.

struct Limit: Equatable {
    enum Kind: Int, Comparable { case session = 0, weekly = 1, scoped = 2
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue } }
    let kind: Kind
    let label: String
    let percent: Double
    let resetsAt: Date?
    let elevated: Bool   // server says severity isn't "normal"

    var isHot: Bool { elevated || percent >= 90 }

    /// The window this number describes has reset, so the number is no longer true. Decided by the clock alone:
    /// a reply sent just before a reset can arrive just after it, so the fetch time proves nothing.
    func isStale(now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
}

// MARK: - parsing

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
}()
private let isoPlain = ISO8601DateFormatter()

/// Accepts "2026-11-13T05:20:00.394316+00:00" (microseconds, which ISO8601DateFormatter rejects) and plain forms.
/// Strings without a time zone are rejected: guessing one would put the countdown hours off.
func parseDate(_ s: String) -> Date? {
    if let d = isoPlain.date(from: s) ?? isoFrac.date(from: s) { return d }
    guard let dot = s.firstIndex(of: ".") else { return nil }
    let afterDot = s[s.index(after: dot)...]
    let digits = afterDot.prefix { $0.isNumber }
    let rest = afterDot.dropFirst(digits.count)
    let millis = digits.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0)
    return isoFrac.date(from: s[..<dot] + "." + millis + rest)
}

/// No limit window is longer than a week; anything over a year out is garbage, not a date to count down to.
let maxResetAhead: TimeInterval = 366 * 86400

/// `resets_at` as an ISO string, or as a Unix epoch in seconds or milliseconds. Rejects absurd values.
func parseReset(_ v: Any?, now: Date = Date()) -> Date? {
    let d: Date?
    if let s = v as? String { d = parseDate(s) }
    else if let n = (v as? NSNumber)?.doubleValue, n.isFinite, n > 0 { d = Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
    else { d = nil }
    return d.flatMap { $0.timeIntervalSince(now) <= maxResetAhead ? $0 : nil }
}

private func fromLimitsArray(_ arr: [[String: Any]]) -> [Limit] {
    arr.compactMap { l in
        guard let pct = (l["percent"] as? NSNumber)?.doubleValue, pct.isFinite, let kind = l["kind"] as? String else { return nil }
        let resets = parseReset(l["resets_at"])
        let elevated = (l["severity"] as? String).map { $0 != "normal" } ?? false
        switch kind {
        case "session": return Limit(kind: .session, label: "Session", percent: pct, resetsAt: resets, elevated: elevated)
        case "weekly_all": return Limit(kind: .weekly, label: "Weekly", percent: pct, resetsAt: resets, elevated: elevated)
        case "weekly_scoped":
            let scope = l["scope"] as? [String: Any]
            let name = ((scope?["model"] as? [String: Any])?["display_name"] as? String)
                ?? ((scope?["surface"] as? [String: Any])?["display_name"] as? String)
                ?? (scope?["surface"] as? String)
            guard let n = name, !n.isEmpty else { return nil }
            return Limit(kind: .scoped, label: "\(n) weekly", percent: pct, resetsAt: resets, elevated: elevated)
        default: return nil   // unknown kinds (daily, monthly, …): skip rather than mislabel
        }
    }
}

private func fromLegacyKeys(_ obj: [String: Any]) -> [Limit] {
    obj.compactMap { key, val in
        guard let d = val as? [String: Any], let u = (d["utilization"] as? NSNumber)?.doubleValue, u.isFinite else { return nil }
        let resets = parseReset(d["resets_at"])
        if key == "five_hour" { return Limit(kind: .session, label: "Session", percent: u, resetsAt: resets, elevated: false) }
        if key == "seven_day" { return Limit(kind: .weekly, label: "Weekly", percent: u, resetsAt: resets, elevated: false) }
        guard key.hasPrefix("seven_day_") else { return nil }
        let name = key.dropFirst("seven_day_".count).split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        return Limit(kind: .scoped, label: "\(name) weekly", percent: u, resetsAt: resets, elevated: false)
    }
}

/// Turns the /api/oauth/usage reply into limits, session first. Prefers the newer `limits` array and fills
/// any limit it lacks from the legacy `five_hour` / `seven_day` / `seven_day_*` keys. [] if nothing usable.
func parseUsage(_ data: Data) -> [Limit] {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    let primary = fromLimitsArray(obj["limits"] as? [[String: Any]] ?? [])
    // Fill per kind. Legacy scoped labels come from key names ("Sonnet weekly") and the new ones from
    // display_name ("Sonnet 4.5 weekly"), so they can't be matched by label: any scoped entry in `limits` wins.
    let missing = fromLegacyKeys(obj).filter { legacy in !primary.contains { $0.kind == legacy.kind } }
    return (primary + missing).sorted { ($0.kind, $0.label) < ($1.kind, $1.label) }
}

// MARK: - formatting

func pct(_ p: Double) -> String { "\(Int(min(max(p, 0), 999).rounded()))%" }

/// "resets in 1h 28m (22:20)", "resets in 20h 5m (Fri 19:57)", "resets in <1m (22:20)", "resetting now".
/// The weekday appears whenever the reset isn't today, so a time is never ambiguous.
func countdown(to d: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
    let left = Int(min(d.timeIntervalSince(now), maxResetAhead))   // clamped: Int(...) traps on huge intervals
    if left <= 0 { return "resetting now" }
    let days = left / 86400, h = (left % 86400) / 3600, m = (left % 3600) / 60
    let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = locale
    f.setLocalizedDateFormatFromTemplate(calendar.isDate(d, inSameDayAs: now) ? "jj:mm" : "EEE jj:mm")
    let span = days >= 1 ? "\(days)d \(h)h" : h >= 1 ? "\(h)h \(m)m" : m >= 1 ? "\(m)m" : "<1m"
    return "resets in \(span) (\(f.string(from: d)))"
}

/// "Updated just now", "Updated 5 min ago", "Updated 2 h ago", then "Updated Wed 21:52" once it's a day old,
/// so yesterday's numbers never read as today's.
func updatedText(_ at: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
    let ago = now.timeIntervalSince(at)
    if ago < 60 { return "Updated just now" }
    if ago < 3600 { return "Updated \(Int(ago / 60)) min ago" }
    if ago < 86400 { return "Updated \(Int(ago / 3600)) h ago" }
    let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = locale
    f.setLocalizedDateFormatFromTemplate("EEE jj:mm")
    return "Updated \(f.string(from: at))"
}

/// One tooltip / menu line. A stale limit says its window reset instead of showing an old number.
func describe(_ l: Limit, now: Date = Date()) -> String {
    if l.isStale(now: now) { return "\(l.label) – · reset, waiting for new numbers" }
    return "\(l.label) \(pct(l.percent)) · " + (l.resetsAt.map { countdown(to: $0, now: now) } ?? "no reset time")
}

/// Menu bar numbers: session and weekly. nil means unknown (missing, or its window reset since the fetch).
func barParts(_ limits: [Limit], now: Date = Date()) -> (session: Limit?, weekly: Limit?) {
    func current(_ k: Limit.Kind) -> Limit? { limits.first { $0.kind == k && !$0.isStale(now: now) } }
    return (current(.session), current(.weekly))
}

/// Hover text: when session and weekly reset, no percentages (the bar has them). Model-scoped limits are
/// left to the click menu. `status` is appended only when something is wrong.
func tooltip(_ limits: [Limit], now: Date = Date(), status: String?) -> String {
    let main = [Limit.Kind.session, .weekly].compactMap { k in limits.first { $0.kind == k } }
    let lines = main.map { l -> String in
        if l.isStale(now: now) { return "\(l.label) reset, waiting for new numbers" }
        return l.resetsAt.map { "\(l.label) \(countdown(to: $0, now: now))" } ?? "\(l.label): no reset time"
    } + [status].compactMap { $0 }
    return lines.isEmpty ? "Limitbar" : lines.joined(separator: "\n")
}

// MARK: - scheduling

enum Poll {
    static let base: TimeInterval = 300        // normal cadence
    static let maxBackoff: TimeInterval = 1800 // cap on the doubling after repeated 429s
    static let maxRetryAfter: TimeInterval = 6 * 3600  // honour Retry-After past the cap, within reason
    static let staleOnOpen: TimeInterval = 60  // menu open refetches when the last attempt is older
    static let retryDelays: [TimeInterval] = [15, 30, 60]  // after an offline failure (e.g. Wi-Fi not back after wake)
}

struct PollState: Equatable {
    var lastAttempt: Date?
    var interval: TimeInterval = Poll.base
    var paused = false   // Keychain access was refused: wait for a manual Refresh instead of re-prompting
    var offlineFailures = 0   // consecutive offline failures; the first few retry quickly
    var holdUntil: Date?      // after wake: the timer waits for the network to come back
    var timeouts = 0          // consecutive timeouts: a firewall silently dropping requests looks like this
    var liftsOnUnlock = false // paused because the Keychain didn't answer: retry once when the user is back

    var backingOff: Bool { interval > Poll.base }
    /// The quick retry delay in force, or nil when the normal interval applies.
    var retryDelay: TimeInterval? {
        guard !backingOff, offlineFailures >= 1, offlineFailures <= Poll.retryDelays.count else { return nil }
        return Poll.retryDelays[offlineFailures - 1]
    }
}

/// Should the timer fetch now? Due on the interval, or once right after a window resets
/// (compared with the last attempt, so a failing fetch can't retry every tick).
func shouldFetch(_ s: PollState, limits: [Limit], now: Date) -> Bool {
    guard !s.paused else { return false }
    if let hold = s.holdUntil, now < hold { return false }
    guard let last = s.lastAttempt, last <= now else { return true }   // a future last attempt: the clock moved back
    if now.timeIntervalSince(last) >= (s.retryDelay ?? s.interval) { return true }
    guard !s.backingOff else { return false }
    return limits.contains { l in l.resetsAt.map { $0 > last && $0 <= now } ?? false }
}

/// Should opening the menu fetch? Only when the last attempt is a minute old and nothing says wait.
func shouldFetchOnOpen(_ s: PollState, now: Date) -> Bool {
    guard !s.paused, !s.backingOff else { return false }
    return s.lastAttempt.map { now.timeIntervalSince($0) >= Poll.staleOnOpen } ?? true
}

enum Outcome: Equatable { case success, rateLimited(retryAfter: TimeInterval?), accessDenied, keychainNoAnswer, offline(timedOut: Bool), failure }

/// The next poll state after a fetch. Backoff holds until a success; access denied pauses polling;
/// offline failures retry quickly a few times, then fall back to the normal cadence.
func nextState(_ s: PollState, after o: Outcome) -> PollState {
    var n = s   // a copy; the caller's state is untouched
    switch o {
    case .success: n.interval = Poll.base; n.paused = false; n.offlineFailures = 0; n.timeouts = 0; n.liftsOnUnlock = false
    case .rateLimited(let after):
        let doubled = min(s.interval * 2, Poll.maxBackoff)
        n.interval = max(doubled, min(after ?? 0, Poll.maxRetryAfter)); n.paused = false; n.offlineFailures = 0
    case .accessDenied: n.paused = true; n.liftsOnUnlock = false
    case .keychainNoAnswer: n.paused = true; n.liftsOnUnlock = true; n.timeouts = 0
    case .offline(let timedOut):
        n.offlineFailures = min(s.offlineFailures + 1, Poll.retryDelays.count + 1)
        n.timeouts = timedOut ? s.timeouts + 1 : 0
    case .failure: n.offlineFailures = 0; n.timeouts = 0
    }
    if case .rateLimited = o { n.timeouts = 0 }
    if case .accessDenied = o { n.timeouts = 0 }
    return n
}

/// The user is back (screen unlocked or Mac woke). A pause from a Keychain that didn't answer lifts, so one
/// fetch is tried; a pause from an explicit Deny stays until Refresh, so no dialog comes back on every unlock.
func userReturned(_ s: PollState) -> PollState {
    guard s.paused, s.liftsOnUnlock else { return s }
    var n = s; n.paused = false; n.liftsOnUnlock = false; return n
}

// MARK: - status

let loginExpiredMessage = "Login expired — run Claude Code to renew"
let firewallHint = "Can't reach api.anthropic.com — check Little Snitch or your firewall allows Limitbar"
let timeoutsBeforeHint = 3
let dimAfter: TimeInterval = 600   // numbers older than 10 min are shown dimmed

/// What the menu and tooltip say about the last failure. `calm` is for the routine case (the login expires
/// overnight): a neutral line instead of a warning.
func status(_ message: String, poll: PollState) -> (text: String, calm: Bool) {
    if poll.timeouts >= timeoutsBeforeHint { return (firewallHint, false) }
    return (message, message == loginExpiredMessage)
}

/// The bar dims when its numbers may be out of date: never loaded, over 10 minutes old, or the last fetch failed.
func barDimmed(fetchedAt: Date, now: Date, failing: Bool) -> Bool {
    failing || now.timeIntervalSince(fetchedAt) > dimAfter
}

// MARK: - Keychain read via a child process

/// How a child process ended.
enum ToolRun: Equatable { case exited(status: Int32, output: Data), timedOut, couldNotRun }

private final class Box { var data = Data() }

/// Runs a tool and collects its stdout, but never waits past `deadline`: a child blocked on a dialog nobody
/// answers is sent SIGTERM, then SIGKILL, and reported as `.timedOut`. stdin is closed so it can't wait on input.
func runTool(_ path: String, _ args: [String], deadline: TimeInterval) -> ToolRun {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in exited.signal() }
    do { try p.run() } catch { return .couldNotRun }
    let box = Box(), read = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {   // drain while waiting: a full pipe would block the child
        box.data = out.fileHandleForReading.readDataToEndOfFile(); read.signal()
    }
    guard exited.wait(timeout: .now() + deadline) == .success else {
        p.terminate()
        if exited.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 1) }
        return .timedOut
    }
    return .exited(status: p.terminationStatus, output: read.wait(timeout: .now() + 2) == .success ? box.data : Data())
}

struct FetchFailure: Error, Equatable { let message: String; let outcome: Outcome
    init(_ m: String, _ o: Outcome) { message = m; outcome = o } }

/// `security -w` prints the secret as hex when it isn't plain text.
func hexDecode(_ s: String) -> Data? {
    guard s.count % 2 == 0, s.allSatisfy({ $0.isHexDigit }) else { return nil }
    var bytes = [UInt8](); bytes.reserveCapacity(s.count / 2)
    var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); guard let b = UInt8(s[i..<j], radix: 16) else { return nil }; bytes.append(b); i = j }
    return Data(bytes)
}

/// Maps a `security find-generic-password -w` run to the item's bytes or a failure.
/// `security` exits with the low byte of the OSStatus: 44 errSecItemNotFound, 128 errSecUserCanceled,
/// 36 errSecInteractionNotAllowed. No answer before the deadline means a dialog nobody answered (or a locked
/// keychain): polling pauses until Refresh rather than putting the dialog back every 5 minutes.
func keychainData(_ run: ToolRun) -> Result<Data, FetchFailure> {
    switch run {
    case .couldNotRun: return .failure(FetchFailure("Couldn't run the security tool", .failure))
    case .timedOut: return .failure(FetchFailure("Keychain didn't answer — click Refresh to try again", .keychainNoAnswer))
    case let .exited(0, data):
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(text.hasPrefix("{") ? Data(text.utf8) : hexDecode(text) ?? Data(text.utf8))
    case .exited(44, _): return .failure(FetchFailure("No Claude Code login found", .failure))
    case .exited(128, _): return .failure(FetchFailure("Keychain access denied — click Refresh to ask again", .accessDenied))
    case .exited(36, _): return .failure(FetchFailure("Keychain is locked — unlock it, then click Refresh", .failure))
    case let .exited(code, _): return .failure(FetchFailure("Keychain read failed (\(code))", .failure))
    }
}

// MARK: - pace

/// Window lengths: the session limit is 5 hours, every weekly limit 7 days.
func windowLength(_ k: Limit.Kind) -> TimeInterval { k == .session ? 5 * 3600 : 7 * 86400 }

/// Used share of a limit against the elapsed share of its window. `runsOutAt` is set when, at the rate so far,
/// the limit hits 100% before it resets: exactly the "ahead of pace" case.
struct Pace: Equatable {
    let used: Double      // percent
    let elapsed: Double   // percent of the window
    let runsOutAt: Date?
    var ahead: Bool { runsOutAt != nil }
    var reached: Bool { used >= 100 }
}

let paceMinElapsed = 5.0   // percent of the window: earlier than this, a projection is mostly noise

func pace(_ l: Limit, now: Date) -> Pace? {
    guard let reset = l.resetsAt, reset > now else { return nil }
    let length = windowLength(l.kind)
    let elapsed = length - min(reset.timeIntervalSince(now), length)
    let elapsedPct = elapsed / length * 100
    guard elapsedPct >= paceMinElapsed else { return nil }
    guard l.percent > elapsedPct, l.percent < 100 else { return Pace(used: l.percent, elapsed: elapsedPct, runsOutAt: nil) }
    let full = elapsed * 100 / l.percent   // seconds from window start to 100% at the rate so far
    return Pace(used: l.percent, elapsed: elapsedPct, runsOutAt: now.addingTimeInterval(full - elapsed))
}

/// "52% used, 30% of window elapsed — ahead of pace, runs out ~21:40" or "… — within pace".
/// The run-out time carries a weekday when it isn't today, as countdowns do.
func paceText(_ p: Pace, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
    if p.reached { return "\(pct(p.used)) used — limit reached" }
    let head = "\(pct(p.used)) used, \(pct(p.elapsed)) of window elapsed — "
    guard let out = p.runsOutAt else { return head + "within pace" }
    let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = locale
    f.setLocalizedDateFormatFromTemplate(calendar.isDate(out, inSameDayAs: now) ? "jj:mm" : "EEE jj:mm")
    return head + "ahead of pace, runs out ~\(f.string(from: out))"
}

// MARK: - notifications

struct Alert: Equatable {
    let keys: [String]   // what to record as sent; one per threshold covered, so 95% doesn't also fire 80%
    let title: String
    let body: String
}

/// One limit's notification rule: on/off and the percentages that notify.
struct LimitAlert: Codable, Equatable {
    var on = true
    var thresholds: [Double] = [80, 95]
}

/// Which limits notify and at what percentages, keyed by limit label ("Session", "Weekly", "Fable weekly").
/// Limits without an entry use the default rule. The master switch lives with the permission, in the app.
struct NotifySettings: Codable, Equatable {
    var limits: [String: LimitAlert] = [:]
    var sessionReset = true   // "Session reset" once a session passed its first threshold

    func rule(for label: String) -> LimitAlert { limits[label] ?? LimitAlert() }

    /// Unreadable or missing data gives the defaults, never a silent "notify nothing".
    static func decode(_ data: Data?) -> NotifySettings {
        data.flatMap { try? JSONDecoder().decode(NotifySettings.self, from: $0) } ?? NotifySettings()
    }
}

/// Whole percentages from 1 to 100, without duplicates, ascending.
func cleanThresholds(_ t: [Double]) -> [Double] {
    Array(Set(t.filter { $0.isFinite }.map { $0.rounded() }.filter { $0 >= 1 && $0 <= 100 })).sorted()
}

/// The limits the settings window lists: session and weekly always, then every other limit seen.
func notifyLabels(_ limits: [Limit]) -> [String] {
    let others = limits.filter { $0.kind == .scoped }.map { $0.label }
    return ["Session", "Weekly"] + others.filter { $0 != "Session" && $0 != "Weekly" }
}

let resetAlertWithin: TimeInterval = 3600   // a reset older than this (say, seen at relaunch) isn't news
let sameWindowWithin: TimeInterval = 1800   // resets this close are one window; real windows are 5 h+ apart

/// `resets_at` jitters by under a second between replies (05:20:00.39 in one, 05:19:59.9 in the next), so a
/// window is matched against sent keys with a tolerance rather than by exact value.
private func alreadySent(_ prefix: String, _ reset: Date, _ sent: Set<String>) -> Bool {
    sent.contains { key in
        guard key.hasPrefix(prefix + "|"), let e = Double(key.dropFirst(prefix.count + 1)) else { return false }
        return abs(e - reset.timeIntervalSince1970) <= sameWindowWithin
    }
}

/// Notifications due now: each enabled limit at each of its thresholds, once per window, and "Session reset"
/// when a session that passed its first threshold resets. `sent` holds keys already delivered.
func alertsDue(_ limits: [Limit], now: Date, sent: Set<String>, settings: NotifySettings = NotifySettings()) -> [Alert] {
    limits.compactMap { l -> Alert? in
        guard let reset = l.resetsAt else { return nil }
        let epoch = Int(reset.timeIntervalSince1970)
        let rule = settings.rule(for: l.label)
        let thresholds = cleanThresholds(rule.thresholds)
        if l.isStale(now: now) {
            let prefix = "\(l.label)|reset"
            guard l.kind == .session, settings.sessionReset, l.percent >= (thresholds.first ?? 80),
                  now.timeIntervalSince(reset) <= resetAlertWithin, !alreadySent(prefix, reset, sent) else { return nil }
            return Alert(keys: ["\(prefix)|\(epoch)"], title: "Session reset", body: "Your 5-hour session limit is fresh again.")
        }
        guard rule.on else { return nil }
        let crossed = thresholds.filter { l.percent >= $0 }
        guard let top = crossed.last, !alreadySent("\(l.label)|\(Int(top))", reset, sent) else { return nil }
        return Alert(keys: crossed.map { "\(l.label)|\(Int($0))|\(epoch)" }, title: "\(l.label) at \(Int(top))%",
                     body: "\(l.label) \(countdown(to: reset, now: now))")
    }
}

/// Drops keys for windows that reset over 8 days ago, so the stored set stays small.
func pruneSent(_ sent: Set<String>, now: Date) -> Set<String> {
    sent.filter { key in
        guard let epoch = key.split(separator: "|").last.flatMap({ Double($0) }) else { return false }
        return Date(timeIntervalSince1970: epoch) > now.addingTimeInterval(-8 * 86400)
    }
}

// MARK: - status-line cache (fallback when the token has expired)

/// Reads ~/Library/Application Support/Limitbar/latest.json, written by scripts/statusline-tee.py from Claude Code's
/// status-line input: `{"written_at": <epoch s>, "rate_limits": {"five_hour"|"seven_day": {"used_percentage": 0-100,
/// "resets_at": <epoch s>}}}` (documented at code.claude.com/docs/en/statusline; either window may be absent).
func parseStatusLineCache(_ data: Data, now: Date = Date()) -> (limits: [Limit], writtenAt: Date)? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let written = (obj["written_at"] as? NSNumber)?.doubleValue, written.isFinite,
          let rl = obj["rate_limits"] as? [String: Any] else { return nil }
    let writtenAt = Date(timeIntervalSince1970: written)
    guard writtenAt <= now.addingTimeInterval(60) else { return nil }   // from the future: clock or file is wrong
    func window(_ key: String, _ kind: Limit.Kind, _ label: String) -> Limit? {
        guard let w = rl[key] as? [String: Any], let p = (w["used_percentage"] as? NSNumber)?.doubleValue, p.isFinite else { return nil }
        return Limit(kind: kind, label: label, percent: p, resetsAt: parseReset(w["resets_at"], now: now), elevated: false)
    }
    let limits = [window("five_hour", .session, "Session"), window("seven_day", .weekly, "Weekly")].compactMap { $0 }
    return limits.isEmpty ? nil : (limits, writtenAt)
}

// MARK: - bar text (Settings submenu toggles)

/// How the menu bar title looks. Defaults: `52% · 34%` in Claude orange.
struct BarStyle: Equatable {
    var showSessionReset = false   // `52% · 34% · 1h28m`
    var separator = true           // the mid-dot between parts; off: `52% 34%`
    var percentSign = true         // off: `52 · 34`
    var orange = true              // off: the menu bar's own text colour (colour is applied by the app)
}

struct BarSegment: Equatable { let text: String; let hot: Bool }

/// Which colour a bar segment gets. The bar and the Settings preview both use this (via `barColor` in
/// Settings.swift), so they can't drift. Dimming when stale is applied on top, to every segment alike.
enum BarInk: Equatable { case hot, orange, plain }

func barInk(_ segment: BarSegment, style: BarStyle) -> BarInk {
    segment.hot ? .hot : style.orange ? .orange : .plain
}

/// "1h28m", "20m", "<1m": compact enough for the bar.
func shortCountdown(to d: Date, now: Date) -> String {
    let left = Int(min(max(d.timeIntervalSince(now), 0), maxResetAhead))
    let days = left / 86400, h = (left % 86400) / 3600, m = (left % 3600) / 60
    return days >= 1 ? "\(days)d\(h)h" : h >= 1 ? "\(h)h\(String(format: "%02d", m))m" : m >= 1 ? "\(m)m" : "<1m"
}

/// The bar title as segments, so the app can colour a hot number red on its own. Unknown or reset numbers are `–`.
func barSegments(_ limits: [Limit], style: BarStyle, now: Date = Date()) -> [BarSegment] {
    let (s, w) = barParts(limits, now: now)
    func number(_ l: Limit?) -> BarSegment {
        guard let l else { return BarSegment(text: "–", hot: false) }
        let p = pct(l.percent)
        return BarSegment(text: style.percentSign ? p : String(p.dropLast()), hot: l.isHot)
    }
    let gap = BarSegment(text: style.separator ? " · " : " ", hot: false)
    var parts = [number(s), gap, number(w)]
    if style.showSessionReset, let reset = s?.resetsAt {
        parts += [gap, BarSegment(text: shortCountdown(to: reset, now: now), hot: false)]
    }
    return parts
}

/// Merges status-line numbers into the current ones, per limit kind. The status line can re-send an idle
/// session's last-known numbers long after they were measured, so its write time proves nothing. Same window
/// (resets within 30 min of each other): the higher percentage wins, since use within a window doesn't go down.
/// Different windows: the later reset wins. nil when nothing from the status line wins.
func mergeStatusLine(_ current: [Limit], _ cache: [Limit]) -> [Limit]? {
    let winners = cache.filter { c in
        guard let old = current.first(where: { $0.kind == c.kind }) else { return true }
        guard let cr = c.resetsAt, let or = old.resetsAt else { return false }
        if abs(cr.timeIntervalSince(or)) <= sameWindowWithin { return c.percent > old.percent }
        return cr > or
    }
    guard !winners.isEmpty else { return nil }
    let kinds = Set(winners.map { $0.kind })
    return (winners + current.filter { !kinds.contains($0.kind) }).sorted { ($0.kind, $0.label) < ($1.kind, $1.label) }
}
