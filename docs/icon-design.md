# Fileto 应用图标

图标用「文件 → 应用」表达默认打开方式管理：白色折角文件、向右箭头与橙色应用方块，搭配蓝色圆角底座。保留少量立体感，与原生 macOS 界面协调；不使用文字，让小尺寸下的主体更清晰。

- 原图：`Resources/AppIcon.png`，底座外为透明背景。
- macOS 图标：`Sources/FiletoApp/Resources/AppIcon.icns`，包含 16–1024 像素的标准尺寸，同时作为 Swift Package 资源供 Xcode 直接运行使用。
- 标准 AppIcon 资源集：`Sources/FiletoApp/Resources/Assets.xcassets/AppIcon.appiconset`，包含 macOS 的全部十个尺寸槽位。
- `scripts/build-icons.sh` 使用系统 `sips` 与 `iconutil` 从原图生成 `.icns` 和资产目录中的图片。
- 原生 Xcode 工程通过 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` 编译资源集；`scripts/build.sh` 也通过 `actool` 编译同一资源集。应用包包含 `Assets.car`、兼容用的 `.icns`，以及 `CFBundleIconFile` / `CFBundleIconName` 元数据。
- Xcode 的推荐入口是 `Fileto.xcodeproj`，共享的 Fileto Scheme 构建并运行完整的 `Fileto.app`。原生应用目标与 Swift Package 复用同一套应用源码和 `FiletoCore`，没有重复实现核心模块。
- 应用启动时优先从应用包加载同一份 `.icns`；Xcode/Swift Package 直接运行时通过 `Bundle.module` 加载。显式启用普通应用模式，并在启动完成后再次配置 Dock 图标。正式应用包为 Finder 与应用切换提供图标。
- 窗口使用 macOS 默认的最小化及台前调度机制，不设置 `AppleDockIconEnabled` 或 `NSWindow.miniwindowImage`。这些自定义 Dock 最小化窗口接口不是台前调度的应用图标配置。

系统接口参考：[应用 Dock 图标](https://developer.apple.com/documentation/appkit/nsapplication/applicationiconimage)、[窗口最小化图标及启用条件](https://developer.apple.com/documentation/appkit/nswindow/miniwindowimage)。

系统识别检查使用 [NSRunningApplication 的应用图标](https://developer.apple.com/documentation/appkit/nsrunningapplication/icon)及应用包信息。

## 应用身份与验证

直接运行 Swift Package 可执行文件时，运行时 Dock 图标不能证明完整应用身份或台前调度画面正确。验证应使用 `Fileto.xcodeproj` 或脚本构建的完整应用包，并检查实际桌面画面。

Xcode Debug 使用 `com.fileto.app.debug`，Release 和脚本打包使用 `com.fileto.app`。`Resources/Info.plist` 中的 `$(PRODUCT_BUNDLE_IDENTIFIER)` 由 Xcode 展开；脚本打包显式写入正式标识。

从旧资源配置升级时，先停止旧进程，在 Xcode 执行 **Product → Clean Build Folder（⇧⌘K）**，再重新构建。应用包应同时包含 `Assets.car` 和 `Info.plist` 指向的 `AppIcon.icns`。

修改源图标后，在项目根目录执行：

```bash
bash scripts/build-icons.sh
bash scripts/build.sh
```

完整打包与签名校验后，仍需检查 Finder、Dock、应用切换和台前调度的实际显示。
