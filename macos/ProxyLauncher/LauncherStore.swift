import AppKit
import Foundation

/// All mutations are serialized by the channel. Only bundles created under
/// this directory can be replaced or moved to Trash.
final class LauncherStore {
    let directory: URL
    let helper: URL
    private let files = FileManager.default

    init(directory: URL, helper: URL) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.helper = helper
    }

    func configurations() throws -> [(URL, LauncherConfiguration)] {
        guard files.fileExists(atPath: directory.path) else { return [] }
        return try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { $0.pathExtension == "app" && !$0.lastPathComponent.hasPrefix(".") }
            .map { url in
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw LauncherError.invalid("A managed launcher cannot be a symbolic link.")
                }
                let data = try Data(contentsOf: url.appendingPathComponent("Contents/Resources/\(LauncherConfiguration.fileName)"))
                let config = try JSONDecoder().decode(LauncherConfiguration.self, from: data).validated()
                let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                guard info?["CFBundleIdentifier"] as? String == LauncherConfiguration.bundlePrefix + config.id.lowercased() else {
                    throw LauncherError.invalid("Unrecognized application in the launcher directory.")
                }
                return (url, config)
            }.sorted { $0.1.name.localizedStandardCompare($1.1.name) == .orderedAscending }
    }

    func find(_ id: String) throws -> (URL, LauncherConfiguration) {
        guard let entry = try configurations().first(where: { $0.1.id == id }) else {
            throw LauncherError.invalid("Launcher no longer exists. Refresh the list.")
        }
        return entry
    }

    func save(_ input: LauncherConfiguration, creating: Bool) throws -> (URL, LauncherConfiguration) {
        let config = try input.validated()
        let target = try config.targetBundle()
        let entries = try configurations()
        let previous = entries.first { $0.1.id == config.id }
        guard creating ? previous == nil : previous != nil else {
            throw LauncherError.invalid("Launcher changed. Refresh the list before saving.")
        }
        guard files.isExecutableFile(atPath: helper.path) else {
            throw LauncherError.invalid("This build is missing the proxy launcher helper.")
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        // Retain the path on edits so Dock aliases keep opening the same app.
        let destination = previous?.0 ?? directory.appendingPathComponent("\(config.name) - \(config.id.prefix(8)).app")
        guard previous != nil || !files.fileExists(atPath: destination.path) else {
            throw LauncherError.invalid("The launcher destination already exists.")
        }
        let stage = directory.appendingPathComponent(".staging-\(UUID().uuidString).app")
        defer { try? files.removeItem(at: stage) }
        let contents = stage.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        let executables = contents.appendingPathComponent("MacOS")
        try files.createDirectory(at: resources, withIntermediateDirectories: true)
        try files.createDirectory(at: executables, withIntermediateDirectories: true)
        try files.copyItem(at: helper, to: executables.appendingPathComponent("ProxyLauncher"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: resources.appendingPathComponent(LauncherConfiguration.fileName))
        var info: [String: Any] = [
            "CFBundleIdentifier": LauncherConfiguration.bundlePrefix + config.id.lowercased(),
            "CFBundleName": config.name,
            "CFBundleDisplayName": config.name,
            "CFBundleExecutable": "ProxyLauncher",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "LSUIElement": true,
            "LSMinimumSystemVersion": Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String ?? "12.0",
        ]
        if let iconName = target.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           !iconName.contains("/"),
           let icon = target.url(forResource: (iconName as NSString).deletingPathExtension,
                                 withExtension: (iconName as NSString).pathExtension.isEmpty ? "icns" : (iconName as NSString).pathExtension) {
            try files.copyItem(at: icon, to: resources.appendingPathComponent("AppIcon.icns"))
            info["CFBundleIconFile"] = "AppIcon.icns"
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        for args in [["--force", "--sign", "-", "--timestamp=none", stage.path],
                     ["--verify", "--strict", stage.path]] {
            let result = try launcherCommand("/usr/bin/codesign", args)
            guard result.0 == 0 else { throw LauncherError.invalid("Launcher signing failed: \(result.1)") }
        }
        if previous != nil {
            _ = try files.replaceItemAt(destination, withItemAt: stage)
        } else {
            try files.moveItem(at: stage, to: destination)
        }
        return (destination, config)
    }

    func trash(_ id: String) throws {
        let (url, _) = try find(id)
        try files.trashItem(at: url, resultingItemURL: nil)
    }
}
