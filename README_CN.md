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

- **fvm**（管理 Flutter 版本）+ Flutter **3.38.6**（项目已固定）
- 对应平台的原生库（从 Release 下载，或用 Rust 源码本地编译）

> 详细环境搭建、原生库准备与各平台运行见 **[开发文档 docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)**；
> 目录结构 / 状态管理 / FFI / 代码风格等规范见 **[docs/CONVENTIONS.md](docs/CONVENTIONS.md)**。

### 本地开发

```bash
fvm install 3.38.6              # 首次：安装项目固定的 Flutter 版本
fvm use 3.38.6                  # 在本目录固定版本（生成 .fvmrc）
fvm flutter pub get
fvm flutter run -d windows      # 或 -d macos / -d linux / <设备 id>
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
