// The Settings window (menu bar → Settings…, ⌘,): every setting of config.toml, laid out after Sleeve's settings.
// It edits the file in place (settingTOML and friends in TOML.swift), so comments, rules and order stay as the user
// wrote them, and applies each change like "Reload Config". The file stays the source of truth: every reload, from the
// menu or `nori reload`, rereads it here too. nori's own windows never join the strip (listWindows skips them).

import Cocoa
import SwiftUI

// What the window shows, as the file says on the last reload.
@Observable final class SettingsModel {
    var values: [String: String] = [:]     // as readConfig took them: what nori runs with
    var rules: [[String: TOMLValue]] = []  // every [[rule]] table in file order, valid or not
    var recording: String?                 // the binding whose recorder waits for a key press

    func refresh() {
        values = config
        let text = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        var count = 0
        var tables: [Int: [String: TOMLValue]] = [:]
        for entry in parseTOML(text, onHeader: { table, index, _ in if table == "rule", let index { count = index + 1 } }, report: { _, _ in })
        where entry.table == "rule" {
            tables[entry.index!, default: [:]][entry.key] = entry.value
        }
        rules = (0..<count).map { tables[$0] ?? [:] }
    }

    // Changes the file as it is on disk now, so an edit made in an editor since the last reload stays, then applies it.
    func edit(_ change: (String) -> String) {
        writeDefaultConfig()
        // A symlinked config (dotfiles) is written where the link points, so the link survives the atomic write.
        let url = URL(fileURLWithPath: configPath).resolvingSymlinksInPath()
        do {
            try change(try String(contentsOf: url, encoding: .utf8)).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fputs("config.toml: \(error.localizedDescription)\n", stderr)
        }
        reloadSettings()
    }

    func set(_ key: String, to value: TOMLValue?) {
        edit { settingTOML($0, table: bindingDefaults[key] == nil ? "" : "bindings", key: key, to: value) }
    }

    func setRule(_ index: Int, _ key: String, to value: TOMLValue?) {
        edit { settingTOML($0, table: "rule", index: index, key: key, to: value) }
    }

    func number(_ key: String) -> Double { values[key].flatMap(Double.init) ?? numberDefaults[key] ?? 0 }
    func flag(_ key: String) -> Bool { values[key] == "true" }
    func text(_ key: String) -> String { values[key] ?? bindingDefaults[key] ?? choiceKeys[key]?.first ?? "" }

    // Other actions on the same keys, and a system "Switch to Desktop N" shortcut, which the event tap serves first.
    func conflicts(_ action: String) -> [String] {
        guard let mine = chord(text(action)) else { return [] }
        let same = { (other: Chord?) in other.map { $0.key == mine.key && $0.flags == mine.flags } ?? false }
        return bindingDefaults.keys.sorted().filter { $0 != action && same(chord(text($0))) }.map { describe($0).title }
            + desktopHotkeys.filter { same($0.chord) }.map { "Switch to Desktop \($0.number)" }
    }

    // A key press while a recorder waits; the event tap hands it over instead of acting on it (main.swift).
    // Escape cancels, Delete unbinds. A binding needs Control, Option or Command, or it would eat that key everywhere.
    func record(_ event: CGEvent) {
        guard let action = recording, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection(chordModifiers)
        switch code {
        case 53: recording = nil
        case 51, 117: recording = nil; set(action, to: .string("none"))
        default:
            guard let key = keycodes.first(where: { $0.value == code })?.key,
                  !flags.isDisjoint(with: [.maskControl, .maskAlternate, .maskCommand]) else { return NSSound.beep() }
            recording = nil
            set(action, to: .string(chordText(flags, key)))
        }
    }
}

let settingsModel = SettingsModel()

// Modifiers in the order the defaults spell them, with the glyphs menus show.
let modifierNames: [(name: String, glyph: String, flag: CGEventFlags)] =
    [("ctrl", "⌃", .maskControl), ("option", "⌥", .maskAlternate), ("cmd", "⌘", .maskCommand), ("shift", "⇧", .maskShift)]

func chordText(_ flags: CGEventFlags, _ key: String?) -> String {
    (modifierNames.filter { flags.contains($0.flag) }.map(\.name) + [key].compactMap { $0 }).joined(separator: "+")
}

// "ctrl+option+h" as "⌃⌥H", in the order macOS menus use.
func chordGlyphs(_ text: String) -> String {
    guard let chord = chord(text) else { return text }
    let key = keycodes.first { $0.value == chord.key }!.key
    let arrows = ["left": "←", "right": "→", "up": "↑", "down": "↓"]
    return [("⌃", CGEventFlags.maskControl), ("⌥", .maskAlternate), ("⇧", .maskShift), ("⌘", .maskCommand)]
        .filter { chord.flags.contains($0.1) }.map(\.0).joined() + (arrows[key] ?? key.uppercased())
}

var settingsWindow: NSWindow?

func showSettings() {
    settingsModel.refresh()
    if settingsWindow == nil {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sceneBridgingOptions = .all  // SwiftUI's title, subtitle and toolbar go to the window
        hosting.sizingOptions = .minSize
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]  // opens on the current Space instead of switching to its own
        window.center()
        window.setFrameAutosaveName("Settings")
        // A recorder must not keep swallowing keys once the user is elsewhere.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
            settingsModel.recording = nil
        }
        settingsWindow = window
        NSApp.mainMenu = editMenu()
    }
    NSApp.activate()
    settingsWindow?.makeKeyAndOrderFront(nil)
}

// An .accessory app shows no menu bar, but key equivalents still go through its main menu: without this one, ⌘C, ⌘V,
// ⌘Z and ⌘W do nothing in the window's fields.
func editMenu() -> NSMenu {
    let edit = NSMenu(title: "Edit")
    for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
                                 ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
                                 ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a"),
                                 ("Close", #selector(NSWindow.performClose(_:)), "w")] {
        edit.addItem(withTitle: title, action: action, keyEquivalent: key)
    }
    let menu = NSMenu()
    menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
    return menu
}

enum Page: String, CaseIterable, Identifiable {
    case general = "General", layout = "Layout", focus = "Focus", hotkeys = "Hotkeys", rules = "App Rules"
    var id: Self { self }
    var icon: (symbol: String, color: Color) {
        switch self {
        case .layout: ("rectangle.split.3x1", .blue)
        case .focus: ("scope", .orange)
        case .hotkeys: ("command", .gray)
        case .rules: ("macwindow.on.rectangle", .purple)
        case .general: ("gearshape", .gray)
        }
    }
    var preview: Bool { self == .focus }
}

let sidebar: [(title: String, pages: [Page])] = [("", [.general]), ("Strip", [.layout, .focus]), ("Controls", [.hotkeys]), ("Apps", [.rules])]

// Each page's cards, by config key. A key Config.swift has and no card lists lands on an "Other" card (Hotkeys for a
// binding, General for the rest), so a new setting shows up here before anyone places it.
let pageCards: [Page: [(title: String, keys: [String])]] = [
    .layout: [("Columns", ["gap", "resize-step"]), ("Screen padding", ["padding-top", "padding-bottom", "padding-left", "padding-right"])],
    .focus: [("Centering", ["center-focused-column", "always-center-single-column"]), ("Unfocused windows", ["inactive-opacity"]),
             ("Navigation", ["wrap-around"])],
    .hotkeys: [("Mouse", ["mouse-modifier"]),
               ("Columns", ["focus-left", "focus-right", "focus-first", "focus-last", "center-column", "move-left", "move-right"]),
               ("Width", ["grow-width", "shrink-width", "cycle-width-forward", "cycle-width-backward", "toggle-full-width"]),
               ("Spaces", ["focus-space-down", "focus-space-up", "move-to-space-down", "move-to-space-up"] + (1...9).map { "move-to-space-\($0)" }),
               ("Overview", ["overview"])],
    .general: [("Startup", ["launch-at-login"]), ("Overview", ["overview-background"])],
]

func cards(_ page: Page) -> [(title: String, keys: [String])] {
    let all = Set(pageCards.values.flatMap { $0.flatMap(\.keys) })
    let other = (page == .hotkeys ? bindingDefaults.keys.sorted() : page == .general ? numberKeys + flagKeys + choiceKeys.keys.sorted() + modifierKeys : [])
        .filter { !all.contains($0) }
    return (pageCards[page] ?? []) + (other.isEmpty ? [] : [("Other", other)])
}

let descriptions: [String: (title: String, help: String)] = [
    "gap": ("Gap", "Between windows, in points"),
    "resize-step": ("Resize step", "How much Wider and Narrower change a window, in % of the screen width"),
    "padding-top": ("Top", "From the menu bar"),
    "padding-bottom": ("Bottom", "From the Dock or the bottom of the screen"),
    "padding-left": ("Left", ""),
    "padding-right": ("Right", ""),
    "center-focused-column": ("Center the focused window", ""),
    "always-center-single-column": ("Center a single window", "A lone window sits in the center in any mode"),
    "inactive-opacity": ("Opacity", "Of the strip's unfocused windows, so the focused one stands out; 1 turns it off"),
    "wrap-around": ("Wrap around", "Focus past the last column or Space goes round to the first"),
    "launch-at-login": ("Launch at login", "Adds Nori.app to Login Items. Move the app to Applications first"),
    "overview-background": ("Background", ""),
    "mouse-modifier": ("Drag modifier", "Held for a left drag to move a window, a right drag to resize it"),
    "focus-left": ("Column to the left", ""),
    "focus-right": ("Column to the right", ""),
    "focus-first": ("First column", ""),
    "focus-last": ("Last column", ""),
    "center-column": ("Center the focused window", "Whatever the centering mode says"),
    "move-left": ("Move window left", ""),
    "move-right": ("Move window right", ""),
    "grow-width": ("Wider", "By the resize step"),
    "shrink-width": ("Narrower", "By the resize step"),
    "cycle-width-forward": ("Next width", "1/3, 1/2, 2/3 of the screen"),
    "cycle-width-backward": ("Previous width", "1/3, 1/2, 2/3 of the screen"),
    "toggle-full-width": ("Full width", "And back"),
    "focus-space-down": ("Space below", ""),
    "focus-space-up": ("Space above", ""),
    "move-to-space-down": ("Move window to the Space below", ""),
    "move-to-space-up": ("Move window to the Space above", ""),
    "overview": ("Overview", "All Spaces of the display, windows live"),
]

func describe(_ key: String) -> (title: String, help: String) {
    if let known = descriptions[key] { return known }
    if key.hasPrefix("move-to-space-"), let n = Int(key.dropFirst(14)) { return ("Move window to Desktop \(n)", "") }
    return (key, "")
}

let choiceDescriptions: [String: (title: String, help: String)] = [
    "center-focused-column=always": ("Always", "The focused window sits in the center of the screen"),
    "center-focused-column=never": ("Never", "The strip scrolls only as far as it takes to show the focused window whole"),
    "center-focused-column=on-overflow": ("On overflow", "Centered when it doesn't fit beside the window focus came from, else like Never"),
    "overview-background=none": ("Black", "Black behind the overview's Spaces"),
    "overview-background=blur": ("Wallpaper", "The wallpaper, blurred and dimmed, behind the overview's Spaces"),
]

func matches(_ key: String, _ query: String) -> Bool {
    let (title, help) = describe(key)
    return query.isEmpty || [key, title, help].contains { $0.localizedCaseInsensitiveContains(query) }
}

// The App Rules page answers to these words with every rule, and to an app's name with its rules.
func ruleWords(_ query: String) -> Bool {
    query.isEmpty || ["app rules", "floating", "ignore", "width", "space", "desktop", "title"].contains { $0.localizedCaseInsensitiveContains(query) }
}

func ruleMatches(_ index: Int, _ query: String) -> Bool {
    if case .string(let app)? = settingsModel.rules[index]["app"] { return app.localizedCaseInsensitiveContains(query) }
    return false
}

func matches(_ page: Page, _ query: String) -> Bool {
    guard !query.isEmpty else { return true }
    if page == .rules { return settingsModel.rules.indices.contains { ruleMatches($0, query) } || ruleWords(query) }
    return page.rawValue.localizedCaseInsensitiveContains(query) || cards(page).contains { $0.keys.contains { matches($0, query) } }
}

struct SettingsView: View {
    @State private var page: Page? = .general
    @State private var query = ""

    var body: some View {
        let current = page ?? .general
        NavigationSplitView {
            List(selection: $page) {
                ForEach(sidebar, id: \.title) { section in
                    let pages = section.pages.filter { matches($0, query) }
                    if section.title.isEmpty {
                        ForEach(pages, content: SidebarRow.init)
                    } else if !pages.isEmpty {
                        Section(section.title) { ForEach(pages, content: SidebarRow.init) }
                    }
                }
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 280)  // last, or it doesn't reach the column
        } detail: {
            Group {
                if current == .rules { RulesPage(query: query) } else { SettingsPage(page: current, query: query) }
            }
            .navigationTitle("nori")
            .navigationSubtitle(current.rawValue)
            .toolbar {
                if current == .rules { ToolbarItem { AddRuleMenu() } }
                ToolbarItem {
                    Button { menuActions.openConfig() } label: { Label("Open in Editor", systemImage: "doc.text") }
                        .help("Open config.toml in your text editor")
                }
                ToolbarItem {
                    Button { reloadSettings() } label: { Label("Reload Config", systemImage: "arrow.clockwise") }
                        .help("Read config.toml again, after an edit by hand")
                }
            }
        }
        .searchable(text: $query, placement: .sidebar)
        .inspector(isPresented: .constant(current.preview)) {
            StripPreview(shown: current.preview).inspectorColumnWidth(min: 360, ideal: 480, max: 700)
        }
        .onChange(of: query) {
            if !matches(current, query) { page = Page.allCases.first { matches($0, query) } ?? page }
        }
        .frame(minHeight: 560)  // no minWidth: against the columns' own minimums it loops AppKit's layout
    }
}

struct SidebarRow: View {
    let page: Page

    var body: some View {
        NavigationLink(value: page) {
            Label { Text(page.rawValue) } icon: { IconTile(symbol: page.icon.symbol, color: page.icon.color) }
        }
    }
}

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

// The cards of one page; with a search, only the rows that match, or all when the page's name does.
struct SettingsPage: View {
    let page: Page
    let query: String

    var body: some View {
        let query = page.rawValue.localizedCaseInsensitiveContains(query) ? "" : query
        Form {
            ForEach(cards(page), id: \.title) { card in
                let keys = card.keys.filter { matches($0, query) }
                if !keys.isEmpty {
                    Section(card.title) {
                        ForEach(keys, id: \.self) { SettingRow(key: $0) }
                    }
                }
            }
            if page == .general && query.isEmpty { ConfigFileSection() }
        }
        .formStyle(.grouped)
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
    ][action] ?? "keyboard"
}

struct ConfigFileSection: View {
    var body: some View {
        Section("Config file") {
            LabeledContent {
                HStack {
                    Button("Open in Editor") { menuActions.openConfig() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: configPath)]) }
                }
            } label: {
                Text((configPath as NSString).abbreviatingWithTildeInPath).monospaced()
                Text("Every change here goes into this file. Comments, rules and keys you wrote stay as they are")
            }
        }
    }
}

// Apps for the app pickers: running ones with a name, nori itself left out.
func runningApps() -> [NSRunningApplication] {
    var seen: Set<String> = []
    return NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy != .prohibited && $0.processIdentifier != getpid() && $0.localizedName != nil
            && seen.insert($0.bundleIdentifier ?? $0.localizedName!).inserted }
        .sorted { $0.localizedName!.localizedCaseInsensitiveCompare($1.localizedName!) == .orderedAscending }
}

func smallIcon(_ image: NSImage?) -> NSImage {
    let icon = (image ?? NSWorkspace.shared.icon(for: .application)).copy() as! NSImage
    icon.size = NSSize(width: 16, height: 16)
    return icon
}

// An app by name or bundle id: running, or installed under that bundle id or name.
func appIcon(_ app: String) -> NSImage? {
    if let running = NSWorkspace.shared.runningApplications.first(where: { [$0.localizedName, $0.bundleIdentifier].contains { $0?.caseInsensitiveCompare(app) == .orderedSame } }) {
        return running.icon
    }
    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)
        ?? ["/Applications", "/System/Applications"].map { URL(fileURLWithPath: "\($0)/\(app).app") }.first { FileManager.default.fileExists(atPath: $0.path) }
    return url.map { NSWorkspace.shared.icon(forFile: $0.path) }
}

// Running apps by name, each with its icon, in a menu at the pointer. An NSMenu, so the icons show for sure.
func pickRunningApp(_ pick: @escaping (String) -> Void) {
    let menu = NSMenu()
    for app in runningApps() {
        let action = MenuAction { pick(app.localizedName!) }
        let item = NSMenuItem(title: app.localizedName!, action: #selector(MenuAction.fire), keyEquivalent: "")
        item.target = action
        item.representedObject = action  // the target is weak
        item.image = smallIcon(app.icon)
        menu.addItem(item)
    }
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

struct RulesPage: View {
    let query: String
    @State private var expanded: Set<Int> = []  // rules by index, open like an accordion

    var body: some View {
        let rules = settingsModel.rules
        ScrollViewReader { proxy in
            Form {
                Section {
                    Text("Each rule is for an app, by name or bundle id, and can be narrowed to windows whose title matches a regular expression. The first rule that matches a window wins.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rules.indices.filter { ruleWords(query) || ruleMatches($0, query) }, id: \.self) { index in
                    RuleSection(index: index, table: rules[index], expanded: Binding(
                        get: { expanded.contains(index) }, set: { if $0 { expanded.insert(index) } else { expanded.remove(index) } }
                    ))
                    .id(index)
                }
                if rules.isEmpty {
                    Section { Text("No rules yet. Add one with + in the toolbar.").foregroundStyle(.secondary) }
                }
                Section {
                    Text("\(builtinNames()) are ignored without a rule. A rule of your own for one of them comes first.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .onChange(of: rules.count) { old, new in
                // A new rule opens for editing; after a delete the indices shift, so all close.
                expanded = new > old ? [new - 1] : []
                if new > old { withAnimation { proxy.scrollTo(new - 1, anchor: .bottom) } }
            }
        }
    }

    private func builtinNames() -> String {
        let names = builtinRules.map { rule in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.app).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                ?? String(rule.app.split(separator: ".").last!)  // not installed: "com.runningwithcrayons.Alfred" → "Alfred"
        }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
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
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                fields(app)
            } label: {
                HStack(spacing: 10) {
                    Image(nsImage: appIcon(app) ?? NSWorkspace.shared.icon(for: .application)).resizable().frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.isEmpty ? "New rule" : app).font(.headline)
                        if makeRule(table) == nil { Text(problem).foregroundStyle(.orange) } else { Text(summary).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button(role: .destructive) { model.edit { removingTOMLTable($0, "rule", index: index) } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete this rule")
                }
            }
        }
    }

    @ViewBuilder private func fields(_ app: String) -> some View {
        let model = settingsModel
        LabeledContent("App") {
        HStack {
            CommitField(value: app, prompt: "Name or bundle id") { model.setRule(index, "app", to: .string($0)) }
            Button { pickRunningApp { model.setRule(index, "app", to: .string($0)) } } label: { Image(systemName: "list.bullet") }
                .buttonStyle(.borderless)
                .help("Pick a running app")
        }
        }
        LabeledContent {
        CommitField(value: string("title"), prompt: "Any window") { model.setRule(index, "title", to: $0.isEmpty ? nil : .string($0)) }
        } label: {
        Text("Window title")
        Text("A regular expression the title must contain, any case")
        }
        Picker(selection: Binding(get: { number("space").map(Int.init) ?? 0 }, set: { model.setRule(index, "space", to: $0 == 0 ? nil : .number(Double($0))) })) {
        Text("Where it opens").tag(0)
        ForEach(1...16, id: \.self) { Text("Desktop \($0)").tag($0) }
        } label: {
        Text("Space")
        Text("A new window moves there once")
        }
        LabeledContent {
        CommitField(value: number("width").map { tomlText(.number($0)) } ?? "", prompt: "As it opens") {
            model.setRule(index, "width", to: Double($0).map { .number(min(max($0, 1), 100)) })
        }
        } label: {
        Text("Width")
        Text("In % of the usable width, once, when the window joins the strip")
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
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
            .onChange(of: value, initial: true) { draft = value }
    }

    private func save() { if draft != value { commit(draft) } }
}

// The main display's wallpaper, scaled down: the preview draws it on every change.
func wallpaperThumbnail() -> NSImage? {
    guard let screen = NSScreen.screens.first, let url = NSWorkspace.shared.desktopImageURL(for: screen),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                      kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary)
    else { return nil }
    return NSImage(cgImage: image, size: .zero)
}

// The strip as the settings set it: the main display with its wallpaper and menu bar, four windows at
// the width presets, gap and padding to scale. ◀ ▶ move the focus so the centering mode shows; where the strip rests
// comes from Scroll, the code the strip itself uses.
struct StripPreview: View {
    let shown: Bool  // SwiftUI keeps the inspector's toolbar items while it is hidden
    @State private var focused = 1
    @State private var previous: Int?
    @State private var offset: CGFloat = 0
    @State private var single = false
    @State private var wallpaper: NSImage?

    var body: some View {
        let model = settingsModel
        let screen = NSScreen.screens.first
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = screen?.visibleFrame ?? frame
        let strip = scroll()
        let left = model.number("padding-left"), usable = strip.view
        let top = frame.maxY - visible.maxY + model.number("padding-top")
        let height = frame.height - (visible.minY - frame.minY) - model.number("padding-bottom") - top
        GeometryReader { geo in
            let scale = min((geo.size.width - 48) / frame.width, (geo.size.height - 140) / frame.height)
            ZStack(alignment: .topLeading) {
                Background(image: wallpaper)
                Rectangle().fill(.ultraThinMaterial).frame(height: (frame.maxY - visible.maxY) * scale)
                Rectangle()
                    .strokeBorder(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: usable * scale, height: height * scale)
                    .offset(x: left * scale, y: top * scale)
                ForEach(Array(strip.widths.indices), id: \.self) { i in
                    PreviewWindow(focused: i == focused, scale: scale)
                        .frame(width: strip.widths[i] * scale, height: height * scale)
                        .opacity(i == focused ? 1 : min(max(model.number("inactive-opacity"), 0.1), 1))
                        .offset(x: (left + usable / 2 + strip.centers[i] - offset - strip.widths[i] / 2) * scale, y: top * scale)
                }
            }
            .frame(width: frame.width * scale, height: frame.height * scale, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .background { Background(image: wallpaper).blur(radius: 40).overlay(.black.opacity(0.35)).ignoresSafeArea() }
        .toolbar {
            if shown {
                ToolbarItemGroup {
                    Button { move(-1) } label: { Label("Focus Left", systemImage: "chevron.left") }
                        .help("Focus the column to the left")
                    Button { move(1) } label: { Label("Focus Right", systemImage: "chevron.right") }
                        .help("Focus the column to the right")
                    Toggle(isOn: $single) { Label("Single Window", systemImage: "rectangle") }
                        .help("A single window")
                }
            }
        }
        .animation(.smooth, value: model.values)
        .onChange(of: model.values, initial: true) { settle() }
        .onChange(of: single) { settle() }
        .task { wallpaper = wallpaperThumbnail() }
    }

    private func scroll() -> Scroll {
        let model = settingsModel
        let width = (NSScreen.screens.first?.frame.width ?? 1512) - model.number("padding-left") - model.number("padding-right")
        let gap = model.number("gap")
        let third: CGFloat = 1 / 3
        let presets: [CGFloat] = single ? [0.5] : [0.5, third, 2 * third, 0.5]
        return Scroll(widths: presets.map { (width + gap) * $0 - gap }, view: width, gap: gap,
                      mode: model.text("center-focused-column"), centerSingle: model.flag("always-center-single-column"))
    }

    private func move(_ by: Int) {
        let count = scroll().widths.count
        previous = focused
        focused = settingsModel.flag("wrap-around") ? (focused + by + count) % count : min(max(focused + by, 0), count - 1)
        settle()
    }

    // Where the strip comes to rest for the focused column, as focusColumn and layout put it.
    private func settle() {
        let strip = scroll()
        focused = min(focused, strip.widths.count - 1)
        let rest = strip.rest(focused, from: offset, previous: previous)
        withAnimation(.smooth) { offset = min(max(rest, strip.bounds.lowerBound), strip.bounds.upperBound) }
        previous = nil
    }
}

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

// A window in the preview: a title bar with its three buttons, gray when it isn't focused.
struct PreviewWindow: View {
    let focused: Bool
    let scale: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(16 * scale, 3), style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: max(8 * scale, 2)) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(focused ? color : .gray.opacity(0.5)).frame(width: max(12 * scale, 3), height: max(12 * scale, 3))
                }
            }
            .padding(max(14 * scale, 3))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(focused ? 0.35 : 0.12)))
        .shadow(color: .black.opacity(focused ? 0.35 : 0.15), radius: 6 * scale + 2, y: 2)
    }
}
