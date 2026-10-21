import Foundation

enum LauncherError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

/// Shared by the editor and the standalone launcher: the signed bundle owns
/// its settings, so a launcher continues to work when CipherRelay is closed.
struct LauncherConfiguration: Codable {
    var schemaVersion = 1
    var id: String
    var name: String
    var appPath: String
    var bundleIdentifier: String
    var mode: String
    var port: Int
    var bypassRules: [String]

    static let fileName = "launcher.json"
    static let bundlePrefix = "com.cipherrelay.launcher."

    func validated() throws -> Self {
        guard schemaVersion == 1, UUID(uuidString: id) != nil else {
            throw LauncherError.invalid("Unsupported launcher configuration.")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, !name.contains("/"), !name.contains(":"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw LauncherError.invalid("Invalid launcher name.")
        }
        guard appPath.hasPrefix("/"), appPath.hasSuffix(".app"),
              !bundleIdentifier.isEmpty,
              !bundleIdentifier.hasPrefix(Self.bundlePrefix) else {
            throw LauncherError.invalid("Select an installed application, not another proxy launcher.")
        }
        guard mode == "chromium" || mode == "environment", (1...65535).contains(port) else {
            throw LauncherError.invalid("Invalid launch mode or proxy port.")
        }
        guard bypassRules.count <= 200 else {
            throw LauncherError.invalid("Use at most 200 bypass rules.")
        }
        var result = self
        var seen = Set<String>()
        result.bypassRules = try bypassRules.compactMap { raw in
            let rule = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Only hosts, IP literals and host globs; never shell syntax, URL
            // paths, Chromium subtractive rules or option delimiters.
            guard !rule.isEmpty, rule.count <= 253,
                  rule.range(of: #"^[a-z0-9*._\-\[\]:]+$"#, options: .regularExpression) != nil,
                  rule != ".", !rule.contains(".."),
                  (!rule.contains(":") || rule == "::1" || rule == "[::1]") else {
                throw LauncherError.invalid("Invalid bypass host: \(raw)")
            }
            return seen.insert(rule).inserted ? rule : nil
        }
        return result
    }

    var proxyURL: String { "http://127.0.0.1:\(port)" }

    var chromiumBypassRules: [String] {
        ["localhost", "127.0.0.1", "[::1]"] + bypassRules.flatMap { rule -> [String] in
            if rule == "::1" { return ["[::1]"] }
            // A leading dot represents the domain and its subdomains in this
            // UI. Chromium itself only matches subdomains for this spelling.
            if rule.hasPrefix(".") { return [String(rule.dropFirst()), "*\(rule)"] }
            return [rule]
        }
    }

    var environmentBypassRules: [String] {
        ["localhost", "127.0.0.1", "::1"] + bypassRules.compactMap { rule in
            if rule == "[::1]" { return "::1" }
            if rule == "*" { return "*" }
            if rule.hasPrefix("*."), !rule.dropFirst().contains("*") {
                return String(rule.dropFirst())
            }
            // NO_PROXY has no portable arbitrary-glob semantics. Do not pass
            // a misleading *oa* entry to backend HTTP clients.
            return rule.contains("*") ? nil : rule
        }
    }

    var chromiumArguments: [String] {
        mode == "chromium" ? [
            "--proxy-server=\(proxyURL)",
            "--proxy-bypass-list=\(chromiumBypassRules.joined(separator: ";"))",
        ] : []
    }

    var openArguments: [String] {
        var args = ["-a", appPath]
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
            args += ["--env", "\(key)=\(proxyURL)"]
        }
        for key in ["NO_PROXY", "no_proxy"] {
            args += ["--env", "\(key)=\(environmentBypassRules.joined(separator: ","))"]
        }
        if !chromiumArguments.isEmpty { args += ["--args"] + chromiumArguments }
        return args
    }

    func targetBundle() throws -> Bundle {
        guard let bundle = Bundle(path: appPath),
              bundle.bundleIdentifier == bundleIdentifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LauncherError.invalid("The target application moved or changed. Select it again in CipherRelay.")
        }
        return bundle
    }
}

@discardableResult
func launcherCommand(_ path: String, _ arguments: [String]) throws -> (Int32, String) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
