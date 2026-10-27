// ~/.config/nori/config.toml: gaps, screen padding, resize step, key bindings and app rules.
// Read at start and on "Reload Config".

import Cocoa

// Top level: numbers (missing: 0) and flags (missing: false). [bindings]: key bindings (missing: the default below).
// [[rule]]: app rules, see Rules.swift. Unknown keys and bad values are reported and skipped.
let numberKeys = ["gap", "padding-top", "padding-bottom", "padding-left", "padding-right", "resize-step"]
let flagKeys = ["launch-at-login"]
let bindingDefaults = ["overview": "option+o", "grow-width": "option+=", "shrink-width": "option+-",
                       "move-left": "option+shift+h", "move-right": "option+shift+l"]
    .merging((1...9).map { ("move-to-space-\($0)", "option+shift+\($0)") }) { a, _ in a }
let configPath = NSHomeDirectory() + "/.config/nori/config.toml"

// Numbers, flags and bindings as strings by key; the rules in file order.
func readConfig() -> (values: [String: String], rules: [Rule]) {
    guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return ([:], []) }
    let report = { (line: Int, message: String) in _ = fputs("config.toml:\(line): \(message)\n", stderr) }
    var values: [String: String] = [:]
    var ruleTables: [Int: [String: TOMLValue]] = [:]
    for entry in parseTOML(text, report: report) {
        switch (entry.table, entry.value) {
        case ("", .number(let n)) where numberKeys.contains(entry.key): values[entry.key] = String(n)
        case ("", .bool(let b)) where flagKeys.contains(entry.key): values[entry.key] = String(b)
        case ("bindings", .string(let s)) where bindingDefaults[entry.key] != nil && chord(s) != nil: values[entry.key] = s
        case ("rule", _) where entry.index != nil: ruleTables[entry.index!, default: [:]][entry.key] = entry.value
        default:
            report(entry.line, "skipping \(entry.key): unknown key or bad value. Top level: \((numberKeys + flagKeys).joined(separator: ", ")); "
                + "[bindings]: \(bindingDefaults.keys.sorted().joined(separator: ", ")); [[rule]]: app, space, floating, ignore")
        }
    }
    let rules = ruleTables.keys.sorted().compactMap { i in
        let rule = makeRule(ruleTables[i]!)
        if rule == nil { fputs("config.toml: skipping [[rule]] #\(i + 1): needs app = \"…\" and space = N, floating = true or ignore = true\n", stderr) }
        return rule
    }
    return (values, rules)
}

// Values below are computed on every use, so a reload ("configFile = readConfig()") reaches them all.
var configFile = readConfig()
var config: [String: String] { configFile.values }
var rules: [Rule] { configFile.rules }

func number(_ key: String) -> CGFloat { CGFloat(Double(config[key] ?? "") ?? 0) }
var launchAtLogin: Bool { config["launch-at-login"] == "true" }
var gap: CGFloat { number("gap") }
var paddingTop: CGFloat { number("padding-top") }
var paddingBottom: CGFloat { number("padding-bottom") }
var paddingLeft: CGFloat { number("padding-left") }
var paddingRight: CGFloat { number("padding-right") }
var resizeStep: CGFloat { config["resize-step"].flatMap(Double.init).map { CGFloat($0) } ?? 10 }  // percent of the usable width

// Bindings: modifiers and one key joined by "+", e.g. "option+o", "ctrl+shift+1". Keys are letters, digits, "-" and "=".
// Keycodes are from the US layout, so a binding means the same physical key in any layout.
typealias Chord = (key: Int64, flags: CGEventFlags)
let chordModifiers: CGEventFlags = [.maskAlternate, .maskControl, .maskCommand, .maskShift]
let keycodes: [String: Int64] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
    "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    "-": 27, "=": 24,
]

func chord(_ text: String) -> Chord? {
    var flags: CGEventFlags = []
    var key: Int64?
    for part in text.lowercased().split(separator: "+") {
        switch part {
        case "option", "alt", "opt": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        default:
            guard key == nil, let code = keycodes[String(part)] else { return nil }
            key = code
        }
    }
    return key.map { ($0, flags) }
}

func binding(_ name: String) -> Chord { chord(config[name] ?? bindingDefaults[name]!)! }
var overviewChord: Chord { binding("overview") }
var growChord: Chord { binding("grow-width") }
var shrinkChord: Chord { binding("shrink-width") }
var moveLeftChord: Chord { binding("move-left") }
var moveRightChord: Chord { binding("move-right") }

func matches(_ event: CGEvent, _ chord: Chord) -> Bool {
    event.getIntegerValueField(.keyboardEventKeycode) == chord.key && event.flags.intersection(chordModifiers) == chord.flags
}
