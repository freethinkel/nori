// ~/.config/nori/config.toml: gaps, screen padding, resize step, key bindings and app rules.
// Read at start and on "Reload Config".

import Cocoa

// Top level: numbers (missing: numberDefaults, else 0), flags (missing: false, or true for flagsOn) and choices (missing: the first). [bindings]: key bindings (missing: the default below).
// [[rule]]: app rules, see Rules.swift. [[monitor]]: one display's padding. Unknown keys and bad values are reported and skipped.
let paddingKeys = ["padding-top", "padding-bottom", "padding-left", "padding-right"]
let numberKeys = ["gap"] + paddingKeys + ["resize-step", "inactive-opacity", "border-width", "overview-scale",
                  "swipe-speed", "space-swipe-distance", "overview-swipe-distance"]
let numberDefaults: [String: Double] = ["resize-step": 10, "inactive-opacity": 1, "border-width": 4, "overview-scale": 0.4,
                                         "swipe-speed": 1.3, "space-swipe-distance": 50, "overview-swipe-distance": 30]  // the rest: 0
let flagKeys = ["padding-per-monitor", "launch-at-login", "always-center-single-column", "wrap-around", "focus-follows-mouse", "mouse-follows-focus", "border", "border-inactive", "analytics", "leave-system-gestures"]
let flagsOn = ["analytics"]
let choiceKeys = ["overview-background": ["none", "blur"], "center-focused-column": ["always", "never", "on-overflow"],
                  "gesture-strip": swipeChoices(["sideways"], fingers: 3), "gesture-spaces": swipeChoices(["vertical"], fingers: 3),
                  "gesture-overview": swipeChoices(["vertical", "pinch"], fingers: 4)]
let modifierKeys = ["mouse-modifier"]  // modifiers joined by "+", at least one
let colorDefaults = ["border-color": "#3083FB", "border-inactive-color": "#808080"]  // "#RRGGBB", or "#RRGGBBAA" with alpha
// The ways the display actions go, niri's. Which display that is: `neighbour` in Displays.swift.
let monitorWays = ["left", "right", "up", "down", "next", "previous"]
// Every action has a binding; "none" unbinds one. The actions themselves are in Actions.swift. The display actions have
// no keys by default: with one display they do nothing, and a key of theirs would just stop reaching apps.
let bindingDefaults = ["focus-left": "option+h", "focus-right": "option+l", "focus-first": "ctrl+option+h", "focus-last": "ctrl+option+l",
                       "focus-space-down": "option+j", "focus-space-up": "option+k", "center-column": "option+c",
                       "overview": "option+o", "show-floating": "option+f", "toggle-floating": "option+shift+v",
                       "grow-width": "option+=", "shrink-width": "option+-",
                       "cycle-width-forward": "option+.", "cycle-width-backward": "option+,", "toggle-full-width": "option+shift+f",
                       "move-left": "option+shift+h", "move-right": "option+shift+l",
                       "move-to-space-down": "option+shift+j", "move-to-space-up": "option+shift+k"]
    .merging((1...9).map { ("focus-space-\($0)", "option+\($0)") }) { a, _ in a }
    .merging((1...9).map { ("move-to-space-\($0)", "option+shift+\($0)") }) { a, _ in a }
    .merging((1...9).flatMap { [("focus-space-slot-\($0)", "none"), ("move-to-space-slot-\($0)", "none")] }) { a, _ in a }
    .merging(monitorWays.flatMap { [("focus-monitor-\($0)", "none"), ("move-window-to-monitor-\($0)", "none")] }) { a, _ in a }
// NORI_CONFIG: another file, to try settings out without touching your own.
let configPath = ProcessInfo.processInfo.environment["NORI_CONFIG"] ?? NSHomeDirectory() + "/.config/nori/config.toml"

let defaultConfigPath = (configPath as NSString).deletingLastPathComponent + "/config.default.toml"

// Every setting with its default and what it does. Written as config.toml where there is none yet (first launch,
// "Open in Editor"), and as config.default.toml on every start and reload, so a config from an older version can look up
// what is new. Settings that change nothing at their default are commented out.
let defaultConfig = """
# nori config. Save, then run `nori reload`, or choose "Reload Config" in the toolbar of Settings… (⌘,) in nori's menu bar item.
# Or change it in that window: it writes here and keeps your comments.
# A line starting with # is off: remove the # to turn it on. A key nori doesn't know, or a bad value, is skipped
# with a warning, and the rest still applies.
# Every setting of the running version, with its default: config.default.toml next to this file.
# More in the README: https://github.com/freethinkel/nori#config

# Space around windows, in points.
gap = 16                  # between two windows
padding-top = 40          # below the menu bar
padding-bottom = 0        # above the Dock, or the bottom of the screen
padding-left = 24
padding-right = 24
# padding-per-monitor = true  # each display its own padding, see [[monitor]] at the end. Default false: these on all

# Where the strip puts the focused window:
#   "always"       in the center of the screen
#   "never"        the strip scrolls only as far as it takes to show the window whole
#   "on-overflow"  in the center when it doesn't fit beside the window focus came from, else like "never"
center-focused-column = "always"
# always-center-single-column = true   # a lone window in the center, whatever the setting above says

resize-step = 10          # how much grow-width and shrink-width change a window, in % of the screen width

# wrap-around = true          # focus past the last window or Space goes round to the first one
# focus-follows-mouse = true  # the window the pointer stops on takes focus, and the strip scrolls to it
# mouse-follows-focus = true  # the pointer goes to the window that takes focus, unless it is on it already
# inactive-opacity = 0.85     # windows without focus fade to this opacity, 0.1 to 1. Default 1: off
# border = true               # a border around the strip's focused window
# border-width = 4            # its width, in points
# border-color = "#3083FB"    # its color, "#RRGGBB" or "#RRGGBBAA"
# border-inactive = true      # a border around the strip's other windows too
# border-inactive-color = "#808080"  # theirs
# overview-background = "blur"  # the wallpaper, blurred, behind the overview's Spaces. Default "none": black
# overview-scale = 0.5        # size of the Spaces in the overview, 0.2 to 0.8. Default 0.4
# mouse-modifier = "ctrl+option"  # held for a left drag (move a window) or a right drag (resize it). Default "option"
# launch-at-login = true      # start Nori.app at login. Move the app to /Applications first
# analytics = false           # no anonymous `active` event a day, see the README. Default true
# gesture-strip = "3 sideways"    # the swipe that moves the strip: 3 to 5 fingers and "sideways", or "none"
# gesture-spaces = "3 vertical"   # the swipe that switches Spaces: 3 to 5 fingers and "vertical", or "none"
# gesture-overview = "4 vertical" # the one that opens the overview: 3 to 5 fingers and "vertical" or "pinch", or "none".
#                                  # Vertical takes a pinch of the same fingers too
# swipe-speed = 1.3           # strip points per point of finger travel, 0.25 to 5
# space-swipe-distance = 50   # swipe per Space, % of the trackpad, 10 to 100
# overview-swipe-distance = 30  # swipe from closed to open, % of the trackpad, 10 to 100
# leave-system-gestures = true  # keep Mission Control and App Exposé, from the next launch. macOS may act on nori's swipes too

# Key bindings: modifiers and one key joined by "+". Modifiers: option, ctrl, cmd, shift. Keys: a to z, 0 to 9,
# - = , . and left, right, up, down. Keys are physical keys on the US layout, so a binding stays put in any
# keyboard layout. "none" turns a binding off. Each action is also a command, see `nori help`.
# Desktop numbers run across displays, like macOS's own shortcuts: with two Desktops on the first display, the second
# one's start at 3. The focus-space-slot and move-to-space-slot actions count on the display that has focus instead.
[bindings]
focus-left = "option+h"             # the window to the left / right
focus-right = "option+l"
focus-first = "ctrl+option+h"       # the first / last window of the strip
focus-last = "ctrl+option+l"
focus-space-down = "option+j"       # the Space below / above
focus-space-up = "option+k"
\((1...9).map { "focus-space-\($0) = \"option+\($0)\"" + ($0 == 1 ? "           # go to Desktop 1, and so on" : "") }.joined(separator: "\n"))
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
# With several displays. No keys by default, try "ctrl+option+left". next and previous go round.
\((1...9).map { "focus-space-slot-\($0) = \"none\"" + ($0 == 1 ? "      # Desktop 1 of the display that has focus, as Mission Control labels it" : "") }.joined(separator: "\n"))
\((1...9).map { "move-to-space-slot-\($0) = \"none\"" + ($0 == 1 ? "    # send the focused window there" : "") }.joined(separator: "\n"))
\(monitorWays.map { "focus-monitor-\($0) = \"none\"" + ($0 == "left" ? "       # focus goes to the display on that side" : "") }.joined(separator: "\n"))
\(monitorWays.map { "move-window-to-monitor-\($0) = \"none\"" + ($0 == "left" ? "  # the focused window goes there, and focus with it" : "") }.joined(separator: "\n"))

# App rules. One [[rule]] table each; the first rule that matches a window wins.
#   app       the app's name or bundle id, any case. Find them with:
#             nori query windows | jq -r '.[] | "\\(.app)\\t\\(.bundleId)"' | sort -u
#   title     optional: a regular expression the window title must contain, any case
# and at least one of:
#   space     new windows of the app go to Desktop N, across all displays, once; move one back by hand and it stays
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

# Padding of one display, with padding-per-monitor on. One [[monitor]] table each; name is the display's, as System
# Settings → Displays shows it. A padding left out, or a display without a table, takes the one at the top of this file.
#
# [[monitor]]
# name = "Studio Display"
# padding-top = 16
# padding-left = 48

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

// Numbers, flags and bindings as strings by key; the rules in file order; paddings by display name; what was skipped and
// why, one line each, for Settings, the menu (Problems.swift) and stderr.
// ponytail: two displays of one name share a table, unless macOS numbers them; match on the UUID if that bites.
func parseConfig(_ text: String) -> (values: [String: String], rules: [Rule], monitors: [String: [String: Double]], problems: [String]) {
    var problems: [String] = []
    let report = { (line: Int, message: String) in problems.append("line \(line): \(message)") }
    var values: [String: String] = [:]
    var ruleTables: [Int: [String: TOMLValue]] = [:]
    var monitorTables: [Int: [String: TOMLValue]] = [:]
    for entry in parseTOML(text, report: report) {
        switch (entry.table, entry.value) {
        case ("", .number(let n)) where numberKeys.contains(entry.key): values[entry.key] = String(n)
        case ("", .bool(let b)) where flagKeys.contains(entry.key): values[entry.key] = String(b)
        case ("", .string(let s)) where choiceKeys[entry.key]?.contains(s) == true: values[entry.key] = s
        case ("", .string(let s)) where modifierKeys.contains(entry.key) && modifiers(s) != nil: values[entry.key] = s
        case ("", .string(let s)) where colorDefaults[entry.key] != nil && parseColor(s) != nil: values[entry.key] = s
        case ("bindings", .string(let s)) where bindingDefaults[entry.key] != nil && (s == "none" || chord(s) != nil): values[entry.key] = s
        case ("rule", _) where entry.index != nil: ruleTables[entry.index!, default: [:]][entry.key] = entry.value
        case ("monitor", .string) where entry.index != nil && entry.key == "name",
             ("monitor", .number) where entry.index != nil && paddingKeys.contains(entry.key):
            monitorTables[entry.index!, default: [:]][entry.key] = entry.value
        default: report(entry.line, "skipping \(entry.key): unknown key or bad value")
        }
    }
    var monitors: [String: [String: Double]] = [:]
    for i in monitorTables.keys.sorted() {
        let table = monitorTables[i]!
        guard case .string(let name)? = table["name"] else {
            problems.append("skipping [[monitor]] #\(i + 1): needs name = \"…\"")
            continue
        }
        for key in paddingKeys { if case .number(let n)? = table[key] { monitors[name, default: [:]][key] = n } }
    }
    let rules = ruleTables.keys.sorted().compactMap { i in
        let rule = makeRule(ruleTables[i]!)
        if rule == nil { problems.append("skipping [[rule]] #\(i + 1): needs app = \"…\" and space = N, floating = true, ignore = true or width = N, with a valid title and width") }
        return rule
    }
    return (values, rules, monitors, problems)
}

func readConfig() -> (values: [String: String], rules: [Rule], monitors: [String: [String: Double]], problems: [String]) {
    writeDefaultConfig()
    guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
        fputs("cannot read \(configPath)\n", stderr)
        return ([:], [], [:], ["cannot read \(configPath), so nori runs on its defaults"])
    }
    let parsed = parseConfig(text)
    for problem in parsed.problems { fputs("config.toml: \(problem)\n", stderr) }
    if !parsed.problems.isEmpty {
        fputs("config.toml: top level: \((numberKeys + flagKeys + choiceKeys.keys + modifierKeys + colorDefaults.keys).joined(separator: ", ")); "
            + "[bindings]: \(bindingDefaults.keys.sorted().joined(separator: ", ")); [[rule]]: app, title, space, floating, ignore, width; "
            + "[[monitor]]: name, \(paddingKeys.joined(separator: ", "))\n", stderr)
    }
    return parsed
}

// Values below are computed on every use, so a reload ("configFile = readConfig()") reaches them all.
var configFile = readConfig()
var config: [String: String] { configFile.values }
var rules: [Rule] { configFile.rules + builtinRules }

func number(_ key: String) -> CGFloat { CGFloat(config[key].flatMap(Double.init) ?? numberDefaults[key] ?? 0) }
var launchAtLogin: Bool { config["launch-at-login"] == "true" }
var overviewBlur: Bool { config["overview-background"] == "blur" }
var gap: CGFloat { number("gap") }
var paddingPerMonitor: Bool { config["padding-per-monitor"] == "true" }
// On the display of this name: its [[monitor]] table's with padding-per-monitor on, else the shared one.
func padding(_ key: String, on name: @autoclosure () -> String?) -> CGFloat {
    (paddingPerMonitor ? name().flatMap { configFile.monitors[$0]?[key] } : nil).map { CGFloat($0) } ?? number(key)
}
var resizeStep: CGFloat { number("resize-step") }  // percent of the usable width
var centerFocusedColumn: String { config["center-focused-column"] ?? "always" }  // see Scroll.swift
var alwaysCenterSingleColumn: Bool { config["always-center-single-column"] == "true" }
var wrapAround: Bool { config["wrap-around"] == "true" }
var focusFollowsMouse: Bool { config["focus-follows-mouse"] == "true" }
var mouseFollowsFocus: Bool { config["mouse-follows-focus"] == "true" }
var inactiveOpacity: Float { Float(min(max(number("inactive-opacity"), 0.1), 1)) }  // 1: off
var borderWidth: CGFloat { config["border"] == "true" ? min(max(number("border-width"), 1), 100) : 0 }  // 0: off
var borderInactive: Bool { config["border-inactive"] == "true" }

// "#RRGGBB" or "#RRGGBBAA", red, green, blue and alpha from 0 to 1.
func parseColor(_ text: String) -> [Double]? {
    guard text.hasPrefix("#"), text.count == 7 || text.count == 9, let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
    let full = text.count == 9 ? value : value << 8 | 0xff
    return [24, 16, 8, 0].map { Double(full >> UInt32($0) & 0xff) / 255 }
}

func color(_ key: String) -> [Double] { parseColor(config[key] ?? colorDefaults[key]!)! }
var overviewScale: CGFloat { min(max(number("overview-scale"), 0.2), 0.8) }
var analyticsOn: Bool { config["analytics"] != "false" }
var leaveSystemGestures: Bool { config["leave-system-gestures"] == "true" }
var swipeSpeed: CGFloat { min(max(number("swipe-speed"), 0.25), 5) }  // above 1 the strip outruns the fingers
var spaceSwipeDistance: CGFloat { min(max(number("space-swipe-distance"), 10), 100) / 100 }  // of the trackpad, per Space
var overviewSwipeDistance: CGFloat { min(max(number("overview-swipe-distance"), 10), 100) / 100 }  // of the trackpad, closed to open
var mouseModifier: CGEventFlags { config["mouse-modifier"].flatMap(modifiers) ?? .maskAlternate }

// Trackpad actions, each on a swipe of its own: "3 sideways" is fingers and way, "none" is off. An action only takes
// swipes that go the way it moves: the strip runs sideways, Spaces are stacked, the overview also zooms, so a pinch.
// Two fingers are the system's scroll. The first choice is the default.
let gestureKeys = ["gesture-strip", "gesture-spaces", "gesture-overview"]

func swipeChoices(_ kinds: [String], fingers: Int) -> [String] {
    let first = "\(fingers) \(kinds[0])"
    return [first] + kinds.flatMap { kind in (3...5).map { "\($0) \(kind)" } }.filter { $0 != first } + ["none"]
}

struct Gesture: Equatable {
    let fingers: Int32
    let kind: String
}

func gesture(_ key: String) -> Gesture? {
    let parts = (config[key] ?? choiceKeys[key]![0]).split(separator: " ")
    return parts.count == 2 ? Gesture(fingers: Int32(parts[0])!, kind: String(parts[1])) : nil
}

// The first action wins where a file edited by hand gives two the same swipe. The overview also takes a pinch of its
// fingers when it swipes vertically, as it zooms: closing in opens it.
func swipeAction(fingers: Int32, kind: String) -> String? {
    gestureKeys.first { gesture($0) == Gesture(fingers: fingers, kind: kind) }
        ?? (kind == "pinch" && gesture("gesture-overview") == Gesture(fingers: fingers, kind: "vertical") ? "gesture-overview" : nil)
}

func ourGesture(_ fingers: Int32) -> Bool {
    gestureKeys.contains { gesture($0)?.fingers == fingers }
}

func swipeFingers() -> Set<Int32> { Set(gestureKeys.compactMap { gesture($0)?.fingers }) }

// A swipe is one action's. The action that had the swipe `key` takes moves to the fingers `key` left, or the first free ones.
func gestureChanges(_ key: String, to new: String, current: (String) -> String) -> [(key: String, value: String)] {
    var changes = [(key: key, value: new)]
    guard new != "none", let other = gestureKeys.first(where: { $0 != key && current($0) == new }) else { return changes }
    let kind = new.split(separator: " ")[1]
    let taken = gestureKeys.filter { $0 != other }.map { $0 == key ? new : current($0) }
    let fingers = [String(current(key).split(separator: " ")[0])] + (3...5).map(String.init)
    let free = fingers.map { "\($0) \(kind)" }.first { choiceKeys[other]!.contains($0) && !taken.contains($0) }
    changes.append((other, free ?? "none"))
    return changes
}

// A system shortcut, com.apple.symbolichotkeys: whether it is on, and its keys. 65535 is no key.
struct SymbolicHotkey {
    var enabled: Bool
    var character: Int, keycode: Int, flags: Int
    var pressable: Bool { enabled && keycode != 65535 }
}

// The shortcuts nori needs and can't press now, by id: "Move left/right a space" (79, 81) and "Switch to Desktop N"
// (118…133) of each Desktop. With a single Space there is nothing to switch to.
// ponytail: Desktops past 16 have no shortcut, and stay out of reach unnoticed.
func shortcutsOff(desktops: Int, spaces: Int, hotkey: (Int) -> SymbolicHotkey) -> [Int] {
    guard spaces > 1 else { return [] }
    return ([79, 81] + (0..<min(desktops, 16)).map { 118 + $0 }).filter { !hotkey($0).pressable }
}

// The value `defaults write … -dict-add` takes to turn a shortcut on, with the keys it has.
func enabledPlist(_ hotkey: SymbolicHotkey) -> String {
    let parameters = [hotkey.character, hotkey.keycode, hotkey.flags].map { "<integer>\($0)</integer>" }.joined()
    return "<dict><key>enabled</key><true/><key>value</key><dict><key>parameters</key><array>\(parameters)</array>"
        + "<key>type</key><string>standard</string></dict></dict>"
}

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

// Every binding with its keys. The event taps keep this list: the config is the main thread's, see Tap.swift.
func boundChords() -> [(chord: Chord, action: String)] {
    bindingDefaults.keys.compactMap { name in binding(name).map { ($0, name) } }
}

// The action a key press is bound to, if any.
func boundAction(_ event: CGEvent, in chords: [(chord: Chord, action: String)]) -> String? {
    chords.first { matches(event, $0.chord) }?.action
}
