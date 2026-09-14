import Foundation
import Security

/// Only an opaque Keychain reference is persisted in Network Extension preferences.
enum TunnelConfigurationStore {
  static let service = "com.proxyui.packet-tunnel.configuration"

  static func save(_ data: Data) throws -> Data {
    guard data.count <= 65536,
      let group = Bundle.main.object(forInfoDictionaryKey: "ProxyUIKeychainAccessGroup") as? String,
      !group.isEmpty, !group.contains("$(")
    else { throw failure("The shared Keychain signing configuration is missing.") }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "current",
      kSecAttrAccessGroup as String: group,
      kSecUseDataProtectionKeychain as String: true,
    ]
    let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if updated == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let status = SecItemAdd(item as CFDictionary, nil)
      guard status == errSecSuccess else { throw failure("Cannot save VPN configuration to Keychain (\(status)).") }
    } else if updated != errSecSuccess {
      throw failure("Cannot update VPN configuration in Keychain (\(updated)).")
    }
    var referenceQuery = query
    referenceQuery[kSecReturnPersistentRef as String] = true
    var reference: CFTypeRef?
    let status = SecItemCopyMatching(referenceQuery as CFDictionary, &reference)
    guard status == errSecSuccess, let data = reference as? Data else {
      throw failure("Cannot obtain the VPN Keychain reference (\(status)).")
    }
    return data
  }

  static func load(reference: Data) throws -> Data {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecValuePersistentRef as String: reference,
      kSecReturnData as String: true,
      kSecUseDataProtectionKeychain as String: true,
    ]
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    guard status == errSecSuccess, let data = value as? Data, data.count <= 65536 else {
      throw failure("Cannot read VPN configuration from Keychain (\(status)).")
    }
    return data
  }

  static func failure(_ message: String) -> NSError {
    NSError(domain: "com.proxyui.packet-tunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
