// make test: checks of the TOML reader (daemon/TOML.swift). Fails with an assertion.

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
