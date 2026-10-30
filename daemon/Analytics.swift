// Aptabase (self-hosted, aptabase.freethinkel.dev): how many people use nori each day, on which macOS. Anonymous: an
// `active` event a day, at launch and then on each new UTC day, the way Shepherd does it. Nothing else leaves the
// machine. `analytics = false` turns it off, on the next hourly look too, and so does DO_NOT_TRACK=1. A build without a
// Developer ID (make app, build/nori) reports as debug.

import Foundation

private let appKey = "A-SH-5385447007"
private let eventsURL = URL(string: "https://aptabase.freethinkel.dev/api/v0/events")!
private var sentDay: Int?

func startAnalytics() {
    guard ["", "0"].contains(ProcessInfo.processInfo.environment["DO_NOT_TRACK"] ?? "") else { return }
    DispatchQueue.global().async {
        let isDebug = team(Bundle.main.bundleURL) == nil  // codesign is a process: off the main thread
        DispatchQueue.main.async {
            sendActive(isDebug: isDebug)
            Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in sendActive(isDebug: isDebug) }
        }
    }
}

// ponytail: an event that fails to send is dropped, no queue or retry; the next day's goes out anyway
private func sendActive(isDebug: Bool) {
    let now = Date()
    let secs = Int(now.timeIntervalSince1970)
    guard analyticsOn, sentDay != secs / 86_400 else { return }
    sentDay = secs / 86_400
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    let event: [String: Any] = [
        "timestamp": ISO8601DateFormatter().string(from: now),
        "sessionId": String(secs * 100_000_000 + Int.random(in: 0..<100_000_000)),  // a session a day, like Aptabase's SDKs
        "eventName": "active",
        "systemProps": ["isDebug": isDebug, "osName": "macOS", "osVersion": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                        "locale": "", "appVersion": version, "sdkVersion": "nori@\(version)"],
    ]
    var request = URLRequest(url: eventsURL)
    request.httpMethod = "POST"
    request.setValue(appKey, forHTTPHeaderField: "App-Key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [event])
    URLSession.shared.dataTask(with: request).resume()
}
