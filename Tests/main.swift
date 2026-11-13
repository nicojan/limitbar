import Foundation

// Tiny assertion runner: ./test.sh compiles this with Sources/Core.swift and runs it.

var failures = 0, passes = 0
func check(_ cond: @autoclosure () -> Bool, _ name: String, line: UInt = #line) {
    if cond() { passes += 1 } else { failures += 1; print("FAIL \(name) (line \(line))") }
}
func fixture(_ name: String) -> Data {
    let dir = URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("fixtures")
    return try! Data(contentsOf: dir.appendingPathComponent(name))
}
func json(_ s: String) -> Data { Data(s.utf8) }
extension Result { var failure: Failure? { if case let .failure(f) = self { return f }; return nil } }

var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
let posix = Locale(identifier: "en_US_POSIX")
let now = parseDate("2026-11-13T03:52:00+00:00")!
let fetched = now.addingTimeInterval(-60)

// MARK: dates
check(parseDate("2026-11-13T05:20:00.394316+00:00") != nil, "parses microseconds with offset")
check(parseDate("2026-11-13T05:20:00.394Z") != nil, "parses milliseconds Z")
check(parseDate("2026-11-13T05:20:00Z") != nil, "parses plain")
check(parseDate("2026-11-13T05:20:00+00:00") == parseDate("2026-11-13T05:20:00.000Z"), "plain == zero fraction")
check(parseDate("not a date") == nil, "rejects garbage")
check(parseDate("2026-11-13T05:20:00") == nil, "rejects missing time zone")
check(parseDate("2026-11-13T05:20:00.5+00:00").map { abs($0.timeIntervalSince(parseDate("2026-11-13T05:20:00Z")!) - 0.5) < 0.001 } == true, "pads short fraction")
check(parseReset(NSNumber(value: 1_763_011_200)) == Date(timeIntervalSince1970: 1_763_011_200), "epoch seconds")
check(parseReset(NSNumber(value: 1_763_011_200_000.0)) == Date(timeIntervalSince1970: 1_763_011_200), "epoch milliseconds")
check(parseReset(NSNull()) == nil && parseReset(nil) == nil, "null reset")

// MARK: parsing
// Real reply (Team plan, 2026-11-12), legacy keys edited to differ (61/44) so the test proves `limits` won.
let real = parseUsage(fixture("usage-limits.json"))
check(real.map { $0.label } == ["Session", "Weekly", "Fable weekly"], "real: labels and order")
check(real.map { $0.percent } == [52, 34, 0], "real: percents come from limits, not legacy keys")
check(real.allSatisfy { $0.resetsAt != nil }, "real: all have reset times")
check(real.allSatisfy { !$0.isHot }, "real: none hot")

let legacy = parseUsage(fixture("usage-legacy.json"))
check(legacy.map { $0.label } == ["Session", "Weekly", "Opus weekly"], "legacy: labels and order")
check(legacy.first?.isHot == true, "legacy: 93% is hot")
check(legacy.last?.resetsAt == nil, "legacy: missing resets_at tolerated")

let partial = parseUsage(json(#"{"limits":[{"kind":"session","percent":10,"severity":"normal","resets_at":null}],"five_hour":{"utilization":99},"seven_day":{"utilization":44,"resets_at":null}}"#))
check(partial.map { "\($0.label)=\(Int($0.percent))" } == ["Session=10", "Weekly=44"], "partial limits: weekly filled from legacy, session not overridden")

let dedupe = parseUsage(json(#"{"limits":[{"kind":"session","percent":1},{"kind":"weekly_all","percent":2},{"kind":"weekly_scoped","percent":3,"scope":{"model":{"display_name":"Opus"}}}],"seven_day_opus":{"utilization":50}}"#))
check(dedupe.map { $0.percent } == [1, 2, 3], "scoped legacy duplicate dropped")

// Bug 5: legacy key names ("Sonnet weekly") don't match display_name ("Sonnet 4.5 weekly"); no duplicate.
let mismatched = parseUsage(json(#"{"limits":[{"kind":"session","percent":1},{"kind":"weekly_all","percent":2},{"kind":"weekly_scoped","percent":3,"scope":{"model":{"display_name":"Sonnet 4.5"}}}],"seven_day_sonnet":{"utilization":3},"seven_day_opus":{"utilization":7}}"#))
check(mismatched.map { $0.label } == ["Session", "Weekly", "Sonnet 4.5 weekly"], "scoped legacy dropped when limits has scoped: \(mismatched.map { $0.label })")
let legacyScopedOnly = parseUsage(json(#"{"limits":[{"kind":"session","percent":1}],"seven_day":{"utilization":2},"seven_day_opus":{"utilization":7}}"#))
check(legacyScopedOnly.map { $0.label } == ["Session", "Weekly", "Opus weekly"], "legacy scoped kept when limits has none")

let unknown = parseUsage(json(#"{"limits":[{"kind":"session","percent":5},{"kind":"monthly","percent":9,"scope":{"model":{"display_name":"Fable"}}}]}"#))
check(unknown.map { $0.label } == ["Session"], "unknown kinds skipped, not called weekly")

let warn = parseUsage(json(#"{"limits":[{"kind":"session","percent":70,"severity":"warning","resets_at":null}]}"#))
check(warn.count == 1 && warn[0].isHot, "severity warning is hot")

check(parseUsage(json("[]")).isEmpty, "array reply -> empty")
check(parseUsage(json("{}")).isEmpty, "empty object -> empty")
check(parseUsage(json("<html>")).isEmpty, "html -> empty")
check(parseUsage(json(#"{"limits":[{"kind":"weekly_scoped","percent":5,"scope":null}]}"#)).isEmpty, "scoped without name -> empty")

// MARK: formatting
func norm(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }  // macOS puts a narrow no-break space before AM/PM
func cd(_ seconds: Int) -> String { norm(countdown(to: now.addingTimeInterval(TimeInterval(seconds)), now: now, calendar: utc, locale: posix)) }
check(cd(-5) == "resetting now", "past -> resetting now")
check(cd(0) == "resetting now", "zero -> resetting now")
check(cd(30) == "resets in <1m (3:52 AM)", "under a minute: \(cd(30))")
check(cd(28 * 60) == "resets in 28m (4:20 AM)", "minutes: \(cd(28 * 60))")
check(cd(88 * 60) == "resets in 1h 28m (5:20 AM)", "hours: \(cd(88 * 60))")
check(cd(21 * 3600) == "resets in 21h 0m (Sat 12:52 AM)", "under a day but tomorrow shows weekday: \(cd(21 * 3600))")
check(cd(6 * 86400 + 7 * 3600) == "resets in 6d 7h (Thu 10:52 AM)", "days: \(cd(6 * 86400 + 7 * 3600))")
check(pct(51.6) == "52%" && pct(0) == "0%", "percent rounding")
check(pct(1e300) == "999%" && pct(-3) == "0%", "percent clamped")

// MARK: staleness, bar, tooltip
let session = real[0]   // resets 05:20:00.39
let afterReset = parseDate("2026-11-13T05:21:00Z")!
check(!session.isStale(now: now), "fresh before reset")
check(session.isStale(now: afterReset), "stale after reset")
// Bug 4: request sent before the reset, reply after it. The old number must not show as current.
check(session.isStale(now: afterReset.addingTimeInterval(60)), "a reply that straddles the reset is still stale")

let parts = barParts(real, now: now)
check(parts.session?.percent == 52 && parts.weekly?.percent == 34, "bar parts")
check(barParts(real, now: afterReset).session == nil, "bar hides a reset session")
check(barParts(real, now: afterReset).weekly?.percent == 34, "bar keeps a live weekly")
check(barParts([]).session == nil, "bar parts empty")

// Tooltip: reset times for session and weekly only, no percentages; scoped limits live in the menu.
let tip = tooltip(real, now: now, status: nil)
let tipLines = tip.split(separator: "\n").map(String.init)
check(tipLines.count == 2, "tooltip: session and weekly only: \(tip)")
check(tipLines.first?.hasPrefix("Session resets in 1h 28m (") == true, "tooltip session line: \(tip)")
check(tipLines.last?.hasPrefix("Weekly resets in 5d 23h (") == true, "tooltip weekly line: \(tip)")
check(!tip.contains("%"), "tooltip has no percentages")
check(!tip.contains("Fable"), "tooltip leaves scoped limits to the menu")
check(tooltip(real, now: now, status: "Login expired").split(separator: "\n").last == "Login expired", "tooltip appends status")
check(tooltip(real, now: afterReset, status: nil).hasPrefix("Session reset, waiting for new numbers"), "tooltip marks reset session")
check(tooltip([], status: nil) == "Limitbar", "tooltip empty")
check(tooltip([], status: "Offline") == "Offline", "tooltip status only")
let noReset = parseUsage(json(#"{"limits":[{"kind":"session","percent":5,"resets_at":null}]}"#))
check(tooltip(noReset, now: now, status: nil) == "Session: no reset time", "tooltip without reset time")

// MARK: scheduling
let t0 = now
let fresh = PollState()
check(shouldFetch(fresh, limits: [], now: t0), "first tick fetches")
let polled = PollState(lastAttempt: t0)
check(!shouldFetch(polled, limits: real, now: t0.addingTimeInterval(299)), "not due before 5 min")
check(shouldFetch(polled, limits: real, now: t0.addingTimeInterval(300)), "due at 5 min")
check(shouldFetch(PollState(lastAttempt: parseDate("2026-11-13T05:18:00Z")!), limits: real, now: afterReset), "fetches right after a reset")
// The fetch after the reset failed: lastAttempt is now past the reset, so the next tick must not retry.
check(!shouldFetch(PollState(lastAttempt: afterReset), limits: real, now: afterReset.addingTimeInterval(60)), "failed post-reset fetch doesn't retry every tick")
let beforeReset = parseDate("2026-11-13T05:15:00Z")!   // backing off until 05:25; the reset at 05:20 falls inside
check(!shouldFetch(PollState(lastAttempt: beforeReset, interval: 600), limits: real, now: afterReset), "backoff suppresses reset refetch")
check(shouldFetch(PollState(lastAttempt: beforeReset), limits: real, now: afterReset), "same moment without backoff does refetch")
check(!shouldFetch(PollState(lastAttempt: t0, interval: Poll.base, paused: true), limits: real, now: t0.addingTimeInterval(9999)), "paused never fetches")

// Bug 3: an offline failure retries at 15 s, 30 s, 60 s, then the normal 5 min.
let off1 = nextState(polled, after: .offline(timedOut: false))
check(off1.retryDelay == 15, "first offline failure retries in 15 s")
check(!shouldFetch(off1, limits: real, now: t0.addingTimeInterval(14)) && shouldFetch(off1, limits: real, now: t0.addingTimeInterval(15)), "retry due at 15 s")
let off3 = nextState(nextState(off1, after: .offline(timedOut: false)), after: .offline(timedOut: false))
check(off3.retryDelay == 60, "third offline failure retries in 60 s")
let off4 = nextState(off3, after: .offline(timedOut: false))
check(off4.retryDelay == nil && !shouldFetch(off4, limits: [], now: t0.addingTimeInterval(299)), "then back to the normal cadence")
check(nextState(off3, after: .success).retryDelay == nil, "success ends fast retries")
let limited = PollState(lastAttempt: t0, interval: 600)
check(nextState(limited, after: .offline(timedOut: false)).retryDelay == nil, "no fast retries while rate limited")
check(nextState(limited, after: .offline(timedOut: false)).interval == 600, "offline keeps the 429 backoff")
// After wake the timer holds off until the grace period ends, so it can't fetch before the network is back.
let held = PollState(lastAttempt: t0.addingTimeInterval(-600), holdUntil: t0.addingTimeInterval(5))
check(!shouldFetch(held, limits: [], now: t0.addingTimeInterval(4)), "timer holds during the wake grace period")
check(shouldFetch(held, limits: [], now: t0.addingTimeInterval(5)), "timer fetches after the grace period")

check(shouldFetchOnOpen(PollState(lastAttempt: t0), now: t0.addingTimeInterval(61)), "open refetches stale data")
check(!shouldFetchOnOpen(PollState(lastAttempt: t0), now: t0.addingTimeInterval(30)), "open keeps fresh data")
check(!shouldFetchOnOpen(PollState(lastAttempt: t0, interval: 600), now: t0.addingTimeInterval(999)), "open respects backoff")
check(!shouldFetchOnOpen(PollState(lastAttempt: t0, paused: true), now: t0.addingTimeInterval(999)), "open respects pause")

let b1 = nextState(polled, after: .rateLimited(retryAfter: nil))
check(b1.interval == 600, "429 doubles")
let b2 = nextState(nextState(nextState(b1, after: .rateLimited(retryAfter: nil)), after: .rateLimited(retryAfter: nil)), after: .rateLimited(retryAfter: nil))
check(b2.interval == Poll.maxBackoff, "429 caps at 30 min")
check(nextState(polled, after: .rateLimited(retryAfter: 1200)).interval == 1200, "Retry-After respected")
check(nextState(b1, after: .failure).interval == 600, "other failure keeps backoff")
check(nextState(b1, after: .success).interval == Poll.base, "success resets backoff")
check(nextState(polled, after: .accessDenied).paused, "access denied pauses")
check(!nextState(PollState(lastAttempt: t0, paused: true), after: .success).paused, "success unpauses")

// MARK: child process deadline (bug 1: a blocked `security` must not freeze fetching forever)
check(runTool("/bin/echo", ["hi"], deadline: 5) == .exited(status: 0, output: Data("hi\n".utf8)), "runTool: output and status")
check(runTool("/bin/sh", ["-c", "exit 44"], deadline: 5) == .exited(status: 44, output: Data()), "runTool: exit status")
let started = Date()
check(runTool("/bin/sleep", ["30"], deadline: 0.5) == .timedOut, "runTool: deadline kills a blocked child")
check(Date().timeIntervalSince(started) < 5, "runTool: returns soon after the deadline")
let marker = "limitbar-test-\(getpid())"
check(runTool("/usr/bin/perl", ["-e", "$SIG{TERM}='IGNORE'; sleep 30", marker], deadline: 0.5) == .timedOut, "runTool: a child ignoring SIGTERM times out")
check(runTool("/usr/bin/pgrep", ["-f", marker], deadline: 5) == .exited(status: 1, output: Data()), "runTool: the SIGTERM-ignoring child is really gone (SIGKILL)")
check(Date().timeIntervalSince(started) < 10, "runTool: SIGKILL fallback is quick")
if case let .exited(0, big) = runTool("/bin/sh", ["-c", "head -c 200000 /dev/zero"], deadline: 5) { check(big.count == 200000, "runTool: large output") } else { check(false, "runTool: large output doesn't deadlock") }
check(runTool("/nonexistent/tool", [], deadline: 1) == .couldNotRun, "runTool: missing tool")

// MARK: keychain read mapping
check(keychainData(.exited(status: 0, output: Data("{\"a\":1}\n".utf8))) == .success(Data("{\"a\":1}".utf8)), "keychain: JSON as is")
check(keychainData(.exited(status: 0, output: Data("7b7d".utf8))) == .success(Data("{}".utf8)), "keychain: hex decoded")
check(keychainData(.exited(status: 44, output: Data())).failure?.message == "No Claude Code login found", "keychain: 44 no item")
check(keychainData(.exited(status: 128, output: Data())).failure?.outcome == .accessDenied, "keychain: 128 cancelled pauses")
// Review 3: a refused access-list read is likely errSecAuthFailed (51), not only 128; either pauses instead of re-prompting.
check(keychainData(.exited(status: 51, output: Data())).failure?.outcome == .accessDenied, "keychain: 51 auth failed pauses")
check(keychainData(.timedOut).failure?.outcome == .keychainNoAnswer, "keychain: no answer pauses instead of re-prompting")
check(keychainData(.timedOut).failure?.message.contains("Refresh") == true, "keychain: no answer says how to retry")
check(keychainData(.exited(status: 36, output: Data())).failure?.message.contains("locked") == true, "keychain: 36 says locked")
check(keychainData(.couldNotRun).failure?.outcome == .failure, "keychain: missing tool")
check(hexDecode("zz") == nil && hexDecode("abc") == nil, "hex: rejects non-hex and odd length")

// MARK: phase 3
// Bug 6: Retry-After beyond the 30 min doubling cap is honoured (within a sane 6 h ceiling).
check(nextState(polled, after: .rateLimited(retryAfter: 3600)).interval == 3600, "Retry-After over 30 min honoured")
check(nextState(polled, after: .rateLimited(retryAfter: 1e9)).interval == Poll.maxRetryAfter, "absurd Retry-After capped")
check(nextState(PollState(lastAttempt: t0, interval: 3600), after: .rateLimited(retryAfter: nil)).interval == Poll.maxBackoff, "doubling still capped at 30 min")

// Bug 9: absurd reset times are rejected instead of trapping in Int(...).
check(parseReset(NSNumber(value: 1e300), now: now) == nil, "huge epoch rejected")
check(parseReset(NSNumber(value: Double.infinity), now: now) == nil, "infinite epoch rejected")
check(parseReset("9999-01-01T00:00:00Z", now: now) == nil, "far-future ISO rejected")
check(parseReset("2026-11-19T03:00:00Z", now: now) != nil, "a week out accepted")
check(norm(countdown(to: .distantFuture, now: now, calendar: utc, locale: posix)).hasPrefix("resets in "), "countdown survives a far date")

// Bug 10 / UX: relative "Updated" time; a weekday once it's a day old.
func upd(_ ago: TimeInterval) -> String { norm(updatedText(now.addingTimeInterval(-ago), now: now, calendar: utc, locale: posix)) }
check(upd(20) == "Updated just now", "updated: just now")
check(upd(5 * 60) == "Updated 5 min ago", "updated: minutes")
check(upd(2 * 3600 + 100) == "Updated 2 h ago", "updated: hours")
check(upd(30 * 3600) == "Updated Wed 9:52 PM", "updated: over a day shows weekday: \(upd(30 * 3600))")

// MARK: phase 4 (UX)
// Dim the bar when the numbers may be out of date, instead of a cryptic " !".
check(!barDimmed(fetchedAt: now.addingTimeInterval(-60), now: now, failing: false), "fresh data: bright")
check(barDimmed(fetchedAt: now.addingTimeInterval(-11 * 60), now: now, failing: false), "over 10 min old: dimmed")
check(barDimmed(fetchedAt: now.addingTimeInterval(-60), now: now, failing: true), "last fetch failed: dimmed")
check(barDimmed(fetchedAt: .distantPast, now: now, failing: false), "never loaded: dimmed")

// Firewall hint after 3 consecutive timeouts; any other result resets the count.
let to1 = nextState(polled, after: .offline(timedOut: true))
let to3 = nextState(nextState(to1, after: .offline(timedOut: true)), after: .offline(timedOut: true))
check(to1.timeouts == 1 && to3.timeouts == 3, "timeouts counted")
check(nextState(to3, after: .offline(timedOut: false)).timeouts == 0, "a non-timeout offline error resets the count")
check(nextState(to3, after: .success).timeouts == 0, "success resets the count")
check(status("Offline (The request timed out.)", poll: to1).text == "Offline (The request timed out.)", "one timeout: plain message")
check(status("Offline (The request timed out.)", poll: to3).text == firewallHint, "three timeouts: firewall hint")
check(firewallHint.contains("api.anthropic.com") && firewallHint.contains("Little Snitch"), "hint names host and filter")

// An expired login is routine overnight: calm, not a warning.
check(status(loginExpiredMessage, poll: polled).calm, "expired login is calm")
check(!status("Usage service unavailable (500)", poll: polled).calm, "server error is a warning")

// MARK: phase 5: pace
func lim(_ k: Limit.Kind, _ p: Double, resetsIn: TimeInterval?, label: String? = nil) -> Limit {
    Limit(kind: k, label: label ?? (k == .session ? "Session" : "Weekly"), percent: p, resetsAt: resetsIn.map { now.addingTimeInterval($0) }, elevated: false)
}
// Session: 5 h window, 3.5 h left -> 1.5 h (30%) elapsed. 52% used: ahead, 100% after 1.5 h * 100/52 = 2.885 h from window start.
let ahead = pace(lim(.session, 52, resetsIn: 3.5 * 3600), now: now)
check(ahead.map { Int($0.elapsed.rounded()) } == 30, "pace: elapsed share of the window")
check(ahead?.ahead == true, "pace: 52% used at 30% elapsed is ahead")
let expectedOut = now.addingTimeInterval(-1.5 * 3600 + 1.5 * 3600 * 100 / 52)
check(ahead?.runsOutAt.map { abs($0.timeIntervalSince(expectedOut)) < 1 } == true, "pace: projected run-out time")
check(ahead.map { norm(paceText($0, now: now, calendar: utc, locale: posix)) } == "52% used, 30% of window elapsed — ahead of pace, runs out ~5:15 AM", "pace text ahead: \(ahead.map { paceText($0, now: now, calendar: utc, locale: posix) } ?? "nil")")
let behind = pace(lim(.weekly, 20, resetsIn: 3.5 * 86400), now: now)   // 7 d window, half elapsed
check(behind?.ahead == false && behind?.runsOutAt == nil, "pace: 20% at 50% elapsed is within pace")
check(behind.map { paceText($0, now: now, calendar: utc, locale: posix) } == "20% used, 50% of window elapsed — within pace", "pace text within")
let weeklyAhead = pace(lim(.weekly, 60, resetsIn: 4 * 86400), now: now)!   // 3 of 7 days gone: 100% at day 5
check(norm(paceText(weeklyAhead, now: now, calendar: utc, locale: posix)) == "60% used, 43% of window elapsed — ahead of pace, runs out ~Sun 3:52 AM", "pace text: another day shows the weekday: \(paceText(weeklyAhead, now: now, calendar: utc, locale: posix))")
check(pace(lim(.session, 3, resetsIn: 4.9 * 3600), now: now) == nil, "pace: too early in the window to project")
check(pace(lim(.session, 50, resetsIn: nil), now: now) == nil, "pace: no reset time")
check(pace(lim(.session, 50, resetsIn: -60), now: now) == nil, "pace: window already reset")
check(pace(lim(.session, 100, resetsIn: 3600), now: now)?.runsOutAt == nil, "pace: already at 100% has no projection")
check(pace(lim(.scoped, 60, resetsIn: 3.5 * 86400, label: "Fable weekly"), now: now)?.ahead == true, "pace: scoped limits use the weekly window")

// MARK: phase 5: notifications
let at85 = [lim(.session, 85, resetsIn: 3600), lim(.weekly, 40, resetsIn: 86400)]
let due85 = alertsDue(at85, now: now, sent: [])
check(due85.map { $0.title } == ["Session at 80%"], "alert: crossing 80% notifies once: \(due85.map { $0.title })")
check(due85.first?.body.hasPrefix("Session resets in 1h 0m") == true, "alert body says when it resets")
check(alertsDue(at85, now: now, sent: Set(due85.flatMap { $0.keys })).isEmpty, "alert: not repeated in the same window")
let at96 = [lim(.session, 96, resetsIn: 3600)]
check(alertsDue(at96, now: now, sent: []).map { $0.title } == ["Session at 95%"], "alert: jumping past both thresholds sends only the higher")
check(alertsDue(at96, now: now, sent: Set(due85.flatMap { $0.keys })).map { $0.title } == ["Session at 95%"], "alert: 95% after 80% in the same window")
check(alertsDue([lim(.session, 85, resetsIn: 3600 + 5 * 3600)], now: now, sent: Set(due85.flatMap { $0.keys })).count == 1, "alert: a new window notifies again")
check(alertsDue([lim(.weekly, 81, resetsIn: 86400, label: "Fable weekly")], now: now, sent: []).first?.title == "Fable weekly at 80%", "alert: scoped limits too")
// Session reset: only for a session pushed past 80%, and only soon after the reset itself.
check(alertsDue([lim(.session, 85, resetsIn: -30)], now: now, sent: []).map { $0.title } == ["Session reset"], "alert: session reset after 80%")
check(alertsDue([lim(.session, 50, resetsIn: -30)], now: now, sent: []).isEmpty, "alert: no reset notice for a light session")
check(alertsDue([lim(.session, 85, resetsIn: -2 * 3600)], now: now, sent: []).isEmpty, "alert: no reset notice for an old reset (e.g. after relaunch)")
check(alertsDue([lim(.session, 85, resetsIn: nil)], now: now, sent: []).isEmpty, "alert: needs a reset time to know the window")
let oldKey = "Session|80|\(Int(now.addingTimeInterval(-9 * 86400).timeIntervalSince1970))"
check(pruneSent(Set(due85.flatMap { $0.keys }).union([oldKey]), now: now) == Set(due85.flatMap { $0.keys }), "alert keys for long-gone windows are pruned")

// MARK: feature 3: status-line cache (shape from code.claude.com/docs/en/statusline: used_percentage 0-100, resets_at epoch s)
let cacheNow = Date(timeIntervalSince1970: 1794540600)   // 10 min after it was written
let cached = parseStatusLineCache(fixture("statusline-cache.json"), now: cacheNow)
check(cached?.writtenAt == Date(timeIntervalSince1970: 1794540000.5), "cache: written_at")
check(cached?.limits.map { "\($0.label)=\($0.percent)" } == ["Session=23.5", "Weekly=41.2"], "cache: session and weekly")
check(cached?.limits.first?.resetsAt == Date(timeIntervalSince1970: 1794545400), "cache: epoch seconds reset")
check(parseStatusLineCache(json(#"{"written_at":1794540000,"rate_limits":{"seven_day":{"used_percentage":5,"resets_at":1794960000}}}"#), now: cacheNow)?.limits.map { $0.label } == ["Weekly"], "cache: a window may be absent")
check(parseStatusLineCache(json(#"{"written_at":1794540000,"rate_limits":{}}"#), now: cacheNow) == nil, "cache: no windows -> nil")
check(parseStatusLineCache(json(#"{"rate_limits":{"five_hour":{"used_percentage":5}}}"#), now: cacheNow) == nil, "cache: no written_at -> nil")
// Real file written by the wrapper from a live Claude Code status line (2026-11-12, Team plan).
let realCache = parseStatusLineCache(fixture("statusline-cache-real.json"), now: Date(timeIntervalSince1970: 1794543600))
check(realCache?.limits.map { "\($0.label)=\(Int($0.percent))" } == ["Session=76", "Weekly=38"], "cache: real capture parses")
check(parseStatusLineCache(json("garbage"), now: cacheNow) == nil, "cache: garbage -> nil")
check(parseStatusLineCache(json(#"{"written_at":1894540000,"rate_limits":{"five_hour":{"used_percentage":5}}}"#), now: cacheNow) == nil, "cache: written in the future -> nil")

// MARK: bar style toggles (Settings submenu)
func bar(_ l: [Limit], _ st: BarStyle) -> String { barSegments(l, style: st, now: now).map { $0.text }.joined() }
let two = [lim(.session, 52, resetsIn: 88 * 60), lim(.weekly, 34, resetsIn: 86400)]
check(bar(two, BarStyle()) == "52% · 34%", "bar default: \(bar(two, BarStyle()))")
check(bar(two, BarStyle(showSessionReset: true)) == "52% · 34% · 1h28m", "bar with session reset")
check(bar(two, BarStyle(separator: false)) == "52% 34%", "bar without mid-dot")
check(bar(two, BarStyle(showSessionReset: true, separator: false)) == "52% 34% 1h28m", "bar without mid-dot, with reset")
check(bar(two, BarStyle(percentSign: false)) == "52 · 34", "bar without % sign")
check(bar([lim(.session, 52, resetsIn: 20 * 60), two[1]], BarStyle(showSessionReset: true)) == "52% · 34% · 20m", "reset under an hour")
check(bar([lim(.session, 52, resetsIn: 30), two[1]], BarStyle(showSessionReset: true)) == "52% · 34% · <1m", "reset under a minute")
check(bar([lim(.session, 52, resetsIn: -60), two[1]], BarStyle(showSessionReset: true)) == "– · 34%", "reset session: dash, no countdown")
check(bar([lim(.session, 52, resetsIn: nil), two[1]], BarStyle(showSessionReset: true)) == "52% · 34%", "no reset time: no countdown")
check(barSegments([lim(.session, 95, resetsIn: 600), two[1]], style: BarStyle(), now: now).map { $0.hot } == [true, false, false], "hot marks only its number")
// One colour rule for the bar and the Settings preview: hot red; the rest orange or the menu bar colour.
let hotFirst = barSegments([lim(.session, 95, resetsIn: 600), two[1]], style: BarStyle(), now: now)
check(hotFirst.map { barInk($0, style: BarStyle()) } == [.hot, .orange, .orange], "ink: hot red, rest orange")
check(hotFirst.map { barInk($0, style: BarStyle(orange: false)) } == [.hot, .plain, .plain], "ink: hot red, rest plain with orange off")

// MARK: review fixes
// 1: resets_at jitters by under a second between replies (05:20:00.39 vs 05:19:59.9); same window, no repeat.
let jittered = [lim(.session, 85, resetsIn: 3600 - 0.6)]
check(alertsDue(jittered, now: now, sent: Set(due85.flatMap { $0.keys })).isEmpty, "alert: sub-second reset jitter is the same window")
check(alertsDue([lim(.session, 85, resetsIn: 3600 + 1.2)], now: now, sent: Set(due85.flatMap { $0.keys })).isEmpty, "alert: jitter the other way too")
// 2: at or over 100% the pace line must not read as calm.
let full = pace(lim(.session, 100, resetsIn: 3.5 * 3600), now: now)
check(full?.reached == true && full?.ahead == false, "pace: 100% is 'reached', not ahead or within")
check(full.map { paceText($0, now: now, calendar: utc, locale: posix) } == "100% used — limit reached", "pace text at the limit")
check(pace(lim(.session, 104, resetsIn: 3.5 * 3600), now: now)?.reached == true, "pace: over 100% is reached")
// 4: a Keychain that didn't answer pauses, but the pause lifts once when the user is back (unlock / wake).
let noAnswer = nextState(polled, after: .keychainNoAnswer)
check(noAnswer.paused && noAnswer.liftsOnUnlock, "no answer pauses, liftable")
check(!userReturned(noAnswer).paused, "user back: no-answer pause lifted")
let denied = nextState(polled, after: .accessDenied)
check(userReturned(denied).paused, "user back: an explicit deny stays paused (no dialog every unlock)")
check(!nextState(noAnswer, after: .success).liftsOnUnlock, "success clears the flag")
// 5: the clock moved backwards past the last attempt: fetch rather than wait for the clock to catch up.
check(shouldFetch(PollState(lastAttempt: t0.addingTimeInterval(3600)), limits: [], now: t0), "clock moved back: due")

// MARK: per-limit notification settings
check(cleanThresholds([95, 80, 80, 0, 101, -5, .nan, 79.6]) == [80, 95], "thresholds: rounded, deduped, 1-100, sorted")
var ns = NotifySettings()
check(ns.rule(for: "Fable weekly") == LimitAlert(on: true, thresholds: [80, 95]), "default rule for any limit: 80 and 95")
ns.limits["Weekly"] = LimitAlert(on: false, thresholds: [80, 95])
ns.limits["Session"] = LimitAlert(on: true, thresholds: [50])
let mixed = [lim(.session, 60, resetsIn: 3600), lim(.weekly, 99, resetsIn: 86400)]
check(alertsDue(mixed, now: now, sent: [], settings: ns).map { $0.title } == ["Session at 50%"], "per-limit: custom threshold, weekly off")
ns.limits["Session"] = LimitAlert(on: true, thresholds: [])
check(alertsDue(mixed, now: now, sent: [], settings: ns).isEmpty, "per-limit: no thresholds means no alerts")
// Session reset follows the session's lowest threshold, and has its own switch.
var resetRule = NotifySettings(); resetRule.limits["Session"] = LimitAlert(on: true, thresholds: [60, 90])
check(alertsDue([lim(.session, 65, resetsIn: -30)], now: now, sent: [], settings: resetRule).map { $0.title } == ["Session reset"], "reset notice after the session's first threshold")
check(alertsDue([lim(.session, 55, resetsIn: -30)], now: now, sent: [], settings: resetRule).isEmpty, "no reset notice below it")
resetRule.sessionReset = false
check(alertsDue([lim(.session, 65, resetsIn: -30)], now: now, sent: [], settings: resetRule).isEmpty, "reset notice can be turned off")
// Persisted as JSON; unreadable data falls back to defaults rather than silencing everything.
let encoded = try! JSONEncoder().encode(ns)
check(NotifySettings.decode(encoded) == ns, "settings round-trip")
check(NotifySettings.decode(Data("junk".utf8)) == NotifySettings(), "bad settings data -> defaults")
check(NotifySettings.decode(nil) == NotifySettings(), "no settings -> defaults")
check(notifyLabels(real) == ["Session", "Weekly", "Fable weekly"], "settings list every known limit")
check(notifyLabels([]) == ["Session", "Weekly"], "settings always list session and weekly")

// Review 2 #6: a reset near a 10-minute edge (04:55:00 +/- 0.6 s) is still one window.
let edgeNow = parseDate("2026-11-13T04:00:00Z")!
let edgeA = Limit(kind: .session, label: "Session", percent: 85, resetsAt: parseDate("2026-11-13T04:54:59.4Z"), elevated: false)
let edgeB = Limit(kind: .session, label: "Session", percent: 85, resetsAt: parseDate("2026-11-13T04:55:00.4Z"), elevated: false)
let edgeSent = Set(alertsDue([edgeA], now: edgeNow, sent: []).flatMap { $0.keys })
check(alertsDue([edgeB], now: edgeNow, sent: edgeSent).isEmpty, "alert: jitter across a rounding edge is one window")
check(alertsDue([lim(.session, 85, resetsIn: 3600 + 5 * 3600)], now: now, sent: edgeSent.union(Set(due85.flatMap { $0.keys }))).count == 1, "alert: the next window still notifies")

// Review 2 #1: status-line numbers merge per window; an idle session re-sending old numbers never wins.
let apiNow = [lim(.session, 70, resetsIn: 3600), lim(.weekly, 40, resetsIn: 86400), lim(.scoped, 5, resetsIn: 86400, label: "Fable weekly")]
check(mergeStatusLine(apiNow, [lim(.session, 40, resetsIn: 3600 + 0.5)]) == nil, "merge: same window, lower % (idle session) loses")
let higher = mergeStatusLine(apiNow, [lim(.session, 76, resetsIn: 3600)])
check(higher?.map { "\($0.label)=\(Int($0.percent))" } == ["Session=76", "Weekly=40", "Fable weekly=5"], "merge: same window, higher % wins; others kept")
check(mergeStatusLine(apiNow, [lim(.session, 3, resetsIn: 3600 + 5 * 3600)])?.first?.percent == 3, "merge: a later window wins even at a lower %")
check(mergeStatusLine(apiNow, [lim(.session, 90, resetsIn: 3600 - 5 * 3600)]) == nil, "merge: an earlier window loses")
check(mergeStatusLine([], [lim(.weekly, 12, resetsIn: 86400)])?.map { $0.label } == ["Weekly"], "merge: fills a missing limit")

// Keychain notice: explained before the first read, and again before a retry after macOS's prompt was refused or unanswered.
check(keychainNoticeNeeded(acknowledged: false, last: nil), "notice: first read is explained")
check(!keychainNoticeNeeded(acknowledged: true, last: nil), "notice: once acknowledged, not again")
check(!keychainNoticeNeeded(acknowledged: true, last: .success), "notice: not after a good read")
check(!keychainNoticeNeeded(acknowledged: true, last: .offline(timedOut: true)), "notice: not for a network failure")
check(keychainNoticeNeeded(acknowledged: true, last: .accessDenied), "notice: again after Deny")
check(keychainNoticeNeeded(acknowledged: true, last: .keychainNoAnswer), "notice: again after an unanswered prompt")

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
