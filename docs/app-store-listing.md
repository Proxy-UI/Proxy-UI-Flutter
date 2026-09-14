# CipherRelay App Store listing

Name: **CipherRelay**. Chinese product name: **密流**.
Suggested category: Utilities. The category describes the utility; it does not
change the Network Extension implementation or resolve App Review guideline 5.4.

Primary locale: English (US). Support:
<https://github.com/Proxy-UI/Proxy-UI-Flutter/issues>.
The first submission is free in Hong Kong, the United States, Canada and Singapore.
The app does not bundle servers, paid node access, or node subscriptions.

## English description

CipherRelay is a proxy client for servers you host and control. A compatible
server and your own connection configuration are required for actual connections.

Use CipherRelay to manage server connections, configure traffic routing, and
inspect local connection logs. CipherRelay does not provide servers, bundled
proxy nodes, or node subscriptions. An explicitly labelled offline demo lets you
explore sample configuration and node interactions without a server or a VPN
connection. Demo status and events are simulated.

Encryption is available for the configured proxy connection between your Mac
and your server. Direct routes and direct UDP fallback are outside that
encrypted connection. Protection between your server and the destination
depends on the destination protocol, such as HTTPS.

The Mac App Store edition uses Apple Network Extension to route system traffic
and requires macOS VPN permission for actual connections. It runs in the App Sandbox.

Keywords: `proxy,self-hosted,encryption,network,server,SOCKS,HTTP`

## 中文描述

CipherRelay（密流）是连接自建服务器的代理客户端。你需要自行部署兼容的服务器，
并提供自己的连接配置才能建立真实连接。离线演示使用示例数据，
可体验配置和节点交互，不连接服务器或启动 VPN；演示状态与事件均为模拟。

你可以管理服务器连接、配置流量路由和查看本地连接日志。本应用不提供服务器、
预置代理节点或节点订阅。

相应加密配置启用后，可加密 Mac 与代理服务器之间的代理连接。直连分流和 UDP
直连回退不在这段加密连接的保护范围内。服务器到目标站点的保护取决于 HTTPS 等
目标协议。

Mac App Store 版本通过 Apple Network Extension 转发系统流量，需要 macOS VPN
授权，应用本身运行在 App Sandbox 内。

## Submitted review material

Version **1.2.16 (42)** was submitted on **14 September 2026**. At submission,
App Store Connect confirmed **Waiting for Review**. This records a submission,
not approval; consult App Store Connect for the current review state.

- Three 1440×900 screenshots show the actual offline demo widgets. They are
  rendered headlessly by `tool/render_store_screenshots_test.dart`, without
  starting the native app or a system VPN.
- The published [privacy policy](https://github.com/Proxy-UI/Proxy-UI-Flutter/blob/main/docs/privacy-policy.md)
  matches the first-use disclosure and the App Store privacy declaration.
  The Store edition disables external GeoIP queries, database downloads and
  LAN configuration sharing. User-selected endpoints still receive connection
  traffic; the connection test may request `www.gstatic.com/generate_204`.
- The encryption questionnaire declares standard cryptography beyond the Apple
  operating system and no distribution in France. Reassess the answers when
  the implementation or distribution territories change.
- Review notes explicitly disclose that there is no dedicated review server.
  The maintainer chose to attempt review with the offline demo and accepts that
  Apple may require additional access or reject the submission.
- Publishing remains manual after approval.

## Offline review instructions

1. On first launch, choose **Explore demo** on the privacy screen. No privacy
   acknowledgement or VPN permission is needed to enter the demo.
2. Edit the sample hostname, then add, select or remove sample nodes.
3. Use **Simulate connection / Simulate disconnection** and inspect the demo
   event log. The main toolbar also offers the play-circle demo button.

All demo state stays in memory and is discarded when the screen closes. The
page does not forward traffic, make network requests, install a VPN configuration
or change saved settings. It demonstrates a subset of interactions and does not
validate real forwarding. Actual connections require a compatible user-owned
server and use `NETunnelProviderManager` with the embedded Packet Tunnel extension.

System-level Network Extension behavior still requires validation on an
independent device. Do not run VPN tests on the maintainer's work Mac or alter
its iOA, routes, DNS or system proxy. A self-hosted-server description and a
Utilities category do not establish an exception to Apple's review requirements.
