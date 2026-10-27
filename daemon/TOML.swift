// The part of TOML the config needs: comments, bare keys, basic and literal strings, numbers, booleans,
// [table] and [[array of tables]]. A line with anything else (dotted or quoted keys, arrays, inline tables,
// multi-line strings, dates) is reported and skipped, like a key the config doesn't know.

import Foundation

enum TOMLValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
}

// One "key = value" line. table is "" at the top; index counts the [[table]] headers of that name, from 0, or is nil.
struct TOMLEntry {
    var table: String
    var index: Int?
    var key: String
    var value: TOMLValue
    var line: Int
}

// onHeader hears each [table] or [[table]] line with its index and line number; a malformed one as table "?".
func parseTOML(_ text: String, onHeader: (String, Int?, Int) -> Void = { _, _, _ in }, report: (Int, String) -> Void) -> [TOMLEntry] {
    var entries: [TOMLEntry] = []
    var table = "", index: Int?
    var arrays: [String: Int] = [:]
    var seen: Set<String> = []  // table/index/key, for duplicate keys
    for (n, raw) in text.components(separatedBy: "\n").enumerated() {
        let line = n + 1
        var rest = Substring(raw).drop { $0 == " " || $0 == "\t" }
        guard !rest.isEmpty, !rest.hasPrefix("#"), rest != "\r" else { continue }

        if rest.hasPrefix("[") {
            let array = rest.hasPrefix("[[")
            rest = rest.dropFirst(array ? 2 : 1)
            let name = rest.prefix(while: isBareKeyChar)
            rest = rest.dropFirst(name.count)
            guard !name.isEmpty, rest.hasPrefix(array ? "]]" : "]"), isEnd(rest.dropFirst(array ? 2 : 1)) else {
                report(line, "expected [table] or [[table]] with a plain name")
                table = "?"; index = nil  // its keys are skipped as unknown
                onHeader(table, index, line)
                continue
            }
            table = String(name)
            index = array ? arrays[table, default: -1] + 1 : nil
            if array { arrays[table] = index }
            onHeader(table, index, line)
            continue
        }

        let key = rest.prefix(while: isBareKeyChar)
        rest = rest.dropFirst(key.count).drop { $0 == " " || $0 == "\t" }
        guard !key.isEmpty, rest.hasPrefix("=") else {
            report(line, "expected key = value")
            continue
        }
        rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
        guard let (value, after) = parseValue(rest), isEnd(after) else {
            report(line, "unsupported value; use a \"string\", a number, true or false")
            continue
        }
        guard seen.insert("\(table)/\(index ?? -1)/\(key)").inserted else {
            report(line, "\(key) is set twice")
            continue
        }
        entries.append(TOMLEntry(table: table, index: index, key: String(key), value: value, line: line))
    }
    return entries
}

private func isBareKeyChar(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-") }

// Only spaces and a comment may follow.
private func isEnd(_ rest: Substring) -> Bool {
    let tail = rest.drop { $0 == " " || $0 == "\t" || $0 == "\r" }
    return tail.isEmpty || tail.hasPrefix("#")
}

private func parseValue(_ text: Substring) -> (TOMLValue, Substring)? {
    if text.hasPrefix("'") {
        guard let end = text.dropFirst().firstIndex(of: "'") else { return nil }
        return (.string(String(text[text.index(after: text.startIndex)..<end])), text[text.index(after: end)...])
    }
    if text.hasPrefix("\"") {
        var result = ""
        var i = text.index(after: text.startIndex)
        while i < text.endIndex {
            let c = text[i]
            i = text.index(after: i)
            if c == "\"" { return (.string(result), text[i...]) }
            guard c == "\\" else { result.append(c); continue }
            guard i < text.endIndex else { return nil }
            let e = text[i]
            i = text.index(after: i)
            switch e {
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "u", "U":
                let digits = e == "u" ? 4 : 8
                guard text.distance(from: i, to: text.endIndex) >= digits,
                      let code = UInt32(text[i..<text.index(i, offsetBy: digits)], radix: 16),
                      let scalar = Unicode.Scalar(code) else { return nil }
                result.unicodeScalars.append(scalar)
                i = text.index(i, offsetBy: digits)
            default: return nil
            }
        }
        return nil  // no closing quote
    }
    let word = text.prefix { !" \t\r#".contains($0) }
    let after = text.dropFirst(word.count)
    if word == "true" { return (.bool(true), after) }
    if word == "false" { return (.bool(false), after) }
    // Decimal numbers with optional sign, "_" between digits, fraction and exponent.
    let digits = word.replacingOccurrences(of: "_", with: "")
    guard digits.range(of: #"^[+-]?\d+(\.\d+)?([eE][+-]?\d+)?$"#, options: .regularExpression) != nil,
          let number = Double(digits) else { return nil }
    return (.number(number), after)
}

// Edits for the Settings window. Only the lines of the key or table in question change: comments, order and keys
// nori doesn't know stay as written.

// The text with one key set, or with its line gone for nil. The value changes inside its own line and a comment after
// it keeps its column. A missing key takes a commented-out line of it, or goes under the last key of its table, or
// under the header of an empty one; a top-level key with no other one goes first in the file, a [table] that isn't
// there is added at the end.
func settingTOML(_ text: String, table: String = "", index: Int? = nil, key: String, to value: TOMLValue?) -> String {
    var lines = text.components(separatedBy: "\n")
    var headers: [(table: String, index: Int?, line: Int)] = []
    let entries = parseTOML(text, onHeader: { headers.append(($0, $1, $2)) }, report: { _, _ in })
        .filter { $0.table == table && $0.index == index }
    if let entry = entries.first(where: { $0.key == key }) {
        if let value { lines[entry.line - 1] = replacingValue(lines[entry.line - 1], with: tomlText(value)) } else { lines.remove(at: entry.line - 1) }
        return lines.joined(separator: "\n")
    }
    guard let value else { return text }
    // The default config has optional settings as "# key = value  # what it does": such a line of the table is turned
    // back on in place. Not in [[tables]], whose commented-out examples may sit among them.
    if index == nil {
        let start = table == "" ? 0 : headers.first { $0.table == table }?.line ?? lines.count
        let end = (headers.first { $0.line > start }?.line).map { $0 - 1 } ?? lines.count
        for i in start..<max(start, end) {
            let rest = lines[i].drop { $0 == " " || $0 == "\t" }
            guard rest.hasPrefix("#") else { continue }
            let uncommented = String(rest.dropFirst().drop { $0 == " " || $0 == "\t" })
            guard uncommented.hasPrefix(key), uncommented.dropFirst(key.count).drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("=") else { continue }
            let line = replacingValue(uncommented, with: tomlText(value), shift: lines[i].count - uncommented.count)
            if line != uncommented { lines[i] = line; return lines.joined(separator: "\n") }
        }
    }
    let line = "\(key) = \(tomlText(value))"
    if let last = entries.last {
        lines.insert(line, at: last.line)
    } else if let header = headers.first(where: { $0.table == table && $0.index == index }) {
        lines.insert(line, at: header.line)
    } else if table == "" {
        lines.insert(line, at: 0)
    } else if index == nil {
        return withBlankLine(text) + "[\(table)]\n\(line)\n"
    }
    return lines.joined(separator: "\n")
}

// The text with a new [[name]] table of these keys at the end.
func appendingTOMLTable(_ text: String, _ name: String, _ keys: [(String, TOMLValue)]) -> String {
    withBlankLine(text) + "[[\(name)]]\n" + keys.map { "\($0) = \(tomlText($1))\n" }.joined()
}

// The text without the index-th [[name]] table: its header, everything up to its last key and the blank line above.
// Comments under its last key stay, as they may be about the table that follows.
func removingTOMLTable(_ text: String, _ name: String, index: Int) -> String {
    var lines = text.components(separatedBy: "\n")
    var headers: [(table: String, index: Int?, line: Int)] = []
    _ = parseTOML(text, onHeader: { headers.append(($0, $1, $2)) }, report: { _, _ in })
    guard let header = headers.first(where: { $0.table == name && $0.index == index }) else { return text }
    let isNote = { (line: String) in line.trimmingCharacters(in: .whitespaces).isEmpty || line.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    var end = (headers.first { $0.line > header.line }?.line ?? lines.count + 1) - 1  // its last line, from 1
    while end > header.line && isNote(lines[end - 1]) { end -= 1 }
    var start = header.line - 1
    if start > 0 && lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
    lines.removeSubrange(start..<end)
    return lines.joined(separator: "\n")
}

// A value as the file spells it: whole numbers without ".0", strings in quotes with escapes.
func tomlText(_ value: TOMLValue) -> String {
    switch value {
    case .bool(let on): return String(on)
    case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
    case .string(let s):
        return "\"" + s.unicodeScalars.map { c -> String in
            switch c {
            case "\"": return "\\\""
            case "\\": return "\\\\"
            case "\n": return "\\n"
            case "\t": return "\\t"
            case "\r": return "\\r"
            default: return c.value < 0x20 || c.value == 0x7f ? String(format: "\\u%04X", c.value) : String(c)
            }
        }.joined() + "\""
    }
}

// A key's line with another value. Spaces before a comment shrink or grow so the comment stays where it was, `shift`
// more for what was cut off the line's start.
private func replacingValue(_ line: String, with value: String, shift: Int = 0) -> String {
    let text = Substring(line)
    guard let equals = text.firstIndex(of: "=") else { return line }
    let start = text[text.index(after: equals)...].firstIndex { $0 != " " && $0 != "\t" } ?? text.endIndex
    guard let (_, after) = parseValue(text[start...]) else { return line }
    let spaces = after.prefix { $0 == " " || $0 == "\t" }
    let rest = after.dropFirst(spaces.count)
    let width = text.distance(from: start, to: after.startIndex) + spaces.count - value.count + shift
    return String(text[..<start]) + value + (rest.hasPrefix("#") ? String(repeating: " ", count: max(1, width)) : String(spaces)) + rest
}

// The text ending in a blank line, ready for a table to follow; empty stays empty.
private func withBlankLine(_ text: String) -> String {
    guard !text.isEmpty else { return "" }
    let ended = text.hasSuffix("\n") ? text : text + "\n"
    return ended.hasSuffix("\n\n") ? ended : ended + "\n"
}
