import Foundation
import AppKit

final class BoundedFetch: NSObject, URLSessionDataDelegate {
    private var bytes = Data(); private var failure: Error?; private let limit: Int; private let done = DispatchSemaphore(value: 0)
    init(limit: Int) { self.limit = limit }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.expectedContentLength <= Int64(limit) else { failure = GuardError.message("更新服务器响应异常或文件过大"); completionHandler(.cancel); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if bytes.count + data.count > limit { failure = GuardError.message("更新下载超过大小限制"); dataTask.cancel() } else { bytes.append(data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if failure == nil { failure = error }; done.signal() }
    static func get(_ url: URL, limit: Int) throws -> Data {
        let receiver = BoundedFetch(limit: limit), configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: url).resume()
        try require(receiver.done.wait(timeout: .now() + 190) == .success, "更新下载超时")
        if let error = receiver.failure { throw error }; return receiver.bytes
    }
}
struct MacUpdate { let version: String; let zip: URL; let hashes: URL }
enum MacUpdates {
    static let bundleID = "com.soujer.remote-guard"
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    static func version(_ text: String) -> [Int]? {
        guard text.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else { return nil }
        let values = text.split(separator: ".").compactMap { Int($0) }; return values.count == 3 ? values : nil
    }
    static func select(_ releases: [[String: Any]], current: String) -> MacUpdate? {
        guard let installed = version(current) else { return nil }
        var candidates = [MacUpdate]()
        for release in releases {
            guard release["prerelease"] as? Bool != true, release["draft"] as? Bool != true, let tag = release["tag_name"] as? String, tag.hasPrefix("v"), let number = version(String(tag.dropFirst())), installed.lexicographicallyPrecedes(number), let assets = release["assets"] as? [[String: Any]] else { continue }
            let value = String(tag.dropFirst()), name = "remote-guard-macos-universal-v" + value + ".zip", hashName = "SHA256SUMS-macos-v" + value + ".txt"
            let zips = assets.filter { $0["name"] as? String == name }, hashes = assets.filter { $0["name"] as? String == hashName }
            let prefix = "https://gitee.com/Soujer/remote-guard/releases/download/" + tag + "/"
            guard zips.count == 1, hashes.count == 1, zips[0]["browser_download_url"] as? String == prefix + name, hashes[0]["browser_download_url"] as? String == prefix + hashName else { continue }
            candidates.append(MacUpdate(version: value, zip: URL(string: prefix + name)!, hashes: URL(string: prefix + hashName)!))
        }
        return candidates.max { version($0.version)!.lexicographicallyPrecedes(version($1.version)!) }
    }
    static func check() throws -> MacUpdate? {
        let data = try BoundedFetch.get(URL(string: "https://gitee.com/api/v5/repos/Soujer/remote-guard/releases?per_page=100&page=1")!, limit: 4_194_304)
        guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw GuardError.message("发行版列表格式异常") }
        return select(releases, current: current)
    }
    static func prepare(_ update: MacUpdate) throws -> URL {
        let hashes = try BoundedFetch.get(update.hashes, limit: 65_536)
        let name = update.zip.lastPathComponent
        let lines = String(decoding: hashes, as: UTF8.self).components(separatedBy: .newlines).filter { $0.hasSuffix("  " + name) }
        try require(lines.count == 1, "校验清单缺少唯一的 macOS 包校验值")
        let hash = String(lines[0].prefix(64)).lowercased()
        try require(hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, "校验清单格式异常")
        let data = try BoundedFetch.get(update.zip, limit: 67_108_864)
        try require(Vault.sha(data) == hash, "macOS 更新包 SHA-256 校验失败")
        let cache = supportRoot.appendingPathComponent("update-cache/" + UUID().uuidString, isDirectory: true)
        try ensureDirectory(cache)
        do {
            let zip = cache.appendingPathComponent("app.zip"); try data.write(to: zip)
            try SafeZIP.extract(data, zipURL: zip, directory: cache)
            let app = cache.appendingPathComponent("RemoteGuard.app", isDirectory: true)
            guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else { throw GuardError.message("更新包缺少应用信息") }
            try require(info["CFBundleIdentifier"] as? String == bundleID && info["CFBundleShortVersionString"] as? String == update.version, "更新包标识或版本不一致")
            let signed = try runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]); try require(signed.code == 0, "更新程序签名完整性校验失败")
            let arch = try runTool("/usr/bin/lipo", [app.appendingPathComponent("Contents/MacOS/RemoteGuard").path, "-verify_arch", "arm64", "x86_64"]); try require(arch.code == 0, "更新包缺少 Apple 芯片或 Intel 支持")
            return app
        } catch { try? fm.removeItem(at: cache); throw error }
    }
    static func install(_ staged: URL) throws {
        let installed = Bundle.main.bundleURL.resolvingSymlinksInPath()
        try require(installed.pathExtension == "app" && !installed.path.contains("AppTranslocation") && fm.isWritableFile(atPath: installed.deletingLastPathComponent().path), "请先将软件放到本用户的“应用程序”文件夹再更新")
        let backupRoot = supportRoot.appendingPathComponent("backups", isDirectory: true); try ensureDirectory(backupRoot)
        let backup = backupRoot.appendingPathComponent("RemoteGuard-" + UUID().uuidString + ".app")
        let helper = staged.deletingLastPathComponent().appendingPathComponent("apply-update.sh")
        // All paths are positional arguments, never interpolated as shell code.
        let script = #"""
#!/bin/bash
set -eu
installed="$1"; staged="$2"; backup="$3"; oldpid="$4"; agent="$5"; userdomain="$6"
while kill -0 "$oldpid" 2>/dev/null; do sleep 1; done
/bin/launchctl bootout "$userdomain/com.soujer.remote-guard.desktop" 2>/dev/null || true
if ! /bin/mv "$installed" "$backup"; then /usr/bin/open "$installed"; exit 1; fi
if ! /bin/mv "$staged" "$installed"; then
    /bin/mv "$backup" "$installed"
    /usr/bin/open "$installed"
    exit 1
fi
if [ -f "$agent" ]; then /bin/launchctl bootstrap "$userdomain" "$agent" 2>/dev/null || true; fi
/usr/bin/open "$installed"
"""#
        try Data(script.utf8).write(to: helper)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = [helper.path, installed.path, staged.path, backup.path, String(getpid()), LaunchAgent.url.path, "gui/\(getuid())"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; try process.run()
    }
}
// Validate central AND local names; extract exact regular files through a bounded pipe.
// No archive-supplied path, symlink or file mode is passed to a general archive extractor.
enum SafeZIP {
    static let files: Set<String> = ["RemoteGuard.app/Contents/MacOS/RemoteGuard", "RemoteGuard.app/Contents/Info.plist", "RemoteGuard.app/Contents/Resources/VERSION", "RemoteGuard.app/Contents/Resources/README.md", "RemoteGuard.app/Contents/Resources/LICENSE", "RemoteGuard.app/Contents/_CodeSignature/CodeResources"]
    static let directories: Set<String> = ["RemoteGuard.app/", "RemoteGuard.app/Contents/", "RemoteGuard.app/Contents/MacOS/", "RemoteGuard.app/Contents/Resources/", "RemoteGuard.app/Contents/_CodeSignature/"]
    struct Entry { let name: String; let size: Int }
    static func entries(_ data: Data) throws -> [Entry] {
        func u16(_ at: Int) throws -> Int { try require(at >= 0 && at + 2 <= data.count, "ZIP 已截断"); return Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ at: Int) throws -> Int { try require(at >= 0 && at + 4 <= data.count, "ZIP 已截断"); return Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24 }
        try require(data.count >= 22 && data.count <= 67_108_864, "ZIP 大小无效")
        var end: Int?
        for index in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) { if try u32(index) == 0x06054b50 { end = index; break } }
        guard let end else { throw GuardError.message("ZIP 索引缺失") }
        try require(try u16(end + 4) == 0 && u16(end + 6) == 0 && u16(end + 8) == u16(end + 10) && end + 22 + u16(end + 20) == data.count, "不支持多卷 ZIP")
        let count = try u16(end + 10), centralSize = try u32(end + 12), central = try u32(end + 16)
        try require(count <= 32 && central + centralSize == end, "ZIP 索引无效")
        var position = central, seen = Set<String>(), result = [Entry](), total = 0
        for _ in 0..<count {
            try require(try u32(position) == 0x02014b50, "ZIP 索引项无效")
            let flags = try u16(position + 8), method = try u16(position + 10), compressed = try u32(position + 20), size = try u32(position + 24), nameSize = try u16(position + 28), extra = try u16(position + 30), comment = try u16(position + 32), local = try u32(position + 42), mode = try u32(position + 38) >> 16
            try require(position + 46 + nameSize + extra + comment <= end, "ZIP 文件名越界")
            guard let name = String(data: data.subdata(in: (position + 46)..<(position + 46 + nameSize)), encoding: .utf8) else { throw GuardError.message("ZIP 文件名无效") }
            try require((files.contains(name) || directories.contains(name)) && !seen.contains(name) && mode & 0xf000 != 0xa000 && flags & 1 == 0 && [0, 8].contains(method), "ZIP 包含重复文件、不安全路径或符号链接")
            seen.insert(name); total += size; try require(size <= 33_554_432 && total <= 67_108_864, "ZIP 解压大小超限")
            try require(try u32(local) == 0x04034b50 && u16(local + 6) & 1 == 0 && u16(local + 8) == method, "ZIP 本地索引无效")
            let localName = try u16(local + 26), localExtra = try u16(local + 28), payload = local + 30 + localName + localExtra
            try require(localName == nameSize && payload + compressed <= central && data.subdata(in: (local + 30)..<(local + 30 + localName)) == Data(name.utf8), "ZIP 本地文件名或内容范围不一致")
            if files.contains(name) { result.append(Entry(name: name, size: size)) }; position += 46 + nameSize + extra + comment
        }
        try require(position == end && files.isSubset(of: seen), "ZIP 缺少必要应用文件")
        return result
    }
    static func extract(_ data: Data, zipURL: URL, directory: URL) throws {
        for entry in try entries(data) {
            let target = directory.appendingPathComponent(entry.name); try ensureDirectory(target.deletingLastPathComponent())
            fm.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: entry.name.hasSuffix("/MacOS/RemoteGuard") ? 0o755 : 0o600])
            let output = try FileHandle(forWritingTo: target); defer { try? output.close() }
            let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); process.arguments = ["-p", zipURL.path, entry.name]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); var written = 0
            do {
                while true { let bytes = pipe.fileHandleForReading.readData(ofLength: 65_536); if bytes.isEmpty { break }; written += bytes.count; try require(written <= entry.size, "ZIP 解压内容超过声明大小"); try output.write(contentsOf: bytes) }
                process.waitUntilExit(); try require(process.terminationStatus == 0 && written == entry.size, "ZIP 文件解压或 CRC 校验失败")
            } catch { process.terminate(); process.waitUntilExit(); throw error }
        }
    }
}
