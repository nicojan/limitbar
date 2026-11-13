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

    /// The window this number describes has reset since it was fetched, so the number is no longer true.
    func isStale(fetchedAt: Date, now: Date) -> Bool {
        guard let r = resetsAt else { return false }
        return r > fetchedAt && r <= now
    }
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
    let missing = fromLegacyKeys(obj).filter { legacy in
        !primary.contains { $0.kind == legacy.kind && ($0.kind != .scoped || $0.label == legacy.label) }
    }
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
func describe(_ l: Limit, fetchedAt: Date, now: Date = Date()) -> String {
    if l.isStale(fetchedAt: fetchedAt, now: now) { return "\(l.label) – · reset, waiting for new numbers" }
    return "\(l.label) \(pct(l.percent)) · " + (l.resetsAt.map { countdown(to: $0, now: now) } ?? "no reset time")
}

/// Menu bar numbers: session and weekly. nil means unknown (missing, or its window reset since the fetch).
func barParts(_ limits: [Limit], fetchedAt: Date, now: Date = Date()) -> (session: Limit?, weekly: Limit?) {
    func current(_ k: Limit.Kind) -> Limit? { limits.first { $0.kind == k && !$0.isStale(fetchedAt: fetchedAt, now: now) } }
    return (current(.session), current(.weekly))
}

/// Hover text: when session and weekly reset, no percentages (the bar has them). Model-scoped limits are
/// left to the click menu. `status` is appended only when something is wrong.
func tooltip(_ limits: [Limit], fetchedAt: Date, now: Date = Date(), status: String?) -> String {
    let main = [Limit.Kind.session, .weekly].compactMap { k in limits.first { $0.kind == k } }
    let lines = main.map { l -> String in
        if l.isStale(fetchedAt: fetchedAt, now: now) { return "\(l.label) reset, waiting for new numbers" }
        return l.resetsAt.map { "\(l.label) \(countdown(to: $0, now: now))" } ?? "\(l.label): no reset time"
    } + [status].compactMap { $0 }
    return lines.isEmpty ? "Limitbar" : lines.joined(separator: "\n")
}

// MARK: - scheduling

enum Poll {
    static let base: TimeInterval = 300        // normal cadence
    static let maxBackoff: TimeInterval = 1800 // cap after repeated 429s
    static let staleOnOpen: TimeInterval = 60  // menu open refetches when the last attempt is older
}

struct PollState: Equatable {
    var lastAttempt: Date?
    var interval: TimeInterval = Poll.base
    var paused = false   // Keychain access was refused: wait for a manual Refresh instead of re-prompting

    var backingOff: Bool { interval > Poll.base }
}

/// Should the timer fetch now? Due on the interval, or once right after a window resets
/// (compared with the last attempt, so a failing fetch can't retry every tick).
func shouldFetch(_ s: PollState, limits: [Limit], now: Date) -> Bool {
    guard !s.paused else { return false }
    guard let last = s.lastAttempt else { return true }
    if now.timeIntervalSince(last) >= s.interval { return true }
    guard !s.backingOff else { return false }
    return limits.contains { l in l.resetsAt.map { $0 > last && $0 <= now } ?? false }
}

/// Should opening the menu fetch? Only when the last attempt is a minute old and nothing says wait.
func shouldFetchOnOpen(_ s: PollState, now: Date) -> Bool {
    guard !s.paused, !s.backingOff else { return false }
    return s.lastAttempt.map { now.timeIntervalSince($0) >= Poll.staleOnOpen } ?? true
}

enum Outcome: Equatable { case success, rateLimited(retryAfter: TimeInterval?), accessDenied, failure }

/// The next poll state after a fetch. Backoff holds until a success; access denied pauses polling.
func nextState(_ s: PollState, after o: Outcome) -> PollState {
    switch o {
    case .success: return PollState(lastAttempt: s.lastAttempt, interval: Poll.base, paused: false)
    case .rateLimited(let after):
        let doubled = min(s.interval * 2, Poll.maxBackoff)
        return PollState(lastAttempt: s.lastAttempt, interval: min(max(doubled, after ?? 0), Poll.maxBackoff), paused: false)
    case .accessDenied: return PollState(lastAttempt: s.lastAttempt, interval: s.interval, paused: true)
    case .failure: return s
    }
}
