import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  #if MAC_APP_STORE
  private let vpnController = MacAppStoreVpnController()
  #endif
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    #if MAC_APP_STORE
    vpnController.register(with: flutterViewController)
    #endif

    super.awakeFromNib()
  }
}
