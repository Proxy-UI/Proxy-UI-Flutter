import AppKit
import FlutterMacOS

/// App-proxy settings, detection and launchers live in the native core. The
/// page only asks AppKit for the icons it shows, which the core cannot draw.
final class ProxyLauncherChannel {
    func register(with controller: FlutterViewController) {
        let channel = FlutterMethodChannel(name: "proxy_ui/launchers", binaryMessenger: controller.engine.binaryMessenger)
        channel.setMethodCallHandler { call, reply in
            guard call.method == "icons" else {
                reply(FlutterMethodNotImplemented)
                return
            }
            let paths = (call.arguments as? [String: Any])?["paths"] as? [String] ?? []
            reply(Self.icons(paths))
        }
    }

    /// Finder's icon for each existing path as base64 PNG, drawn at twice the
    /// size the page shows so it stays sharp on Retina displays.
    private static func icons(_ paths: [String]) -> [String: String] {
        let side = 96
        var result: [String: String] = [:]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSWorkspace.shared.icon(forFile: path)
                .draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            result[path] = bitmap.representation(using: .png, properties: [:])?.base64EncodedString()
        }
        return result
    }
}
