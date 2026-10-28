import Cocoa
import SwiftUI

// The cards of one page; with a search, only the rows that match, or all when the page's name does.
struct SettingsPage: View {
    let page: Page
    let query: String

    var body: some View {
        let query = page.rawValue.localizedCaseInsensitiveContains(query) ? "" : query
        Form {
            ForEach(cards(page), id: \.title) { card in
                let keys = card.keys.filter { matches($0, query) }
                if !keys.isEmpty {
                    Section(card.title) {
                        ForEach(keys, id: \.self) { SettingRow(key: $0) }
                    }
                }
            }
            if page == .general && query.isEmpty { ConfigFileSection() }
        }
        .formStyle(.grouped)
    }
}

struct ConfigFileSection: View {
    var body: some View {
        Section("Config file") {
            LabeledContent {
                HStack {
                    Button("Open in Editor") { menuActions.openConfig() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: configPath)]) }
                }
            } label: {
                Text((configPath as NSString).abbreviatingWithTildeInPath).monospaced()
                Text("Every change here goes into this file. Comments, rules and keys you wrote stay as they are")
            }
        }
    }
}

struct RulesPage: View {
    let query: String
    @State private var expanded: Set<Int> = []  // rules by index, open like an accordion

    var body: some View {
        let rules = settingsModel.rules
        ScrollViewReader { proxy in
            Form {
                Section {
                    Text("Each rule is for an app, by name or bundle id, and can be narrowed to windows whose title matches a regular expression. The first rule that matches a window wins.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rules.indices.filter { ruleWords(query) || ruleMatches($0, query) }, id: \.self) { index in
                    RuleSection(index: index, table: rules[index], expanded: Binding(
                        get: { expanded.contains(index) }, set: { if $0 { expanded.insert(index) } else { expanded.remove(index) } }
                    ))
                    .id(index)
                }
                if rules.isEmpty {
                    Section { Text("No rules yet. Add one with + in the toolbar.").foregroundStyle(.secondary) }
                }
                Section {
                    Text("\(builtinNames()) are ignored without a rule. A rule of your own for one of them comes first.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
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
