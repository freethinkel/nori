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
