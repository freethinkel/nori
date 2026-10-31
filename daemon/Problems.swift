// What is wrong right now, in one list: the status item marks it, the menu shows it, `nori problems` prints it.
// Whoever finds a problem reports it under a key, and clears it once it is fixed. Main thread.

import Cocoa

struct Problem {
    let key: String
    let title: String         // what is wrong
    let help: String          // what the user loses, and what to do
    var fix: Selector? = nil  // a MenuActions method, run when its menu item is chosen
}

var problems: [Problem] = []
private let problemItemTag = 1

// stderr too, for terminal runs, once per change.
func report(_ problem: Problem) {
    if let known = problems.first(where: { $0.key == problem.key }), known.title == problem.title, known.help == problem.help { return }
    fputs("\(problem.title): \(problem.help)\n", stderr)
    problems.removeAll { $0.key == problem.key }
    problems.append(problem)
    showProblems()
}

func clearProblem(_ key: String) {
    guard problems.contains(where: { $0.key == key }) else { return }
    problems.removeAll { $0.key == key }
    showProblems()
}

func showProblems() {
    statusItem.button?.title = problems.isEmpty ? "" : "!"
    statusItem.button?.toolTip = problems.first?.title
    guard let menu = statusItem.menu else { return }
    menu.items.filter { $0.tag == problemItemTag }.forEach(menu.removeItem)
    guard !problems.isEmpty else { return }
    let items = problems.map { problem in
        let item = NSMenuItem(title: problem.title, action: problem.fix, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Problem")
        if #available(macOS 14.4, *) { item.subtitle = problem.help } else { item.toolTip = problem.help }
        return item
    }
    let copy = NSMenuItem(title: "Copy Problem Report", action: #selector(MenuActions.copyReport), keyEquivalent: "")
    let at = menu.index(of: updateItem) + 1
    for (offset, item) in ([.separator()] + items + [copy]).enumerated() {
        item.tag = problemItemTag
        item.target = menuActions
        menu.insertItem(item, at: at + offset)
    }
}

// `nori problems` and "Copy Problem Report": what a bug report needs.
func problemReport() -> String {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
    let lines = problems.isEmpty ? ["No problems"] : problems.map { "\($0.title): \($0.help)" }
    return (["nori \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"] + lines).joined(separator: "\n") + "\n"
}

extension MenuActions {
    @objc func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(problemReport(), forType: .string)
    }
}
