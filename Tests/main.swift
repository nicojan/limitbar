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
check(runTool("/bin/sh", ["-c", "trap '' TERM; sleep 30"], deadline: 0.5) == .timedOut, "runTool: a child ignoring SIGTERM is killed")
check(Date().timeIntervalSince(started) < 10, "runTool: SIGKILL fallback is quick")
if case let .exited(0, big) = runTool("/bin/sh", ["-c", "head -c 200000 /dev/zero"], deadline: 5) { check(big.count == 200000, "runTool: large output") } else { check(false, "runTool: large output doesn't deadlock") }
check(runTool("/nonexistent/tool", [], deadline: 1) == .couldNotRun, "runTool: missing tool")

// MARK: keychain read mapping
check(keychainData(.exited(status: 0, output: Data("{\"a\":1}\n".utf8))) == .success(Data("{\"a\":1}".utf8)), "keychain: JSON as is")
check(keychainData(.exited(status: 0, output: Data("7b7d".utf8))) == .success(Data("{}".utf8)), "keychain: hex decoded")
check(keychainData(.exited(status: 44, output: Data())).failure?.message == "No Claude Code login found", "keychain: 44 no item")
check(keychainData(.exited(status: 128, output: Data())).failure?.outcome == .accessDenied, "keychain: 128 cancelled pauses")
check(keychainData(.timedOut).failure?.outcome == .accessDenied, "keychain: no answer pauses instead of re-prompting")
check(keychainData(.timedOut).failure?.message.contains("Refresh") == true, "keychain: no answer says how to retry")
check(keychainData(.exited(status: 36, output: Data())).failure?.message.contains("locked") == true, "keychain: 36 says locked")
check(keychainData(.couldNotRun).failure?.outcome == .failure, "keychain: missing tool")
check(hexDecode("zz") == nil && hexDecode("abc") == nil, "hex: rejects non-hex and odd length")

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
