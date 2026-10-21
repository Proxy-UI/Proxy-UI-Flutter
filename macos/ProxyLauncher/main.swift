import AppKit
import Foundation

let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true

func message(_ zh: String, _ en: String, detail: String = "") {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = chinese ? zh : en
    alert.informativeText = detail
    alert.addButton(withTitle: chinese ? "知道了" : "OK")
    alert.runModal()
}

do {
    let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(LauncherConfiguration.fileName)")
    let config = try JSONDecoder().decode(LauncherConfiguration.self, from: Data(contentsOf: url)).validated()
    _ = try config.targetBundle()
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: config.bundleIdentifier)
    let listening = try launcherCommand("/usr/bin/nc", ["-z", "-G", "2", "127.0.0.1", String(config.port)]).0 == 0
    func matches(_ app: NSRunningApplication) -> Bool {
        guard config.mode == "chromium",
              app.bundleURL?.resolvingSymlinksInPath().path
                == URL(fileURLWithPath: config.appPath).resolvingSymlinksInPath().path,
              let result = try? launcherCommand("/bin/ps", ["-p", String(app.processIdentifier), "-o", "args="]),
              result.0 == 0 else { return false }
        let arguments = Set(result.1.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        return config.chromiumArguments.allSatisfy(arguments.contains)
    }
    if CommandLine.arguments.contains("--check") {
        let report: [String: Any] = [
            "proxy": config.proxyURL,
            "proxyListening": listening,
            "launchArguments": config.openArguments,
            "runningApplications": running.map { ["pid": Int($0.processIdentifier), "matches": matches($0)] as [String: Any] },
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else if !listening {
        message("请先开启本地代理", "Start the local proxy first",
                detail: chinese ? "请在 CipherRelay 中连接节点，确保 \(config.proxyURL) 可用。无需开启 TUN。"
                                : "Connect to a node in CipherRelay and make sure \(config.proxyURL) is listening. TUN is not required.")
    } else if let existing = running.first {
        if running.allSatisfy(matches) {
            existing.activate(options: [.activateAllWindows])
        } else {
            message("请先完全退出目标应用", "Quit the target application first",
                    detail: chinese ? "请保存工作并按 ⌘Q 完全退出目标应用，再点击此启动器。运行中的应用无法接收新的代理或直连规则。"
                                    : "Save your work and fully quit the target app with ⌘Q, then open this launcher again. Running apps cannot receive new proxy or bypass settings.")
        }
    } else {
        let result = try launcherCommand("/usr/bin/open", config.openArguments)
        guard result.0 == 0 else { throw LauncherError.invalid("macOS could not launch the app: \(result.1)") }
    }
} catch {
    if CommandLine.arguments.contains("--check") {
        FileHandle.standardError.write(Data(error.localizedDescription.utf8))
        exit(1)
    }
    message("启动失败", "Could not launch the application", detail: error.localizedDescription)
}
