import Foundation
import NetworkExtension
import os

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.proxyui.PacketTunnel", category: "proxy-core")
  private let stateQueue = DispatchQueue(label: "com.proxyui.packet-tunnel.state", autoreleaseFrequency: .workItem)
  private let readerQueue = DispatchQueue(label: "com.proxyui.packet-tunnel.reader", qos: .userInitiated)
  private var tunnel: OpaquePointer?
  private var generation: UInt64 = 0
  private var starting: ((Error?) -> Void)?
  private var stopping = false
  private var stopCompletions: [() -> Void] = []
  private let trafficLock = NSLock()
  private var receivedBytes: UInt64 = 0
  private var sentBytes: UInt64 = 0
  private var receivedPackets: UInt64 = 0
  private var sentPackets: UInt64 = 0
  private var droppedPackets: UInt64 = 0
  private var diagnosticsTimer: DispatchSourceTimer?
  private var diagnosticsURL: URL?
  private var peakFootprint: UInt64 = 0
  private var startedAt = Date()
  private var activeProbes = 0

  // Probe sockets must originate in the provider. A containing-app probe is
  // captured by this VPN and measures selected-node -> candidate-node instead.
  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
    guard let completion = completionHandler else { return }
    let respond: ([String: Any]) -> Void = { value in
      completion(try? JSONSerialization.data(withJSONObject: value))
    }
    guard messageData.count <= 4096,
      let request = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
      request["operation"] as? String == "probeNode",
      let host = request["host"] as? String, !host.isEmpty, host.utf8.count <= 253,
      !host.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      let port = request["port"] as? Int, (1...65535).contains(port),
      let protocolVersion = request["protocol"] as? Int, [0, 3].contains(protocolVersion),
      let timeoutMs = request["timeoutMs"] as? Int, (1...30000).contains(timeoutMs)
    else { respond(["success": false, "error": "Invalid node probe request"]); return }
    stateQueue.async {
      guard self.tunnel != nil, !self.stopping, self.starting == nil, self.activeProbes < 32 else {
        respond(["success": false, "error": "VPN is unavailable or node probes are busy"])
        return
      }
      let generation = self.generation
      self.activeProbes += 1
      // The same async runtime used by desktop/Android owns the sockets. Do
      // not park a GCD worker per node or serialize a catalogue behind four
      // unresponsive nodes. The app admits 16; leave room for a separate test.
      ProviderNodeProbe.start(host: host, port: UInt16(port), timeoutMs: UInt32(timeoutMs),
                              protocolVersion: Int32(protocolVersion)) { value in
        self.stateQueue.async {
          self.activeProbes -= 1
          guard generation == self.generation, !self.stopping else {
            respond(["success": false, "error": "VPN changed while probing the node"])
            return
          }
          respond(value)
        }
      }
    }
  }

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
        self.diagnosticsURL = cache.appendingPathComponent("packet-tunnel-status.json")
        self.startedAt = Date()
        self.peakFootprint = 0
        self.trafficLock.lock()
        self.receivedBytes = 0
        self.sentBytes = 0
        self.receivedPackets = 0
        self.sentPackets = 0
        self.droppedPackets = 0
        self.trafficLock.unlock()
        proxy_set_log_callback { level, message in
          guard let message = message else { return }
          // Rust worker threads have no Cocoa run loop to drain temporary
          // Objective-C objects created by bridging and unified logging.
          autoreleasepool {
            let line = String(cString: message)
            proxy_free_string(UnsafeMutablePointer(mutating: message))
            if level >= 4 { PacketTunnelProvider.logger.error("\(line, privacy: .private)") }
            else if level >= 3 { PacketTunnelProvider.logger.warning("\(line, privacy: .private)") }
            else { PacketTunnelProvider.logger.info("\(line, privacy: .private)") }
          }
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
            self.startDiagnostics()
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
          self.trafficLock.lock()
          if result == 0 {
            self.receivedBytes += UInt64(packet.count)
            self.receivedPackets += 1
          } else if result == 1 { self.droppedPackets += 1 }
          self.trafficLock.unlock()
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
        // This dispatch block lives for the entire VPN session. Its default
        // pool would retain bridged NSData/NSArray objects until disconnect,
        // crossing iOS's 50 MB extension limit during ordinary downloads.
        let written = autoreleasepool {
          let packet = Data(buffer.prefix(Int(length)))
          let family: Int32 = buffer[0] >> 4 == 6 ? AF_INET6 : AF_INET
          return self.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: family)])
        }
        if !written { break }
        self.trafficLock.lock()
        self.sentBytes += UInt64(length)
        self.sentPackets += 1
        self.trafficLock.unlock()
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
    stateQueue.async {
      Self.logger.notice("VPN stop reason: \(reason.rawValue, privacy: .public)")
      self.stopSession(completion: completionHandler)
    }
  }

  private func startDiagnostics() {
    let timer = DispatchSource.makeTimerSource(queue: stateQueue)
    timer.schedule(deadline: .now(), repeating: .seconds(5))
    timer.setEventHandler { [weak self] in self?.recordDiagnostics(running: true) }
    diagnosticsTimer = timer
    timer.resume()
  }

  // Only aggregate counts are persisted; no destinations, credentials or packet
  // contents. The latest snapshot remains readable after an OS memory kill.
  private func recordDiagnostics(running: Bool) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    let footprint = result == KERN_SUCCESS ? info.phys_footprint : 0
    peakFootprint = max(peakFootprint, footprint)
    trafficLock.lock()
    var snapshot: [String: Any] = [
      "running": running, "pid": ProcessInfo.processInfo.processIdentifier,
      "uptimeSeconds": Date().timeIntervalSince(startedAt),
      "receivedBytes": receivedBytes, "receivedPackets": receivedPackets,
      "sentBytes": sentBytes, "sentPackets": sentPackets,
      "droppedPackets": droppedPackets,
      "footprintBytes": footprint, "peakFootprintBytes": peakFootprint,
    ]
    trafficLock.unlock()
    if let handle = tunnel, let stats = proxy_packet_tunnel_routing_stats(handle) {
      defer { proxy_free_string(stats) }
      if let data = String(cString: stats).data(using: .utf8),
        let routing = try? JSONSerialization.jsonObject(with: data) {
        snapshot["routing"] = routing
      }
    }
    if let url = diagnosticsURL, let data = try? JSONSerialization.data(withJSONObject: snapshot, options: .sortedKeys) {
      try? data.write(to: url, options: .atomic)
    }
    Self.logger.info("VPN footprint bytes: \(footprint, privacy: .public)")
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
    diagnosticsTimer?.cancel()
    diagnosticsTimer = nil
    recordDiagnostics(running: false)
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

/// A native batch owns copied target strings and delivers exactly once. The
/// retained context lives until that callback, including a tunnel stop; the
/// provider checks its generation before returning the result to the app.
private final class ProviderNodeProbe {
  private let completion: ([String: Any]) -> Void

  private init(_ completion: @escaping ([String: Any]) -> Void) {
    self.completion = completion
  }

  static func start(host: String, port: UInt16, timeoutMs: UInt32, protocolVersion: Int32,
                    completion: @escaping ([String: Any]) -> Void) {
    let context = Unmanaged.passRetained(ProviderNodeProbe(completion))
    let token = UInt64(UInt(bitPattern: context.toOpaque()))
    var port = port
    let status = host.withCString { host in
      var pointer: UnsafePointer<CChar>? = host
      return proxy_probe_nodes_v1(&pointer, &port, 1, 1, timeoutMs, protocolVersion, { token, _, result in
        guard let address = UnsafeRawPointer(bitPattern: UInt(token)) else { return }
        let context = Unmanaged<ProviderNodeProbe>.fromOpaque(address).takeRetainedValue()
        guard let result = result else {
          context.completion(["success": false, "error": "Node probe returned no result"])
          return
        }
        defer { proxy_release_node_probe_result(result) }
        let probe = result.pointee
        autoreleasepool {
          context.completion([
            "success": probe.success == 1,
            "countryCode": probe.country_code.map { String(cString: $0) } ?? "",
            "egressIp": probe.egress_ip.map { String(cString: $0) } ?? "",
            "latencyMs": probe.latency_ms,
            "error": probe.error.map { String(cString: $0) } as Any? ?? NSNull(),
          ])
        }
      }, token)
    }
    if status != 0 {
      // Rejected batches never invoke their callback.
      context.release()
      completion(["success": false, "error": "Cannot start the node probe (\(status))"])
    }
  }
}
