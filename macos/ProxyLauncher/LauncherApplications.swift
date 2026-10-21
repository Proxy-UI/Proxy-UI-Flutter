import AppKit
import Foundation

struct LauncherApplication {
    let name: String
    let url: URL
    let identifier: String
    let mode: String
    let version: String

    static let knownNames = [
        "com.openai.codex": "Codex",
        "com.anthropic.claudefordesktop": "Claude",
    ]

    init?(_ url: URL) {
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        self.url = url.resolvingSymlinksInPath()
        self.identifier = identifier
        name = Self.knownNames[identifier]
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let frameworks = (try? FileManager.default.contentsOfDirectory(
            atPath: url.appendingPathComponent("Contents/Frameworks").path
        )) ?? []
        let chromium = Self.knownNames[identifier] != nil || frameworks.contains {
            let name = $0.lowercased()
            return ["electron", "chrome", "chromium", "microsoft edge", "brave browser", "codex framework"]
                .contains(where: name.contains)
        }
        let nativeClaude = identifier == "com.anthropic.claudefordesktop" &&
            version.compare("1.44121.1", options: .numeric) != .orderedAscending
        mode = nativeClaude ? "claudeNative" : (chromium ? "chromium" : "environment")
    }

    var dictionary: [String: String] {
        ["name": name, "appPath": url.path, "applicationId": identifier, "mode": mode]
    }

    /// Only installed locations are searched; mounted installers and generated
    /// wrappers must not win over the user's actual application.
    static func discover(
        roots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ],
        preferred: [URL]? = nil
    ) -> [LauncherApplication] {
        let active = preferred ?? NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        var candidates = active
        for root in roots {
            candidates += (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
        }
        let installed = candidates.compactMap(LauncherApplication.init).filter { app in
            knownNames[app.identifier] != nil && roots.contains {
                app.url.path.hasPrefix($0.resolvingSymlinksInPath().path + "/")
            }
        }
        let preferredPaths = Set(active.map { $0.resolvingSymlinksInPath().path })
        var selected: [String: LauncherApplication] = [:]
        for app in installed {
            if let previous = selected[app.identifier] {
                let currentActive = preferredPaths.contains(app.url.path)
                let previousActive = preferredPaths.contains(previous.url.path)
                if previousActive && !currentActive { continue }
                if currentActive == previousActive &&
                    app.version.compare(previous.version, options: .numeric) != .orderedDescending { continue }
            }
            selected[app.identifier] = app
        }
        return selected.values.sorted { $0.name < $1.name }
    }
}
