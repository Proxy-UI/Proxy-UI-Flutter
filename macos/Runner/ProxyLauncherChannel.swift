import AppKit
import FlutterMacOS
import UniformTypeIdentifiers

final class ProxyLauncherChannel {
    private let queue = DispatchQueue(label: "com.cipherrelay.proxy-launchers", qos: .userInitiated)
    private let store = LauncherStore(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/CipherRelay Launchers"),
        helper: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/CipherRelayProxyLauncher")
    )

    func register(with controller: FlutterViewController) {
        let channel = FlutterMethodChannel(name: "proxy_ui/launchers", binaryMessenger: controller.engine.binaryMessenger)
        channel.setMethodCallHandler { [self] call, reply in
            if call.method == "chooseApplication" {
                chooseApplication(reply)
                return
            }
            let args = call.arguments as? [String: Any] ?? [:]
            queue.async { [self] in
                do {
                    let value: Any?
                    switch call.method {
                    case "discover":
                        value = LauncherApplication.discover().map(\.dictionary)
                    case "validateNative":
                        guard let path = args["appPath"] as? String,
                              let application = LauncherApplication(URL(fileURLWithPath: path)),
                              application.mode == "claudeNative" else {
                            throw LauncherError.invalid("This Claude version does not support native proxy configuration.")
                        }
                        for path in [
                            "/Library/Managed Preferences/com.anthropic.claudefordesktop.plist",
                            "/Library/Managed Preferences/\(NSUserName())/com.anthropic.claudefordesktop.plist",
                        ] where FileManager.default.fileExists(atPath: path) {
                            guard let policy = NSDictionary(contentsOfFile: path), policy.count == 0 else {
                                throw LauncherError.invalid("Claude is managed by an organization. Local proxy settings may be overridden; no settings were changed.")
                            }
                        }
                        value = nil
                    case "openNative":
                        guard let path = args["appPath"] as? String,
                              let application = LauncherApplication(URL(fileURLWithPath: path)),
                              application.mode == "claudeNative" else {
                            throw LauncherError.invalid("Select an installed Claude application.")
                        }
                        DispatchQueue.main.async {
                            NSWorkspace.shared.openApplication(at: application.url,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
                                DispatchQueue.main.async { reply(error.map(Self.failure)) }
                            }
                        }
                        return
                    case "revealNative":
                        guard let path = args["path"] as? String else {
                            throw LauncherError.invalid("Missing configuration path.")
                        }
                        DispatchQueue.main.async {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            reply(nil)
                        }
                        return
                    case "list":
                        value = try store.configurations().map(Self.dictionary)
                    case "save":
                        guard let name = args["name"] as? String,
                              let path = args["appPath"] as? String,
                              let bundle = Bundle(path: path), let bundleID = bundle.bundleIdentifier,
                              bundleID != Bundle.main.bundleIdentifier,
                              let mode = args["mode"] as? String,
                              let port = args["port"] as? Int,
                              let rules = args["bypassRules"] as? [String] else {
                            throw LauncherError.invalid("Invalid launcher settings.")
                        }
                        let id = args["id"] as? String
                        let config = LauncherConfiguration(
                            id: id ?? UUID().uuidString.lowercased(), name: name, appPath: path,
                            bundleIdentifier: bundleID, mode: mode, port: port, bypassRules: rules
                        )
                        value = try Self.dictionary(store.save(config, creating: id == nil))
                    case "trash":
                        try store.trash(try Self.id(args))
                        value = nil
                    case "reveal", "open":
                        let (url, _) = try store.find(try Self.id(args))
                        DispatchQueue.main.async {
                            if call.method == "reveal" {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                                reply(nil)
                            } else {
                                NSWorkspace.shared.openApplication(
                                    at: url, configuration: NSWorkspace.OpenConfiguration()
                                ) { _, error in
                                    DispatchQueue.main.async {
                                        reply(error.map(Self.failure))
                                    }
                                }
                            }
                        }
                        return
                    default:
                        DispatchQueue.main.async { reply(FlutterMethodNotImplemented) }
                        return
                    }
                    DispatchQueue.main.async { reply(value) }
                } catch {
                    DispatchQueue.main.async { reply(Self.failure(error)) }
                }
            }
        }
    }

    private func chooseApplication(_ reply: @escaping FlutterResult) {
        let panel = NSOpenPanel()
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.applicationBundle]
        } else {
            panel.allowedFileTypes = ["app"]
        }
        // AppKit must allow package directories to select .app bundles.
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                reply(nil)
                return
            }
            guard let application = LauncherApplication(url) else {
                reply(Self.failure(LauncherError.invalid("Select an installed .app application.")))
                return
            }
            reply(application.dictionary)
        }
    }

    private static func id(_ args: [String: Any]) throws -> String {
        guard let id = args["id"] as? String else { throw LauncherError.invalid("Missing launcher ID.") }
        return id
    }

    private static func dictionary(_ entry: (URL, LauncherConfiguration)) throws -> [String: Any] {
        var result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry.1)) as! [String: Any]
        result["launcherPath"] = entry.0.path
        return result
    }

    private static func failure(_ error: Error) -> FlutterError {
        FlutterError(code: "launcher_error", message: error.localizedDescription, details: nil)
    }
}
