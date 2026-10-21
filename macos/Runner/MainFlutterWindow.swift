import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  #if MAC_APP_STORE
  private let vpnController = AppleVpnController()
  #else
  private let launcherChannel = ProxyLauncherChannel()
  #endif
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    #if MAC_APP_STORE
    vpnController.register(with: flutterViewController.engine.binaryMessenger)
    #else
    launcherChannel.register(with: flutterViewController)
    #endif

    super.awakeFromNib()
  }
}
