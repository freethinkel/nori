import Cocoa
import SwiftUI

// A white symbol on a colored rounded square, as in System Settings.
struct IconTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// A page of Cards. It stops growing with the window, or the controls drift away from their labels.
struct Cards<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 22) { content }
                .frame(maxWidth: 620)
                .padding(20)
        }
        // The title bar is transparent: on their way under the title the cards fade out instead of running into it.
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 20)
                Color.black
            }
        }
    }
}

// Rows on a quiet fill, with the heading and a footnote outside it, as Rex lays out its settings. Every row is a
// cardRow(), which draws the hairline above it; the clip takes the first one away.
struct Card<Content: View>: View {
    var title = ""
    var footer = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !title.isEmpty { Text(title).fontWeight(.semibold).padding(.horizontal, 10) }
            VStack(spacing: 0) { content }
                .padding(.top, -0.5)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if !footer.isEmpty { Text(footer).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 10) }
        }
    }
}

extension View {
    func cardRow() -> some View {
        frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // Not a Divider: in a Button's label it stands upright.
            .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 0.5).padding(.horizontal, 10) }
    }
}

// A label on the left, the control on the right.
struct Row<Control: View>: View {
    let title: String
    var help = ""
    var helpColor = Color.secondary
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 12) {
            Labels(title: title, help: help, color: helpColor).layoutPriority(1)  // or the Spacer takes half the room from it
            Spacer(minLength: 0)
            control
        }
        .cardRow()
    }
}

struct Labels: View {
    let title: String
    let help: String
    var color = Color.secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            if !help.isEmpty { Text(help).font(.subheadline).foregroundStyle(color) }
        }
    }
}

struct SwitchRow: View {
    let title: String
    var help = ""
    @Binding var isOn: Bool

    var body: some View {
        Row(title: title, help: help) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
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
            SwitchRow(title: title, help: help, isOn: Binding(get: { model.flag(key) }, set: { model.set(key, to: .bool($0)) }))
        } else if key == "overview-background" {
            BackgroundTiles(key: key)
        } else if gestureKeys.contains(key) {
            GestureRow(key: key)
        } else if let choices = choiceKeys[key] {
            let value = model.text(key)
            Row(title: title, help: choiceDescriptions["\(key)=\(value)"]?.help ?? help) {
                Picker(title, selection: Binding(get: { value }, set: { model.set(key, to: .string($0)) })) {
                    ForEach(choices, id: \.self) { Text(choiceDescriptions["\(key)=\($0)"]?.title ?? $0).tag($0) }
                }
                .labelsHidden()
                .buttonStyle(.borderless)
                .fixedSize()
            }
        } else if modifierKeys.contains(key) {
            ModifierRow(key: key)
        } else if bindingDefaults[key] != nil {
            let conflicts = model.conflicts(key)
            Row(title: title, help: conflicts.isEmpty ? help : "Same keys as \(conflicts.joined(separator: ", "))", helpColor: conflicts.isEmpty ? .secondary : .red) {
                Recorder(action: key)
            }
        }
    }
}

// Slider span, allowed values and step per number; the rest are points (padding). The field and stepper go past the
// slider's end, up to the limit.
let numberRanges: [String: (slider: ClosedRange<Double>, limits: ClosedRange<Double>, step: Double)] = [
    "gap": (0...64, 0...500, 1),
    "resize-step": (1...50, 1...100, 1),
    "inactive-opacity": (0.1...1, 0.1...1, 0.05),
    "overview-scale": (0.2...0.8, 0.2...0.8, 0.05),
    "swipe-speed": (0.5...3, 0.25...5, 0.1),
    "space-swipe-distance": (20...100, 10...100, 5),
    "overview-swipe-distance": (10...60, 10...100, 5),
]
let numberUnits = ["resize-step": "%", "inactive-opacity": "", "overview-scale": "", "swipe-speed": "×",
                   "space-swipe-distance": "%", "overview-swipe-distance": "%"]  // the rest: pt

let gestureNames = ["sideways": "Swipe sideways", "vertical": "Swipe up or down", "pinch": "Pinch", "none": "Off"]

// A trackpad action: the swipes it can take, only those, and on how many fingers. The fingers of an action turned off
// stay greyed at its default, so the columns line up.
struct GestureRow: View {
    let key: String

    var body: some View {
        let model = settingsModel
        let (title, help) = describe(key)
        let parts = model.text(key).split(separator: " ").map(String.init)
        let kind = parts.last!
        let choices = choiceKeys[key]!
        let fingers = parts.count == 2 ? parts[0] : String(choices[0].split(separator: " ")[0])
        let kinds = choices.reduce(into: [String]()) { all, choice in
            let kind = String(choice.split(separator: " ").last!)
            if !all.contains(kind) { all.append(kind) }
        }
        let same = kind == "none" ? [] : gestureKeys.filter { $0 != key && model.text($0) == model.text(key) }.map { describe($0).title }
        Row(title: title, help: same.isEmpty ? choiceDescriptions["\(key)=\(kind)"]?.help ?? help : "Same swipe as \(same.joined(separator: ", "))",
            helpColor: same.isEmpty ? .secondary : .red) {
            Picker("Gesture", selection: Binding(get: { kind }, set: { model.setGesture(key, to: $0 == "none" ? "none" : "\(fingers) \($0)") })) {
                ForEach(kinds, id: \.self) { Text(gestureNames[$0] ?? $0).tag($0) }
            }
            .labelsHidden()
            .buttonStyle(.borderless)
            .fixedSize()
            Picker("Fingers", selection: Binding(get: { fingers }, set: { model.setGesture(key, to: "\($0) \(kind)") })) {
                ForEach(3...5, id: \.self) { Text("\($0) fingers").tag(String($0)) }
            }
            .labelsHidden()
            .buttonStyle(.borderless)
            .fixedSize()
            .disabled(kind == "none")
        }
    }
}

// A number as a slider, the value and a stepper. The slider writes when it is let go, not on every step:
// each write rewrites the file and lays the windows out.
struct NumberRow: View {
    let key: String
    @State private var draft: Double?  // the slider's value while it moves

    var body: some View {
        let value = settingsModel.number(key)
        let (title, help) = describe(key)
        let range = numberRanges[key] ?? (0...200, 0...500, 1)
        let typed = Binding(get: { draft ?? value }, set: save)
        Row(title: title, help: help) {
            // No step on the slider, which would draw tick marks; it snaps here instead.
            Slider(value: Binding(get: { draft ?? value }, set: { draft = snap($0) }), in: range.slider, onEditingChanged: { editing in
                if !editing, let draft { save(draft) }
            })
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 120)
            HStack(spacing: 6) {
                HStack(spacing: 0) {
                    TextField(title, value: typed, format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 30)
                    // The range takes in a value from the file beyond the limits, or the stepper would clamp it and write.
                    Stepper(title, value: typed, in: min(range.limits.lowerBound, value)...max(range.limits.upperBound, value), step: range.step)
                        .labelsHidden()
                        .controlSize(.mini)
                }
                .padding(.leading, 6)
                .padding(.trailing, 3)
                .frame(height: 26)  // the stepper is taller than the text: the box goes by it, or it sticks out
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.separator))
                Text(numberUnits[key] ?? "pt").font(.subheadline).foregroundStyle(.secondary).frame(width: 14, alignment: .leading)
            }
        }
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
        Row(title: title, help: help) {
            HStack(spacing: 2) {
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
            .controlSize(.small)
        }
    }
}

// overview-background as Rex shows a color scheme: a preview per value with its name under it, the chosen one ringed
// in the accent color.
struct BackgroundTiles: View {
    let key: String
    @State private var wallpaper: NSImage?

    var body: some View {
        let value = settingsModel.text(key)
        let (title, help) = describe(key)
        Row(title: title, help: help) {
            ForEach(choiceKeys[key]!, id: \.self) { choice in
                let on = choice == value
                Button { settingsModel.set(key, to: .string(choice)) } label: {
                    VStack(spacing: 4) {
                        Group {
                            if choice == "blur" { Background(image: wallpaper).blur(radius: 4) } else { Color.black }
                        }
                        .frame(width: 68, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.15)))
                        .padding(3)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2))
                        Text(choiceDescriptions["\(key)=\(choice)"]?.title ?? choice)
                            .font(.subheadline)
                            .fontWeight(on ? .semibold : .regular)
                            .foregroundStyle(on ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .task { wallpaper = wallpaperThumbnail() }
    }
}

// As Rex records shortcuts: a key of one width, so the column lines up. "Record Shortcut" when unbound, "Type Shortcut"
// while it waits (the event tap hands the next press to SettingsModel.record), else the keys; click to record again.
// The mark inside it unbinds on hover, and goes back to the default while it waits.
struct Recorder: View {
    let action: String
    @State private var hovering = false

    var body: some View {
        let model = settingsModel
        let text = model.text(action)
        let standard = bindingDefaults[action]!
        let waiting = model.recording == action
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Button { model.recording = waiting ? nil : action } label: {
            Group {
                if waiting {
                    Text("Type Shortcut").foregroundStyle(.tint)
                } else if text == "none" {
                    Text("Record Shortcut").foregroundStyle(.tertiary)
                } else {
                    Text(chordGlyphs(text)).tracking(1.5)
                }
            }
            .frame(width: 130, height: 24)
            .background(Color.primary.opacity(text == "none" && !waiting ? 0.04 : 0.1), in: shape)
            .overlay(shape.strokeBorder(waiting ? Color.accentColor : .clear))
            .contentShape(shape)
        }
        .overlay(alignment: .trailing) {
            if waiting {
                Button { model.recording = nil; model.set(action, to: .string(standard)) } label: { Image(systemName: "arrow.uturn.backward.circle.fill") }
                    .help("Back to \(chordGlyphs(standard)). Esc cancels, Delete unbinds")
            } else if hovering && text != "none" {
                Button { model.set(action, to: .string("none")) } label: { Image(systemName: "xmark.circle.fill") }
                    .help("Unbind")
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
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
        let valid = makeRule(table) != nil
        VStack(spacing: 0) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(nsImage: appIcon(app) ?? NSWorkspace.shared.icon(for: .application)).resizable().frame(width: 24, height: 24)
                    Labels(title: app.isEmpty ? "New rule" : app, help: valid ? summary : problem, color: valid ? .secondary : .orange)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .cardRow()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(spacing: 0) {
                    Row(title: "App") {
                        CommitField(value: app, prompt: "Name or bundle id") { model.setRule(index, "app", to: .string($0)) }
                            .frame(width: 180)
                        Button { pickRunningApp { model.setRule(index, "app", to: .string($0)) } } label: { Image(systemName: "list.bullet").frame(width: 18) }
                            .help("Pick a running app")
                    }
                    Row(title: "Title", help: "A regular expression it must contain") {
                        CommitField(value: string("title"), prompt: "Any window") { model.setRule(index, "title", to: $0.isEmpty ? nil : .string($0)) }
                            .frame(width: 180)
                        Button {
                            popUpMenu(windowTitles(app).map { title in (title, nil, { model.setRule(index, "title", to: .string(NSRegularExpression.escapedPattern(for: title))) }) },
                                      empty: "No open windows of \(app.isEmpty ? "this app" : app)")
                        } label: { Image(systemName: "macwindow").frame(width: 18) }
                            .help("Pick one of the app's open windows")
                    }
                    Row(title: "Space", help: "A new window moves to this Desktop once") {
                        Picker("Space", selection: Binding(get: { number("space").map(Int.init) ?? 0 }, set: { model.setRule(index, "space", to: $0 == 0 ? nil : .number(Double($0))) })) {
                            Text("Where it opens").tag(0)
                            ForEach(1...16, id: \.self) { Text("Desktop \($0)").tag($0) }
                        }
                        .labelsHidden()
                        .buttonStyle(.borderless)
                        .fixedSize()
                    }
                    Row(title: "Width", help: "Of the usable width, once, when it joins the strip") {
                        CommitField(value: number("width").map { tomlText(.number($0)) } ?? "", prompt: "As it opens") {
                            model.setRule(index, "width", to: Double($0).map { .number(min(max($0, 1), 100)) })
                        }
                        .frame(width: 96)
                        Text("%").foregroundStyle(.secondary)
                    }
                    SwitchRow(title: "Floating", help: "Its windows stay out of the strip, where you put them",
                              isOn: Binding(get: { flag("floating") }, set: { model.setRule(index, "floating", to: $0 ? .bool(true) : nil) }))
                    SwitchRow(title: "Ignore", help: "nori neither moves nor lists its windows",
                              isOn: Binding(get: { flag("ignore") }, set: { model.setRule(index, "ignore", to: $0 ? .bool(true) : nil) }))
                    Row(title: "") {
                        Button { model.edit { removingTOMLTable($0, "rule", index: index) } } label: { Text("Delete Rule").foregroundStyle(.red) }
                            .buttonStyle(.plain)
                    }
                }
                .buttonStyle(.borderless)
                .background(Color.primary.opacity(0.03))
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
            .padding(.vertical, 3)
            .padding(.horizontal, 7)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.15)))
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
