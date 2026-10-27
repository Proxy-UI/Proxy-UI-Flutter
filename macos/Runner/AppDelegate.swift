import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Bring the window back when the app is reopened while hidden.
  ///
  /// Closing hides to the tray, which orders the window out. Without this the
  /// Dock icon and a second launch both do nothing, because AppKit only offers
  /// to reopen windows it still knows about, and the single-instance guard that
  /// handles this on Windows has no macOS counterpart.
  ///
  /// Minimizing to the tray leaves the window both miniaturized and ordered
  /// out, so it is deminiaturized rather than ordered back into the Dock. Only
  /// the main window is restored: the app's other windows belong to the status
  /// item and menus. Returning false keeps AppKit's own reopen handling from
  /// acting on the same window a second time.
  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    guard !flag, let window = mainFlutterWindow else { return true }
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
    sender.activate(ignoringOtherApps: true)
    return false
  }
}
