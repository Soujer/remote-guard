import Foundation

struct SocketRecord { let pid: String; let command: String; let endpoint: String }
enum Detection {
    static func parse(_ text: String) -> [SocketRecord] {
        var pid = "", command = "", records = [SocketRecord]()
        for line in text.split(separator: "\n") {
            switch line.first {
            case "p": pid = String(line.dropFirst()); command = ""
            case "c": command = String(line.dropFirst())
            case "n": if !pid.isEmpty { records.append(SocketRecord(pid: pid, command: command, endpoint: String(line.dropFirst()))) }
            default: break
            }
        }
        return records
    }
    static func tool(_ command: String) -> String? {
        let value = command.lowercased()
        let tools: [(String, [String])] = [("屏幕共享", ["screensharingd", "applevncserver"]), ("UU远程", ["gameviewer", "gameviewer_service", "uuremote", "uu远程"]), ("ToDesk", ["todesk", "todesk_service"]), ("向日葵", ["sunloginclient", "sunloginremote", "awesun", "awesun_guard"]), ("RustDesk", ["rustdesk", "rustdesk_desktop"]), ("AnyDesk", ["anydesk"]), ("TeamViewer", ["teamviewer", "teamviewer_service"]), ("Chrome远程桌面", ["remoting_me2me_host"]), ("Parsec", ["parsecd"])]
        return tools.first(where: { $0.1.contains(value) })?.0
    }
    static func port(_ endpoint: String) -> String? {
        guard let range = endpoint.range(of: ":[0-9]+$", options: .regularExpression) else { return nil }; return String(endpoint[range].dropFirst())
    }
    static func candidates(listeners: [SocketRecord], established: [SocketRecord]) -> Set<String> {
        let ports = Set(listeners.compactMap { record -> String? in guard tool(record.command) != nil, let port = port(record.endpoint) else { return nil }; return record.pid + ":" + port })
        var result = Set<String>()
        for connection in established {
            guard let name = tool(connection.command) else { continue }
            let endpoints = connection.endpoint.components(separatedBy: "->")
            guard endpoints.count == 2, let localPort = port(endpoints[0]), let peerPort = port(endpoints[1]), !["80", "443"].contains(peerPort), !endpoints[1].hasPrefix("127."), !endpoints[1].hasPrefix("[::1]:"), !endpoints[1].hasPrefix("localhost:") else { continue }
            // Require an established inbound channel to this same process's listening port.
            if ports.contains(connection.pid + ":" + localPort) { result.insert(name) }
        }
        return result
    }
    static func sample() throws -> Set<String> {
        let listeners = try runTool("/usr/sbin/lsof", ["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"])
        let connections = try runTool("/usr/sbin/lsof", ["+c", "0", "-nP", "-iTCP", "-sTCP:ESTABLISHED", "-Fpcn"])
        for result in [listeners, connections] { try require((result.code == 0 || result.code == 1) && result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "网络采样失败，保留上次状态") }
        return candidates(listeners: parse(listeners.output), established: parse(connections.output))
    }
}
struct SessionTracker: Codable {
    var confirmed = [String: Double]()
    var streaks = [String: Int]()
    mutating func update(_ candidates: Set<String>?, now: Double) -> Set<String> {
        guard let candidates else { for name in confirmed.keys { confirmed[name] = now }; streaks.removeAll(); return Set(confirmed.keys) }
        for name in Set(streaks.keys).subtracting(candidates) { streaks.removeValue(forKey: name) }
        for name in candidates {
            streaks[name, default: 0] += 1
            if confirmed[name] != nil || streaks[name, default: 0] >= 2 { confirmed[name] = now }
        }
        for (name, seen) in confirmed where !candidates.contains(name) && now - seen >= 180 { confirmed.removeValue(forKey: name) }
        return Set(confirmed.keys)
    }
}
enum Notifications {
    static func send(_ title: String, body: String, settings: Settings, completion: @escaping (Bool) -> Void) {
        var urls = [URL]()
        if !settings.barkKey.isEmpty {
            var parts = URLComponents(string: "https://api.day.app")!
            let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            parts.percentEncodedPath = "/" + [settings.barkKey, title, body].map { $0.addingPercentEncoding(withAllowedCharacters: safe)! }.joined(separator: "/")
            parts.queryItems = [URLQueryItem(name: "group", value: "remote-guard")]; if let url = parts.url { urls.append(url) }
        }
        if !settings.hayoToken.isEmpty {
            var parts = URLComponents(string: "https://hayo.svip8.vip/send")!
            parts.queryItems = [URLQueryItem(name: "token", value: settings.hayoToken), URLQueryItem(name: "title", value: title), URLQueryItem(name: "content", value: body)]
            if let url = parts.url { urls.append(url) }
        }
        guard !urls.isEmpty else { completion(false); return }
        let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration), group = DispatchGroup(), lock = NSLock(); var success = false
        for url in urls {
            group.enter(); session.dataTask(with: url) { _, response, _ in
                if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) { lock.lock(); success = true; lock.unlock() }; group.leave()
            }.resume()
        }
        group.notify(queue: .main) { session.finishTasksAndInvalidate(); completion(success) }
    }
}
enum LaunchAgent {
    static let label = "com.soujer.remote-guard.desktop"
    static var url: URL { fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/" + label + ".plist") }
    static func register(_ app: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let value: [String: Any] = ["Label": label, "ProgramArguments": [app.appendingPathComponent("Contents/MacOS/RemoteGuard").path, "--background"], "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ProcessType": "Interactive", "LimitLoadToSessionType": "Aqua"]
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
        _ = try? runTool("/bin/launchctl", ["bootout", "gui/\(getuid())/" + label])
        let result = try runTool("/bin/launchctl", ["bootstrap", "gui/\(getuid())", url.path]); try require(result.code == 0, "登录启动注册失败")
    }
    static func remove() throws { try? fm.removeItem(at: url); _ = try? runTool("/bin/launchctl", ["bootout", "gui/\(getuid())/" + label]) }
}
