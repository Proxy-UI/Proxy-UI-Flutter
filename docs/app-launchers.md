# 应用代理 / App proxies

macOS 直装版和 Windows 的侧边栏提供 **应用代理 / App proxies**。
先连接 CipherRelay，无需 TUN。Claude 优先使用原生配置，Codex 及其他应用使用启动器。

**一键配置常用应用** 自动识别已安装的 Claude 和 Codex：

- 新配置使用当前 **Proxy 配置的 `localPort`**，没有固定的 `10801`。
  编辑页可以手动指定端口，或点击 **使用当前 Proxy 端口**。
  端口按应用保存；修改 Proxy 端口后，用该按钮同步已有应用，再保存。
- 默认直连规则为 `*oa*`、`.oa.com` 和 `.woa.com`，可按应用编辑、清空或恢复默认。
- 支持原生代理配置的 Claude（1.44121.1 或更新版本）自动迁移为原生配置，
  保留此前的端口和规则，旧的生成启动器移至废纸篓/回收站。
- Codex 保留启动器及其现有路径，Dock 或桌面快捷方式继续有效。
- 重复点击保留已有配置；单个应用失败不影响其他应用。不会自动重启目标应用。

macOS 按应用包标识识别（包括应用名称为 ChatGPT 的 Codex），
查找 `/Applications` 和 `~/Applications`，优先正在运行的安装，否则选较新版本。
Windows 查找常见安装目录、卸载注册信息和当前用户的 MSIX 安装。
较旧的 Claude 以及其他不支持原生配置的应用仍可使用通用启动器。

## Claude 原生配置 / Native Claude configuration

保存后完整退出 Claude，再点击原来的 Claude 图标即可，无需独立启动器。
使用期间保持 CipherRelay 运行（关闭窗口至托盘不影响；退出进程会停止规则入口）。

CipherRelay 只合并当前 Claude 配置的 `egressProxyUrl` / `egressProxyPacUrl`，
不更改登录、模型服务、MCP 或其他设置。不覆盖组织托管策略；存在托管策略时提示错误。
配置位置为 macOS 的 `~/Library/Application Support/Claude-3p/configLibrary/`
或 Windows 的 `%LOCALAPPDATA%\Claude-3p\configLibrary/`，通过 `_meta.json` 找到当前配置。
配置写入使用同目录临时文件再替换，macOS 文件权限为 `0600`。

Claude 的 agent 只接收一个固定代理，不会逐个请求执行 PAC。
因此原生配置指向 CipherRelay 管理的 **仅监听回环地址** 的应用规则入口：
它统一检查窗口和 agent 请求的目标主机，匹配的请求直连，其余转发到 UI 所选的
当前本地代理端口。规则入口端口由系统分配并持久化，与用户选择的上游代理端口不同。
HTTPS 使用透明 CONNECT 隧道，不解密 TLS；上游失败不会自动转为直连。
启动 CipherRelay 时恢复规则入口；端口冲突会显示错误，编辑并保存可修复。

应用代理状态保存在 `CipherRelay/AppProxies/claude-native.json`（macOS 位于
`~/Library/Application Support/`，Windows 位于 `%LOCALAPPDATA%`）。
只备份原有两个代理字段，不复制 Claude 的凭证或完整配置。
**移除代理配置** 会恢复保存前的代理字段；如果用户随后修改了其中任一字段，
保留整组外部代理设置，避免 PAC 优先级覆盖新设置。移除后需重启 Claude。

See [Claude native proxy behavior](https://claude.com/docs/third-party/claude-desktop/network-proxy)
and [configuration sources](https://claude.com/docs/third-party/claude-desktop/configuration).
Claude's updater and externally launched browsers follow their own proxy settings.

## Codex 和通用启动器 / Codex and generic launchers

添加应用、确认模式/端口/规则后点击 **保存并生成**。完全退出目标应用，
再通过启动器打开。macOS 可拖到 Dock，Windows 可复制快捷方式到桌面。
编辑保留生成路径，不影响已有快捷方式；移除只回收生成文件，不删除目标应用。

The page manages per-app proxy settings. New entries take the current Proxy
configuration's local port; it is not hard-coded. Ports and bypass rules remain
independently editable. Supported Claude versions use native settings and a
loopback-only router for consistent app/agent host filtering. Codex retains its
launcher. Keep CipherRelay running; restart the target app after first applying
its configuration. Native removal restores only owned proxy settings and
preserves later external edits.

## 规则语义 / Bypass semantics

“过滤”表示 **绕过代理、直接连接**，不是禁止访问。
Claude 原生模式下，所有规则（包括任意主机通配符）同时用于窗口和内部 agent。
下表仅描述通用启动器模式的差异。
规则匹配 URL 的主机名，不检查网页正文、路径或查询参数。

| 规则 / Rule | Chromium / Electron 页面 | 后台 `NO_PROXY` |
| --- | --- | --- |
| `*oa*`（默认） | 主机名包含 `oa` 时直连 | 不传递，缺乏通用支持 |
| `.oa.com`、`.woa.com`（默认） | 域名及其子域名直连 | 传递域名后缀 |
| `example.com` | 该主机直连 | 传递；客户端可能同时匹配子域名 |
| `*.example.com` | 子域名直连 | 转换为 `.example.com` |
| `*` | 全部直连 | 全部直连 |

每行一个主机规则，最多 200 条。不接受 URL、路径、端口限制、CIDR 或命令。
本机 `localhost`、`127.0.0.1` 和 `::1` 始终直连。
清空规则只移除用户规则；恢复默认会还原上述三条 OA 规则。

Default rules are `*oa*`, `.oa.com` and `.woa.com`. Arbitrary host globs apply
only to Chromium/Electron's browser networking in launcher mode. Claude native
mode applies all host rules at its routing entry point, including agent traffic. Compatible hosts and suffixes
are exported through `NO_PROXY` for background HTTP clients, whose matching
semantics vary. In environment-only mode, `*oa*` has no effect.
See [Chromium's proxy documentation](https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md)
and [libcurl's NO_PROXY semantics](https://curl.se/libcurl/c/CURLOPT_NOPROXY.html).

Chromium / Electron 模式同时传递 `--proxy-server`、
`--proxy-bypass-list` 和代理环境变量。选择器根据 Electron/Chromium 文件
推测默认模式，可以手动修改。其他应用可选 **仅代理环境变量**。
应用必须支持这些参数或变量；此功能不保证接管不支持代理的流量，
也不会覆盖应用自身的企业策略或专有代理设置。

## 文件和生命周期 / Files and lifecycle

- macOS：`~/Applications/CipherRelay Launchers/` 下的独立 `.app`。
  Xcode 构建时编译辅助程序并随 CipherRelay 分发，生成时复制、签名并校验；
  用户电脑不需要 Swift 编译器。配置在生成包的 `Contents/Resources/launcher.json`。
  在同一目录暂存后替换，保存失败时保留原包。
- Windows：`%LOCALAPPDATA%\CipherRelay\ProxyLaunchers\<id>\` 保存 JSON、
  PowerShell 辅助脚本和 `.lnk`。无需额外安装 PowerShell。
  快捷方式通过系统 Windows PowerShell 启动；不修改系统或用户环境变量。
  企业策略若禁止 PowerShell 或 COM，此功能可能无法使用。
- 保存后必须完全退出并重开目标应用。Windows 对运行中的应用提示退出；
  macOS 对 Chromium 启动参数匹配的运行实例直接激活，否则提示退出。
  启动器不终止用户进程。
- 启动前探测本机端口；未监听时提示先连接 CipherRelay。
  探测仅确认 TCP 端口开放，不代表代理上游已连通。
- 移除会把生成的启动器移入废纸篓/回收站，不删除目标应用及其数据。
  手工创建的旧启动器不会自动导入或修改。
- Linux、移动端和 Mac App Store 沙盒版不显示此入口。

## 开发验证 / Development verification

从 Flutter 子仓库运行：

```sh
fvm flutter analyze --no-fatal-infos
fvm flutter test
fvm flutter build macos --debug
python3 scripts/macos/test_proxy_launcher.py
python3 scripts/test_windows_proxy_launcher.py
```

macOS 原生测试生成临时签名启动器，实际启动无界面的测试应用，验证路径转义、
环境变量、浏览器参数、独立配置、原位更新和失败保留；结束后清理测试文件。
Windows 脚本测试在 Windows 上验证真实 COM 快捷方式创建和编辑，并把自己的
测试启动器移到回收站。在其他系统上需设置 `POWERSHELL=/path/to/pwsh`，
验证语法、参数与规则转换（原生配置文件和本机路由由跨平台 Dart 测试覆盖），Win32 进程枚举被测试替身替换，COM 测试明确跳过。
这不能替代 Windows 桌面端到端验收。

Windows CI 会运行真实 COM 快捷方式测试、跨平台配置与路由测试；仓库内 PR
还会使用校验过 SHA-256 的原生发布库构建桌面应用，并检查 DLL 和启动器脚本齐全。
CI 构建仅用于验证，不发布安装包，也不替代 Claude / Codex 的交互式实机验收。

完整 Windows 构建从父仓库使用 `scripts/windows/build.ps1`，
确认 `CipherRelay.exe`、`http_proxy.dll`、`wintun.dll` 和 `data` 完整。
