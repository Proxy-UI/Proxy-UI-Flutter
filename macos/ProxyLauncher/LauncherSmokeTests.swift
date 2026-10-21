import AppKit
import Foundation

@main
struct LauncherSmokeTests {
    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("launcher-test-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications")
        func app(_ name: String, _ id: String, _ version: String) throws -> URL {
            let app = applications.appendingPathComponent(name + ".app")
            try files.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": id, "CFBundleExecutable": "App",
                "CFBundleShortVersionString": version, "CFBundleName": name,
                "CFBundlePackageType": "APPL",
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            let executable = app.appendingPathComponent("Contents/MacOS/App")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            return app
        }
        let oldCodex = try app("Codex", "com.openai.codex", "1.9")
        let newCodex = try app("ChatGPT", "com.openai.codex", "1.10")
        _ = try app("Claude", "com.anthropic.claudefordesktop", "2.0")
        _ = try app("Codex Copy", "unrelated.application", "99.0")
        let detected = LauncherApplication.discover(roots: [applications], preferred: [])
        precondition(detected.count == 2)
        let codex = detected.first { $0.name == "Codex" }!
        precondition(codex.url.path == newCodex.resolvingSymlinksInPath().path)
        precondition(detected.first { $0.name == "Claude" }?.mode == "claudeNative")
        precondition(detected.first { $0.name == "Codex" }?.mode == "chromium")
        let active = LauncherApplication.discover(roots: [applications], preferred: [oldCodex])
        precondition(active.first { $0.name == "Codex" }!.url.path == oldCodex.resolvingSymlinksInPath().path)
        precondition(LauncherApplication.discover(roots: [root.appendingPathComponent("Missing")], preferred: []).isEmpty)
        let target = root.appendingPathComponent("测试 App '$;.app")
        let macos = target.appendingPathComponent("Contents/MacOS")
        try files.createDirectory(at: macos, withIntermediateDirectories: true)
        let bundleID = "test.cipherrelay.\(UUID().uuidString)"
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleExecutable": "Target",
            "CFBundleName": "Test App", "CFBundlePackageType": "APPL", "LSUIElement": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: target.appendingPathComponent("Contents/Info.plist"))
        let marker = root.appendingPathComponent("received.txt")
        let targetScript = "#!/bin/sh\nprintf '%s\\n' \"$HTTP_PROXY\" \"$HTTPS_PROXY\" \"$NO_PROXY\" \"$@\" > '\(marker.path)'\n"
        let executable = macos.appendingPathComponent("Target")
        try Data(targetScript.utf8).write(to: executable)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = LauncherStore(directory: root.appendingPathComponent("Launchers"), helper: helper)
        var config = LauncherConfiguration(
            id: UUID().uuidString.lowercased(), name: "Test Launcher", appPath: target.path,
            bundleIdentifier: bundleID, mode: "chromium", port: Int(CommandLine.arguments[2])!,
            bypassRules: ["*oa*", ".oa.com", ".woa.com"]
        )
        let (installed, _) = try store.save(config, creating: true)
        let launcher = installed.appendingPathComponent("Contents/MacOS/ProxyLauncher")
        let check = try launcherCommand(launcher.path, ["--check"])
        precondition(check.0 == 0, check.1)
        let report = try JSONSerialization.jsonObject(with: Data(check.1.utf8)) as! [String: Any]
        precondition(report["proxyListening"] as? Bool == true)
        precondition(config.environmentBypassRules == ["localhost", "127.0.0.1", "::1", ".oa.com", ".woa.com"])
        precondition(config.chromiumBypassRules.contains("*oa*"))

        // Exercise LaunchServices with an inert target that only writes the
        // received environment/arguments, including a path with shell syntax.
        let launch = try launcherCommand(launcher.path, [])
        precondition(launch.0 == 0, launch.1)
        for _ in 0..<60 {
            if files.fileExists(atPath: marker.path) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let received = try String(contentsOf: marker, encoding: .utf8)
        precondition(received.contains(config.proxyURL))
        precondition(received.contains(config.chromiumArguments[1]))
        precondition(received.contains("localhost,127.0.0.1,::1,.oa.com,.woa.com"))

        var second = config
        second.id = UUID().uuidString.lowercased()
        second.bypassRules = [".internal.example"]
        _ = try store.save(second, creating: true)
        config.bypassRules = []
        let edited = try store.save(config, creating: false)
        // macOS enumerates /var temporary directories through /private/var.
        precondition(edited.0.resolvingSymlinksInPath().path == installed.resolvingSymlinksInPath().path,
                     "Editing must preserve Dock paths: \(installed.path) -> \(edited.0.path)")
        let independent = try store.find(second.id)
        precondition(independent.1.bypassRules == [".internal.example"])
        let before = try Data(contentsOf: installed.appendingPathComponent("Contents/Resources/launcher.json"))
        var invalid = config
        invalid.bypassRules = ["host;--proxy-server=evil"]
        do {
            _ = try store.save(invalid, creating: false)
            fatalError("Invalid rules were accepted.")
        } catch is LauncherError {}
        let after = try Data(contentsOf: installed.appendingPathComponent("Contents/Resources/launcher.json"))
        precondition(before == after, "Failed edits must preserve the existing launcher.")
        let signature = try launcherCommand("/usr/bin/codesign", ["--verify", "--strict", installed.path])
        precondition(signature.0 == 0, signature.1)
        print("PASS: app identity discovery/deduplication, signed launcher, real launch/env, isolation, stable update, failed-edit preservation")
    }
}
