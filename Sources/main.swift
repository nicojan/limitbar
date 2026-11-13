import Cocoa
import Security
import ServiceManagement
import UserNotifications

// Limitbar: Claude session and weekly limits in the menu bar.
// Reads the token Claude Code keeps in the login Keychain (read-only: it never refreshes or writes it,
// because refreshing would sign Claude Code out) and asks Claude's usage service for the limits.

enum Config {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let usagePage = URL(string: "https://claude.ai/settings/usage")!
    static let authorPage = URL(string: "https://nicojan.com/")!
    static let keychainService = "Claude Code-credentials"
    static let tick: TimeInterval = 60      // re-render countdowns, check whether a fetch is due
    static let timeout: TimeInterval = 10
    static let keychainDeadline: TimeInterval = 15
    static let statusLineCache = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Limitbar/latest.json")
    static let stuckAfter: TimeInterval = 60  // an outstanding fetch older than this no longer blocks new ones
    static let wakeDelay: TimeInterval = 5  // let the network come back after sleep
}

// MARK: - Keychain + network

enum FetchResult {
    case limits([Limit], plan: String)
    case failure(String, Outcome)
}


/// Reads the item through /usr/bin/security, the tool Claude Code itself saves it with. The item's access list
/// already trusts that tool, so there is no Keychain dialog, and rebuilding Limitbar (a new ad-hoc signature)
/// doesn't bring one back either. Read-only: `find-generic-password -w` prints the secret and changes nothing.
/// The deadline keeps a dialog nobody answers from blocking every later fetch.
func readKeychainItem() -> Result<Data, FetchFailure> {
    keychainData(runTool("/usr/bin/security", ["find-generic-password", "-s", Config.keychainService, "-w"], deadline: Config.keychainDeadline))
}

func readCredential(now: Date = Date()) -> Result<(token: String, plan: String), FetchFailure> {
    let raw: Data
    switch readKeychainItem() {
    case let .failure(f): return .failure(f)
    case let .success(d): raw = d
    }
    guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String, !token.isEmpty else {
        return .failure(FetchFailure("Claude Code login unreadable", .failure))
    }
    if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue, Date(timeIntervalSince1970: ms / 1000) <= now {
        return .failure(FetchFailure(loginExpiredMessage, .failure))
    }
    return .success((token, (oauth["subscriptionType"] as? String ?? "").capitalized))
}

/// Refuses redirects so the bearer token can only ever go to the URL we asked for.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral          // no cookies, no cache on disk
    c.timeoutIntervalForRequest = Config.timeout
    c.timeoutIntervalForResource = Config.timeout
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
}()

/// Calls `done` on the main queue. The Keychain read happens off the main thread because macOS may
/// block it on an "allow access" dialog.
func fetchUsage(_ done: @escaping (FetchResult) -> Void) {
    DispatchQueue.global(qos: .utility).async {
        switch readCredential() {
        case let .failure(f): DispatchQueue.main.async { done(.failure(f.message, f.outcome)) }
        case let .success(cred): request(token: cred.token, plan: cred.plan, done)
        }
    }
}

private func request(token: String, plan: String, _ done: @escaping (FetchResult) -> Void) {
    var req = URLRequest(url: Config.usageURL)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("Limitbar/1.0", forHTTPHeaderField: "User-Agent")
    session.dataTask(with: req) { data, resp, err in
        let http = resp as? HTTPURLResponse
        let result: FetchResult
        switch http?.statusCode ?? 0 {
        case 200:
            let limits = data.map(parseUsage) ?? []
            result = limits.isEmpty ? .failure("Unexpected reply from the usage service", .failure) : .limits(limits, plan: plan)
        case 401: result = .failure(loginExpiredMessage, .failure)
        case 403: result = .failure("This login can't read usage (403)", .failure)
        case 429:
            let after = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            result = .failure("Rate limited — backing off", .rateLimited(retryAfter: after))
        case 0:   // no HTTP reply: offline, DNS, refused, timed out (often a firewall silently dropping it)
            let timedOut = (err as? URLError)?.code == .timedOut
            result = .failure(err.map { "Offline (\($0.localizedDescription))" } ?? "No response", .offline(timedOut: timedOut))
        case let code: result = .failure("Usage service unavailable (\(code))", .failure)
        }
        DispatchQueue.main.async { done(result) }
    }.resume()
}

// MARK: - App

// MARK: - Notifications

/// Per-limit percentages (80% and 95% unless changed in Settings) and a session reset notice. Off by default;
/// permission is asked the first time it's turned on. Sent keys persist, so a relaunch doesn't repeat a notification.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let defaults = UserDefaults.standard
    private let enabledKey = "notificationsEnabled", sentKey = "sentAlerts"
    var enabled: Bool { defaults.bool(forKey: enabledKey) }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Turning on asks for permission; if macOS refuses, it stays off and says where to allow it.
    func set(_ on: Bool, _ done: @escaping (Bool) -> Void) {
        guard on else { defaults.set(false, forKey: enabledKey); done(false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.defaults.set(granted, forKey: self.enabledKey)
                if !granted {
                    let a = NSAlert(); a.messageText = "Notifications are off for Limitbar"
                    a.informativeText = "Allow them in System Settings → Notifications → Limitbar, then turn them on here again."
                        + (error.map { "\n\n(\($0.localizedDescription))" } ?? "")
                    if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
                    a.runModal()
                }
                done(granted)
            }
        }
    }

    func check(_ limits: [Limit], now: Date = Date()) {
        guard enabled else { return }
        let sent = Set(defaults.stringArray(forKey: sentKey) ?? [])
        let due = alertsDue(limits, now: now, sent: sent, settings: Prefs.notify())
        guard !due.isEmpty else { return }
        defaults.set(Array(pruneSent(sent.union(due.flatMap { $0.keys }), now: now)), forKey: sentKey)
        for alert in due {
            let c = UNMutableNotificationContent(); c.title = alert.title; c.body = alert.body; c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.keys.last ?? alert.title, content: c, trigger: nil))
        }
    }

    // A menu bar app counts as frontmost; show banners anyway.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) { done([.banner, .sound]) }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let notifier = Notifier()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var limits: [Limit] = []
    var plan = ""
    var error: (text: String, calm: Bool)?   // the last fetch failed; old numbers (if any) stay, dimmed
    var fetchedAt = Date.distantPast
    var fromStatusLine = false   // the numbers came from Claude Code's status line, not the usage API
    var poll = PollState()
    var inFlight = false
    var inFlightSince = Date.distantPast
    var generation = 0   // replies from a superseded fetch are dropped
    var timer: Timer?
    var updates: Updates?   // created at launch, never in `--once`
    var lastKeychainOutcome: Outcome?   // how the last read that reached the Keychain went; nil after a success
    var noticeOpen = false

    func applicationDidFinishLaunching(_ n: Notification) {
        updates = Updates()
        updates?.onPendingChange = { [weak self] in self?.rebuildMenu() }
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        render()
        // .common: keeps ticking while a modal (the Keychain notice, Sparkle's window) or the menu is open.
        let t = Timer(timeInterval: Config.tick, repeats: true) { [weak self] _ in self?.onTick() }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            var p = userReturned(self.poll); p.holdUntil = Date().addingTimeInterval(Config.wakeDelay); self.poll = p   // keep the overdue timer off
            DispatchQueue.main.asyncAfter(deadline: .now() + Config.wakeDelay) { [weak self] in self?.onWake() }
        }
        // Screen unlocked: the user is back, so a Keychain that didn't answer earlier gets one more try.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self, self.poll.liftsOnUnlock else { return }
            self.poll = userReturned(self.poll)
            self.fetch()
        }
        // Travelling across time zones: reset times are shown in local time, so re-render with the new zone.
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            NSTimeZone.resetSystemTimeZone()
            self?.render(); self?.rebuildMenu()
        }
        // After setup, so a first-launch Keychain notice left open doesn't hold up the timer and observers.
        DispatchQueue.main.async { [weak self] in self?.fetch(explain: true) }
    }

    /// Always re-renders, so countdowns and reset windows stay current even while a fetch is outstanding.
    func onTick() {
        notifier.check(limits)   // also catches a session reset on the clock, before new numbers replace it
        if error != nil { useStatusLineCache() }   // also while paused or backing off, when no fetch runs
        if shouldFetch(poll, limits: limits, now: Date()) { fetch() }
        render()
    }

    func onWake() {
        if shouldFetchOnOpen(poll, now: Date()) { fetch() } else { render() }
    }

    /// Manual refresh: also lifts a Keychain-denied pause, so macOS asks once more, and supersedes
    /// any fetch still outstanding instead of silently doing nothing.
    @objc func manualRefresh() {
        var p = poll; p.paused = false; poll = p
        fetch(force: true, explain: true)
    }

    /// `explain`: the user is here on purpose (launch, Refresh), so the Keychain notice may be shown if it's due.
    /// Other fetches (timer, wake, unlock, menu open) never show a modal; when the notice is due they wait for Refresh.
    func fetch(force: Bool = false, explain: Bool = false) {
        // A fetch is bounded (Keychain deadline + request timeout), but never let one block the rest for long.
        guard force || !inFlight || Date().timeIntervalSince(inFlightSince) > Config.stuckAfter else { return }
        guard explainKeychainIfNeeded(ask: explain) else { return }
        generation += 1
        let gen = generation
        inFlight = true
        inFlightSince = Date()
        var p = poll; p.lastAttempt = inFlightSince; poll = p
        rebuildMenu()
        fetchUsage { [weak self] result in
            guard let self, gen == self.generation else { return }
            self.inFlight = false
            switch result {
            case let .limits(l, p):
                self.notifier.check(self.limits)   // a reset the old numbers show, then the new numbers
                self.notifier.check(l)
                self.limits = l; self.plan = p; self.error = nil; self.fetchedAt = Date(); self.fromStatusLine = false
                self.poll = nextState(self.poll, after: .success)
                self.lastKeychainOutcome = nil
            case let .failure(msg, outcome):
                self.lastKeychainOutcome = outcome
                self.poll = nextState(self.poll, after: outcome)
                self.error = status(msg, poll: self.poll)
                self.useStatusLineCache()
            }
            self.render()
            self.rebuildMenu()   // cheap; an open menu then always shows the result, however fast it came
            self.scheduleRetry()
        }
    }

    /// Says what is about to happen before the Keychain read that may bring up macOS's password prompt: before the
    /// first read, and before a retry after that prompt was refused or unanswered. false: no read now (Not Now, or
    /// the notice is due but `ask` is false); polling pauses until Refresh.
    func explainKeychainIfNeeded(ask: Bool) -> Bool {
        guard keychainNoticeNeeded(acknowledged: Prefs.keychainNoticeAcknowledged, last: lastKeychainOutcome) else { return true }
        guard ask, !noticeOpen else {
            if !noticeOpen { pauseForKeychain() }
            return false
        }
        noticeOpen = true
        defer { noticeOpen = false }
        let alert = NSAlert()
        alert.messageText = "Limitbar is about to read your Claude Code sign-in"
        alert.informativeText = (lastKeychainOutcome == nil ? "" : "Last time, the Keychain didn't allow it.\n\n")
            + "To show your limits, Limitbar reads the sign-in Claude Code keeps in your login Keychain and sends it only to "
            + "api.anthropic.com. It never changes or saves it.\n\nmacOS may now ask for your Mac password. Choose Always Allow "
            + "so it doesn't ask again."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        guard alert.runModal() == .alertFirstButtonReturn else {
            pauseForKeychain()
            return false
        }
        Prefs.keychainNoticeAcknowledged = true
        lastKeychainOutcome = nil
        return true
    }

    func pauseForKeychain() {
        var p = poll; p.paused = true; p.liftsOnUnlock = false; poll = p
        if error == nil || error?.calm == true || lastKeychainOutcome == nil {
            error = (text: "Waiting to read the Keychain — click Refresh when you're ready", calm: true)
        }
        render(); rebuildMenu()
    }

    /// When the API path fails (expired token, paused, backing off), take what Claude Code's status line has seen,
    /// merged per window so an idle session re-sending old numbers never replaces newer ones. Read only when the
    /// file changed since the last look.
    var statusLineSeen = Date.distantPast
    func useStatusLineCache() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Config.statusLineCache.path),
              let modified = attrs[.modificationDate] as? Date, modified > statusLineSeen else { return }
        statusLineSeen = modified
        guard let data = FileManager.default.contents(atPath: Config.statusLineCache.path),
              let cache = parseStatusLineCache(data), let merged = mergeStatusLine(limits, cache.limits) else { return }
        limits = merged
        fetchedAt = max(fetchedAt, cache.writtenAt)
        fromStatusLine = true
    }

    /// Offline: try again soon rather than in 5 minutes.
    func scheduleRetry() {
        guard let delay = poll.retryDelay else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.onTick() }
    }

    // MARK: rendering

    let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    func dimmed(_ now: Date = Date()) -> Bool { barDimmed(fetchedAt: fetchedAt, now: now, failing: error != nil) }

    func render() {
        let now = Date()
        // Dimmed when the numbers may be out of date (the menu says why), instead of a cryptic marker.
        let alpha: CGFloat = dimmed(now) ? barDimAlpha : 1
        let style = self.style
        let segments = limits.isEmpty ? [BarSegment(text: error == nil ? "…" : "—", hot: false)] : barSegments(limits, style: style, now: now)
        let title = NSMutableAttributedString()
        for seg in segments {
            title.append(NSAttributedString(string: seg.text, attributes: [.font: font, .foregroundColor: barColor(barInk(seg, style: style), alpha: alpha)]))
        }
        let tip = tooltip(limits, now: now, status: error?.text)
        item.button?.attributedTitle = title
        item.button?.toolTip = tip
        item.button?.setAccessibilityLabel("Claude limits. " + tip.replacingOccurrences(of: "\n", with: ". "))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if shouldFetchOnOpen(poll, now: Date()) { fetch() }
        rebuildMenu()
    }

    func rebuildMenu() {
        menu.removeAllItems()
        // Columns sized to the widest label, so a long scoped name ("Sonnet 4.5 weekly") can't break them.
        let widest = limits.map { ($0.label as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let pctWidth = ("100%" as NSString).size(withAttributes: [.font: font]).width
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: ceil(widest + 12 + pctWidth)),
                         NSTextTab(textAlignment: .left, location: ceil(widest + 12 + pctWidth + 14))]
        let now = Date()
        for l in limits {
            let stale = l.isStale(now: now)
            let reset = stale ? "reset, waiting for new numbers" : l.resetsAt.map { countdown(to: $0, now: now) } ?? "no reset time"
            let base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .foregroundColor: NSColor.labelColor]
            let row = NSMutableAttributedString(string: "\(l.label)\t", attributes: base)
            row.append(NSAttributedString(string: stale ? "–" : pct(l.percent),
                                          attributes: base.merging([.foregroundColor: l.isHot && !stale ? NSColor.systemRed : NSColor.labelColor]) { $1 }))
            row.append(NSAttributedString(string: "\t\(reset)", attributes: base.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 }))
            let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            mi.attributedTitle = row; mi.isEnabled = false
            menu.addItem(mi)
        }
        // Pace for session and weekly: used share against elapsed share of the window.
        let paced = [Limit.Kind.session, .weekly].compactMap { k in limits.first { $0.kind == k } }
            .compactMap { l in pace(l, now: now).map { (l.label, $0) } }
        if !paced.isEmpty { menu.addItem(.separator()) }
        for (label, p) in paced {
            let mi = info("\(label): \(paceText(p, now: now))")
            mi.attributedTitle = NSAttributedString(string: mi.title, attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: p.ahead || p.reached ? NSColor.labelColor : NSColor.secondaryLabelColor])
            menu.addItem(mi)
        }
        if !limits.isEmpty { menu.addItem(.separator()) }

        let when = fetchedAt == .distantPast ? (inFlight ? "Loading…" : "Not loaded yet") : updatedText(fetchedAt, now: now)
        let source = fromStatusLine ? "\(when) · from Claude Code's status line" : plan.isEmpty ? when : "\(when) · \(plan)"
        menu.addItem(info(source))
        if inFlight && fetchedAt != .distantPast { menu.addItem(info("Refreshing…")) }
        if let e = error { menu.addItem(info(e.calm ? e.text : "⚠︎ " + e.text)) }

        menu.addItem(.separator())
        menu.addItem(action("Refresh", #selector(manualRefresh), key: "r"))
        menu.addItem(action("Open Usage Page…", #selector(openPage)))
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        if let v = updates?.pending {
            menu.addItem(action("Update Available: Limitbar \(v)…", #selector(checkForUpdates)))
        } else if Updates.available {
            menu.addItem(action("Check for Updates…", #selector(checkForUpdates)))
        }
        menu.addItem(.separator())
        menu.addItem(madeBy())
        menu.addItem(action("Quit Limitbar", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    /// "Made with ♥ by Nico Jan", small and secondary like Quip's footer; opens nicojan.com.
    func madeBy() -> NSMenuItem {
        let mi = action("Made with ♥ by Nico Jan", #selector(openAuthor))
        let font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let title = NSMutableAttributedString(string: "Made with ", attributes: base)
        title.append(NSAttributedString(string: "♥", attributes: base.merging([.foregroundColor: NSColor.systemPink]) { $1 }))
        title.append(NSAttributedString(string: " by Nico Jan", attributes: base))
        mi.attributedTitle = title
        mi.toolTip = Config.authorPage.absoluteString
        return mi
    }

    @objc func openAuthor() { NSWorkspace.shared.open(Config.authorPage) }
    @objc func checkForUpdates() { updates?.check() }

    var style: BarStyle { Prefs.style() }

    let settingsWindow = SettingsWindow()

    @objc func openSettings() {
        let model = SettingsModel(
            labels: notifyLabels(limits), notificationsOn: notifier.enabled, loginOn: SMAppService.mainApp.status == .enabled,
            preview: { [weak self] st in
                guard let self else { return BarPreview(segments: [], dimmed: false) }
                // With no numbers yet the preview shows sample ones, bright; otherwise exactly what the bar shows.
                if self.limits.isEmpty { return BarPreview(segments: barSegments(Self.sampleLimits, style: st), dimmed: false) }
                return BarPreview(segments: barSegments(self.limits, style: st), dimmed: self.dimmed())
            },
            changed: { [weak self] in self?.render(); self?.rebuildMenu(); self?.notifier.check(self?.limits ?? []) },
            setNotifications: { [weak self] on, done in self?.notifier.set(on, done) },
            setLogin: { [weak self] on in self?.setLogin(on) ?? false }, updates: updates)
        settingsWindow.show(model)
    }

    static let sampleLimits = [Limit(kind: .session, label: "Session", percent: 52, resetsAt: Date().addingTimeInterval(88 * 60), elevated: false),
                               Limit(kind: .weekly, label: "Weekly", percent: 34, resetsAt: Date().addingTimeInterval(6 * 86400), elevated: false)]

    func info(_ text: String) -> NSMenuItem {
        let mi = NSMenuItem(title: text, action: nil, keyEquivalent: ""); mi.isEnabled = false; return mi
    }
    func action(_ title: String, _ sel: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key); mi.target = target ?? self; return mi
    }

    @objc func openPage() { NSWorkspace.shared.open(Config.usagePage) }

    /// Returns whether Start at Login is on afterwards. Needing approval opens Login Items settings.
    func setLogin(_ on: Bool) -> Bool {
        let svc = SMAppService.mainApp
        do {
            if on {
                try svc.register()
                if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try svc.unregister()
            }
        } catch {
            let a = NSAlert(); a.messageText = "Couldn't change Start at Login"; a.informativeText = error.localizedDescription
            if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            a.runModal()
        }
        return svc.status == .enabled
    }
}

// MARK: - entry

// `Limitbar --version`: the installed version, for checking an update from a terminal.
if CommandLine.arguments.contains("--version") {
    print("Limitbar \(appVersion)\(Updates.available ? "" : " (built from source, no updater)")")
    exit(0)
}

// `Limitbar --once`: fetch, print what the menu bar would show, exit. For checking an install from a terminal.
if CommandLine.arguments.contains("--once") {
    fetchUsage { result in
        switch result {
        case let .limits(l, p):
            let (s, w) = barParts(l)
            print("bar: \(s.map { pct($0.percent) } ?? "–") · \(w.map { pct($0.percent) } ?? "–")   plan: \(p)")
            l.forEach { print(describe($0)) }   // every limit, as the click menu lists them
            l.filter { $0.kind != .scoped }.forEach { x in pace(x, now: Date()).map { print("\(x.label): \(paceText($0))") } }
            exit(0)
        case let .failure(msg, _): print("error: \(msg)"); exit(1)
        }
    }
    dispatchMain()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
