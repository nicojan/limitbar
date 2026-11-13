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
    static let keychainService = "Claude Code-credentials"
    static let tick: TimeInterval = 60      // re-render countdowns, check whether a fetch is due
    static let timeout: TimeInterval = 10
    static let keychainDeadline: TimeInterval = 15
    static let dimAlpha: CGFloat = 0.5       // bar text when its numbers may be out of date
    static let stuckAfter: TimeInterval = 60  // an outstanding fetch older than this no longer blocks new ones
    static let wakeDelay: TimeInterval = 5  // let the network come back after sleep
    /// Claude orange #D97757 on a dark menu bar (4.5:1). On a light bar it would be 2.6:1, so a deeper tone of the
    /// same orange, #B4532F (4.2:1), is used there. Resolved against the menu bar's own appearance.
    static let orange = NSColor(name: "LimitbarOrange") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)
            : NSColor(srgbRed: 0xB4 / 255.0, green: 0x53 / 255.0, blue: 0x2F / 255.0, alpha: 1)
    }
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

/// At 80% / 95% per limit and on a session reset, when turned on in the menu. Off by default; permission is
/// asked the first time it's turned on. Sent keys persist, so a relaunch doesn't repeat a notification.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let defaults = UserDefaults.standard
    private let enabledKey = "notificationsEnabled", sentKey = "sentAlerts"
    var enabled: Bool { defaults.bool(forKey: enabledKey) }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Turning on asks for permission; if macOS refuses, it stays off and says where to allow it.
    func toggle(_ done: @escaping () -> Void) {
        guard !enabled else { defaults.set(false, forKey: enabledKey); done(); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                self.defaults.set(granted, forKey: self.enabledKey)
                if !granted {
                    let a = NSAlert(); a.messageText = "Notifications are off for Limitbar"
                    a.informativeText = "Allow them in System Settings → Notifications → Limitbar, then turn them on here again."
                    if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
                    a.runModal()
                }
                done()
            }
        }
    }

    func check(_ limits: [Limit], now: Date = Date()) {
        guard enabled else { return }
        let sent = Set(defaults.stringArray(forKey: sentKey) ?? [])
        let due = alertsDue(limits, now: now, sent: sent)
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
    var poll = PollState()
    var inFlight = false
    var inFlightSince = Date.distantPast
    var generation = 0   // replies from a superseded fetch are dropped
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        render()
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: Config.tick, repeats: true) { [weak self] _ in self?.onTick() }
        timer?.tolerance = 5
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            var p = self.poll; p.holdUntil = Date().addingTimeInterval(Config.wakeDelay); self.poll = p   // keep the overdue timer off
            DispatchQueue.main.asyncAfter(deadline: .now() + Config.wakeDelay) { [weak self] in self?.onWake() }
        }
        // Travelling across time zones: reset times are shown in local time, so re-render with the new zone.
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            NSTimeZone.resetSystemTimeZone()
            self?.render(); self?.rebuildMenu()
        }
    }

    /// Always re-renders, so countdowns and reset windows stay current even while a fetch is outstanding.
    func onTick() {
        notifier.check(limits)   // also catches a session reset on the clock, before new numbers replace it
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
        fetch(force: true)
    }

    func fetch(force: Bool = false) {
        // A fetch is bounded (Keychain deadline + request timeout), but never let one block the rest for long.
        guard force || !inFlight || Date().timeIntervalSince(inFlightSince) > Config.stuckAfter else { return }
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
                self.limits = l; self.plan = p; self.error = nil; self.fetchedAt = Date()
                self.poll = nextState(self.poll, after: .success)
            case let .failure(msg, outcome):
                self.poll = nextState(self.poll, after: outcome)
                self.error = status(msg, poll: self.poll)
            }
            self.render()
            self.rebuildMenu()   // cheap; an open menu then always shows the result, however fast it came
            self.scheduleRetry()
        }
    }

    /// Offline: try again soon rather than in 5 minutes.
    func scheduleRetry() {
        guard let delay = poll.retryDelay else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.onTick() }
    }

    // MARK: rendering

    let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    func render() {
        let now = Date()
        let (s, w) = barParts(limits, now: now)
        // Dimmed when the numbers may be out of date (the menu says why), instead of a cryptic marker.
        let alpha: CGFloat = barDimmed(fetchedAt: fetchedAt, now: now, failing: error != nil) ? Config.dimAlpha : 1
        let title = NSMutableAttributedString()
        func add(_ text: String, hot: Bool = false) {
            let color = (hot ? NSColor.systemRed : Config.orange).withAlphaComponent(alpha)
            title.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        if limits.isEmpty {
            add(error == nil ? "…" : "—")
        } else {
            add(s.map { pct($0.percent) } ?? "–", hot: s?.isHot ?? false)
            add(" · ")
            add(w.map { pct($0.percent) } ?? "–", hot: w?.isHot ?? false)
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
                .foregroundColor: p.ahead ? NSColor.labelColor : NSColor.secondaryLabelColor])
            menu.addItem(mi)
        }
        if !limits.isEmpty { menu.addItem(.separator()) }

        let when = fetchedAt == .distantPast ? (inFlight ? "Loading…" : "Not loaded yet") : updatedText(fetchedAt, now: now)
        menu.addItem(info(plan.isEmpty ? when : "\(when) · \(plan)"))
        if inFlight && fetchedAt != .distantPast { menu.addItem(info("Refreshing…")) }
        if let e = error { menu.addItem(info(e.calm ? e.text : "⚠︎ " + e.text)) }

        menu.addItem(.separator())
        menu.addItem(action("Refresh", #selector(manualRefresh), key: "r"))
        menu.addItem(action("Open Usage Page…", #selector(openPage)))
        let login = action("Start at Login", #selector(toggleLogin))
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed; login.title = "Start at Login (approve in System Settings)"
        default: login.state = .off
        }
        menu.addItem(login)
        let notify = action("Notify at 80% and 95%", #selector(toggleNotifications))
        notify.state = notifier.enabled ? .on : .off
        menu.addItem(notify)
        menu.addItem(.separator())
        menu.addItem(action("Quit Limitbar", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    func info(_ text: String) -> NSMenuItem {
        let mi = NSMenuItem(title: text, action: nil, keyEquivalent: ""); mi.isEnabled = false; return mi
    }
    func action(_ title: String, _ sel: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key); mi.target = target ?? self; return mi
    }

    @objc func toggleNotifications() { notifier.toggle { [weak self] in self?.rebuildMenu(); self?.notifier.check(self?.limits ?? []) } }

    @objc func openPage() { NSWorkspace.shared.open(Config.usagePage) }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            switch svc.status {
            case .enabled: try svc.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default:
                try svc.register()
                if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            let a = NSAlert(); a.messageText = "Couldn't change Start at Login"; a.informativeText = error.localizedDescription
            if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            a.runModal()
        }
    }
}

// MARK: - entry

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
