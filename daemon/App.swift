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
    statusItem.menu = menu()
    guard bootSetupDone() else { exit(1) }
    waitForAccessibility()
    if !payloadAlive() { loadPayload() }
    applyLaunchAtLogin()
}

// Three columns, the middle one in focus, like the app icon. A template image, so it follows the menu bar's color.
func statusIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { _ in
        NSBezierPath(roundedRect: NSRect(x: 5, y: 0, width: 8, height: 14), xRadius: 1.5, yRadius: 1.5).fill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 2.5, width: 3.5, height: 9), xRadius: 1, yRadius: 1).fill()
        NSBezierPath(roundedRect: NSRect(x: 14.5, y: 2.5, width: 3.5, height: 9), xRadius: 1, yRadius: 1).fill()
        return true
    }
    image.isTemplate = true
    return image
}

final class MenuActions: NSObject {
    @objc func openConfig() {
        let path = configPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        _ = shell("/usr/bin/open", ["-t", path])
    }

    @objc func reloadConfig() {
        configFile = readConfig()
        applyLaunchAtLogin()
        layout(immediate: false)
    }

    @objc func reloadPayload() { loadPayload() }

    @objc func quit() {
        resetOverview()
        exit(0)
    }
}
let menuActions = MenuActions()

func menu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(withTitle: "nori", action: nil, keyEquivalent: "")
    menu.addItem(.separator())
    for (title, action, key) in [
        ("Open Config", #selector(MenuActions.openConfig), ","),
        ("Reload Config", #selector(MenuActions.reloadConfig), "r"),
        ("Restart Dock and Reload Payload", #selector(MenuActions.reloadPayload), ""),
    ] {
        menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = menuActions
    }
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

// The event tap needs it. macOS shows its own prompt; keep the menu working until the permission is granted.
func waitForAccessibility() {
    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    guard !AXIsProcessTrustedWithOptions(prompt) else { return }
    statusItem.button?.appearsDisabled = true
    while !AXIsProcessTrusted() {
        if let event = NSApp.nextEvent(matching: .any, until: Date() + 1, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
    }
    statusItem.button?.appearsDisabled = false
}

// launch-at-login in the config: a Login Item for this bundle, so it stays in System Settings → General → Login Items
// under the user's control too. Nothing to do for build/nori run from a terminal.
func applyLaunchAtLogin() {
    guard Bundle.main.bundleURL.pathExtension == "app" else { return }
    let service = SMAppService.mainApp
    let registered = service.status == .enabled || service.status == .requiresApproval
    guard launchAtLogin != registered else { return }
    do {
        if launchAtLogin { try service.register() } else { try service.unregister() }
    } catch {
        fputs("launch-at-login: \(error.localizedDescription)\n", stderr)
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
    case .canceled: exit(0)
    case .failed(let error):
        alert("Could not load nori into Dock", error, ["Quit"])
        exit(1)
    }
    for _ in 0..<30 where !payloadAlive() { usleep(100_000) }
    if !payloadAlive() {
        alert("nori is not running in Dock",
              "The loader finished, but Dock does not answer. Its log:\n/usr/bin/log show --last 5m --predicate 'process == \"Dock\" AND eventMessage CONTAINS \"nori\"'",
              ["Quit"])
        exit(1)
    }
    layout(immediate: false)
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
