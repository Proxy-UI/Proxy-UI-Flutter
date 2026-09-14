# CipherRelay — Mac App Store Privacy Policy

Effective date: 14 September 2026. Applies to version 1.2.16, build 42 and later.

## Privacy and your connection

Before you use CipherRelay, learn what stays on your Mac and what is sent over the network. This policy applies to the Mac App Store edition.

### Data on your Mac

Server addresses, connection keys, settings and cached node lists are saved in the app’s sandbox preferences. A copy of the current tunnel configuration is stored in the macOS Keychain for the extension. Connection diagnostics and DNS mappings may contain destination hostnames or IP addresses. Logs stay local; log files are pruned by age (three days) and size when the app runs.

### Network connections you choose

When you connect, traffic is handled on your device and forwarded to the server you configure or directly to its destination, according to your settings. Your server operator can receive your source IP and destination information; choose a server you trust. DNS uses the configured network resolver where needed. Refreshing a node list contacts your configured catalogue server. A connection test contacts the selected server and may request www.gstatic.com/generate_204. These operations reveal normal connection information to those endpoints. The Store edition does not send destinations to a geographic lookup service or download a geographic database.

### Encryption and data collection

Encryption with your configured key protects the supported proxy connection between your Mac and your server. Direct traffic and direct UDP fallback are outside that encrypted connection; destination protection depends on protocols such as HTTPS. CipherRelay has no advertising or analytics SDK and no developer-operated traffic collection endpoint. The developer does not collect, sell, or use your traffic for analytics or disclose it to third parties. Your chosen server and destination services remain responsible for their own data handling.

### Your choices

No tunnel starts just because you read this notice. You choose when to connect and grant the macOS VPN permission. Disconnect to stop this app’s tunnel. You can edit or clear saved server settings in the app and remove the VPN configuration in macOS settings. Local files can be managed from the app’s log folder and sandbox container. Do not include connection keys or unredacted logs in public support reports.

Developer: JIANBO LIU. Policy updated: 14 September 2026. Support: https://github.com/Proxy-UI/Proxy-UI-Flutter/issues (GitHub handles data you choose to submit under its own privacy policy).

## 隐私与连接说明

使用 CipherRelay 前，请了解哪些信息保存在 Mac 上、哪些会通过网络发送。本说明适用于 Mac App Store 版本。

### 保存在 Mac 上的数据

服务器地址、连接密钥、设置和缓存节点列表保存在应用沙盒的偏好设置中。当前隧道配置的副本保存在 macOS 钥匙串，供扩展使用。连接诊断和 DNS 映射可能包含目标域名或 IP 地址。日志仅保存在本地；应用运行时会按时间（三天）和容量清理日志文件。

### 由你选择的网络连接

连接后，流量在设备上处理，并按你的配置转发到指定服务器或直达目标。服务器运营者可能获知你的来源 IP 和目标信息，请选择可信的服务器。需要时会使用网络配置的 DNS 解析器。刷新节点列表会连接你配置的节点目录服务器；连接测试会联系所选服务器，并可能访问 www.gstatic.com/generate_204。这些端点会收到正常连接所需的信息。商店版不会向地域查询服务发送目标地址，也不会下载地域数据库。

### 加密与数据收集

配置密钥后的加密保护 Mac 与自建服务器之间受支持的代理连接。直连流量和 UDP 直连回退不在这段加密连接的保护范围内，目标站点的保护取决于 HTTPS 等协议。CipherRelay 不包含广告或分析 SDK，也没有由开发者运营的流量收集端点。开发者不会收集、出售、将你的流量用于分析或向第三方披露；你选择的服务器和目标服务分别负责其自身的数据处理。

### 你的选择

阅读本说明不会启动隧道。连接由你主动发起，并由你授予 macOS VPN 权限。断开连接即可停止本应用的隧道。你可以在应用中修改或清空保存的服务器设置，并在 macOS 设置中移除 VPN 配置。本地文件可通过应用日志目录和沙盒容器管理。请勿在公开支持反馈中包含连接密钥或未经脱敏的日志。

开发者：JIANBO LIU。更新日期：2026 年 9 月 14 日。支持：https://github.com/Proxy-UI/Proxy-UI-Flutter/issues（你主动提交给 GitHub 的信息受其隐私政策约束）。

