# Proxy UI

[English](#english) | [中文](#中文)

---

## English

A cross-platform Flutter GUI for encrypted proxy client.

### Features

- **Proxy Control**: One-tap start/stop proxy with visual status indicator
- **Configuration**: Server host, port, session key, and local port settings
- **Auto Proxy**: Geo-based routing (CN direct, others proxy)
- **Real-time Logs**: Colored log viewer with level filtering (TRACE/DEBUG/INFO/WARN/ERROR)
- **Theme Switching**: 4 color themes (Cyberpunk, Sunset, Ocean, Forest)
- **Dark/Light Mode**: Toggle between dark and light appearance
- **Responsive Layout**: Adapts to phone, tablet, and desktop screens
- **Material 3 Design**: Modern UI with smooth animations

### Supported Platforms

| Platform | Status |
|----------|--------|
| Android | ✅ |
| iOS | ✅ |
| Linux | ✅ |
| macOS | ✅ |
| Windows | ✅ |
| Web | ⚠️ (UI only, no FFI) |

### Build

#### Prerequisites

- Flutter 3.38.6+
- Native libraries (contact maintainer)

#### Local Development

```bash
flutter pub get
flutter run
```

#### Trigger Release Build

Use GitHub Actions workflow dispatch:

```bash
gh workflow run build.yaml \
  -f lib_version=<version> \
  -f create_release=true \
  -f release_tag=v1.0.0
```

Parameters:
- `lib_version`: Native library version
- `create_release`: Whether to create GitHub release (default: true)
- `release_tag`: Release tag name (e.g., v1.0.0)

### CI/CD

- **CI** (`ci.yml`): Runs on every push/PR to `main`/`dev` - checks code analysis, formatting, and builds
- **Release** (`build.yaml`): Manual trigger - builds all platforms and creates GitHub release

---

## 中文

跨平台加密代理客户端的 Flutter 图形界面。

### 功能特性

- **代理控制**：一键启停代理，可视化状态指示
- **配置管理**：服务器地址、端口、会话密钥、本地端口设置
- **自动代理**：基于地理位置的路由（国内直连，国外代理）
- **实时日志**：彩色日志查看器，支持级别过滤（TRACE/DEBUG/INFO/WARN/ERROR）
- **主题切换**：4 种配色主题（赛博朋克、日落、海洋、森林）
- **明暗模式**：深色/浅色外观切换
- **响应式布局**：自适应手机、平板、桌面屏幕
- **Material 3 设计**：现代 UI 与流畅动画

### 支持平台

| 平台 | 状态 |
|------|------|
| Android | ✅ |
| iOS | ✅ |
| Linux | ✅ |
| macOS | ✅ |
| Windows | ✅ |
| Web | ⚠️ (仅 UI，无 FFI) |

### 构建

#### 前置条件

- Flutter 3.38.6+
- 原生库（联系维护者获取）

#### 本地开发

```bash
flutter pub get
flutter run
```

#### 触发发布构建

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

### CI/CD

- **CI** (`ci.yml`)：每次 push/PR 到 `main`/`dev` 时运行 - 检查代码分析、格式化和构建
- **Release** (`build.yaml`)：手动触发 - 构建所有平台并创建 GitHub release
