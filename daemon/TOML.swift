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

func parseTOML(_ text: String, report: (Int, String) -> Void) -> [TOMLEntry] {
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
                continue
            }
            table = String(name)
            index = array ? arrays[table, default: -1] + 1 : nil
            if array { arrays[table] = index }
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
