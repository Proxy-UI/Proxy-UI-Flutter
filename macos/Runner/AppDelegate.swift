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
  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      for window in sender.windows {
        window.setIsVisible(true)
        window.makeKeyAndOrderFront(self)
      }
      sender.activate(ignoringOtherApps: true)
    }
    return true
  }
}
