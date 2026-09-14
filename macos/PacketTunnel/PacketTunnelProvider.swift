import Foundation
import NetworkExtension
import os

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private static let logger = Logger(subsystem: "com.proxyui.proxyUi.store.PacketTunnel", category: "proxy-core")
  private let stateQueue = DispatchQueue(label: "com.proxyui.packet-tunnel.state")
  private let readerQueue = DispatchQueue(label: "com.proxyui.packet-tunnel.reader", qos: .userInitiated)
  private var tunnel: OpaquePointer?
  private var generation: UInt64 = 0
  private var starting: ((Error?) -> Void)?
  private var stopping = false
  private var stopCompletions: [() -> Void] = []

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    stateQueue.async {
      guard self.tunnel == nil, !self.stopping, self.starting == nil else {
        completionHandler(TunnelConfigurationStore.failure("The previous VPN session is still stopping."))
        return
      }
      self.generation &+= 1
      let generation = self.generation
      self.starting = completionHandler
      do {
        guard let config = self.protocolConfiguration as? NETunnelProviderProtocol,
          let reference = config.passwordReference
        else { throw TunnelConfigurationStore.failure("VPN configuration is missing. Reconnect from CipherRelay.") }
        let data = try TunnelConfigurationStore.load(reference: reference)
        guard let json = String(data: data, encoding: .utf8), !json.contains("\0") else {
          throw TunnelConfigurationStore.failure("Invalid VPN configuration encoding.")
        }
        let cache = try FileManager.default.url(for: .applicationSupportDirectory,
          in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ProxyUI", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        proxy_set_log_callback { level, message in
          guard let message = message else { return }
          let line = String(cString: message)
          proxy_free_string(UnsafeMutablePointer(mutating: message))
          // Endpoint metadata stays private in unified logging by default.
          if level >= 4 { PacketTunnelProvider.logger.error("\(line, privacy: .private)") }
          else if level >= 3 { PacketTunnelProvider.logger.warning("\(line, privacy: .private)") }
          else { PacketTunnelProvider.logger.info("\(line, privacy: .private)") }
        }
        proxy_set_log_level(2)
        proxy_init_logging()
        var nativeError: UnsafeMutablePointer<CChar>?
        let handle = json.withCString { jsonPtr in
          cache.path.withCString { pathPtr in proxy_packet_tunnel_create(jsonPtr, pathPtr, &nativeError) }
        }
        defer { if let error = nativeError { proxy_free_string(error) } }
        guard let handle = handle else {
          throw TunnelConfigurationStore.failure(nativeError.map { String(cString: $0) } ?? "Cannot start the proxy core.")
        }
        self.tunnel = handle
        self.setTunnelNetworkSettings(Self.networkSettings()) { error in
          self.stateQueue.async {
            guard generation == self.generation, !self.stopping else { return }
            if let error = error {
              self.finishStart(error)
              self.stopSession(completion: {})
              return
            }
            self.startReader(handle: handle, generation: generation)
            self.readPackets(generation: generation)
            self.finishStart(nil)
          }
        }
      } catch {
        self.finishStart(error)
      }
    }
  }

  private static func networkSettings() -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    let ipv4 = NEIPv4Settings(addresses: ["10.77.0.2"], subnetMasks: ["255.255.255.252"])
    ipv4.includedRoutes = [NEIPv4Route.default()]
    ipv4.excludedRoutes = [NEIPv4Route(destinationAddress: "224.0.0.0", subnetMask: "240.0.0.0")]
    settings.ipv4Settings = ipv4
    let ipv6 = NEIPv6Settings(addresses: ["fd77::2"], networkPrefixLengths: [64])
    ipv6.includedRoutes = [NEIPv6Route.default()]
    ipv6.excludedRoutes = [NEIPv6Route(destinationAddress: "ff00::", networkPrefixLength: 8)]
    settings.ipv6Settings = ipv6
    let dns = NEDNSSettings(servers: ["10.77.0.1"])
    dns.matchDomains = [""]
    settings.dnsSettings = dns
    settings.mtu = 1500
    return settings
  }

  private func readPackets(generation: UInt64) {
    packetFlow.readPackets { packets, protocols in
      self.stateQueue.async {
        guard self.generation == generation, !self.stopping, let handle = self.tunnel else { return }
        for (packet, family) in zip(packets, protocols) {
          // Rust validates the full envelope too. Never reinterpret a packet
          // whose family metadata disagrees with the header.
          guard let first = packet.first,
            (first >> 4 == 4 && family.int32Value == AF_INET)
              || (first >> 4 == 6 && family.int32Value == AF_INET6) else { continue }
          let result = packet.withUnsafeBytes { bytes in
            proxy_packet_tunnel_write(handle, bytes.bindMemory(to: UInt8.self).baseAddress, packet.count)
          }
          if result == -1 { return }
          // A full bounded queue drops packets; TCP retransmits. Do not enqueue
          // an unbounded chain of retry callbacks while the core is congested.
        }
        self.readPackets(generation: generation)
      }
    }
  }

  private func startReader(handle: OpaquePointer, generation: UInt64) {
    readerQueue.async {
      var buffer = [UInt8](repeating: 0, count: 1500)
      while true {
        let length = proxy_packet_tunnel_read(handle, &buffer, buffer.count)
        if length < 0 { break }
        if length == 0 { continue }
        let packet = Data(buffer.prefix(Int(length)))
        let family: Int32 = buffer[0] >> 4 == 6 ? AF_INET6 : AF_INET
        if !self.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: family)]) { break }
      }
      // This runs before the destruction barrier enqueued by stopSession.
      let errorPtr = proxy_packet_tunnel_last_error(handle)
      let message = errorPtr.map { String(cString: $0) } ?? "Packet forwarding stopped."
      if let errorPtr = errorPtr { proxy_free_string(errorPtr) }
      self.stateQueue.async {
        guard self.generation == generation, !self.stopping else { return }
        self.cancelTunnelWithError(TunnelConfigurationStore.failure(message))
        self.stopSession(completion: {})
      }
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    stateQueue.async { self.stopSession(completion: completionHandler) }
  }

  private func finishStart(_ error: Error?) {
    let completion = starting
    starting = nil
    completion?(error)
  }

  private func stopSession(completion: @escaping () -> Void) {
    stopCompletions.append(completion)
    if stopping { return }
    stopping = true
    generation &+= 1
    finishStart(URLError(.cancelled))
    guard let handle = tunnel else { finishStop(); return }
    proxy_packet_tunnel_cancel(handle)
    // All incoming calls are serialized on stateQueue and now gated off.
    // The barrier waits for the blocking reader before freeing native memory.
    readerQueue.async {
      proxy_packet_tunnel_destroy(handle)
      self.stateQueue.async { self.tunnel = nil; self.finishStop() }
    }
  }

  private func finishStop() {
    stopping = false
    let completions = stopCompletions
    stopCompletions.removeAll()
    completions.forEach { $0() }
  }
}
