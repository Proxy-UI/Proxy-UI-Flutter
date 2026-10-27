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

- **应用代理**：macOS 直装版和 Windows 优先为 Claude 写入原生配置，为 Codex 生成启动器，无需 TUN。已安装的应用以自身图标列出，一键添加并使用当前 Proxy 本地端口；端口与直连规则均可按应用编辑，默认域名含 `oa` 时直连。详见 [应用代理说明与限制](docs/app-launchers.md)。

- **安全传输 v2（1.2.18+44）**：需先将客户端和路径上的所有中继、服务端升级到 native 0.4.32。在配置中启用后，TCP、UDP 和控制流量均使用独立的连接与方向密钥，失败不会自动降级。旧配置保留旧协议，需主动迁移；Mac App Store Packet Tunnel 暂不支持 v2。
- **连接恢复（1.2.17+43）**：配合原生库 0.4.31，Windows 在网络变化后刷新新连接的物理出口。原生句柄操作串行执行，清理在 UI 线程外完成，限制日志积压，并独立于日志检查连接状态。验证范围和限制见父仓库 `docs/network-resilience.md`。
- **节点星系图**：节点页默认以 3D 星系图展示。每个国家/地区是一颗印着国旗的恒星，按其在地球上的位置（从北极上方俯视）排布；节点作为行星环绕恒星，颜色表示最近一次测试结果（快速、一般、较慢、不可达、未测试），恒星外圈的状态环显示各状态占比，本机与当前节点之间以光弧相连。拖动旋转、滚轮或双指缩放，点击恒星或行星可查看节点 IP、出口 IP 和延迟，并在面板中连接或测试。尚未定位出口的节点聚在“未定位”星团，测试定位后会飞向所属国家。也可切换为按国家分组的列表视图。
- **主动检查更新**：只有点击标题栏的“检查更新”才会联网检查，不做后台检查、不自动下载。发布清单必须带有效的 Ed25519 签名；确认后：macOS 校验开发者签名与公证后替换并重新打开应用，Windows 安装版静默运行安装程序（一次 UAC），Android 交给系统安装器确认，Windows 便携版与 Linux 下载到“下载”文件夹。补传 Android APK 并更新清单后，需用 `scripts/sign_release_manifest.py` 重新签名并上传 `.sig`
- **代理控制**：概览页和侧边导航栏中的电源按钮可在任意页面一键启停代理
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

Windows、macOS、Linux、Android 和 iOS 共用优化后的星系图渲染器。
手机主页不预先构建星系场景。可见的星系图只在交互、节点变化或镜头过渡期间
重绘，动画跟随屏幕刷新率，静置后停止。进入后台、最小化或窗口失去焦点
时暂停动画；背景图、国旗和行星纹理随可见状态释放，页面销毁时清理文字布局。
原生库 0.6.5 通过独立 Rust crate `galaxy-geometry` 批量投影和裁剪轨道，
Flutter 复用球体光照与光晕纹理，并批量提交可见线段和节点。
批量测速时，等待探测结果期间不再重绘：测速中的圆环和进度都是静止的，
结果分批合并后再刷新界面，整轮测速只保存一次节点目录。原生库导出
`proxy_probe_nodes_v1` 时，探测作为共享运行时上的任务执行，不再为每个
节点占用一个阻塞的 isolate。
验证方法和测量范围见 [星系图资源验证](docs/galaxy-performance.md)。

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

项目通过 `.fvmrc` 固定使用 Flutter 3.47.8。请勿直接调用全局安装的
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
