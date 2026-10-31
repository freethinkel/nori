// make test: checks of the TOML reader (daemon/TOML.swift) and the strip's rest points (daemon/Scroll.swift).
// Fails with an assertion.

import Foundation

setenv("NORI_CONFIG", NSTemporaryDirectory() + "nori-test/config.toml", 1)  // never your own config

var errors: [String] = []
func parse(_ text: String) -> [TOMLEntry] { parseTOML(text) { errors.append("\($0): \($1)") } }

// Strings with escapes and a "#" inside, literal strings, numbers, booleans, comments after values.
var entries = parse("a = \"x \\\"q\\\" \\u00e9 # in\" # comment\nb = 'C:\\path'\nc = -1_000\nd = 2.5e1\nf = false")
assert(entries.map(\.value) == [.string("x \"q\" é # in"), .string("C:\\path"), .number(-1000), .number(25), .bool(false)])
assert(errors.isEmpty, "\(errors)")

// [table] and [[array of tables]]: each [[r]] header starts a new index.
entries = parse("[t]\nk = 1\n[[r]]\nk = 1\n[[r]]\nk = 2\n[[q]]\nk = 3")
assert(entries.map { "\($0.table)\($0.index ?? -1)" } == ["t-1", "r0", "r1", "q0"])

// Arrays, a duplicate key, junk after a value, a bad header, an open string, an inline table: reported, skipped.
errors = []
entries = parse("a = [1, 2]\nb = 1\nb = 2\nc = 1 2\n[bad name]\nd = \"open\ne = {x = 1}")
assert(entries.map(\.key) == ["b"] && errors.count == 6, "\(errors)")

print("toml: ok")

// In-place edits for the Settings window: a value changes in its own line, the comment after it keeps its column; a
// missing key goes under the last key of its table; a [[rule]] comes and goes whole; every other line stays.
let file = """
    # top
    gap = 16      # pt
    name = "a"

    [bindings]
    focus-left = "option+h"

    [[rule]]
    app = "A"
    space = 3
    # about B
    [[rule]]
    app = "B"

    """
func edit(_ table: String, _ index: Int?, _ key: String, _ value: TOMLValue?) -> String {
    settingTOML(file, table: table, index: index, key: key, to: value)
}
func edit(_ key: String, _ value: TOMLValue?) -> String { edit("", nil, key, value) }
assert(edit("gap", .number(8)) == file.replacingOccurrences(of: "gap = 16      #", with: "gap = 8       #"))
assert(edit("gap", .number(1234567)) == file.replacingOccurrences(of: "gap = 16      #", with: "gap = 1234567 #"))
assert(edit("gap", .number(123456789)) == file.replacingOccurrences(of: "gap = 16      #", with: "gap = 123456789 #"))
assert(edit("gap", .number(0.75)).contains("gap = 0.75    # pt"))
assert(edit("name", .string("q\"\\")) == file.replacingOccurrences(of: "name = \"a\"", with: "name = \"q\\\"\\\\\""))
assert(parse(edit("name", .string("q\"\\ \n"))).first { $0.key == "name" }?.value == .string("q\"\\ \n"))
assert(edit("wrap-around", .bool(true)) == file.replacingOccurrences(of: "name = \"a\"\n", with: "name = \"a\"\nwrap-around = true\n"))
assert(edit("bindings", nil, "overview", .string("none")).contains("focus-left = \"option+h\"\noverview = \"none\"\n\n[[rule]]"))
assert(edit("rule", 0, "space", nil) == file.replacingOccurrences(of: "space = 3\n", with: ""))
assert(edit("rule", 1, "floating", .bool(true)) == file + "floating = true\n")
assert(edit("rule", 0, "missing", nil) == file && edit("rule", 5, "app", .string("C")) == file)
assert(settingTOML("[t]\n", table: "t", key: "k", to: .number(1)) == "[t]\nk = 1\n")
assert(settingTOML("# only\n", key: "gap", to: .number(1)) == "gap = 1\n# only\n")
assert(settingTOML("gap = 1", table: "bindings", key: "overview", to: .string("none")) == "gap = 1\n\n[bindings]\noverview = \"none\"\n")
assert(removingTOMLTable(file, "rule", index: 0) == file.replacingOccurrences(of: "\n[[rule]]\napp = \"A\"\nspace = 3\n", with: ""))
assert(removingTOMLTable(file, "rule", index: 1) == file.replacingOccurrences(of: "[[rule]]\napp = \"B\"\n", with: ""))
assert(appendingTOMLTable(file, "rule", [("app", .string("C")), ("ignore", .bool(true))]) == file + "\n[[rule]]\napp = \"C\"\nignore = true\n")
assert(appendingTOMLTable("", "rule", [("app", .string("C"))]) == "[[rule]]\napp = \"C\"\n")
errors = []
assert(parse(appendingTOMLTable(edit("rule", 1, "floating", .bool(true)), "rule", [("app", .string("C"))])).filter { $0.table == "rule" }.map(\.index) == [0, 0, 1, 1, 2] && errors.isEmpty)

// A commented-out "# key = …" line comes back on in place, comment and all; a [[rule]] example doesn't.
let commented = "# wrap-around = true   # round\ngap = 1\n[bindings]\n# overview = \"option+o\"\n[[rule]]\napp = \"A\"\n# space = 3\n"
assert(settingTOML(commented, key: "wrap-around", to: .bool(false)) == commented.replacingOccurrences(of: "# wrap-around = true   #", with: "wrap-around = false    #"))
assert(settingTOML(commented, table: "bindings", key: "overview", to: .string("none")).contains("[bindings]\noverview = \"none\"\n[[rule]]"))
assert(settingTOML(commented, table: "rule", index: 0, key: "space", to: .number(2)).hasSuffix("app = \"A\"\nspace = 2\n# space = 3\n"))
assert(settingTOML(defaultConfig, key: "inactive-opacity", to: .number(0.7)).contains("\ninactive-opacity = 0.7 "))
assert(settingTOML(defaultConfig, key: "overview-scale", to: .number(0.5)).contains("\noverview-scale = 0.5 "))
assert(settingTOML(defaultConfig, key: "analytics", to: .bool(false)).contains("\nanalytics = false "))
assert(settingTOML(defaultConfig, key: "gesture-overview", to: .string("3 pinch")).contains("\ngesture-overview = \"3 pinch\""))
assert(settingTOML(defaultConfig, key: "swipe-speed", to: .number(2)).contains("\nswipe-speed = 2 "))

print("toml edits: ok")

// An action takes only swipes that go its way, and a swipe is one action's.
assert(choiceKeys["gesture-strip"]![0] == "3 sideways" && !choiceKeys["gesture-strip"]!.contains("3 vertical"))
assert(choiceKeys["gesture-spaces"]![0] == "3 vertical" && !choiceKeys["gesture-spaces"]!.contains("3 pinch"))
assert(choiceKeys["gesture-overview"]![0] == "4 vertical" && choiceKeys["gesture-overview"]!.contains("3 pinch"))
assert(choiceKeys["gesture-overview"]!.filter { $0 == "4 vertical" }.count == 1)
assert(swipeAction(fingers: 3, kind: "sideways") == "gesture-strip" && swipeAction(fingers: 3, kind: "vertical") == "gesture-spaces")
assert(swipeAction(fingers: 4, kind: "vertical") == "gesture-overview" && swipeAction(fingers: 4, kind: "sideways") == nil)
assert(ourGesture(3) && ourGesture(4) && !ourGesture(2) && !ourGesture(5))
let filed = configFile
configFile.values = ["gesture-strip": "none", "gesture-spaces": "4 vertical", "gesture-overview": "4 vertical"]
assert(swipeAction(fingers: 4, kind: "vertical") == "gesture-spaces")  // by hand: the first wins
assert(!ourGesture(3))
configFile = filed
var swipes = ["gesture-strip": "3 sideways", "gesture-spaces": "3 vertical", "gesture-overview": "4 vertical"]
func changed(_ key: String, _ value: String) -> [String] { gestureChanges(key, to: value, current: { swipes[$0]! }).map { "\($0.key)=\($0.value)" } }
assert(changed("gesture-overview", "3 vertical") == ["gesture-overview=3 vertical", "gesture-spaces=4 vertical"])  // they swap
assert(changed("gesture-overview", "5 pinch") == ["gesture-overview=5 pinch"])
assert(changed("gesture-overview", "none") == ["gesture-overview=none"])
assert(changed("gesture-strip", "5 sideways") == ["gesture-strip=5 sideways"])
swipes["gesture-overview"] = "none"
assert(changed("gesture-overview", "3 vertical") == ["gesture-overview=3 vertical", "gesture-spaces=4 vertical"])  // it left no fingers
swipes["gesture-overview"] = "3 pinch"
assert(changed("gesture-overview", "3 vertical") == ["gesture-overview=3 vertical", "gesture-spaces=4 vertical"])  // same fingers: the first free
print("gestures: ok")

// A 1000 pt wide screen, gap 10. Three 300 pt columns fit on it, three 600 pt ones don't.
func strip(_ widths: [CGFloat], _ mode: String, single: Bool = false) -> Scroll {
    Scroll(widths: widths, view: 1000, gap: 10, mode: mode, centerSingle: single)
}
let narrow: [CGFloat] = [300, 300, 300], wide: [CGFloat] = [600, 600, 600]

// "always": the focused column in the center, the ends centered too; a lift snaps to the nearest center.
assert(strip(narrow, "always").centers == [0, 310, 620])
assert(strip(narrow, "always").bounds == 0...620 && strip(narrow, "always").rest(2, from: 0, previous: 0) == 620)
assert(strip(narrow, "always").snap(400, focused: 0) == (310, 1))

// "never": no scroll while the column shows whole; else the nearer padding. A lone window sits at the left
// unless always-center-single-column; a window wider than the screen against the left padding.
assert(strip(narrow, "never").bounds == 350...350 && strip(narrow, "never").rest(2, from: 350, previous: 0) == 350)
assert(strip(narrow, "never").snap(500, focused: 2) == (350, 2))  // all on screen: focus stays
assert(strip(wide, "never").bounds == 200...1020 && strip(wide, "never").rest(1, from: 200, previous: 0) == 410)
assert(strip([300], "never").bounds == 350...350 && strip([300], "never", single: true).bounds == 0...0)
assert(strip([1200], "never").rest(0, from: 0, previous: nil) == -100)

// "on-overflow": centered when it doesn't fit beside the column focus came from, else like "never".
assert(strip(wide, "on-overflow").rest(1, from: 200, previous: 0) == 610)
assert(strip(wide, "on-overflow").rest(1, from: 200, previous: nil) == 410)
assert(strip(narrow, "on-overflow").rest(2, from: 350, previous: 0) == 350)
assert(strip(wide, "on-overflow").bounds == 0...1220 && strip(wide, "on-overflow").snap(600, focused: 0) == (610, 1))

print("scroll: ok")

// Displays: the main one, one left of it (negative x), a short one right of it and one above that one.
let main = CGRect(x: 0, y: 0, width: 3008, height: 1692), left = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
let right = CGRect(x: 3008, y: 800, width: 1000, height: 600), above = CGRect(x: 3008, y: -700, width: 1000, height: 600)
let frames = [main, left, right, above]

// A window's center stays on its display, even for an odd width: past the first or last point it would be handed over.
assert(keptOn(left, width: 300) == -2069 ... -151)
assert(keptOn(left, width: 301).lowerBound + 150.5 > left.minX && keptOn(left, width: 301).upperBound + 150.5 < left.maxX)

// A point: on a display, the one it is on; between them, the nearest. Edges belong to the display that starts there.
assert(displayIndex(at: CGPoint(x: -1, y: 300), in: frames) == 1 && displayIndex(at: CGPoint(x: 0, y: 300), in: frames) == 0)
assert(displayIndex(at: CGPoint(x: 3500, y: 600), in: frames) == 2)  // in the gap between the two on the right
assert(displayIndex(at: CGPoint(x: -3000, y: 1300), in: frames) == 1 && displayIndex(at: .zero, in: []) == nil)

// Left and right need an overlap across the way, up and down too, and the nearest center wins.
assert(neighbour(of: 0, in: frames, "left") == 1 && neighbour(of: 1, in: frames, "right") == 0)
assert(neighbour(of: 0, in: frames, "right") == 2)  // the one above doesn't reach the main display's top
assert(neighbour(of: 2, in: frames, "left") == 0 && neighbour(of: 3, in: frames, "left") == nil)
assert(neighbour(of: 2, in: frames, "up") == 3 && neighbour(of: 3, in: frames, "down") == 2)
assert(neighbour(of: 1, in: frames, "left") == nil && neighbour(of: 0, in: frames, "up") == nil)
let nearest = [main, CGRect(x: 3008, y: 0, width: 1000, height: 800), CGRect(x: 4008, y: 0, width: 1000, height: 800)]
assert(neighbour(of: 0, in: nearest, "right") == 1 && neighbour(of: 2, in: nearest, "left") == 1)

// Next and previous go round left to right, then top to bottom; alone, nowhere.
assert(neighbour(of: 1, in: frames, "next") == 0 && neighbour(of: 0, in: frames, "next") == 3 && neighbour(of: 3, in: frames, "next") == 2)
assert(neighbour(of: 2, in: frames, "next") == 1 && neighbour(of: 1, in: frames, "previous") == 2)
assert(neighbour(of: 0, in: [main], "next") == nil && neighbour(of: 0, in: [main], "previous") == nil)

// A frame saved past the edge of a display above the main one comes back with its center on it; one on it stays.
let upper = CGRect(x: -446, y: -1692, width: 3008, height: 1692)
let past = keptFrame(CGRect(x: 2522, y: -1642, width: 1327, height: 1541), on: upper)
assert(upper.contains(CGPoint(x: past.midX, y: past.midY)) && past.minY == -1642 && past.width == 1327, "\(past)")
assert(keptFrame(CGRect(x: 629, y: -1590, width: 1327, height: 1541), on: upper).origin == CGPoint(x: 629, y: -1590))
let below = keptFrame(CGRect(x: 100, y: 200, width: 800, height: 600), on: upper)  // from the display below it
assert(upper.contains(CGPoint(x: below.midX, y: below.midY)) && below.minX == 100, "\(below)")

print("displays: ok")

// padding-per-monitor: a display takes its [[monitor]] table's padding, zero included, and the shared one for what its
// table leaves out. A table without a name is skipped. With the flag off the shared ones apply, and the name isn't asked for.
try! FileManager.default.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
try! """
padding-top = 40
padding-left = 24
padding-per-monitor = true

[[monitor]]
name = "Wide"
padding-top = 8
padding-left = 0

[[monitor]]
padding-top = 1
""".write(toFile: configPath, atomically: true, encoding: .utf8)
configFile = readConfig()
assert(configFile.monitors == ["Wide": ["padding-top": 8, "padding-left": 0]])
assert(padding("padding-top", on: "Wide") == 8 && padding("padding-left", on: "Wide") == 0)
assert(padding("padding-top", on: "Other") == 40 && padding("padding-top", on: nil) == 40)
configFile.values["padding-per-monitor"] = "false"
assert(padding("padding-top", on: "Wide") == 40)
var nameAsked = false
_ = padding("padding-top", on: { nameAsked = true; return "Wide" }())
assert(!nameAsked)

print("monitor padding: ok")

// Rules: a table needs app and an action; title must be a valid regex, width 0 < n <= 100.
assert(makeRule(["app": .string("Safari"), "title": .string("Picture in Picture"), "floating": .bool(true)])?.title == "Picture in Picture")
assert(makeRule(["app": .string("Ghostty"), "width": .number(50)])?.width == 50)
assert(makeRule(["app": .string("Ghostty")]) == nil && makeRule(["app": .string("X"), "title": .string("("), "ignore": .bool(true)]) == nil)
assert(makeRule(["app": .string("X"), "width": .number(0)]) == nil && makeRule(["app": .string("X"), "width": .number(101)]) == nil)

// Matching: app names any case; a title rule skips to the next rule when the title doesn't match; the title is asked
// for once and only when a matching app has a title rule.
let safari = [Rule(app: "safari", title: "picture in picture", floating: true), Rule(app: "com.apple.Safari", width: 50)]
var asked = 0
func title(_ t: String?) -> () -> String? { { asked += 1; return t } }
assert(ruleMatching(["Safari", "com.apple.Safari"], title: title("Picture in Picture"), in: safari)?.floating == true)
assert(ruleMatching(["Safari", "com.apple.Safari"], title: title("Apple"), in: safari)?.width == 50)
assert(ruleMatching(["Safari", "com.apple.Safari"], title: title(nil), in: safari)?.width == 50)
assert(ruleMatching(["Finder"], title: title("Picture in Picture"), in: safari) == nil)
assert(asked == 3, "\(asked)")

print("rules: ok")

// The default config (Config.swift) parses without a warning, only sets known keys to valid values, and names every
// setting and binding, commented out or not, so a new setting can't be left out of it.
errors = []
for entry in parse(defaultConfig) {
    switch (entry.table, entry.value) {
    case ("", .number): assert(numberKeys.contains(entry.key), entry.key)
    case ("", .bool): assert(flagKeys.contains(entry.key), entry.key)
    case ("", .string(let s)): assert(choiceKeys[entry.key]?.contains(s) == true || modifierKeys.contains(entry.key) && modifiers(s) != nil, entry.key)
    case ("bindings", .string(let s)): assert(bindingDefaults[entry.key] == s, entry.key)
    default: assertionFailure("\(entry.table).\(entry.key)")
    }
}
assert(errors.isEmpty, "\(errors)")
for key in numberKeys + flagKeys + choiceKeys.keys + modifierKeys + bindingDefaults.keys {
    assert(defaultConfig.split(separator: "\n").contains { $0.hasPrefix("\(key) = ") || $0.hasPrefix("# \(key) = ") }, "missing \(key)")
}
for key in ["app", "title", "space", "floating", "ignore", "width"] { assert(defaultConfig.contains("#   \(key) "), "missing rule \(key)") }

// The display actions have no keys by default, so they can't take any from apps or from another action.
assert(monitorWays.allSatisfy { bindingDefaults["focus-monitor-\($0)"] == "none" && bindingDefaults["move-window-to-monitor-\($0)"] == "none" })
assert((1...9).allSatisfy { bindingDefaults["focus-space-slot-\($0)"] == "none" && bindingDefaults["move-to-space-slot-\($0)"] == "none" })

print("default config: ok")
