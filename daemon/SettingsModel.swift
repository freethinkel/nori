import Cocoa
import SwiftUI

// What the window shows, as the file says on the last reload.
@Observable final class SettingsModel {
    var values: [String: String] = [:]     // as readConfig took them: what nori runs with
    var monitors: [String: [String: Double]] = [:]  // the same for [[monitor]] tables
    var screens: [String] = []             // names of the displays connected now
    var problems: [String] = []            // what the last reload skipped, line by line
    var rules: [[String: TOMLValue]] = []  // every [[rule]] table in file order, valid or not
    var recording: String? {               // the binding whose recorder waits for a key press
        didSet { updateTapState { [recording] in $0.recording = recording != nil } }
    }

    func refresh() {
        values = config
        monitors = configFile.monitors
        problems = configFile.problems
        screens = NSScreen.screens.map(\.localizedName)
        rules = tables("rule", in: (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? "")
    }

    // Every [[name]] table in file order.
    private func tables(_ name: String, in text: String) -> [[String: TOMLValue]] {
        var count = 0
        var tables: [Int: [String: TOMLValue]] = [:]
        for entry in parseTOML(text, onHeader: { table, index, _ in if table == name, let index { count = index + 1 } }, report: { _, _ in })
        where entry.table == name {
            tables[entry.index!, default: [:]][entry.key] = entry.value
        }
        return (0..<count).map { tables[$0] ?? [:] }
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

    func setGesture(_ key: String, to value: String) {
        edit { file in gestureChanges(key, to: value, current: text).reduce(file) { settingTOML($0, key: $1.key, to: .string($1.value)) } }
    }

    func setRule(_ index: Int, _ key: String, to value: TOMLValue?) {
        edit { settingTOML($0, table: "rule", index: index, key: key, to: value) }
    }

    // Into the display's last table, as that one wins, or a new one.
    func setPadding(_ key: String, on name: String, to value: TOMLValue) {
        edit { file in
            tables("monitor", in: file).lastIndex { $0["name"] == .string(name) }
                .map { settingTOML(file, table: "monitor", index: $0, key: key, to: value) }
                ?? appendingTOMLTable(file, "monitor", [("name", .string(name)), (key, value)])
        }
    }

    func padding(_ key: String, on name: String) -> Double { monitors[name]?[key] ?? number(key) }
    func number(_ key: String) -> Double { values[key].flatMap(Double.init) ?? numberDefaults[key] ?? 0 }
    func flag(_ key: String) -> Bool { values[key].map { $0 == "true" } ?? flagsOn.contains(key) }
    func text(_ key: String) -> String { values[key] ?? bindingDefaults[key] ?? choiceKeys[key]?.first ?? colorDefaults[key] ?? "" }

    // Other actions on the same keys, and a system "Switch to Desktop N" shortcut, which the event tap serves first.
    func conflicts(_ action: String) -> [String] {
        let mine = chords(text(action)) ?? []
        let same = { (other: Chord) in mine.contains { $0.key == other.key && $0.flags == other.flags } }
        return bindingDefaults.keys.sorted().filter { $0 != action && (chords(text($0)) ?? []).contains(where: same) }.map { describe($0).title }
            + desktopHotkeys.filter { same($0.chord) && action != "focus-space-\($0.number)" }.map { "Switch to Desktop \($0.number)" }
    }

    // A key or mouse button press while a recorder waits; the event tap hands it over instead of acting on it (main.swift).
    // Escape cancels, Delete unbinds. A key needs Control, Option or Command, or it would eat that key everywhere; a
    // mouse button doesn't. A key takes the place of the action's keys and a button of its buttons, so an action can
    // have one of each here; the config takes any number.
    func record(_ event: CGEvent) {
        guard let action = recording, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
        let code = pressedKey(event)
        let flags = event.flags.intersection(chordModifiers)
        switch code {
        case 53: recording = nil
        case 51, 117: recording = nil; set(action, to: .string("none"))
        default:
            guard let key = keyName(code),
                  code > mouseKeyBase || !flags.isDisjoint(with: [.maskControl, .maskAlternate, .maskCommand]) else { return NSSound.beep() }
            recording = nil
            let mouse = code > mouseKeyBase
            let kept: [String] = text(action).split(separator: " ").map(String.init).filter { part in
                guard let other = chord(part) else { return false }  // "none"
                return (other.key > mouseKeyBase) != mouse
            }
            let all = mouse ? kept + [chordText(flags, key)] : [chordText(flags, key)] + kept  // keys first
            set(action, to: .string(all.joined(separator: " ")))
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

// "ctrl+option+h" as "⌃⌥H", in the order macOS menus use; several apart by spaces.
func chordGlyphs(_ text: String) -> String {
    let parts = text.split(separator: " ")
    if parts.count > 1 { return parts.map { chordGlyphs(String($0)) }.joined(separator: "  ") }
    guard let chord = chord(text) else { return text }
    let key = keyName(chord.key)!
    let arrows = ["left": "←", "right": "→", "up": "↑", "down": "↓"]
    return [("⌃", CGEventFlags.maskControl), ("⌥", .maskAlternate), ("⇧", .maskShift), ("⌘", .maskCommand)]
        .filter { chord.flags.contains($0.1) }.map(\.0).joined() + (arrows[key] ?? (key.hasPrefix("mouse") ? "Mouse \(key.dropFirst(5))" : key.uppercased()))
}
