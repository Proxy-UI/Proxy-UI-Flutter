#if MAC_APP_STORE
import Cocoa
import FlutterMacOS
import NetworkExtension

/// All state and Flutter completions are serialized on the main queue.
final class MacAppStoreVpnController: NSObject, FlutterStreamHandler {
  private var manager: NETunnelProviderManager?
  private var eventSink: FlutterEventSink?
  private var pendingResult: FlutterResult?
  private var operation: UInt64 = 0
  private var pendingStart = false
  private var sawConnecting = false
  private var timeout: Timer?
  private var observer: NSObjectProtocol?
  private var lastError: String?
  private let extensionIdentifier = Bundle.main.bundleIdentifier! + ".PacketTunnel"

  func register(with controller: FlutterViewController) {
    let methods = FlutterMethodChannel(name: "com.proxyui/macos_vpn", binaryMessenger: controller.engine.binaryMessenger)
    methods.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
    FlutterEventChannel(name: "com.proxyui/macos_vpn/events", binaryMessenger: controller.engine.binaryMessenger)
      .setStreamHandler(self)
    observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
      guard let self = self, let connection = note.object as? NEVPNConnection,
        connection === self.manager?.connection else { return }
      self.statusChanged()
    }
  }

  deinit {
    if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    timeout?.invalidate()
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    events(snapshot())
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? { eventSink = nil; return nil }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      guard pendingResult == nil else { result(busyError()); return }
      loadManager { error in
        if let error = error { result(self.flutterError(error)); return }
        self.statusChanged()
        result(self.snapshot())
      }
    case "start": start(call.arguments, result: result)
    case "stop": stop(result: result)
    case "openLogs":
      guard let path = call.arguments as? String else { result(FlutterError(code: "invalid_path", message: "Missing log folder.", details: nil)); return }
      // Only reveal this app's own support directory; the Dart caller cannot
      // turn this channel into an arbitrary filesystem opener.
      guard let support = try? FileManager.default.url(for: .applicationSupportDirectory,
        in: .userDomainMask, appropriateFor: nil, create: false),
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(support.resolvingSymlinksInPath().path + "/")
      else { result(FlutterError(code: "invalid_path", message: "Log folder is outside the application container.", details: nil)); return }
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func loadManager(_ completion: @escaping (Error?) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      DispatchQueue.main.async {
        if let error = error { completion(error); return }
        self.manager = managers?.first {
          ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.extensionIdentifier
        } ?? NETunnelProviderManager()
        completion(nil)
      }
    }
  }

  private func start(_ arguments: Any?, result: @escaping FlutterResult) {
    guard pendingResult == nil else { result(busyError()); return }
    guard let config = arguments as? [String: Any],
      let host = config["serverHost"] as? String, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let serverPort = config["serverPort"] as? Int, (1...65535).contains(serverPort),
      let localPort = config["localPort"] as? Int, (1...65535).contains(localPort),
      let data = try? JSONSerialization.data(withJSONObject: config), data.count <= 65536
    else { result(FlutterError(code: "invalid_config", message: "Invalid VPN configuration.", details: nil)); return }
    operation &+= 1
    pendingResult = result
    pendingStart = true
    sawConnecting = false
    lastError = nil
    loadManager { error in
      if let error = error { self.finish(error: error); return }
      guard let manager = self.manager else { self.finish(error: TunnelConfigurationStore.failure("VPN manager is unavailable.")); return }
      guard manager.connection.status == .disconnected || manager.connection.status == .invalid else {
        self.finish(error: TunnelConfigurationStore.failure("Disconnect the current VPN session before reconnecting.")); return
      }
      do {
        let reference = try TunnelConfigurationStore.save(data)
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = self.extensionIdentifier
        configuration.serverAddress = host
        configuration.passwordReference = reference
        // Credentials and complete proxy configuration stay in the Keychain.
        configuration.providerConfiguration = ["schemaVersion": 1]
        configuration.disconnectOnSleep = false
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "CipherRelay"
        manager.isEnabled = true
        manager.isOnDemandEnabled = false
        manager.saveToPreferences { error in
          DispatchQueue.main.async {
            if let error = error { self.finish(error: error); return }
            manager.loadFromPreferences { error in
              DispatchQueue.main.async {
                if let error = error { self.finish(error: error); return }
                do {
                  try manager.connection.startVPNTunnel()
                  self.armTimeout(seconds: 120)
                  self.statusChanged()
                } catch { self.finish(error: error) }
              }
            }
          }
        }
      } catch { self.finish(error: error) }
    }
  }

  private func stop(result: @escaping FlutterResult) {
    guard pendingResult == nil else { result(busyError()); return }
    operation &+= 1
    pendingResult = result
    pendingStart = false
    loadManager { error in
      if let error = error { self.finish(error: error); return }
      guard let connection = self.manager?.connection,
        connection.status != .disconnected, connection.status != .invalid else { self.finish(error: nil); return }
      connection.stopVPNTunnel()
      self.armTimeout(seconds: 30)
      self.statusChanged()
    }
  }

  private func armTimeout(seconds: TimeInterval) {
    timeout?.invalidate()
    timeout = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      guard let self = self else { return }
      if self.pendingStart { self.manager?.connection.stopVPNTunnel() }
      self.finish(error: TunnelConfigurationStore.failure("Timed out waiting for the system VPN connection."))
    }
  }

  private func statusChanged() {
    let status = manager?.connection.status ?? .invalid
    if status == .connecting { sawConnecting = true }
    eventSink?(snapshot())
    guard pendingResult != nil else { return }
    if pendingStart && status == .connected { finish(error: nil) }
    else if !pendingStart && (status == .disconnected || status == .invalid) { finish(error: nil) }
    else if pendingStart && sawConnecting && (status == .disconnected || status == .invalid) {
      let failedOperation = operation
      manager?.connection.fetchLastDisconnectError { error in
        DispatchQueue.main.async {
          guard self.operation == failedOperation, self.pendingResult != nil, self.pendingStart else { return }
          self.finish(error: error ?? TunnelConfigurationStore.failure("The VPN extension could not connect. Check the app and extension signing profiles."))
        }
      }
    }
  }

  private func snapshot() -> [String: Any] {
    let status = manager?.connection.status ?? .invalid
    return ["status": status.rawValue, "running": status == .connected || status == .reasserting,
      "busy": status == .connecting || status == .disconnecting, "error": lastError as Any? ?? NSNull()]
  }

  private func finish(error: Error?) {
    timeout?.invalidate()
    timeout = nil
    let result = pendingResult
    pendingResult = nil
    if let error = error { lastError = error.localizedDescription }
    eventSink?(snapshot())
    if let error = error { result?(flutterError(error)) } else { result?(snapshot()) }
  }

  private func flutterError(_ error: Error) -> FlutterError {
    FlutterError(code: "vpn_error", message: error.localizedDescription, details: nil)
  }

  private func busyError() -> FlutterError {
    FlutterError(code: "vpn_busy", message: "A VPN connection operation is already in progress.", details: nil)
  }
}
#endif
