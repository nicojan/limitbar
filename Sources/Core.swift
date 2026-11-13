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

/// `resets_at` as an ISO string, or as a Unix epoch in seconds or milliseconds.
func parseReset(_ v: Any?) -> Date? {
    if let s = v as? String { return parseDate(s) }
    if let n = (v as? NSNumber)?.doubleValue, n > 0 { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
    return nil
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
func countdown(to d: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
    let left = Int(d.timeIntervalSince(now))
    if left <= 0 { return "resetting now" }
    let days = left / 86400, h = (left % 86400) / 3600, m = (left % 3600) / 60
    let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = locale
    f.setLocalizedDateFormatFromTemplate(calendar.isDate(d, inSameDayAs: now) ? "jj:mm" : "EEE jj:mm")
    let span = days >= 1 ? "\(days)d \(h)h" : h >= 1 ? "\(h)h \(m)m" : m >= 1 ? "\(m)m" : "<1m"
    return "resets in \(span) (\(f.string(from: d)))"
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
    static let maxBackoff: TimeInterval = 1800 // cap after repeated 429s
    static let staleOnOpen: TimeInterval = 60  // menu open refetches when the last attempt is older
    static let retryDelays: [TimeInterval] = [15, 30, 60]  // after an offline failure (e.g. Wi-Fi not back after wake)
}

struct PollState: Equatable {
    var lastAttempt: Date?
    var interval: TimeInterval = Poll.base
    var paused = false   // Keychain access was refused: wait for a manual Refresh instead of re-prompting
    var offlineFailures = 0   // consecutive offline failures; the first few retry quickly
    var holdUntil: Date?      // after wake: the timer waits for the network to come back

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
    guard let last = s.lastAttempt else { return true }
    if now.timeIntervalSince(last) >= (s.retryDelay ?? s.interval) { return true }
    guard !s.backingOff else { return false }
    return limits.contains { l in l.resetsAt.map { $0 > last && $0 <= now } ?? false }
}

/// Should opening the menu fetch? Only when the last attempt is a minute old and nothing says wait.
func shouldFetchOnOpen(_ s: PollState, now: Date) -> Bool {
    guard !s.paused, !s.backingOff else { return false }
    return s.lastAttempt.map { now.timeIntervalSince($0) >= Poll.staleOnOpen } ?? true
}

enum Outcome: Equatable { case success, rateLimited(retryAfter: TimeInterval?), accessDenied, offline(timedOut: Bool), failure }

/// The next poll state after a fetch. Backoff holds until a success; access denied pauses polling;
/// offline failures retry quickly a few times, then fall back to the normal cadence.
func nextState(_ s: PollState, after o: Outcome) -> PollState {
    var n = s   // a copy; the caller's state is untouched
    switch o {
    case .success: n.interval = Poll.base; n.paused = false; n.offlineFailures = 0
    case .rateLimited(let after):
        let doubled = min(s.interval * 2, Poll.maxBackoff)
        n.interval = min(max(doubled, after ?? 0), Poll.maxBackoff); n.paused = false; n.offlineFailures = 0
    case .accessDenied: n.paused = true
    case .offline: n.offlineFailures = min(s.offlineFailures + 1, Poll.retryDelays.count + 1)
    case .failure: n.offlineFailures = 0
    }
    return n
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
    case .timedOut: return .failure(FetchFailure("Keychain didn't answer — click Refresh to try again", .accessDenied))
    case let .exited(0, data):
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(text.hasPrefix("{") ? Data(text.utf8) : hexDecode(text) ?? Data(text.utf8))
    case .exited(44, _): return .failure(FetchFailure("No Claude Code login found", .failure))
    case .exited(128, _): return .failure(FetchFailure("Keychain access denied — click Refresh to ask again", .accessDenied))
    case .exited(36, _): return .failure(FetchFailure("Keychain is locked — unlock it, then click Refresh", .failure))
    case let .exited(code, _): return .failure(FetchFailure("Keychain read failed (\(code))", .failure))
    }
}
