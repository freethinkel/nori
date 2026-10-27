// make test: checks of the TOML reader (daemon/TOML.swift) and the strip's rest points (daemon/Scroll.swift).
// Fails with an assertion.

import Foundation

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

print("toml edits: ok")

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
