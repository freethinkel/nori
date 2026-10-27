// ~/.config/nori/config: gaps, screen padding, resize step and key bindings, read once at start.

import Cocoa

// "key = value" lines, # starts a comment. Missing number: 0. Missing binding: its default below.
// ponytail: no live reload, restart to apply.
let numberKeys = ["gap", "padding-top", "padding-bottom", "padding-left", "padding-right", "resize-step"]
let bindingDefaults = ["overview": "option+o", "grow-width": "option+=", "shrink-width": "option+-"]
let config: [String: String] = {
    let path = NSHomeDirectory() + "/.config/nori/config"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var result: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let body = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard !body.allSatisfy(\.isWhitespace) else { continue }
        let parts = body.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              numberKeys.contains(parts[0]) && Double(parts[1]) != nil || bindingDefaults[parts[0]] != nil && chord(parts[1]) != nil
        else {
            fputs("config: skipping \"\(line)\"; keys: \((numberKeys + bindingDefaults.keys.sorted()).joined(separator: ", "))\n", stderr)
            continue
        }
        result[parts[0]] = parts[1]
    }
    return result
}()

func number(_ key: String) -> CGFloat { CGFloat(Double(config[key] ?? "") ?? 0) }
let gap = number("gap")
let paddingTop = number("padding-top")
let paddingBottom = number("padding-bottom")
let paddingLeft = number("padding-left")
let paddingRight = number("padding-right")
let resizeStep = config["resize-step"].flatMap(Double.init).map { CGFloat($0) } ?? 10  // percent of the usable width

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
let overviewChord = binding("overview")
let growChord = binding("grow-width")
let shrinkChord = binding("shrink-width")

func matches(_ event: CGEvent, _ chord: Chord) -> Bool {
    event.getIntegerValueField(.keyboardEventKeycode) == chord.key && event.flags.intersection(chordModifiers) == chord.flags
}
