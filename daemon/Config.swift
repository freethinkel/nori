// ~/.config/niri-mac/config: gaps and screen padding, read once at start.

import Cocoa

// "key = value" lines, # starts a comment. Missing file or key: 0.
// ponytail: no live reload, restart to apply.
let configKeys = ["gap", "padding-top", "padding-bottom", "padding-left", "padding-right"]
let config: [String: CGFloat] = {
    let path = NSHomeDirectory() + "/.config/niri-mac/config"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var result: [String: CGFloat] = [:]
    for line in text.split(separator: "\n") {
        let body = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard !body.allSatisfy(\.isWhitespace) else { continue }
        let parts = body.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, configKeys.contains(parts[0]), let value = Double(parts[1]) else {
            fputs("config: skipping \"\(line)\"; keys: \(configKeys.joined(separator: ", "))\n", stderr)
            continue
        }
        result[parts[0]] = CGFloat(value)
    }
    return result
}()
let gap = config["gap"] ?? 0
let paddingTop = config["padding-top"] ?? 0
let paddingBottom = config["padding-bottom"] ?? 0
let paddingLeft = config["padding-left"] ?? 0
let paddingRight = config["padding-right"] ?? 0
