// Nori.app: the menu bar item, and the setup each launch needs before the event tap: SIP and boot-args,
// Accessibility, the payload in Dock. Run as build/nori from a terminal it does the same; loader and
// payload.dylib sit next to the binary in both cases.

import Cocoa
import ServiceManagement

let helpers = Bundle.main.executableURL!.deletingLastPathComponent()
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

func startApp() {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApp.finishLaunching()
    // Two daemons would fight over every window.
    if alive(controlPath) {
        alert("nori is already running", "Quit the other nori first: its menu bar item, or Ctrl+C in its terminal.", ["Quit"])
        exit(1)
    }
    statusItem.button?.image = statusIcon()
    statusItem.button?.imagePosition = .imageLeading  // the "!" of Problems.swift beside it
    statusItem.menu = menu()
    showConfigProblems()
    guard bootSetupDone() else { exit(1) }
    waitForAccessibility()
    let gesturesChanged = leaveSystemGestures ? putBackSystemGestures() : disableSystemGestures()
    // After an update Dock still runs the old payload.
    if gesturesChanged || !payloadAlive() || CommandLine.arguments.contains("--updated") { loadPayload() }
    quitIfLoadFails = false
    applyLaunchAtLogin()
    startUpdates()
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        watchPayload()
        checkShortcuts()
    }
    RunLoop.main.perform(offerShortcuts)  // not the main queue: nori's own work there would wait for the alert
}

// The two nori sheets of the app icon as a silhouette: status.png (36px, 18pt @2x) in the bundle's
// Resources, or next to build/nori. Not in Contents/MacOS: codesign takes anything there for unsigned code.
// A template image, so it follows the menu bar's color.
func statusIcon() -> NSImage? {
    let image = NSImage(contentsOf: Bundle.main.url(forResource: "status", withExtension: "png") ?? helpers.appendingPathComponent("status.png"))
    image?.size = NSSize(width: 18, height: 18)
    image?.isTemplate = true
    return image
}

// `nori reload`, and "Reload Config" and every change in the Settings window.
func reloadSettings() {
    configFile = readConfig()
    settingsModel.refresh()
    showConfigProblems()
    applyLaunchAtLogin()
    layout(immediate: false)
}

final class MenuActions: NSObject, NSMenuDelegate {
    @objc func openSettings() { showSettings() }

    func openConfig() {
        writeDefaultConfig()
        _ = shell("/usr/bin/open", ["-t", configPath])
    }

    @objc func reloadPayload() { reloadDockPayload() }

    // Whether the payload answers in Dock, under the item that reloads it; a socket connect, so read on each open.
    // A new release shows up the same way: the check runs behind the open menu and renames its item.
    func menuWillOpen(_ menu: NSMenu) {
        if !updateItem.isHidden { checkForUpdate(byHand: false) }
        let loaded = payloadAlive()
        if #available(macOS 14.4, *) {
            payloadItem.subtitle = loaded ? "Payload is running in Dock" : "Payload is not running in Dock"
        } else {
            payloadItem.state = loaded ? .on : .off
        }
    }

    @objc func quit() {
        resetOverview()
        restoreWindows()
        restoreSystemGestures()
        exit(0)
    }
}
let menuActions = MenuActions()
let payloadItem = NSMenuItem(title: "Restart Dock and Reload Payload", action: #selector(MenuActions.reloadPayload), keyEquivalent: "")

func menu() -> NSMenu {
    let menu = NSMenu()
    menu.delegate = menuActions
    menu.addItem(withTitle: "nori", action: nil, keyEquivalent: "")
    menu.addItem(updateItem)
    menu.addItem(.separator())
    menu.addItem(withTitle: "Settings…", action: #selector(MenuActions.openSettings), keyEquivalent: ",").target = menuActions
    payloadItem.target = menuActions
    menu.addItem(payloadItem)
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit nori", action: #selector(MenuActions.quit), keyEquivalent: "q").target = menuActions
    return menu
}

// The loader needs task_for_pid on Dock (Debugging Restrictions off), and Dock loads a third-party arm64e dylib
// only with -arm64e_preview_abi in boot-args. SIP can only change from Recovery; the boot-arg is set here when it can be.
func bootSetupDone() -> Bool {
    let sip = shell("/usr/bin/csrutil", ["status"])
    let debugOff = sip.contains("status: disabled") || sip.contains("Debugging Restrictions: disabled")
    let nvramOff = sip.contains("status: disabled") || sip.contains("NVRAM Protections: disabled")
    let bootArgs = shell("/usr/sbin/nvram", ["boot-args"])  // "boot-args\t<value>", or an error when unset
    if debugOff && bootArgs.contains("-arm64e_preview_abi") { return true }

    if debugOff && nvramOff {
        let current = bootArgs.hasPrefix("boot-args\t") ? bootArgs.dropFirst(10).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let value = (current + " -arm64e_preview_abi").trimmingCharacters(in: .whitespaces)
        guard alert("nori needs a boot argument",
                    "Dock loads nori's code only with -arm64e_preview_abi in boot-args. nori will add it (asks for your password); then restart the Mac and open nori again.",
                    ["Add and Quit", "Quit"]) == .alertFirstButtonReturn else { return false }
        switch runAsAdmin("/usr/sbin/nvram " + shellQuoted("boot-args=" + value), prompt: "nori is adding a boot argument.") {
        case .done: alert("Restart your Mac", "boot-args now has -arm64e_preview_abi. It takes effect after a restart.", ["Quit"])
        case .failed(let error): alert("Could not set boot-args", error, ["Quit"])
        case .canceled: break
        }
        return false
    }

    let command = "csrutil enable --without fs --without debug --without nvram"
    if alert("nori needs part of SIP off",
             """
             nori loads its code into Dock, which macOS allows only with some protections off. Once, from Recovery:

             1. Shut down, hold the power button until "Loading startup options", then Options → Continue.
             2. Utilities → Terminal, run:
             \(command)
             3. Restart and open nori again.

             See "Setup" in nori's README for what this changes and how to undo it.
             """,
             ["Copy Command and Quit", "Quit"]) == .alertFirstButtonReturn {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
    return false
}

// The event tap needs it. If nori can't grant it itself, macOS shows its own prompt; keep the menu working until the
// permission is granted.
func waitForAccessibility() {
    guard !AXIsProcessTrusted() else { return }
    grantAccessibility()
    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    guard !AXIsProcessTrustedWithOptions(prompt) else { return }
    statusItem.button?.appearsDisabled = true
    while !AXIsProcessTrusted() {
        if let event = NSApp.nextEvent(matching: .any, until: Date() + 1, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
    }
    statusItem.button?.appearsDisabled = false
}

// With Filesystem Protections off root can write the row the switch in System Settings writes, and replace the old row of
// an earlier signature. build/nori has no bundle id: from a terminal the permission is the terminal's.
// AXIsProcessTrusted keeps its answer until the notification below. See "Granting Accessibility" in docs/WINDOWSERVER.md.
func grantAccessibility() {
    let sip = shell("/usr/bin/csrutil", ["status"])
    guard sip.contains("status: disabled") || sip.contains("Filesystem Protections: disabled"),
          let client = Bundle.main.bundleIdentifier, let requirement = designatedRequirement() else { return }
    let hex = requirement.map { String(format: "%02x", $0) }.joined()
    let sql = """
        INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags) \
        VALUES ('kTCCServiceAccessibility', '\(client)', 0, 2, 4, 1, X'\(hex)', 0)
        """
    let database = "/Library/Application Support/com.apple.TCC/TCC.db"
    guard runAsAdmin("/usr/bin/sqlite3 -cmd '.timeout 2000' \(shellQuoted(database)) \(shellQuoted(sql))",
                     prompt: "nori is adding itself to Accessibility.") == .done else { return }
    DistributedNotificationCenter.default().postNotificationName(.init("com.apple.accessibility.api"), object: nil, userInfo: nil, deliverImmediately: true)
    for _ in 0..<50 where !AXIsProcessTrusted() { RunLoop.current.run(until: Date() + 0.02) }
}

// What this build's signature must satisfy to hold the permission: the team for a Developer ID build, so updates keep it,
// and the exact code for an ad hoc one.
func designatedRequirement() -> Data? {
    var code: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?, data: CFData?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
          SecRequirementCopyData(requirement, [], &data) == errSecSuccess else { return nil }
    return data as Data?
}

// launch-at-login in the config: a Login Item for this bundle, so it stays in System Settings → General → Login Items
// under the user's control too. Nothing to do for build/nori run from a terminal.
func applyLaunchAtLogin() {
    guard Bundle.main.bundleURL.pathExtension == "app" else { return }
    clearProblem("launch-at-login")
    let service = SMAppService.mainApp
    let registered = service.status == .enabled || service.status == .requiresApproval
    guard launchAtLogin != registered else { return }
    do {
        if launchAtLogin { try service.register() } else { try service.unregister() }
    } catch {
        report(Problem(key: "launch-at-login", title: "launch-at-login did not apply", help: error.localizedDescription))
    }
}

func payloadAlive() -> Bool { alive(socketPath) }

func alive(_ path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    return withAddress(path) { connect(fd, $0, $1) } == 0
}

// Restarts Dock first: a payload from an older build may still be inside, and its hooks would block the new one's.
// task_for_pid on Dock needs root, hence the password. The loader retries until the new Dock has finished launching.
func loadPayload() {
    let loader = shellQuoted(helpers.appendingPathComponent("loader").path)
    let payload = shellQuoted(helpers.appendingPathComponent("payload.dylib").path)
    let script = "killall Dock; for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.5; \(loader) \(payload) && exit 0; done; exit 1"
    switch runAsAdmin(script, prompt: "nori is loading its helper into Dock.") {
    case .done: break
    case .canceled: return loadFailed(nil)
    case .failed(let error): return loadFailed(error)
    }
    for _ in 0..<30 where !payloadAlive() { usleep(100_000) }
    if !payloadAlive() {
        return loadFailed("The loader finished, but Dock does not answer. Its log:\n/usr/bin/log show --last 5m --predicate 'process == \"Dock\" AND eventMessage CONTAINS \"nori\"'")
    }
    layout(immediate: false)
}

// At launch nori is no use without the payload, so it quits. Once running it stays, and the problem stays listed.
var quitIfLoadFails = true

func loadFailed(_ error: String?) {
    if let error { alert("Could not load nori into Dock", error, [quitIfLoadFails ? "Quit" : "OK"]) }
    guard quitIfLoadFails else { return }
    restoreSystemGestures()
    exit(error == nil ? 0 : 1)
}

// Output and errors of a command, for checks like csrutil and nvram.
func shell(_ path: String, _ args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return "" }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: output, as: UTF8.self)
}

func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func appleScriptString(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

enum AdminResult: Equatable { case done, canceled, failed(String) }

// Runs a shell command as root behind the system password dialog.
func runAsAdmin(_ command: String, prompt: String) -> AdminResult {
    var error: NSDictionary?
    NSApp.activate()
    NSAppleScript(source: "do shell script \(appleScriptString(command)) with prompt \(appleScriptString(prompt)) with administrator privileges")?
        .executeAndReturnError(&error)
    guard let error else { return .done }
    if error[NSAppleScript.errorNumber] as? Int == -128 { return .canceled }  // the Cancel button
    return .failed(error[NSAppleScript.errorMessage] as? String ?? "\(error)")
}

@discardableResult
func alert(_ title: String, _ text: String, _ buttons: [String]) -> NSApplication.ModalResponse {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    buttons.forEach { alert.addButton(withTitle: $0) }
    NSApp.activate()
    return alert.runModal()
}
