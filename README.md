# LaunchGrid

LaunchGrid 是一个面向 macOS 的原生应用启动器，目标是在 macOS 26 上尽量还原经典
Launchpad 的应用网格、搜索和横向分页体验。

项目使用 Swift、SwiftUI 和 AppKit，不依赖 Electron、WebView 或第三方运行时。应用
只读取本机普通应用目录，通过 Apple 公共 API 显示并启动应用；不会修改 Dock 数据库、
旧版 Launchpad 数据库或系统文件。

## 已实现功能

- 扫描系统和用户的常见应用目录
- 显示真实应用图标和本地化应用名称
- 按应用名称实时搜索
- 点击应用后使用 `NSWorkspace` 启动，并隐藏 LaunchGrid
- 根据窗口大小自动计算每页容量并横向分页
- 支持触控板横向滚动、滚轮和系统 Swipe 事件切换页面
- 在鼠标指针当前所在的显示器上打开启动器
- 使用无标题栏覆盖窗口，不进入单独的 macOS 全屏 Space
- 窗口关闭或失去焦点时隐藏进程，点击 Dock 图标后可以再次打开
- 缓存应用图标和分页表面，减少翻页过程中的重复工作

## 操作方式

| 操作 | 结果 |
| --- | --- |
| 点击应用图标 | 启动对应应用并隐藏 LaunchGrid |
| 横向滚动或触控板滑动 | 切换应用页面 |
| `Command-F` | 聚焦搜索框 |
| `Return` | 启动当前搜索结果中的第一个应用 |
| `Escape` | 搜索不为空时先清空搜索；搜索为空时隐藏 LaunchGrid |
| 点击真实背景区域 | 隐藏 LaunchGrid |
| 点击 Dock 中的 LaunchGrid | 再次显示启动器 |

当前还没有全局快捷键。LaunchGrid 隐藏后，需要通过 Dock 图标重新打开。

## 应用扫描范围

LaunchGrid 会只读扫描：

```text
/Applications
/Applications/Utilities
/System/Applications
/System/Applications/Utilities
~/Applications
```

扫描会跳过隐藏文件，把 `.app` 视为叶节点，不进入应用包内部继续枚举。应用优先按
Bundle Identifier 去重；没有 Bundle Identifier 时按标准化路径去重。明显的 Helper、
Updater、Agent 和 Crash Reporter 会被保守过滤。

## 构建要求

- 产品目标环境：macOS 26
- 推荐工具链：Xcode 26，并包含 macOS 26 SDK
- 源码语言：Swift 5 模式
- 支持架构：Intel `x86_64` 与 Apple Silicon `arm64`
- 不需要 Homebrew，也没有第三方 Package 依赖

仓库当前存在一个需要后续统一的配置差异：

- `LaunchGrid.xcodeproj` 当前实际 Deployment Target 为 macOS 13.0
- `Package.swift` 声明 macOS 26.0
- 产品设计和项目约束以 macOS 26 为目标，不把当前 Xcode 设置视为对 macOS 13 的
  正式兼容承诺

目前以 Xcode 工程和项目构建脚本为主构建入口。

## 构建与运行

在仓库根目录执行：

```bash
cd LaunchGrid
./script/build_and_run.sh
```

构建、启动并确认进程存在：

```bash
cd LaunchGrid
./script/build_and_run.sh --verify
```

其他调试模式：

```bash
cd LaunchGrid
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --debug
```

脚本会停止旧的 LaunchGrid 进程，使用 `xcodebuild` 构建 `arm64 + x86_64` Debug
应用，把临时应用包放到 `/private/tmp/LaunchGrid-dist/LaunchGrid.app`，执行临时签名，
然后使用 `open -n` 启动。这个签名只用于本地开发，不等同于 Developer ID 签名或
Apple 公证。

## 项目结构

```text
LaunchGrid/
├── LaunchGrid.xcodeproj/   Xcode 工程与共享 Scheme
├── LaunchGridApp.swift     SwiftUI 应用入口
├── AppDelegate.swift       应用生命周期
├── Models/                 应用数据模型
├── Services/               应用扫描、启动与图标缓存
├── ViewModels/             应用列表、搜索与分页状态
├── Window/                 AppKit 窗口、输入和显示器处理
├── Paging/                 实际分页表面、手势和缓存
├── Views/                  SwiftUI 搜索、状态和页面指示器
├── Design/                 集中管理的布局与动画参数
└── script/                 构建、签名、启动和验证脚本
```

当前可见分页链路由 AppKit 窗口事件、`PagingInputController`、
`PagingSurfaceController` 和 `PageSurfaceView` 共同完成。SwiftUI 的
`LauncherView` 主要负责背景、搜索、状态和页面指示器。

## 本地运行与隐私

LaunchGrid 当前没有：

- 服务器或云端接口
- 账户系统
- 网络上传逻辑
- 广告或分析 SDK
- `sudo`、辅助功能注入或私有 Apple Framework

应用只读取普通应用目录和应用包元数据，使用 `NSWorkspace` 获取图标并启动用户点击的
应用。隐藏某个应用、重排或文件夹等持久化功能尚未实现，因此当前不会写入应用布局
数据库，也不会修改或删除真实应用。

`--logs` 和 `--telemetry` 只读取本机 Unified Logging，用于开发调试，不会上传日志。

## 当前验证

2026 年 8 月 16 日在以下环境完成了实际验证：

- Xcode 26.2（Build 17C52）
- macOS 26.5.1
- Intel `x86_64` Mac
- Debug 构建生成 `x86_64 + arm64` Universal Binary
- Release 构建生成 `x86_64 + arm64` Universal Binary
- `./script/build_and_run.sh --verify` 完成构建、临时签名、启动和进程确认

本轮没有用自动化工具逐项操作所有 GUI 交互。翻页手感、不同触控板设置和多显示器
视觉表现仍需要人工观察，不能仅凭构建成功视为已经完全验证。

## 已知限制

- 当前没有可直接下载的正式 Release、Developer ID 签名或 Apple 公证安装包
- 应用重排、跨页拖动、文件夹和持久化布局尚未实现
- 全局快捷键、登录项、菜单栏入口和设置窗口尚未实现
- 当前需要通过 Dock 图标重新显示隐藏后的启动器
- 视觉目标是经典 Launchpad，但没有声明与系统 Launchpad 像素级完全一致
- Xcode 工程与 `Package.swift` 的 Deployment Target 尚未统一
- Xcode 工程是当前完整构建入口；SwiftPM 清单尚未作为最新分页实现的发布入口验证
- GUI 流畅度和输入设备差异仍需要实机人工验证
