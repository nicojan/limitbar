import Cocoa
import SwiftUI

// The settings window: bar appearance, which limits notify and at what percentages, Start at Login.
// The rules themselves (BarStyle, NotifySettings, cleanThresholds) are in Core.swift and tested there.

/// Claude orange #D97757 on a dark menu bar (4.5:1). On a light bar it would be 2.6:1, so a deeper tone of the
/// same orange, #B4532F (4.2:1), is used there. Alpha is applied inside the provider, so the colour stays
/// resolved against whatever draws it (the menu bar's own appearance) at draw time.
func claudeOrange(alpha: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: alpha)
            : NSColor(srgbRed: 0xB4 / 255.0, green: 0x53 / 255.0, blue: 0x2F / 255.0, alpha: alpha)
    }
}

/// Preferences in UserDefaults. A key that was never set keeps the default.
enum Prefs {
    private static let d = UserDefaults.standard
    private static func flag(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }

    static func style() -> BarStyle {
        let base = BarStyle()
        return BarStyle(showSessionReset: flag("barSessionReset", base.showSessionReset), separator: flag("barSeparator", base.separator),
                        percentSign: flag("barPercentSign", base.percentSign), orange: flag("barOrange", base.orange))
    }
    static func save(_ s: BarStyle) {
        d.set(s.showSessionReset, forKey: "barSessionReset"); d.set(s.separator, forKey: "barSeparator")
        d.set(s.percentSign, forKey: "barPercentSign"); d.set(s.orange, forKey: "barOrange")
    }
    static func notify() -> NotifySettings { .decode(d.data(forKey: "notifySettings")) }
    static func save(_ n: NotifySettings) { d.set(try? JSONEncoder().encode(n), forKey: "notifySettings") }
}

/// What the window edits. Every change is saved at once and the bar re-renders; there is no Apply button.
final class SettingsModel: ObservableObject {
    @Published var style: BarStyle { didSet { Prefs.save(style); changed() } }
    @Published var notify: NotifySettings { didSet { Prefs.save(notify); changed() } }
    @Published var notificationsOn: Bool
    @Published var loginOn: Bool
    let labels: [String]
    let preview: (BarStyle) -> String
    private let changed: () -> Void
    private let setNotifications: (Bool, @escaping (Bool) -> Void) -> Void
    private let setLogin: (Bool) -> Bool

    init(labels: [String], notificationsOn: Bool, loginOn: Bool, preview: @escaping (BarStyle) -> String, changed: @escaping () -> Void,
         setNotifications: @escaping (Bool, @escaping (Bool) -> Void) -> Void, setLogin: @escaping (Bool) -> Bool) {
        style = Prefs.style(); notify = Prefs.notify()
        self.labels = labels; self.notificationsOn = notificationsOn; self.loginOn = loginOn
        self.preview = preview; self.changed = changed; self.setNotifications = setNotifications; self.setLogin = setLogin
    }

    var notificationsBinding: Binding<Bool> {
        Binding(get: { self.notificationsOn }, set: { on in self.setNotifications(on) { self.notificationsOn = $0; self.changed() } })
    }
    var loginBinding: Binding<Bool> { Binding(get: { self.loginOn }, set: { self.loginOn = self.setLogin($0) }) }

    func rule(_ label: String) -> Binding<LimitAlert> {
        Binding(get: { self.notify.rule(for: label) }, set: { r in
            var n = self.notify; n.limits[label] = r; self.notify = n
        })
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Menu bar") {
                Toggle("Show when the session resets", isOn: $model.style.showSessionReset)
                Toggle("Mid-dot between numbers", isOn: $model.style.separator)
                Toggle("Show % sign", isOn: $model.style.percentSign)
                Toggle("Claude orange (off: menu bar colour)", isOn: $model.style.orange)
                LabeledContent("Preview") {
                    Text(model.preview(model.style)).font(.body.monospacedDigit())
                        .foregroundColor(model.style.orange ? Color(nsColor: claudeOrange(alpha: 1)) : .primary)
                }
            }
            Section {
                Toggle("Send notifications", isOn: model.notificationsBinding)
                Group {
                    ForEach(model.labels, id: \.self) { label in
                        LimitAlertRow(label: label, rule: model.rule(label))
                    }
                    Toggle("Notify when a session resets after passing its first percentage", isOn: $model.notify.sessionReset)
                }
                .disabled(!model.notificationsOn)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Percentages from 1 to 100, separated by commas. Each one notifies once per window.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Start at login", isOn: model.loginBinding)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One limit: on/off and its percentages, typed as "80, 95". The text is kept as typed; only the parsed
/// percentages are saved, so the field never rewrites itself mid-edit.
struct LimitAlertRow: View {
    let label: String
    @Binding var rule: LimitAlert
    @State private var text = ""

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("", text: $text, prompt: Text("80, 95"))
                    .labelsHidden()
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .disabled(!rule.on)
                    .onChange(of: text) { t in
                        rule.thresholds = cleanThresholds(t.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0.replacingOccurrences(of: "%", with: "")) })
                    }
                Text("%").foregroundStyle(.secondary)
                Toggle("Notify for \(label)", isOn: $rule.on).labelsHidden()
            }
        }
        .onAppear { text = cleanThresholds(rule.thresholds).map { String(Int($0)) }.joined(separator: ", ") }
    }
}

/// One window, reused; rebuilt on each open so the list of limits is current.
final class SettingsWindow {
    private var window: NSWindow?

    func show(_ model: SettingsModel) {
        let host = NSHostingController(rootView: SettingsView(model: model))
        let w = window ?? NSWindow(contentViewController: host)
        w.contentViewController = host
        w.title = "Limitbar Settings"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        if window == nil { w.center() }
        window = w
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        w.makeKeyAndOrderFront(nil)
    }
}
