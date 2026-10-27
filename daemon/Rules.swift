// Per-app rules from the config, one [[rule]] table each:
//   [[rule]]                [[rule]]                   [[rule]]           [[rule]]          [[rule]]
//   app = "Telegram"        app = "com.apple.finder"   app = "Raycast"    app = "Ghostty"   app = "Safari"
//   space = 3               floating = true            ignore = true      width = 50        title = "Picture in Picture"
//                                                                                           floating = true
// space: a new window of the app goes to Desktop N. floating: its windows stay out of the strip, where you put them.
// ignore: nori neither moves nor lists its windows. width: a new window takes N % of the usable width (Strip.swift).
// app is the app's name or bundle id, any case; title a case-insensitive regular expression the window title must
// contain. The first rule that matches a window wins; one rule can have several actions.
// Foundation only, so `make test` compiles it: the lookups that need Cocoa are in Windows.swift.

import Foundation

struct Rule {
    var app: String
    var title: String?
    var space: Int?
    var floating = false
    var ignore = false
    var width: CGFloat?  // percent of the usable width
}

// nil for a table without app or without any action, or with a key or value that doesn't fit.
func makeRule(_ table: [String: TOMLValue]) -> Rule? {
    guard case .string(let app)? = table["app"], !app.isEmpty else { return nil }
    var rule = Rule(app: app)
    for (key, value) in table where key != "app" {
        switch (key, value) {
        case ("title", .string(let pattern)) where !pattern.isEmpty && (try? NSRegularExpression(pattern: pattern)) != nil: rule.title = pattern
        case ("space", .number(let n)) where n >= 1 && n == n.rounded(): rule.space = Int(n)
        case ("floating", .bool(let on)): rule.floating = on
        case ("ignore", .bool(let on)): rule.ignore = on
        case ("width", .number(let n)) where n > 0 && n <= 100: rule.width = CGFloat(n)
        default: return nil
        }
    }
    return rule.space == nil && !rule.floating && !rule.ignore && rule.width == nil ? nil : rule
}

// The first rule for a window of an app with these names (name and bundle id). The title is asked for only when a
// rule that matches the app has one, and once: it may cost an Accessibility call. No title means no match.
func ruleMatching(_ names: [String], title: () -> String?, in rules: [Rule]) -> Rule? {
    var known: String??
    return rules.first { rule in
        guard names.contains(where: { $0.caseInsensitiveCompare(rule.app) == .orderedSame }) else { return false }
        guard let pattern = rule.title else { return true }
        if known == nil { known = .some(title()) }
        return (known ?? nil)?.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

// Launchers and overlays nori leaves alone without a rule: they come after the config's rules, so a [[rule]] for
// one of them in the config wins (a `floating = true` rule puts it back under nori's eye).
let builtinRules = ["com.raycast.macos", "com.runningwithcrayons.Alfred", "com.apple.Spotlight", "at.obdev.LaunchBar"]
    .map { Rule(app: $0, ignore: true) }
