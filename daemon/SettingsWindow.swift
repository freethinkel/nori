// The Settings window (menu bar → Settings…, ⌘,): every setting of config.toml, laid out after Rex's settings.
// It edits the file in place (settingTOML and friends in TOML.swift), so comments, rules and order stay as the user
// wrote them, and applies each change like "Reload Config". The file stays the source of truth: every reload, from the
// menu or `nori reload`, rereads it here too. nori's own windows never join the strip (listWindows skips them).

import Cocoa
import SwiftUI

var settingsWindow: NSWindow?

func showSettings() {
    settingsModel.refresh()
    if settingsWindow == nil {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 572),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sceneBridgingOptions = .all  // SwiftUI's title, subtitle and toolbar go to the window
        hosting.sizingOptions = .minSize
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 740, height: 572))
        window.toolbarStyle = .unifiedCompact
        window.titlebarAppearsTransparent = true  // no band across the top: the pages run up under the title
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]  // opens on the current Space instead of switching to its own
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        // A recorder must not keep swallowing keys once the user is elsewhere.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
            settingsModel.recording = nil
        }
        settingsWindow = window
        NSApp.mainMenu = editMenu()
    }
    NSApp.activate()
    settingsWindow?.makeKeyAndOrderFront(nil)
    settingsWindow?.makeFirstResponder(nil)  // AppKit would pick the page's first number field and light it up
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
    case general = "General", layout = "Layout", focus = "Focus", hotkeys = "Hotkeys", gestures = "Gestures", rules = "App Rules", about = "About"
    var id: Self { self }
    var icon: (symbol: String, color: Color) {
        switch self {
        case .layout: ("rectangle.split.3x1", .blue)
        case .focus: ("scope", .orange)
        case .hotkeys: ("command", .gray)
        case .gestures: ("hand.draw", .teal)
        case .rules: ("macwindow.on.rectangle", .purple)
        case .general: ("gearshape", .gray)
        case .about: ("info", .gray)
        }
    }
}

let sidebar: [[Page]] = [[.general], [.layout, .focus], [.hotkeys, .gestures, .rules], [.about]]

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
               ("Overview", ["overview"]), ("Floating windows", ["show-floating", "toggle-floating"])],
    .general: [("Startup", ["launch-at-login"]), ("Overview", ["overview-background", "overview-scale"])],
    .gestures: [("Actions", ["gesture-strip", "gesture-spaces", "gesture-overview"]),
                ("Sensitivity", ["swipe-speed", "space-swipe-distance", "overview-swipe-distance"]),
                ("macOS", ["leave-system-gestures"])],
    .about: [("Privacy", ["analytics"])],
]

func cards(_ page: Page) -> [(title: String, keys: [String])] {
    let all = Set(pageCards.values.flatMap { $0.flatMap(\.keys) })
    let other = (page == .hotkeys ? bindingDefaults.keys.sorted() : page == .general ? numberKeys + flagKeys + choiceKeys.keys.sorted() + modifierKeys : [])
        .filter { !all.contains($0) }
    return (pageCards[page] ?? []) + (other.isEmpty ? [] : [("Other", other)])
}

let descriptions: [String: (title: String, help: String)] = [
    "gap": ("Gap", "Between windows"),
    "resize-step": ("Resize step", "For Wider and Narrower, of the screen width"),
    "padding-top": ("Top", "From the menu bar"),
    "padding-bottom": ("Bottom", "From the Dock or the bottom of the screen"),
    "padding-left": ("Left", ""),
    "padding-right": ("Right", ""),
    "center-focused-column": ("Center the focused window", ""),
    "always-center-single-column": ("Center a single window", "A lone window sits in the center in any mode"),
    "inactive-opacity": ("Opacity", "1 turns it off"),
    "wrap-around": ("Wrap around", "Focus past the last column or Space goes round to the first"),
    "launch-at-login": ("Launch at login", "Adds Nori.app to Login Items. Move the app to Applications first"),
    "gesture-strip": ("Move the strip", "It settles on a column on lift"),
    "gesture-spaces": ("Switch Spaces", "The next one follows the fingers"),
    "gesture-overview": ("Open the overview", ""),
    "swipe-speed": ("Strip speed", "How far the strip goes for a swipe"),
    "space-swipe-distance": ("Swipe per Space", "Of the trackpad"),
    "overview-swipe-distance": ("Swipe to open", "Of the trackpad"),
    "leave-system-gestures": ("Keep Mission Control and App Exposé", "From the next launch. macOS may act on nori's swipes too"),
    "analytics": ("Share anonymous usage", "One event a day: the nori and macOS versions"),
    "overview-background": ("Background", "Behind the overview's Spaces"),
    "overview-scale": ("Scale", "Size of the Spaces in the overview"),
    "mouse-modifier": ("Drag modifier", "Hold and drag: left moves a window, right resizes it"),
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
    "show-floating": ("Show floating windows", "Windows outside the strip come above it; focus stays"),
    "toggle-floating": ("Float the window", "Out of the strip into the middle of the screen, and back"),
]

func describe(_ key: String) -> (title: String, help: String) {
    if let known = descriptions[key] { return known }
    if key.hasPrefix("move-to-space-"), let n = Int(key.dropFirst(14)) { return ("Move window to Desktop \(n)", "") }
    return (key, "")
}

let choiceDescriptions: [String: (title: String, help: String)] = [
    "center-focused-column=always": ("Always", "The focused window sits in the center"),
    "center-focused-column=never": ("Never", "The strip scrolls only as far as it has to"),
    "center-focused-column=on-overflow": ("On overflow", "Centered when it doesn't fit, else like Never"),
    "gesture-overview=vertical": ("", "Up opens, down closes"),
    "gesture-overview=pinch": ("", "Closing in opens, spreading closes"),
    "overview-background=none": ("Black", ""),
    "overview-background=blur": ("Wallpaper", ""),
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
                ForEach(sidebar, id: \.self) { group in
                    let pages = group.filter { matches($0, query) }
                    if !pages.isEmpty {
                        Section { ForEach(pages, content: SidebarRow.init) }
                    }
                }
            }
            .focusable(false)  // the selection stays a quiet gray, not the accent color of a focused list
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 260)  // last, or it doesn't reach the column
        } detail: {
            Group {
                if current == .rules { RulesPage(query: query) } else { SettingsPage(page: current, query: query) }
            }
            .navigationTitle(current.rawValue)
            .toolbar {
                if current == .rules { ToolbarItem { AddRuleMenu() } }
                ToolbarItem {
                    Menu {
                        Button("Open in Editor") { menuActions.openConfig() }
                        Button("Reload Config") { reloadSettings() }
                    } label: { Label("Config File", systemImage: "ellipsis") }
                    .menuIndicator(.hidden)
                    .help("The config.toml behind this window")
                }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search Settings")
        .onChange(of: query) {
            if !matches(current, query) { page = Page.allCases.first { matches($0, query) } ?? page }
        }
        .frame(minHeight: 420)  // no minWidth: against the columns' own minimums it loops AppKit's layout
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
