import Foundation
import Security
import CommonCrypto

enum GuardError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
func require(_ condition: Bool, _ message: String) throws { if !condition { throw GuardError.message(message) } }
let fm = FileManager.default
let supportRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RemoteGuard", isDirectory: true)
func ensureDirectory(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
func logGuard(_ text: String) {
    try? ensureDirectory(supportRoot)
    let url = supportRoot.appendingPathComponent("remote-guard.log")
    if ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 2_097_152 {
        try? fm.removeItem(at: url.appendingPathExtension("1")); try? fm.moveItem(at: url, to: url.appendingPathExtension("1"))
    }
    let line = Data((ISO8601DateFormatter().string(from: Date()) + " " + text + "\n").utf8)
    if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
    if let file = try? FileHandle(forWritingTo: url) { defer { try? file.close() }; try? file.seekToEnd(); try? file.write(contentsOf: line) }
}
struct Settings: Codable {
    var monitoring = false
    var recording = false
    var autoUpdate = true
    var directory = supportRoot.appendingPathComponent("recordings").path
    var quotaMB = 2048
    var publicKey = ""
    var barkKey = ""
    var hayoToken = ""
    var segmentSeconds = 300
    static let url = supportRoot.appendingPathComponent("settings.json")
    static func load() throws -> Settings {
        guard fm.fileExists(atPath: url.path) else { return Settings() }
        let value = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
        try value.validate(); return value
    }
    func validate() throws {
        try require(directory.hasPrefix("/") && !directory.hasPrefix("/Network/"), "请选择本机磁盘上的绝对保存路径")
        try require((128...1_048_576).contains(quotaMB) && (30...900).contains(segmentSeconds), "录屏存储参数无效")
        if !publicKey.isEmpty { _ = try Vault.publicRSA(publicKey) }
        try require(!recording || !publicKey.isEmpty, "启用录屏前请先创建并保存播放私钥")
    }
    func save() throws { try validate(); try ensureDirectory(supportRoot); try JSONEncoder().encode(self).write(to: Self.url, options: .atomic); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path) }
}
struct ProcessResult { let code: Int32; let output: String; let error: String }
func runTool(_ path: String, _ arguments: [String]) throws -> ProcessResult {
    let process = Process(), output = Pipe(), error = Pipe()
    process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
    process.standardOutput = output; process.standardError = error
    // Tool output is small (lsof, launchctl, codesign); drain stderr concurrently.
    let group = DispatchGroup(); var errors = Data(); group.enter()
    try process.run()
    DispatchQueue.global().async { errors = error.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); group.wait()
    return ProcessResult(code: process.terminationStatus, output: String(decoding: bytes, as: UTF8.self), error: String(decoding: errors, as: UTF8.self))
}
struct DER {
    static func wrap(_ tag: UInt8, _ value: Data) -> Data {
        var length = value.count, bytes = Data()
        if length < 128 { bytes.append(UInt8(length)) }
        else { var encoded = [UInt8](); while length > 0 { encoded.insert(UInt8(length & 255), at: 0); length >>= 8 }; bytes.append(0x80 | UInt8(encoded.count)); bytes.append(contentsOf: encoded) }
        return Data([tag]) + bytes + value
    }
    static func integer(_ value: Data) -> Data {
        var bytes = Array(value); while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        if bytes.isEmpty { bytes = [0] }; if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return wrap(2, Data(bytes))
    }
    static func read(_ bytes: Data, _ position: inout Int, tag: UInt8) throws -> Data {
        try require(position + 2 <= bytes.count && bytes[position] == tag, "RSA 密钥格式无效")
        position += 1; var length = Int(bytes[position]); position += 1
        if length & 128 != 0 { let count = length & 127; try require((1...4).contains(count) && position + count <= bytes.count, "RSA 长度无效"); length = 0; for _ in 0..<count { length = (length << 8) | Int(bytes[position]); position += 1 } }
        try require(length >= 0 && position + length <= bytes.count, "RSA 密钥已截断")
        let result = bytes.subdata(in: position..<(position + length)); position += length; return result
    }
    static func components(_ encoded: Data, privateKey: Bool) throws -> [Data] {
        var index = 0; let sequence = try read(encoded, &index, tag: 0x30); try require(index == encoded.count, "RSA 密钥包含多余内容")
        index = 0; var result = [Data]()
        while index < sequence.count { var value = try read(sequence, &index, tag: 2); while value.count > 1 && value.first == 0 { value.removeFirst() }; result.append(Data(value)) }
        try require(result.count == (privateKey ? 9 : 2), "RSA 密钥字段无效")
        return privateKey ? Array(result.dropFirst()) : result
    }
}
final class KeyXML: NSObject, XMLParserDelegate {
    var values = [String: String](); var current = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) { current = name }
    func parser(_ parser: XMLParser, foundCharacters text: String) { values[current, default: ""] += text }
    static let publicNames = ["Modulus", "Exponent"]
    static let privateNames = ["Modulus", "Exponent", "D", "P", "Q", "DP", "DQ", "InverseQ"]
    static func encode(_ key: SecKey, privateKey: Bool) throws -> String {
        var error: Unmanaged<CFError>?
        guard let bytes = SecKeyCopyExternalRepresentation(key, &error) as Data? else { throw GuardError.message("无法导出 RSA 密钥") }
        let components = try DER.components(bytes, privateKey: privateKey), names = privateKey ? privateNames : publicNames
        return "<RSAKeyValue>" + zip(names, components).map { "<\($0)>\($1.base64EncodedString())</\($0)>" }.joined() + "</RSAKeyValue>"
    }
    static func decode(_ text: String, privateKey: Bool) throws -> SecKey {
        try require(text.utf8.count <= 65_536 && !text.contains("<!"), "RSA 密钥格式无效")
        let delegate = KeyXML(), parser = XMLParser(data: Data(text.utf8)); parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        try require(parser.parse(), "RSA XML 密钥无效")
        if !privateKey { try require(!privateNames.dropFirst(2).contains(where: { delegate.values[$0] != nil }), "录屏配置只允许公钥") }
        let names = privateKey ? privateNames : publicNames
        var parts = [Data]()
        for name in names { guard let value = delegate.values[name], let bytes = Data(base64Encoded: value), !bytes.isEmpty, bytes.count <= 1024 else { throw GuardError.message("RSA 密钥字段无效") }; parts.append(bytes) }
        try require((256...1024).contains(parts[0].count), "RSA 密钥长度无效")
        var body = privateKey ? DER.integer(Data([0])) : Data(); for part in parts { body += DER.integer(part) }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: privateKey ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(DER.wrap(0x30, body) as CFData, attributes as CFDictionary, &error) else { throw GuardError.message("无法读取 RSA 密钥") }
        return key
    }
}
enum Vault {
    static func readBounded(_ url: URL, maximum: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var bytes = Data()
        while let chunk = try file.read(upToCount: min(65_536, maximum + 1 - bytes.count)), !chunk.isEmpty {
            bytes.append(chunk); try require(bytes.count <= maximum, "文件超过大小限制")
        }
        return bytes
    }
    static func random(_ count: Int) throws -> Data { var data = Data(count: count); let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }; try require(result == errSecSuccess, "系统随机数生成失败"); return data }
    static func equal(_ a: Data, _ b: Data) -> Bool { var diff = a.count ^ b.count; for (x, y) in zip(a, b) { diff |= Int(x ^ y) }; return diff == 0 }
    static func sha(_ data: Data) -> String { var digest = [UInt8](repeating: 0, count: 32); data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }; return digest.map { String(format: "%02x", $0) }.joined() }
    static func hmac(_ data: Data, key: Data) -> Data { var result = Data(count: 32); result.withUnsafeMutableBytes { output in key.withUnsafeBytes { secret in data.withUnsafeBytes { input in CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), secret.baseAddress, key.count, input.baseAddress, data.count, output.baseAddress) } } }; return result }
    static func derive(_ password: String, salt: Data) throws -> Data {
        var material = Data(count: 64); let bytes = Array(password.utf8)
        let status = material.withUnsafeMutableBytes { output in salt.withUnsafeBytes { saltBytes in bytes.withUnsafeBytes { input in CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.baseAddress!.assumingMemoryBound(to: Int8.self), bytes.count, saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 210_000, output.baseAddress!.assumingMemoryBound(to: UInt8.self), 64) } } }
        try require(status == kCCSuccess, "密码密钥派生失败"); return material
    }
    static func crypt(_ data: Data, key: Data, iv: Data, encrypt: Bool) throws -> Data {
        var output = Data(count: data.count + 16), written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { target in key.withUnsafeBytes { secret in iv.withUnsafeBytes { vector in data.withUnsafeBytes { source in CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), secret.baseAddress, 32, vector.baseAddress, source.baseAddress, data.count, target.baseAddress, capacity, &written) } } } }
        try require(status == kCCSuccess, "密码错误或加密文件已损坏"); output.count = written; return output
    }
    static func publicRSA(_ xml: String) throws -> SecKey { try KeyXML.decode(xml, privateKey: false) }
    static func passwordError(_ password: String, _ confirmation: String) -> String? {
        if password.isEmpty { return "请输入私钥密码（至少 12 位）" }
        if password.utf16.count < 12 { return "私钥密码不足 12 位，当前为 \(password.utf16.count) 位" }
        if confirmation.isEmpty { return "请再次输入确认密码" }
        if Data(password.utf8) != Data(confirmation.utf8) { return "两次输入的密码不一致" }; return nil
    }
    static func createKey(_ url: URL, password: String) throws -> String {
        try require(password.utf16.count >= 12, "私钥密码至少 12 位")
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 3072] as CFDictionary, &error), let publicKey = SecKeyCopyPublicKey(key) else { throw GuardError.message("创建 RSA 私钥失败") }
        let salt = try random(16), iv = try random(16), material = try derive(password, salt: salt)
        var bytes = Data("RGKEY001".utf8) + salt + iv
        bytes += try crypt(Data(KeyXML.encode(key, privateKey: true).utf8), key: material.subdata(in: 0..<32), iv: iv, encrypt: true)
        bytes += hmac(bytes, key: material.subdata(in: 32..<64))
        // .withoutOverwriting prevents an existing playback key from being replaced.
        try bytes.write(to: url, options: .withoutOverwriting); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try KeyXML.encode(publicKey, privateKey: false)
    }
    static func readKey(_ url: URL, password: String) throws -> SecKey {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try require((88...1_048_576).contains(size), "私钥文件格式无效")
        let data = try readBounded(url, maximum: 1_048_576); try require(data.count >= 88 && data.prefix(8) == Data("RGKEY001".utf8), "不支持的私钥格式")
        let material = try derive(password, salt: data.subdata(in: 8..<24))
        try require(equal(hmac(data.subdata(in: 0..<(data.count - 32)), key: material.subdata(in: 32..<64)), Data(data.suffix(32))), "私钥密码错误或文件已损坏")
        let xml = try crypt(data.subdata(in: 40..<(data.count - 32)), key: material.subdata(in: 0..<32), iv: data.subdata(in: 24..<40), encrypt: false)
        guard let text = String(data: xml, encoding: .utf8) else { throw GuardError.message("私钥内容无效") }; return try KeyXML.decode(text, privateKey: true)
    }
    static func decrypt(_ url: URL, keyURL: URL, password: String) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try require((320...268_435_456).contains(size), "录像大小无效或超过单段 256 MB 限制")
        let data = try readBounded(url, maximum: 268_435_456)
        try require(data.count >= 320, "录像已截断")
        try require(data.prefix(8) == Data("RGREC001".utf8), "不支持的录像格式")
        let length = Int(data[8]) | Int(data[9]) << 8 | Int(data[10]) << 16 | Int(data[11]) << 24
        let start = 12 + length + 16
        try require((256...1024).contains(length) && start + 48 <= data.count && (data.count - start - 32) % 16 == 0, "录像已截断")
        let key = try readKey(keyURL, password: password); var error: Unmanaged<CFError>?
        guard let material = SecKeyCreateDecryptedData(key, .rsaEncryptionOAEPSHA256, data.subdata(in: 12..<(12 + length)) as CFData, &error) as Data?, material.count == 64 else { throw GuardError.message("私钥与录像不匹配") }
        try require(equal(hmac(data.subdata(in: 0..<(data.count - 32)), key: material.subdata(in: 32..<64)), Data(data.suffix(32))), "录像完整性校验失败")
        // Authenticate the whole recording before releasing any plaintext to AVPlayer.
        return try crypt(data.subdata(in: start..<(data.count - 32)), key: material.subdata(in: 0..<32), iv: data.subdata(in: (start - 16)..<start), encrypt: false)
    }
}
final class RecordingWriter {
    private var file: FileHandle?; private var cryptor: CCCryptorRef?; private var mac = CCHmacContext()
    private var count = 0; private let limit: Int; private var closed = false
    init(_ url: URL, publicKey: String, limit: Int) throws {
        self.limit = limit
        let material = try Vault.random(64), iv = try Vault.random(16), rsa = try Vault.publicRSA(publicKey); var error: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(rsa, .rsaEncryptionOAEPSHA256, material as CFData, &error) as Data? else { throw GuardError.message("录屏密钥封装失败") }
        var length = UInt32(wrapped.count).littleEndian
        let header = Data("RGREC001".utf8) + withUnsafeBytes(of: &length) { Data($0) } + wrapped + iv
        let key = material.subdata(in: 0..<32), macKey = material.subdata(in: 32..<64)
        let status = key.withUnsafeBytes { secret in iv.withUnsafeBytes { vector in CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), secret.baseAddress, 32, vector.baseAddress, &cryptor) } }
        try require(status == kCCSuccess, "创建加密流失败")
        macKey.withUnsafeBytes { CCHmacInit(&mac, CCHmacAlgorithm(kCCHmacAlgSHA256), $0.baseAddress, macKey.count) }
        try Data().write(to: url, options: .withoutOverwriting); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        file = try FileHandle(forWritingTo: url); try sink(header)
    }
    private func sink(_ bytes: Data) throws {
        try require(count + bytes.count + 32 <= limit, "加密片段已达到大小上限")
        try file!.write(contentsOf: bytes); bytes.withUnsafeBytes { CCHmacUpdate(&mac, $0.baseAddress, bytes.count) }; count += bytes.count
    }
    func write(_ bytes: Data) throws {
        try require(!closed, "加密片段已经关闭")
        var output = Data(count: bytes.count + 16), length = 0; let capacity = output.count
        let status = output.withUnsafeMutableBytes { target in bytes.withUnsafeBytes { source in CCCryptorUpdate(cryptor, source.baseAddress, bytes.count, target.baseAddress, capacity, &length) } }
        try require(status == kCCSuccess, "录屏加密失败"); output.count = length; try sink(output)
    }
    func finish() throws {
        try require(!closed, "加密片段已经关闭")
        var output = Data(count: 16), length = 0
        let status = output.withUnsafeMutableBytes { CCCryptorFinal(cryptor, $0.baseAddress, 16, &length) }
        try require(status == kCCSuccess, "加密片段收尾失败"); output.count = length; try sink(output)
        var digest = Data(count: 32); digest.withUnsafeMutableBytes { CCHmacFinal(&mac, $0.baseAddress) }
        try file!.write(contentsOf: digest); try file!.synchronize(); closed = true; try file!.close()
    }
    deinit { if let cryptor { CCCryptorRelease(cryptor) }; if !closed { try? file?.close() } }
}
