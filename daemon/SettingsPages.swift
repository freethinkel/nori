import Cocoa
import SwiftUI

// The cards of one page; with a search, only the rows that match, or all when the page's name does.
struct SettingsPage: View {
    let page: Page
    let query: String

    var body: some View {
        let query = page.rawValue.localizedCaseInsensitiveContains(query) ? "" : query
        Cards {
            if page == .general && query.isEmpty && !settingsModel.problems.isEmpty { ConfigProblemsCard() }
            if page == .about && query.isEmpty { AboutCard() }
            ForEach(cards(page), id: \.title) { card in
                let keys = card.keys.filter { matches($0, query) }
                if !keys.isEmpty {
                    Card(title: card.title) {
                        ForEach(keys, id: \.self) { SettingRow(key: $0) }
                    }
                }
            }
            if page == .general && query.isEmpty { ConfigFileCard() }
        }
    }
}

// What runs, the way Rex shows its server. build/nori has no version to compare: Update.swift hides the item there.
struct AboutCard: View {
    var body: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        Card {
            HStack(spacing: 10) {
                // build/nori has no bundle, and AppKit would give it a folder.
                Image(nsImage: Bundle.main.image(forResource: "AppIcon") ?? statusIcon() ?? NSImage()).resizable().frame(width: 36, height: 36)
                Labels(title: "nori", help: version.map { "Version \($0)" } ?? "Development build")
                Spacer(minLength: 0)
                if !updateItem.isHidden {
                    // Not menuActions.update(): with a release found it installs, and this button doesn't say so.
                    Button("Check for Updates…") { checkForUpdate(byHand: true) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                }
            }
            .cardRow()
        }
    }
}

struct ConfigProblemsCard: View {
    var body: some View {
        Card(title: "Problems in config.toml", footer: "nori skipped these and applied the rest.") {
            ForEach(settingsModel.problems, id: \.self) { Text($0).textSelection(.enabled).cardRow() }
        }
    }
}

struct ConfigFileCard: View {
    var body: some View {
        Card(title: "Config file", footer: "Every change here goes into this file. Comments, rules and keys you wrote stay as they are.") {
            Row(title: "config.toml", help: (configPath as NSString).abbreviatingWithTildeInPath) {
                Button("Open in Editor") { menuActions.openConfig() }
                    .fixedSize()  // a long path gives way, not the button
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: configPath)]) } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
    }
}

struct RulesPage: View {
    let query: String
    @State private var expanded: Set<Int> = []  // rules by index, open like an accordion

    var body: some View {
        let rules = settingsModel.rules
        ScrollViewReader { proxy in
            Cards {
                Card(footer: "Each rule is for an app, by name or bundle id, and can be narrowed to windows whose title matches a regular expression, any case. The first rule that matches a window wins. \(builtinNames()) are ignored without a rule; a rule of your own for one of them comes first.") {
                    ForEach(rules.indices.filter { ruleWords(query) || ruleMatches($0, query) }, id: \.self) { index in
                        RuleSection(index: index, table: rules[index], expanded: Binding(
                            get: { expanded.contains(index) }, set: { if $0 { expanded.insert(index) } else { expanded.remove(index) } }
                        ))
                        .id(index)
                    }
                    if rules.isEmpty {
                        ContentUnavailableView("No App Rules", systemImage: "macwindow.on.rectangle", description: Text("Add one with + in the toolbar."))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .onChange(of: rules.count) { old, new in
                // A new rule opens for editing; after a delete the indices shift, so all close.
                expanded = new > old ? [new - 1] : []
                if new > old { withAnimation { proxy.scrollTo(new - 1, anchor: .bottom) } }
            }
        }
    }

    private func builtinNames() -> String {
        let names = builtinRules.map { rule in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.app).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                ?? String(rule.app.split(separator: ".").last!)  // not installed: "com.runningwithcrayons.Alfred" → "Alfred"
        }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
