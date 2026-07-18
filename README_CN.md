# Proxy UI

跨平台加密代理客户端的 Flutter 图形界面。

## 功能特性

- **代理控制**：一键启停代理，可视化状态指示
- **配置管理**：服务器地址、端口、会话密钥、本地端口设置
- **自动代理**：基于地理位置的路由（国内直连，国外代理）
- **实时日志**：彩色日志查看器，支持级别过滤（TRACE/DEBUG/INFO/WARN/ERROR）
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

### 前置条件

- [FVM](https://fvm.app/) 4.x
- Visual Studio 2022，并安装“使用 C++ 的桌面开发”工作负载（Windows）
- 父级 `proxy-everything` 仓库指定的 Rust 工具链

项目通过 `.fvmrc` 固定使用 Flutter 3.38.6。请勿直接调用全局安装的
`flutter` 或 `dart`，统一使用 `fvm flutter` 和 `fvm dart`，确保本地与
CI 使用同一 SDK。

### 本地开发

```bash
fvm install
fvm flutter pub get
fvm flutter run -d windows
```

桌面 UI 依赖 Rust 编译生成的 `http_proxy` 原生库。在 Windows 上从父级
仓库开发时，推荐从父级仓库根目录使用以下命令自动编译、放置 DLL 并启动
Flutter：

```powershell
.\scripts\windows\run-ui.ps1
```

同时构建完整 Rust 工作区和 Windows UI：

```powershell
.\scripts\windows\build.ps1 -Configuration Release
```

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
