// Updating Nori.app from its GitHub releases, the way Shepherd does: the latest release's Nori.zip, unpacked next to
// the running app, checked to be signed by the running app's team, swapped in, then a relaunch that reloads the
// payload. Checked at launch and every 6 hours; the menu offers what it finds. Only a Developer ID build (a CI
// release) updates itself: an ad hoc build from make app has no team to check a download against.

import Cocoa

private let latestRelease = URL(string: "https://api.github.com/repos/freethinkel/nori/releases/latest")!
private var offered: (version: String, url: URL)?
private var updating = false

let updateItem: NSMenuItem = {
    let item = NSMenuItem(title: "", action: #selector(MenuActions.update), keyEquivalent: "")
    item.target = menuActions
    item.isHidden = true
    return item
}()

extension MenuActions {
    @objc func update() { installUpdate() }
}

func startUpdates() {
    guard Bundle.main.bundleURL.pathExtension == "app", team(Bundle.main.bundleURL) != nil else { return }
    checkForUpdate()
    Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in checkForUpdate() }
}

// A release is "v1.2.0" with Nori.zip among its assets; newer when its version sorts after ours, number by number.
func checkForUpdate() {
    var request = URLRequest(url: latestRelease)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: request) { data, _, _ in
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, tag.hasPrefix("v"),
              let assets = json["assets"] as? [[String: Any]],
              let zip = assets.first(where: { $0["name"] as? String == "Nori.zip" }),
              let url = (zip["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return }
        let version = String(tag.dropFirst())
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard version.compare(current, options: .numeric) == .orderedDescending else { return }
        DispatchQueue.main.async {
            guard !updating else { return }
            offered = (version, url)
            updateItem.title = "Update to v\(version)"
            updateItem.isHidden = false
        }
    }.resume()
}

func installUpdate() {
    guard let release = offered, !updating else { return }
    updating = true
    updateItem.title = "Downloading v\(release.version)…"
    URLSession.shared.downloadTask(with: release.url) { file, _, error in
        // The downloaded file is gone once this handler returns, so the swap happens here.
        let failure = file.map(replaceApp) ?? (error?.localizedDescription ?? "the download failed")
        DispatchQueue.main.async {
            guard let failure else { return relaunch() }
            updating = false
            updateItem.title = "Update to v\(release.version)"
            alert("Could not update nori", failure, ["OK"])
        }
    }.resume()
}

// Unpacks the zip beside the app and puts its Nori.app in place: the old one is renamed aside first and comes back
// if the new one cannot move in. Dock keeps the old payload mapped, and this process its binary, after both are deleted.
// Returns why it failed, nil once the new app is in place.
func replaceApp(with zip: URL) -> String? {
    let fm = FileManager.default
    let app = Bundle.main.bundleURL
    let dir = app.deletingLastPathComponent(), name = app.deletingPathExtension().lastPathComponent
    let stage = dir.appendingPathComponent(name + ".update"), old = dir.appendingPathComponent(name + ".old.app")
    try? fm.removeItem(at: stage)
    defer { try? fm.removeItem(at: stage) }
    if let error = run("/usr/bin/ditto", ["-x", "-k", zip.path, stage.path]) { return "cannot unpack the update: \(error)" }
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
