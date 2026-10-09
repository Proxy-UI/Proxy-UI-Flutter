# CipherRelay

跨平台加密代理客户端的 Flutter 图形界面。

## macOS 两个版本

CipherRelay（密流）是 Proxy UI 的新名称。直装版继续生成 `CipherRelay.app`，
保留系统代理、管理员 TUN helper、LAN 访问和进程旁路功能。独立的 `appstore`
构建目标生成 `CipherRelay.app`，通过沙盒内的 Packet Tunnel 扩展转发流量，
使用独立的应用 ID 和数据容器。详见 [商店版构建说明](docs/macos-app-store.md)。
商店版 1.2.16（42）已于 2026 年 9 月 14 日提交审核，尚未通过 App Review。

所有平台的显示名统一为 **CipherRelay**：Windows 程序为 `CipherRelay.exe`，
Linux 程序为 `CipherRelay`，iOS/macOS 应用包为 `CipherRelay.app`。
直装版和商店版仍使用独立应用 ID 和设置目录；需要并存时放在不同安装目录。
升级后重新建立仍指向 `proxy_ui` 的旧快捷方式。

应用 ID、Dart 内部包名、设置键、Windows 安装器 ID 和单实例/自启动标识保持不变。
交付文件统一采用 `cipherrelay-v<版本>-<构建号>-<平台>-<架构>.<扩展名>`，
Windows 安装器额外带 `-setup`。执行 `python3 scripts/release_artifact_name.py android arm64-v8a apk`
可生成对应交付文件名；其他平台参数见 [打包命名说明](README.md#application-and-package-names)。
移动端仍必须本机签名构建，Android 应用 ID 继续使用 `com.proxyui.proxy_ui`。

## 功能特性

- **安全传输 v2（1.2.18+44）**：需先将客户端和路径上的所有中继、服务端升级到 native 0.4.32。在配置中启用后，TCP、UDP 和控制流量均使用独立的连接与方向密钥，失败不会自动降级。旧配置保留旧协议，需主动迁移；Mac App Store Packet Tunnel 暂不支持 v2。
- **连接恢复（1.2.17+43）**：配合原生库 0.4.31，Windows 在网络变化后刷新新连接的物理出口。原生句柄操作串行执行，清理在 UI 线程外完成，限制日志积压，并独立于日志检查连接状态。验证范围和限制见父仓库 `docs/network-resilience.md`。
- **代理控制**：一键启停代理，可视化状态指示
- **配置管理**：服务器地址、端口、会话密钥、本地端口设置
- **自动代理**：基于地理位置的路由（国内直连，国外代理）
- **SOCKS5 UDP**：在同一本地代理端口启用或停用 RFC 1928 UDP 转发
- **Windows TUN**：接管本机 TCP/UDP，并支持运行时修改进程排除列表
- **实时日志**：彩色日志查看器，支持级别过滤（TRACE/DEBUG/INFO/WARN/ERROR）
- **桌面日志文件**：按小时滚动并保留最近三天，支持从日志页直接打开所在文件夹
- **主题切换**：4 种配色主题（赛博朋克、日落、海洋、森林）
- **明暗模式**：深色/浅色外观切换
- **响应式布局**：自适应手机、平板、桌面屏幕
- **Material 3 设计**：现代 UI 与流畅动画

## 支持平台

| 平台 | 状态 |
|------|------|
| Android | ✅ |
| iOS | ✅ |
| Linux | ✅ |
| macOS | ✅ |
| Windows | ✅ |
| Web | ⚠️ (仅 UI，无 FFI) |

## 构建

macOS 发布包通过 Developer ID 签名和 Apple 公证，验证通过后才上传 DMG。
维护者需要先按照 [macOS 签名配置](docs/macos-signing.md) 设置仓库的
Actions Secrets 和变量。公证同时覆盖应用、原生库及 TUN helper。

### 前置条件

- [FVM](https://fvm.app/) 4.x
- Visual Studio 2022，并安装“使用 C++ 的桌面开发”工作负载（Windows）
- 父级 `proxy-everything` 仓库指定的 Rust 工具链

项目通过 `.fvmrc` 固定使用 Flutter 3.47.7。请勿直接调用全局安装的
`flutter` 或 `dart`，统一使用 `fvm flutter` 和 `fvm dart`，确保本地与
CI 使用同一 SDK。

### 本地开发

```bash
fvm install
fvm flutter pub get
fvm flutter run -d windows
```

桌面 UI 依赖 Rust 编译生成的 `http_proxy` 原生库。Windows TUN 模式还
依赖 `wintun.dll`，父级构建脚本会同时放置两个 DLL。在 Windows 上从父级
仓库开发时，推荐从父级仓库根目录使用以下命令自动编译、放置 DLL 并启动 Flutter：

```powershell
.\scripts\windows\run-ui.ps1
```

同时构建完整 Rust 工作区和 Windows UI：

```powershell
.\scripts\windows\build.ps1 -Configuration Release
```

Windows 程序启动时会请求管理员权限，因为创建 Wintun 和修改路由需要提权。
TUN 进程排除列表可在连接前或连接中修改。原生层始终强制排除 UI 自身进程，
避免客户端的出站连接再次被 TUN 捕获而形成死循环。

### 触发发布构建

使用 GitHub Actions 工作流：

```bash
gh workflow run build.yaml \
  -f lib_version=<version> \
  -f create_release=true \
  -f release_tag=v1.0.0
```

参数说明：
- `lib_version`：原生库版本
- `create_release`：是否创建 GitHub release（默认：true）
- `release_tag`：发布标签名（如 v1.0.0）

## CI/CD

- **CI** (`ci.yml`)：每次 push/PR 到 `main`/`dev` 时运行 - 检查代码分析、格式化和构建
- **Release** (`build.yaml`)：手动触发 - 构建所有平台并创建 GitHub release
