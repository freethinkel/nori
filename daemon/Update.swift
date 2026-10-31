// Updating Nori.app from its GitHub releases, the way Shepherd does: the latest release's Nori.dmg, mounted and its app
// copied next to the running one, checked to be signed by the running app's team, swapped in, then a relaunch that reloads the
// payload. Checked at launch, every 6 hours and on each open of the menu, and by hand from the menu's "Check for Updates…",
// which turns into "Update to vX" once a release is found. Only a Developer ID build (a CI release) installs one: an ad hoc
// build from make app has no team to check a download against, so it opens the release page. build/nori has no version to
// compare and shows no such item.

import Cocoa

private let latestRelease = URL(string: "https://api.github.com/repos/freethinkel/nori/releases/latest")!
private let releasePage = URL(string: "https://github.com/freethinkel/nori/releases/latest")!
private var offered: (version: String, url: URL)?
private var canInstall = false
private var updating = false
private var checking = false
private var askedByHand = false
private let checkTitle = "Check for Updates…"

let updateItem: NSMenuItem = {
    let item = NSMenuItem(title: checkTitle, action: #selector(MenuActions.update), keyEquivalent: "")
    item.target = menuActions
    item.isHidden = true
    return item
}()

extension MenuActions {
    @objc func update() {
        if offered != nil { installUpdate() } else { checkForUpdate(byHand: true) }
    }
}

func startUpdates() {
    guard Bundle.main.bundleURL.pathExtension == "app" else { return }
    canInstall = team(Bundle.main.bundleURL) != nil
    updateItem.isHidden = false
    checkForUpdate(byHand: false)
    Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in checkForUpdate(byHand: false) }
}

// What the item says when nothing is going on.
private func showOffer() { updateItem.title = offered.map { "Update to v\($0.version)" } ?? checkTitle }

// A release is "v1.2.0" with Nori.dmg among its assets; newer when its version sorts after ours, number by number.
// A check by hand says what it found, also when there is nothing new or GitHub can't be reached, and one made while a
// quiet check runs takes that check's answer. A quiet check that can't reach GitHub keeps a release it found before.
func checkForUpdate(byHand: Bool) {
    guard !updating else { return }
    if byHand {
        askedByHand = true
        updateItem.title = "Checking for Updates…"
    }
    guard !checking else { return }
    checking = true
    var request = URLRequest(url: latestRelease)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: request) { data, _, error in
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        var found: (version: String, url: URL)?
        if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tag = json["tag_name"] as? String, tag.hasPrefix("v"),
           let assets = json["assets"] as? [[String: Any]],
           let dmg = assets.first(where: { $0["name"] as? String == "Nori.dmg" }),
           let url = (dmg["browser_download_url"] as? String).flatMap(URL.init(string:)) {
            found = (String(tag.dropFirst()), url)
        }
        DispatchQueue.main.async {
            let byHand = askedByHand
            checking = false
            askedByHand = false
            guard !updating else { return }  // Update chosen while this ran: the item says Downloading.
            guard let found else {
                showOffer()
                if byHand { alert("Could not check for updates", error?.localizedDescription ?? "GitHub has no nori release with Nori.dmg.", ["OK"]) }
                return
            }
            guard found.version.compare(current, options: .numeric) == .orderedDescending else {
                offered = nil
                showOffer()
                if byHand { alert("nori is up to date", "v\(current) is the latest release.", ["OK"]) }
                return
            }
            offered = found
            showOffer()
            if byHand, alert("nori v\(found.version) is available",
                             "You have v\(current). " + (canInstall ? "nori restarts after the update." : "A local build can't update itself, so this opens the release page."),
                             [canInstall ? "Update" : "Open Release Page", "Later"]) == .alertFirstButtonReturn {
                installUpdate()
            }
        }
    }.resume()
}

func installUpdate() {
    guard let release = offered, !updating else { return }
    guard canInstall else {
        NSWorkspace.shared.open(releasePage)
        return
    }
    updating = true
    updateItem.title = "Downloading v\(release.version)…"
    URLSession.shared.downloadTask(with: release.url) { file, _, error in
        // The downloaded file is gone once this handler returns, so the swap happens here.
        let failure = file.map(replaceApp) ?? (error?.localizedDescription ?? "the download failed")
        DispatchQueue.main.async {
            guard let failure else { return relaunch() }
            updating = false
            showOffer()
            alert("Could not update nori", failure, ["OK"])
        }
    }.resume()
}

// Mounts the dmg, copies its Nori.app beside the running one and puts it in place: the old one is renamed aside first
// and comes back if the new one cannot move in. Dock keeps the old payload mapped, and this process its binary, after
// both are deleted. Returns why it failed, nil once the new app is in place.
func replaceApp(with download: URL) -> String? {
    let fm = FileManager.default
    let app = Bundle.main.bundleURL
    let dir = app.deletingLastPathComponent(), name = app.deletingPathExtension().lastPathComponent
    let stage = dir.appendingPathComponent(name + ".update"), old = dir.appendingPathComponent(name + ".old.app")
    let dmg = fm.temporaryDirectory.appendingPathComponent("Nori-update.dmg")
    let mount = fm.temporaryDirectory.appendingPathComponent("Nori-update")
    try? fm.removeItem(at: stage)
    try? fm.removeItem(at: dmg)
    defer { try? fm.removeItem(at: stage); try? fm.removeItem(at: dmg) }
    guard (try? fm.moveItem(at: download, to: dmg)) != nil else { return "cannot keep the download" }
    if let error = run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path]) {
        return "cannot open the update: \(error)"
    }
    let copied = run("/usr/bin/ditto", [mount.appendingPathComponent("Nori.app").path, stage.appendingPathComponent("Nori.app").path])
    _ = run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
    if let copied { return "cannot copy the new app: \(copied)" }
    let new = stage.appendingPathComponent("Nori.app")
    if let error = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", new.path]) {
        return "the new app's signature is broken: \(error)"
    }
    guard let want = team(app), team(new) == want else { return "the new app is not signed by team \(team(app) ?? "?")" }
    try? fm.removeItem(at: old)
    guard (try? fm.moveItem(at: app, to: old)) != nil else { return "cannot move \(app.path) aside" }
    guard (try? fm.moveItem(at: new, to: app)) != nil else {
        try? fm.moveItem(at: old, to: app)
        return "cannot move the new app to \(app.path)"
    }
    try? fm.removeItem(at: old)
    return nil
}

// The signing team of an app; nil when ad hoc signed.
func team(_ app: URL) -> String? {
    shell("/usr/bin/codesign", ["-dv", app.path]).split(separator: "\n")
        .first { $0.hasPrefix("TeamIdentifier=") }
        .map { String($0.dropFirst("TeamIdentifier=".count)) }
        .flatMap { $0 == "not set" ? nil : $0 }
}

// Opens the app again once this process is gone; --updated makes it load the new payload into Dock.
func relaunch() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec open \"$2\" --args --updated",
                         "_", "\(getpid())", Bundle.main.bundleURL.path]
    try? process.run()
    resetOverview()
    restoreWindows()
    keepSystemGestures = true
    exit(0)
}

// nil when the command succeeds, else its output.
func run(_ path: String, _ args: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return "cannot run \(path)" }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? nil : String(decoding: output, as: UTF8.self)
}
