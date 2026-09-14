#!/usr/bin/env python3
"""Check a store app's structure, signed sandbox policy and embedded provider."""
import argparse
import json
import datetime
import fnmatch
from pathlib import Path
import plistlib
import subprocess

def run(*args):
    return subprocess.check_output([str(arg) for arg in args], stderr=subprocess.STDOUT)

def require(condition, message):
    if not condition:
        raise ValueError(message)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--unsigned', action='store_true')
    args = parser.parse_args()
    app = args.app.resolve()
    extension = app / 'Contents/PlugIns/PacketTunnel.appex'
    main_info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    extension_info = plistlib.loads((extension / 'Contents/Info.plist').read_bytes())
    require(main_info['CFBundleIdentifier'] == 'com.proxyui.proxyUi.store', 'wrong store app identifier')
    require(extension_info['CFBundleIdentifier'] == main_info['CFBundleIdentifier'] + '.PacketTunnel', 'Store bundle validation failed')
    require(extension_info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.networkextension.packet-tunnel', 'Store bundle validation failed')
    for info in [main_info, extension_info]:
        require(bool(info.get('CFBundleDisplayName', '').strip()), 'CFBundleDisplayName is required for the app and extension')
    for key in ['CFBundleShortVersionString', 'CFBundleVersion']:
        require(main_info[key] == extension_info[key], f'app and extension {key} differ')
    require(not list(app.rglob('http-proxy-tun-helper')), 'privileged helper in store bundle')
    library = app / 'Contents/Frameworks/libhttp_proxy.dylib'
    require(b'_proxy_packet_tunnel_create' in run('nm', '-gU', library), 'wrong native library feature')
    binaries = [app / 'Contents/MacOS' / main_info['CFBundleExecutable'], extension / 'Contents/MacOS' / extension_info['CFBundleExecutable'], library]
    arches = [set(run('lipo', '-archs', path).decode().split()) for path in binaries]
    require(arches[0] == arches[1] == arches[2], 'app, extension and core architectures differ')
    if not args.unsigned:
        policies = []
        for bundle in [app, extension]:
            raw = run('codesign', '-d', '--entitlements', ':-', bundle)
            start = raw.index(b'<?xml')
            policy = plistlib.loads(raw[start:])
            require(policy.get('com.apple.security.app-sandbox') is True, 'App Sandbox is missing')
            require('packet-tunnel-provider' in policy.get('com.apple.developer.networking.networkextension', []), 'Store bundle validation failed')
            require(policy.get('keychain-access-groups'), 'shared Keychain entitlement is missing')
            require((bundle / 'Contents/embedded.provisionprofile').exists(), 'VPN provisioning profile is missing')
            profile = plistlib.loads(run('security', 'cms', '-D', '-i', bundle / 'Contents/embedded.provisionprofile'))
            require(profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Provisioning profile expired')
            allowed = profile['Entitlements']
            require('packet-tunnel-provider' in allowed.get('com.apple.developer.networking.networkextension', []), 'Profile does not allow Packet Tunnel')
            team = policy.get('com.apple.developer.team-identifier')
            require(team in profile.get('TeamIdentifier', []), 'Signing team differs from profile')
            for group in policy['keychain-access-groups']:
                require(any(fnmatch.fnmatchcase(group, pattern) for pattern in allowed.get('keychain-access-groups', [])), 'Profile does not allow the Keychain group')
            info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
            require(info['ProxyUIKeychainAccessGroup'] in policy['keychain-access-groups'], 'Runtime Keychain group differs from signing entitlement')
            policies.append(policy)
        require(policies[0]['com.apple.developer.team-identifier'] == policies[1]['com.apple.developer.team-identifier'], 'App and provider teams differ')
        require(set(policies[0]['keychain-access-groups']) & set(policies[1]['keychain-access-groups']), 'App and provider cannot share credentials')
        run('codesign', '--verify', '--deep', '--strict', app)
    print(json.dumps({'app': str(app), 'version': main_info['CFBundleShortVersionString'], 'build': main_info['CFBundleVersion'], 'architectures': sorted(arches[0]), 'signature_and_entitlements_verified': not args.unsigned}, indent=2))
if __name__ == '__main__':
    main()
