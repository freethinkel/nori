// Events instead of waiting for the poll: Accessibility notifications of every app (window created, focus moved,
// window minimized, app hidden) and NSWorkspace ones (app launched, quit, activated; Space changed) run poll() at once.
// WindowServer's own notifications (SLSRegisterConnectionNotifyProc, SLSRegisterNotifyProc) deliver nothing to a plain
// process on macOS 27: none of the types 100…2000 fired while a window opened and closed (docs/WINDOWSERVER.md).
// Each window also reports its own destruction, so a window closing without a focus change is seen at once too.
// ponytail: the poll stays, once a second, for whatever these still miss.

import Cocoa

var axObservers: [pid_t: AXObserver] = [:]
var pollQueued = false

// A burst of notifications runs one poll.
func pollSoon() {
    guard !pollQueued else { return }
    pollQueued = true
    DispatchQueue.main.async {
        pollQueued = false
        poll()
    }
}

let axNotifications = [
    kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
    kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    kAXApplicationHiddenNotification, kAXApplicationShownNotification,
]

// Kept only once the app accepts the notifications; a just-launched app may not yet, so launches retry.
func observe(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    guard app.activationPolicy == .regular, axObservers[pid] == nil else { return }
    var observer: AXObserver?
    let created = AXObserverCreate(pid, { observer, element, notification, _ in
        pollSoon()
        // A new window may reach CGWindowList a little after its notification.
        if notification as String == kAXWindowCreatedNotification {
            AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { pollSoon() }
        }
    }, &observer)
    guard created == .success, let observer else { return }
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 0.25)  // a hung app must not stall the daemon
    guard axNotifications.map({ AXObserverAddNotification(observer, element, $0 as CFString, nil) }).first == .success else { return }
    var windows: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success {
        for window in windows as? [AXUIElement] ?? [] {
            AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, nil)
        }
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    axObservers[pid] = observer
}

func startEvents() {
    NSWorkspace.shared.runningApplications.forEach(observe)
    let center = NSWorkspace.shared.notificationCenter
    func app(_ note: Notification) -> NSRunningApplication? { note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
    center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
        guard let launched = app(note) else { return }
        for delay in [0, 0.5, 2] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { observe(launched) } }
        pollSoon()
    }
    center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
        if let pid = app(note)?.processIdentifier {
            appNamesCache[pid] = nil
            if let observer = axObservers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
        }
        pollSoon()
    }
    for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                 NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
        center.addObserver(forName: name, object: nil, queue: .main) { _ in pollSoon() }
    }
}
