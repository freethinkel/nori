// ~/.config/nori/config.toml: gaps, screen padding, resize step, key bindings and app rules.
// Read at start and on "Reload Config".

import Cocoa

// Top level: numbers (missing: 0), flags (missing: false) and choices (missing: the first). [bindings]: key bindings (missing: the default below).
// [[rule]]: app rules, see Rules.swift. Unknown keys and bad values are reported and skipped.
let numberKeys = ["gap", "padding-top", "padding-bottom", "padding-left", "padding-right", "resize-step", "inactive-opacity"]
let flagKeys = ["launch-at-login", "always-center-single-column", "wrap-around"]
let choiceKeys = ["overview-background": ["none", "blur"], "center-focused-column": ["always", "never", "on-overflow"]]
let modifierKeys = ["mouse-modifier"]  // modifiers joined by "+", at least one
// Every action has a binding; "none" unbinds one. The actions themselves are in Actions.swift.
let bindingDefaults = ["focus-left": "option+h", "focus-right": "option+l", "focus-first": "ctrl+option+h", "focus-last": "ctrl+option+l",
                       "focus-space-down": "option+j", "focus-space-up": "option+k", "center-column": "option+c",
                       "overview": "option+o", "grow-width": "option+=", "shrink-width": "option+-",
                       "cycle-width-forward": "option+.", "cycle-width-backward": "option+,", "toggle-full-width": "option+shift+f",
                       "move-left": "option+shift+h", "move-right": "option+shift+l",
                       "move-to-space-down": "option+shift+j", "move-to-space-up": "option+shift+k"]
    .merging((1...9).map { ("move-to-space-\($0)", "option+shift+\($0)") }) { a, _ in a }
let configPath = NSHomeDirectory() + "/.config/nori/config.toml"

// Written where there is no config yet (first launch, "Open Config"), so every setting is there to edit.
let defaultConfig = """
# nori, see "Config" in the README
gap = 16                  # between windows, in points
padding-top = 40          # from the menu bar
padding-bottom = 0        # from the Dock or the bottom of the screen
padding-left = 24
padding-right = 24
resize-step = 10          # width step, % of screen width
launch-at-login = false   # start Nori.app at login
overview-background = "none"  # behind the overview's Spaces: "none" (black) or "blur" (the wallpaper, blurred)
center-focused-column = "always"  # "always", "never" (scroll only to show it whole) or "on-overflow"
always-center-single-column = false  # a lone window in the center, whatever center-focused-column says
wrap-around = false       # focus-left on the first column goes to the last, focus-space-up on the first Space to the last
inactive-opacity = 1.0    # opacity of the strip's unfocused windows, 0.1 to 1
mouse-modifier = "option" # held for a left drag to move a window, a right drag to resize it

[bindings]                # "none" unbinds an action
focus-left = "option+h"
focus-right = "option+l"
focus-first = "ctrl+option+h"
focus-last = "ctrl+option+l"
focus-space-down = "option+j"
focus-space-up = "option+k"
center-column = "option+c"          # scroll the focused window to the center
overview = "option+o"
grow-width = "option+="
shrink-width = "option+-"
cycle-width-forward = "option+."    # 1/3, 1/2, 2/3 of the screen
cycle-width-backward = "option+,"
toggle-full-width = "option+shift+f"
move-left = "option+shift+h"
move-right = "option+shift+l"
move-to-space-down = "option+shift+j"
move-to-space-up = "option+shift+k"
\((1...9).map { "move-to-space-\($0) = \"option+shift+\($0)\"" }.joined(separator: "\n"))

# App rules: app is a name or bundle id, title a regular expression; the first matching rule wins.
# [[rule]]
# app = "Telegram"
# space = 3              # new windows go to Desktop 3
#
# [[rule]]
# app = "com.apple.finder"
# floating = true        # windows stay out of the strip
#
# [[rule]]
# app = "Raycast"
# ignore = true          # nori doesn't move or list its windows
#
# [[rule]]
# app = "Ghostty"
# width = 50             # new windows take half the screen width, in %
#
# [[rule]]
# app = "Safari"
# title = "Picture in Picture"
# floating = true

"""

func writeDefaultConfig() {
    guard !FileManager.default.fileExists(atPath: configPath) else { return }
    try? FileManager.default.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? defaultConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
}

// Numbers, flags and bindings as strings by key; the rules in file order.
func readConfig() -> (values: [String: String], rules: [Rule]) {
    writeDefaultConfig()
    guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return ([:], []) }
    let report = { (line: Int, message: String) in _ = fputs("config.toml:\(line): \(message)\n", stderr) }
    var values: [String: String] = [:]
    var ruleTables: [Int: [String: TOMLValue]] = [:]
    for entry in parseTOML(text, report: report) {
        switch (entry.table, entry.value) {
        case ("", .number(let n)) where numberKeys.contains(entry.key): values[entry.key] = String(n)
        case ("", .bool(let b)) where flagKeys.contains(entry.key): values[entry.key] = String(b)
        case ("", .string(let s)) where choiceKeys[entry.key]?.contains(s) == true: values[entry.key] = s
        case ("", .string(let s)) where modifierKeys.contains(entry.key) && modifiers(s) != nil: values[entry.key] = s
        case ("bindings", .string(let s)) where bindingDefaults[entry.key] != nil && (s == "none" || chord(s) != nil): values[entry.key] = s
        case ("rule", _) where entry.index != nil: ruleTables[entry.index!, default: [:]][entry.key] = entry.value
        default:
            report(entry.line, "skipping \(entry.key): unknown key or bad value. Top level: \((numberKeys + flagKeys + choiceKeys.keys + modifierKeys).joined(separator: ", ")); "
                + "[bindings]: \(bindingDefaults.keys.sorted().joined(separator: ", ")); [[rule]]: app, title, space, floating, ignore, width")
        }
    }
    let rules = ruleTables.keys.sorted().compactMap { i in
        let rule = makeRule(ruleTables[i]!)
        if rule == nil { fputs("config.toml: skipping [[rule]] #\(i + 1): needs app = \"…\" and space = N, floating = true, ignore = true or width = N\n", stderr) }
        return rule
    }
    return (values, rules)
}

// Values below are computed on every use, so a reload ("configFile = readConfig()") reaches them all.
var configFile = readConfig()
var config: [String: String] { configFile.values }
var rules: [Rule] { configFile.rules + builtinRules }

func number(_ key: String) -> CGFloat { CGFloat(Double(config[key] ?? "") ?? 0) }
var launchAtLogin: Bool { config["launch-at-login"] == "true" }
var overviewBlur: Bool { config["overview-background"] == "blur" }
var gap: CGFloat { number("gap") }
var paddingTop: CGFloat { number("padding-top") }
var paddingBottom: CGFloat { number("padding-bottom") }
var paddingLeft: CGFloat { number("padding-left") }
var paddingRight: CGFloat { number("padding-right") }
var resizeStep: CGFloat { config["resize-step"].flatMap(Double.init).map { CGFloat($0) } ?? 10 }  // percent of the usable width
var centerFocusedColumn: String { config["center-focused-column"] ?? "always" }  // see Scroll.swift
var alwaysCenterSingleColumn: Bool { config["always-center-single-column"] == "true" }
var wrapAround: Bool { config["wrap-around"] == "true" }
var inactiveOpacity: Float { Float(min(max(config["inactive-opacity"].flatMap(Double.init) ?? 1, 0.1), 1)) }  // 1: off
var mouseModifier: CGEventFlags { config["mouse-modifier"].flatMap(modifiers) ?? .maskAlternate }

// Bindings: modifiers and one key joined by "+", e.g. "option+o", "ctrl+shift+1". Keys are letters, digits, "-", "=", ",", "."
// and the arrows. Keycodes are from the US layout, so a binding means the same physical key in any layout.
typealias Chord = (key: Int64, flags: CGEventFlags)
let chordModifiers: CGEventFlags = [.maskAlternate, .maskControl, .maskCommand, .maskShift]
let keycodes: [String: Int64] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
    "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    "-": 27, "=": 24, ",": 43, ".": 47, "left": 123, "right": 124, "down": 125, "up": 126,
]

// A modifier's flag, nil for anything else.
func modifier(_ part: Substring) -> CGEventFlags? {
    switch part {
    case "option", "alt", "opt": return .maskAlternate
    case "ctrl", "control": return .maskControl
    case "cmd", "command": return .maskCommand
    case "shift": return .maskShift
    default: return nil
    }
}

// Modifiers only, at least one: "option", "ctrl+shift".
func modifiers(_ text: String) -> CGEventFlags? {
    let flags = text.lowercased().split(separator: "+").compactMap(modifier)
    return flags.count == text.split(separator: "+").count && !flags.isEmpty ? CGEventFlags(flags) : nil
}

func chord(_ text: String) -> Chord? {
    var flags: CGEventFlags = []
    var key: Int64?
    for part in text.lowercased().split(separator: "+") {
        if let flag = modifier(part) { flags.insert(flag); continue }
        guard key == nil, let code = keycodes[String(part)] else { return nil }
        key = code
    }
    return key.map { ($0, flags) }
}

func binding(_ name: String) -> Chord? { chord(config[name] ?? bindingDefaults[name]!) }  // nil: "none"

func matches(_ event: CGEvent, _ chord: Chord?) -> Bool {
    guard let chord else { return false }
    return event.getIntegerValueField(.keyboardEventKeycode) == chord.key && event.flags.intersection(chordModifiers) == chord.flags
}

// The action a key press is bound to, if any.
func boundAction(_ event: CGEvent) -> String? { bindingDefaults.keys.first { matches(event, binding($0)) } }
