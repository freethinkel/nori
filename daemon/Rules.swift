// Per-app rules from the config, one [[rule]] table each:
//   [[rule]]                          [[rule]]                            [[rule]]
//   app = "Telegram"                  app = "com.apple.finder"            app = "Raycast"
//   space = 3                         floating = true                     ignore = true
// space: a new window of the app goes to Desktop N. floating: its windows stay out of the strip, where you put them.
// ignore: nori neither moves nor lists its windows. app is the app's name or bundle id, any case.
// The first rule that matches an app wins; one rule can have several actions.

import Cocoa

struct Rule {
    var app: String
    var space: Int?
    var floating = false
    var ignore = false
}

// nil for a table without app or without any action, or with a key or value that doesn't fit.
func makeRule(_ table: [String: TOMLValue]) -> Rule? {
    guard case .string(let app)? = table["app"], !app.isEmpty else { return nil }
    var rule = Rule(app: app)
    for (key, value) in table where key != "app" {
        switch (key, value) {
        case ("space", .number(let n)) where n >= 1 && n == n.rounded(): rule.space = Int(n)
        case ("floating", .bool(let on)): rule.floating = on
        case ("ignore", .bool(let on)): rule.ignore = on
        default: return nil
        }
    }
    return rule.space == nil && !rule.floating && !rule.ignore ? nil : rule
}

func rule(for pid: pid_t, in rules: [Rule]) -> Rule? {
    guard !rules.isEmpty, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
    let names = [app.localizedName, app.bundleIdentifier].compactMap { $0 }
    return rules.first { rule in names.contains { $0.caseInsensitiveCompare(rule.app) == .orderedSame } }
}

// Windows the space rules have looked at. A rule places a window once, when nori first sees it,
// so it can still be moved elsewhere by hand. That includes the windows already open when nori starts.
// ponytail: ids of closed windows stay; window ids are not reused within a session.
var placed: Set<UInt32> = []

// New windows of the current Space whose app has a space rule go to that Desktop, like moveFocused does;
// returns the windows that stay. The strip's focused window takes focus back first, or macOS would
// follow the moved window to its Space (it still does when the strip is empty).
func placeByRules(_ wins: [Win], on space: UInt64) -> [Win] {
    let fresh = wins.filter { !placed.contains($0.id) }
    guard !fresh.isEmpty else { return wins }
    placed.formUnion(fresh.map(\.id))
    let current = rules
    guard current.contains(where: { $0.space != nil }) else { return wins }
    let desktops = spaces()
    let leaving: [(id: UInt32, sid: UInt64)] = fresh.compactMap { win in
        guard let number = rule(for: win.pid, in: current)?.space,
              let sid = desktops.first(where: { $0.number == number })?.id, sid != space else { return nil }
        return (win.id, sid)
    }
    guard !leaving.isEmpty else { return wins }
    movedAway.formUnion(leaving.map(\.id))
    DispatchQueue.main.async {
        focusColumn(at: focusedIndex())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { send(leaving.map { "X \($0.id) \($0.sid)" }) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { movedAway.subtract(leaving.map(\.id)) }
    }
    return wins.filter { win in !leaving.contains { $0.id == win.id } }
}
