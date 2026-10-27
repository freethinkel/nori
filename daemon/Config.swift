// ~/.config/nori/config.toml: gaps, screen padding, resize step, key bindings and app rules.
// Read at start and on "Reload Config".

import Cocoa

// Top level: numbers (missing: numberDefaults, else 0), flags (missing: false) and choices (missing: the first). [bindings]: key bindings (missing: the default below).
// [[rule]]: app rules, see Rules.swift. Unknown keys and bad values are reported and skipped.
let numberKeys = ["gap", "padding-top", "padding-bottom", "padding-left", "padding-right", "resize-step", "inactive-opacity"]
let numberDefaults: [String: Double] = ["resize-step": 10, "inactive-opacity": 1]  // the rest: 0
let flagKeys = ["launch-at-login", "always-center-single-column", "wrap-around"]
let choiceKeys = ["overview-background": ["none", "blur"], "center-focused-column": ["always", "never", "on-overflow"]]
let modifierKeys = ["mouse-modifier"]  // modifiers joined by "+", at least one
// Every action has a binding; "none" unbinds one. The actions themselves are in Actions.swift.
let bindingDefaults = ["focus-left": "option+h", "focus-right": "option+l", "focus-first": "ctrl+option+h", "focus-last": "ctrl+option+l",
                       "focus-space-down": "option+j", "focus-space-up": "option+k", "center-column": "option+c",
                       "overview": "option+o", "show-floating": "option+f", "toggle-floating": "option+shift+v",
                       "grow-width": "option+=", "shrink-width": "option+-",
                       "cycle-width-forward": "option+.", "cycle-width-backward": "option+,", "toggle-full-width": "option+shift+f",
                       "move-left": "option+shift+h", "move-right": "option+shift+l",
                       "move-to-space-down": "option+shift+j", "move-to-space-up": "option+shift+k"]
    .merging((1...9).map { ("move-to-space-\($0)", "option+shift+\($0)") }) { a, _ in a }
// NORI_CONFIG: another file, to try settings out without touching your own.
let configPath = ProcessInfo.processInfo.environment["NORI_CONFIG"] ?? NSHomeDirectory() + "/.config/nori/config.toml"

let defaultConfigPath = (configPath as NSString).deletingLastPathComponent + "/config.default.toml"

// Every setting with its default and what it does. Written as config.toml where there is none yet (first launch,
// "Open Config"), and as config.default.toml on every start and reload, so a config from an older version can look up
// what is new ("Show All Settings"). Settings that change nothing at their default are commented out.
let defaultConfig = """
# nori config. Save, then choose "Reload Config" (⌘R) in nori's menu bar item or run `nori reload`.
# Or change it in Settings… (⌘,) in the same menu: it writes here and keeps your comments.
# A line starting with # is off: remove the # to turn it on. A key nori doesn't know, or a bad value, is skipped
# with a warning, and the rest still applies.
# Every setting of the running version, with its default: config.default.toml next to this file, or
# "Show All Settings" in the menu. More in the README: https://github.com/freethinkel/nori#config

# Space around windows, in points.
gap = 16                  # between two windows
padding-top = 40          # below the menu bar
padding-bottom = 0        # above the Dock, or the bottom of the screen
padding-left = 24
padding-right = 24

# Where the strip puts the focused window:
#   "always"       in the center of the screen
#   "never"        the strip scrolls only as far as it takes to show the window whole
#   "on-overflow"  in the center when it doesn't fit beside the window focus came from, else like "never"
center-focused-column = "always"
# always-center-single-column = true   # a lone window in the center, whatever the setting above says

resize-step = 10          # how much grow-width and shrink-width change a window, in % of the screen width

# wrap-around = true          # focus past the last window or Space goes round to the first one
# inactive-opacity = 0.85     # windows without focus fade to this opacity, 0.1 to 1. Default 1: off
# overview-background = "blur"  # the wallpaper, blurred, behind the overview's Spaces. Default "none": black
# mouse-modifier = "ctrl+option"  # held for a left drag (move a window) or a right drag (resize it). Default "option"
# launch-at-login = true      # start Nori.app at login. Move the app to /Applications first

# Key bindings: modifiers and one key joined by "+". Modifiers: option, ctrl, cmd, shift. Keys: a to z, 0 to 9,
# - = , . and left, right, up, down. Keys are physical keys on the US layout, so a binding stays put in any
# keyboard layout. "none" turns a binding off. Each action is also a command, see `nori help`.
# Option+1…9 aren't here: they are macOS's "Switch to Desktop N" shortcuts, set in System Settings → Keyboard →
# Keyboard Shortcuts → Mission Control, and nori animates them.
[bindings]
focus-left = "option+h"             # the window to the left / right
focus-right = "option+l"
focus-first = "ctrl+option+h"       # the first / last window of the strip
focus-last = "ctrl+option+l"
focus-space-down = "option+j"       # the Space below / above
focus-space-up = "option+k"
center-column = "option+c"          # scroll the focused window to the center, once
overview = "option+o"               # all Spaces of the display, with live windows
show-floating = "option+f"          # windows outside the strip (floating rules, dialogs, PiP) above it, focus stays
toggle-floating = "option+shift+v"  # focused window out of the strip, floating in the middle, and back
grow-width = "option+="             # focused window wider / narrower by resize-step
shrink-width = "option+-"
cycle-width-forward = "option+."    # focused window to the next of 1/3, 1/2, 2/3 of the screen
cycle-width-backward = "option+,"
toggle-full-width = "option+shift+f"  # full width, and back
move-left = "option+shift+h"        # focused window trades places with its neighbour
move-right = "option+shift+l"
move-to-space-down = "option+shift+j"  # send the focused window to the Space below / above
move-to-space-up = "option+shift+k"
\((1...9).map { "move-to-space-\($0) = \"option+shift+\($0)\"" + ($0 == 1 ? "   # send the focused window to Desktop 1, and so on" : "") }.joined(separator: "\n"))

# App rules. One [[rule]] table each; the first rule that matches a window wins.
#   app       the app's name or bundle id, any case. Find them with:
#             nori query windows | jq -r '.[] | "\\(.app)\\t\\(.bundleId)"' | sort -u
#   title     optional: a regular expression the window title must contain, any case
# and at least one of:
#   space     new windows of the app go to Desktop N, once; move one back by hand and it stays
#   floating  true: its windows stay out of the strip, where you put them
#   ignore    true: nori doesn't move or list its windows at all
#   width     new windows take N % of the screen width, once
# Raycast, Alfred, Spotlight and LaunchBar are ignored without a rule.
#
# [[rule]]
# app = "Telegram"
# space = 3
#
# [[rule]]
# app = "com.apple.calculator"
# floating = true
#
# [[rule]]
# app = "Ghostty"
# width = 50
#
# [[rule]]
# app = "Safari"
# title = "Picture in Picture"   # only this Safari window floats, the others stay in the strip
# floating = true

"""

func writeDefaultConfig() {
    let folder = (configPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    if (try? String(contentsOfFile: defaultConfigPath, encoding: .utf8)) != defaultConfig {
        try? defaultConfig.write(toFile: defaultConfigPath, atomically: true, encoding: .utf8)
    }
    guard !FileManager.default.fileExists(atPath: configPath) else { return }
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

func number(_ key: String) -> CGFloat { CGFloat(config[key].flatMap(Double.init) ?? numberDefaults[key] ?? 0) }
var launchAtLogin: Bool { config["launch-at-login"] == "true" }
var overviewBlur: Bool { config["overview-background"] == "blur" }
var gap: CGFloat { number("gap") }
var paddingTop: CGFloat { number("padding-top") }
var paddingBottom: CGFloat { number("padding-bottom") }
var paddingLeft: CGFloat { number("padding-left") }
var paddingRight: CGFloat { number("padding-right") }
var resizeStep: CGFloat { number("resize-step") }  // percent of the usable width
var centerFocusedColumn: String { config["center-focused-column"] ?? "always" }  // see Scroll.swift
var alwaysCenterSingleColumn: Bool { config["always-center-single-column"] == "true" }
var wrapAround: Bool { config["wrap-around"] == "true" }
var inactiveOpacity: Float { Float(min(max(number("inactive-opacity"), 0.1), 1)) }  // 1: off
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
