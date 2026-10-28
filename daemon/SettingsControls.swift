import Cocoa
import SwiftUI

// A white symbol on a colored rounded square, as in System Settings.
struct IconTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// The control fits the kind of setting Config.swift says the key is.
struct SettingRow: View {
    let key: String

    var body: some View {
        let model = settingsModel
        let (title, help) = describe(key)
        if numberKeys.contains(key) {
            NumberRow(key: key)
        } else if flagKeys.contains(key) {
            Toggle(isOn: Binding(get: { model.flag(key) }, set: { model.set(key, to: .bool($0)) })) { Labels(title: title, help: help) }
        } else if key == "overview-background" {
            BackgroundTiles(key: key)
        } else if let choices = choiceKeys[key] {
            let value = model.text(key)
            Picker(selection: Binding(get: { value }, set: { model.set(key, to: .string($0)) })) {
                ForEach(choices, id: \.self) { Text(choiceDescriptions["\(key)=\($0)"]?.title ?? $0).tag($0) }
            } label: {
                Labels(title: title, help: choiceDescriptions["\(key)=\(value)"]?.help ?? help)
            }
            .pickerStyle(.segmented)
        } else if modifierKeys.contains(key) {
            ModifierRow(key: key)
        } else if bindingDefaults[key] != nil {
            let conflicts = model.conflicts(key)
            HStack(spacing: 10) {
                Image(systemName: bindingIcon(key)).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if !conflicts.isEmpty {
                        Text("Same keys as \(conflicts.joined(separator: ", "))").font(.callout).foregroundStyle(.red)
                    } else if !help.isEmpty {
                        Text(help).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Recorder(action: key)
            }
        }
    }
}

struct Labels: View {
    let title: String
    let help: String

    var body: some View {
        Text(title)
        if !help.isEmpty { Text(help) }
    }
}

// Slider span, allowed values and step per number; the rest are points (padding). The field and stepper go past the
// slider's end, up to the limit.
let numberRanges: [String: (slider: ClosedRange<Double>, limits: ClosedRange<Double>, step: Double)] = [
    "gap": (0...64, 0...500, 1),
    "resize-step": (1...50, 1...100, 1),
    "inactive-opacity": (0.1...1, 0.1...1, 0.05),
]

// A number as Sleeve shows a size: slider, value, stepper. The slider writes when it is let go, not on every step:
// each write rewrites the file and lays the windows out.
struct NumberRow: View {
    let key: String
    @State private var draft: Double?  // the slider's value while it moves

    var body: some View {
        let value = settingsModel.number(key)
        let (title, help) = describe(key)
        let range = numberRanges[key] ?? (0...200, 0...500, 1)
        let typed = Binding(get: { draft ?? value }, set: save)
        LabeledContent {
            HStack(spacing: 8) {
                // No step on the slider, which would draw tick marks; it snaps here instead.
                Slider(value: Binding(get: { draft ?? value }, set: { draft = snap($0) }), in: range.slider, onEditingChanged: { editing in
                    if !editing, let draft { save(draft) }
                })
                    .labelsHidden()
                    .frame(width: 180)
                TextField(title, value: typed, format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .frame(width: 44)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .overlay(Capsule().strokeBorder(.separator))
                // The range takes in a value from the file beyond the limits, or the stepper would clamp it and write.
                Stepper(title, value: typed, in: min(range.limits.lowerBound, value)...max(range.limits.upperBound, value), step: range.step)
                    .labelsHidden()
                    .controlSize(.small)
            }
        } label: { Labels(title: title, help: help) }
        .onChange(of: value) { draft = nil }
    }

    // To the step, and to two decimals so 0.05 steps don't come out as 0.35000000000000003.
    private func snap(_ value: Double) -> Double {
        let step = (numberRanges[key] ?? (0...200, 0...500, 1)).step
        return ((value / step).rounded() * step * 100).rounded() / 100
    }

    private func save(_ new: Double) {
        let range = numberRanges[key] ?? (0...200, 0...500, 1)
        let new = min(max(snap(new), range.limits.lowerBound), range.limits.upperBound)
        draft = nil
        if new != settingsModel.number(key) { settingsModel.set(key, to: .number(new)) }
    }
}

// mouse-modifier: one button per modifier, at least one on.
struct ModifierRow: View {
    let key: String

    var body: some View {
        let flags = modifiers(settingsModel.text(key)) ?? .maskAlternate
        let (title, help) = describe(key)
        LabeledContent {
            HStack(spacing: 4) {
                ForEach(modifierNames, id: \.name) { modifier in
                    Toggle(modifier.glyph, isOn: Binding(get: { flags.contains(modifier.flag) }, set: { on in
                        let new = on ? flags.union(modifier.flag) : flags.subtracting(modifier.flag)
                        if new.isEmpty { return NSSound.beep() }
                        settingsModel.set(key, to: .string(chordText(new, nil)))
                    }))
                    .toggleStyle(.button)
                    .help(modifier.name)
                }
            }
        } label: { Labels(title: title, help: help) }
    }
}

// overview-background as Sleeve shows a style: a tile per value with a swatch, its name under it, the chosen one
// outlined in the accent color.
struct BackgroundTiles: View {
    let key: String
    @State private var wallpaper: NSImage?

    var body: some View {
        let value = settingsModel.text(key)
        let (title, _) = describe(key)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(choiceDescriptions["\(key)=\(value)"]?.help ?? "").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ForEach(choiceKeys[key]!, id: \.self) { choice in
                    let on = choice == value
                    let tile = RoundedRectangle(cornerRadius: 12, style: .continuous)
                    Button { settingsModel.set(key, to: .string(choice)) } label: {
                        VStack(spacing: 6) {
                            Group {
                                if choice == "blur" { Background(image: wallpaper).blur(radius: 4) } else { Color.black }
                            }
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.15)))
                            .frame(width: 96, height: 64)
                            .background(on ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06), in: tile)
                            .overlay(tile.strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: on ? 3 : 1))
                            Text(choiceDescriptions["\(key)=\(choice)"]?.title ?? choice)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .foregroundStyle(on ? .white : .secondary)
                                .background(on ? Color.accentColor : .clear, in: Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task { wallpaper = wallpaperThumbnail() }
    }
}

// As Sleeve records hotkeys: "Record" when unbound, "REC" while it waits (the event tap hands the next press to
// SettingsModel.record), else the keys as keycaps; click them to record again.
struct Recorder: View {
    let action: String

    var body: some View {
        let model = settingsModel
        let text = model.text(action)
        let standard = bindingDefaults[action]!
        HStack(spacing: 8) {
            if model.recording == action {
                Button { model.recording = nil } label: {
                    HStack(spacing: 6) {
                        Circle().strokeBorder(.secondary, lineWidth: 1.5).frame(width: 9, height: 9)
                        Text("REC").fontWeight(.bold).foregroundStyle(.red)
                    }
                    .capsuleButton()
                }
                .help("Press the shortcut. Esc cancels, Delete unbinds")
                Button { model.recording = nil; model.set(action, to: .string(standard)) } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .help("Back to \(chordGlyphs(standard))")
            } else if text == "none" {
                Button { model.recording = action } label: { Text("Record").capsuleButton() }
            } else {
                Button { model.recording = action } label: { Keycaps(text: text) }
                    .help("Click to record another shortcut")
                Button { model.set(action, to: .string("none")) } label: { Image(systemName: "trash").foregroundStyle(.secondary) }
                    .help("Unbind")
            }
        }
        .buttonStyle(.plain)
    }
}

// "ctrl+option+h" as keycaps: ⌃ + ⌥ + H.
struct Keycaps: View {
    let text: String

    var body: some View {
        let keys = chordGlyphs(text).map(String.init)
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { i, key in
                if i > 0 { Text("+").foregroundStyle(.secondary) }
                Text(key)
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, 4)
                    .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 0.5, y: 1)
            }
        }
        .padding(4)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
    }
}

extension View {
    func capsuleButton() -> some View {
        frame(minWidth: 72, minHeight: 22)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2)))
    }
}

func bindingIcon(_ action: String) -> String {
    if action.hasPrefix("move-to-space-"), let n = Int(action.dropFirst(14)) { return "\(n).square" }
    return [
        "focus-left": "arrow.left", "focus-right": "arrow.right", "focus-first": "arrow.left.to.line", "focus-last": "arrow.right.to.line",
        "center-column": "align.horizontal.center", "move-left": "arrow.left.square", "move-right": "arrow.right.square",
        "grow-width": "arrow.left.and.right", "shrink-width": "arrow.right.and.line.vertical.and.arrow.left",
        "cycle-width-forward": "rectangle.righthalf.inset.filled", "cycle-width-backward": "rectangle.lefthalf.inset.filled",
        "toggle-full-width": "arrow.up.left.and.arrow.down.right", "focus-space-down": "arrow.down", "focus-space-up": "arrow.up",
        "move-to-space-down": "arrow.down.square", "move-to-space-up": "arrow.up.square", "overview": "square.grid.2x2",
        "show-floating": "macwindow.on.rectangle", "toggle-floating": "square.on.square",
    ][action] ?? "keyboard"
}

// Apps for the app pickers: the running ones in the Dock, nori itself left out. Agents and helpers have no windows
// worth a rule.
func runningApps() -> [NSRunningApplication] {
    var seen: Set<String> = []
    return NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() && $0.localizedName != nil
            && seen.insert($0.bundleIdentifier ?? $0.localizedName!).inserted }
        .sorted { $0.localizedName!.localizedCaseInsensitiveCompare($1.localizedName!) == .orderedAscending }
}

func smallIcon(_ image: NSImage?) -> NSImage {
    let icon = (image ?? NSWorkspace.shared.icon(for: .application)).copy() as! NSImage
    icon.size = NSSize(width: 16, height: 16)
    return icon
}

// The running processes of an app by name or bundle id, any case, as rules match it.
func running(_ app: String) -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { [$0.localizedName, $0.bundleIdentifier].contains { $0?.caseInsensitiveCompare(app) == .orderedSame } }
}

// An app by name or bundle id: running, or installed under that bundle id or name.
func appIcon(_ app: String) -> NSImage? {
    if let running = running(app).first { return running.icon }
    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)
        ?? ["/Applications", "/System/Applications"].map { URL(fileURLWithPath: "\($0)/\(app).app") }.first { FileManager.default.fileExists(atPath: $0.path) }
    return url.map { NSWorkspace.shared.icon(forFile: $0.path) }
}

// Titles of an app's open windows, for a title rule: CGWindowList has every Space's (with Screen Recording),
// Accessibility the current Space's.
func windowTitles(_ app: String) -> [String] {
    let pids = running(app).map(\.processIdentifier)
    let listed = (CGWindowListCopyWindowInfo(.excludeDesktopElements, kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { $0[kCGWindowLayer as String] as? Int == 0 && pids.contains($0[kCGWindowOwnerPID as String] as? pid_t ?? 0) }
        .compactMap { $0[kCGWindowName as String] as? String }
    let current = pids.flatMap { axWindows($0) ?? [] }.compactMap { window -> String? in
        var title: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success ? title as? String : nil
    }
    return Set(listed + current).filter { !$0.isEmpty }.sorted()
}

func pickRunningApp(_ pick: @escaping (String) -> Void) {
    popUpMenu(runningApps().map { app in (app.localizedName!, smallIcon(app.icon), { pick(app.localizedName!) }) }, empty: "No apps")
}

// A menu at the pointer. An icon goes into the item's title: this macOS draws no NSMenuItem.image in such a menu.
func popUpMenu(_ entries: [(title: String, icon: NSImage?, run: () -> Void)], empty: String) {
    let menu = NSMenu()
    for entry in entries {
        let action = MenuAction(entry.run)
        let item = NSMenuItem(title: entry.title, action: #selector(MenuAction.fire), keyEquivalent: "")
        item.target = action
        item.representedObject = action  // the target is weak
        if let icon = entry.icon {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
            let title = NSMutableAttributedString(attachment: attachment)
            title.append(NSAttributedString(string: "  " + entry.title, attributes: [.font: NSFont.menuFont(ofSize: 0)]))
            item.attributedTitle = title
        }
        menu.addItem(item)
    }
    if entries.isEmpty { menu.addItem(withTitle: empty, action: nil, keyEquivalent: "") }  // no action: shown disabled
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
}

final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

// New rules float, the commonest wish; the card shows what else a rule can do.
struct AddRuleMenu: View {
    var body: some View {
        Button {
            pickRunningApp { name in
                settingsModel.edit { appendingTOMLTable($0, "rule", [("app", .string(name)), ("floating", .bool(true))]) }
            }
        } label: {
            Label("Add Rule", systemImage: "plus")
        }
        .help("Add a rule for a running app")
    }
}

// One [[rule]] table: a row with the app and what the rule does, which opens to its fields. An emptied field takes
// its key out of the file.
struct RuleSection: View {
    let index: Int
    let table: [String: TOMLValue]
    @Binding var expanded: Bool

    var body: some View {
        let model = settingsModel
        let app = string("app")
        // Each view a row of the card, so the Form draws the lines between them.
        Section {
            HStack(spacing: 10) {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Image(nsImage: appIcon(app) ?? NSWorkspace.shared.icon(for: .application)).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.isEmpty ? "New rule" : app).font(.headline)
                            if makeRule(table) == nil { Text(problem).foregroundStyle(.orange) } else { Text(summary).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { model.edit { removingTOMLTable($0, "rule", index: index) } } label: { Image(systemName: "trash").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Delete this rule")
            }
            if expanded {
                RuleField("App") {
                    CommitField(value: app, prompt: "Name or bundle id") { model.setRule(index, "app", to: .string($0)) }
                    Button { pickRunningApp { model.setRule(index, "app", to: .string($0)) } } label: { Image(systemName: "list.bullet") }
                        .help("Pick a running app")
                }
                RuleField("Title", help: "A regular expression the window title must contain, any case. Empty: every window of the app") {
                    CommitField(value: string("title"), prompt: "Any window") { model.setRule(index, "title", to: $0.isEmpty ? nil : .string($0)) }
                    Button {
                        popUpMenu(windowTitles(app).map { title in (title, nil, { model.setRule(index, "title", to: .string(NSRegularExpression.escapedPattern(for: title))) }) },
                                  empty: "No open windows of \(app.isEmpty ? "this app" : app)")
                    } label: { Image(systemName: "macwindow") }
                        .help("Pick one of the app's open windows")
                }
                RuleField("Space", help: "A new window moves to this Desktop once") {
                    Picker("Space", selection: Binding(get: { number("space").map(Int.init) ?? 0 }, set: { model.setRule(index, "space", to: $0 == 0 ? nil : .number(Double($0))) })) {
                        Text("Where it opens").tag(0)
                        ForEach(1...16, id: \.self) { Text("Desktop \($0)").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                RuleField("Width", help: "In % of the usable width, once, when the window joins the strip") {
                    CommitField(value: number("width").map { tomlText(.number($0)) } ?? "", prompt: "As it opens") {
                        model.setRule(index, "width", to: Double($0).map { .number(min(max($0, 1), 100)) })
                    }
                    .frame(width: 120)
                    Text("%").foregroundStyle(.secondary)
                    Spacer()
                }
                Toggle(isOn: Binding(get: { flag("floating") }, set: { model.setRule(index, "floating", to: $0 ? .bool(true) : nil) })) {
                    Text("Floating")
                    Text("Its windows stay out of the strip, where you put them")
                }
                Toggle(isOn: Binding(get: { flag("ignore") }, set: { model.setRule(index, "ignore", to: $0 ? .bool(true) : nil) })) {
                    Text("Ignore")
                    Text("nori neither moves nor lists its windows")
                }
            }
        }
    }

    // What the rule does, for the closed row: "“Picture in Picture” · Floating".
    private var summary: String {
        var parts = [string("title")].filter { !$0.isEmpty }.map { "“\($0)”" }
        if let space = number("space") { parts.append("Desktop \(Int(space))") }
        if let width = number("width") { parts.append("\(tomlText(.number(width)))% wide") }
        if flag("floating") { parts.append("Floating") }
        if flag("ignore") { parts.append("Ignored") }
        return parts.joined(separator: " · ")
    }

    private var problem: String {
        if string("app").isEmpty { return "Not applied: no app" }
        if let title = table["title"], case .string(let pattern) = title, (try? NSRegularExpression(pattern: pattern)) == nil {
            return "Not applied: the title isn't a valid regular expression"
        }
        return "Not applied: needs a Space, a width, Floating or Ignore"
    }

    private func string(_ key: String) -> String { if case .string(let s)? = table[key] { s } else { "" } }
    private func number(_ key: String) -> Double? { if case .number(let n)? = table[key] { n } else { nil } }
    private func flag(_ key: String) -> Bool { table[key] == .bool(true) }
}

// A row of a rule as Sleeve lays out its settings: the name in a column on the left, the controls beside it, a line
// of help under them.
struct RuleField<Content: View>: View {
    let name: String
    let help: String
    @ViewBuilder let content: Content

    init(_ name: String, help: String = "", @ViewBuilder content: () -> Content) {
        (self.name, self.help, self.content) = (name, help, content())
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) { content }.buttonStyle(.borderless)
                if !help.isEmpty { Text(help).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }
}

// Writes when the user presses Return or leaves the field, not on every keystroke: each write rewrites the file and
// lays the windows out again.
struct CommitField: View {
    let value: String
    let prompt: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(prompt, text: $draft, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .overlay(Capsule().strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.15)))
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
            .onChange(of: value, initial: true) { draft = value }
    }

    private func save() { if draft != value { commit(draft) } }
}

// The main display's wallpaper, scaled down for the Background tile.
func wallpaperThumbnail() -> NSImage? {
    guard let screen = NSScreen.screens.first, let url = NSWorkspace.shared.desktopImageURL(for: screen),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                      kCGImageSourceThumbnailMaxPixelSize: 200] as CFDictionary)
    else { return nil }
    return NSImage(cgImage: image, size: .zero)
}

// The wallpaper tile, or a gradient where the wallpaper can't be read (a video).
struct Background: View {
    let image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(colors: [.indigo, .blue, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
