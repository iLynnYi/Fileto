# AGENTS.md

## 项目定位

Fileto 是管理文件类型默认打开方式的原生 macOS 应用，使用 Swift、SwiftUI、AppKit 和 Swift Package Manager，部署目标为 macOS 13。当前没有第三方包依赖；优先沿用系统公开 API。用户可见文案沿用中文和原生 macOS 交互。

当前范围包括类型发现、默认与候选应用查询、单项和批量修改、操作历史及条件恢复。单文件覆盖、URL scheme、关联数据库修复和 Mac App Store 沙盒发行属于范围扩展，不能作为现有能力描述。

## 架构与代码归属

| 位置 | 职责与修改入口 |
| --- | --- |
| `Sources/FiletoApp/` | SwiftUI 视图、弹窗与 `AppModel` 状态协调 |
| `Sources/FiletoCore/TypeCatalog.swift` | UTI 发现、扩展名解析、应用声明读取 |
| `Sources/FiletoCore/AssociationManager.swift` | 预览、冲突检查、顺序执行、读回验证与恢复规则 |
| `Sources/FiletoCore/SystemWorkspace.swift` | `WorkspaceAccess` 与真实 `NSWorkspace` 系统调用 |
| `Sources/FiletoCore/Models.swift`、`HistoryStore.swift` | 普通数据模型与本机操作记录 |
| `Sources/FiletoProbe/` | 只读诊断与原生界面验证启动器 |
| `Tests/FiletoCoreTests/` | XCTest 与 `FakeWorkspace` 测试替身 |

排查行为时沿 `ContentView / ChangeSheets → AppModel → AssociationManager → SystemWorkspace` 追踪。视图负责交互，业务规则放在核心模块，系统访问通过现有 `WorkspaceAccess` 边界；核心模块不引入 SwiftUI。

保留现有 `@MainActor` 隔离和异步设置流程。类型发现使用后台任务，界面状态在主线程更新；批量查询继续分批让出主线程。

## 常用命令

以下命令均在项目根目录运行；构建与测试需要 Xcode 工具链。

| 目的 | 命令 |
| --- | --- |
| SwiftPM 编译 | `bash scripts/swift.sh build` |
| 核心模块测试 | `bash scripts/swift.sh test` |
| 聚焦关联测试 | `bash scripts/swift.sh test --filter AssociationManagerTests` |
| 完整 Release 应用打包与签名校验 | `bash scripts/build.sh` |
| 完整 Debug 应用打包 | `bash scripts/build.sh debug` |
| 启动打包应用 | `open dist/Fileto.app` |

使用 `scripts/swift.sh`，使缓存与配置保持在项目 `.build/` 中。项目当前没有独立的 lint 或 formatter 命令，不臆造检查脚本。

只读诊断需先完成 Debug 编译：

```bash
.build/debug/fileto-probe pdf jpg md json
.build/debug/fileto-probe --catalog
.build/debug/fileto-probe --file /absolute/path/to/sample.json
```

系统集成验证使用 `bash scripts/system-smoke.sh` 或 `bash scripts/system-smoke.sh release`。这不是无人值守单元测试：需要 Python 3、普通 macOS 用户会话和用户手动完成系统确认，测试窗口会显示在前台。

## Code Review Rules

以下规则同时用于实现和审查；发现违规时指出具体触发场景及影响。

- **类型身份**：以 UTI 为记录和去重单位。共享 UTI 的扩展名共同受影响；同扩展名的不同 UTI 必须保留。应用声明只用于发现类型，默认与候选应用以系统查询为准；反向列表仅覆盖已发现类型。
- **设置成功**：执行前重新查询当前默认与目标候选，保留预览后的冲突检查和“已是默认”分支。只有读回目标应用才标记 `.changed`；系统接受请求但未读回目标时保留 `.unverified`。
- **批量与取消**：按类型顺序执行并保留逐项结果。停止只影响后续项，不能把部分成功视为整批成功，也不能把系统取消归为普通失败。
- **条件恢复**：通过 `restorePreview` 重新检查原应用、候选范围和当前关联，再进入普通执行流程。当前默认已偏离记录中的目标时跳过，不能覆盖用户后续修改。
- **系统确认**：保留 `AppModel.execute()` 等待原生预览弹窗实际关闭的流程。系统确认由用户完成；前台辅助只能显示确认窗口，不能代答、绕过授权或改用旧 API 避开确认。
- **历史与隐私**：`HistoryStore` 以原子 JSON 写入最近 30 次操作，默认位置为 `~/Library/Application Support/Fileto/history.json`。保留已有记录的可读性和失败结果；不保存被查询文件的内容，测试使用独立临时存储。

## 系统验证与应用资源

- 系统写入验证使用现有夹具的 `filetovalidationone` / `filetovalidationtwo` 专用类型，按脚本清理本轮临时应用；不要为测试修改 PDF、图片等日常关联或重建全局 Launch Services 数据库。
- 受限沙盒中的 Launch Services 查询失败或动态类型结果不能代表真实系统状态。遇到限制时记录原因，并区分模拟测试、真实系统查询和人工桌面验收。
- 应用包与图标问题通过 `Fileto.xcodeproj` 或打包脚本验证。Swift Package 的 Fileto Scheme 是裸可执行文件，运行时 Dock 图标不能证明完整应用身份或台前调度画面正确。
- `Resources/Info.plist` 的应用标识由 Xcode 展开；脚本打包显式写入正式标识。保留 Xcode Debug 的 `com.fileto.app.debug` 与 Release / 脚本打包的 `com.fileto.app` 区分。
- 图标修改从 `Resources/AppIcon.png` 出发，使用 `bash scripts/build-icons.sh` 同步生成 `.icns` 和 AppIcon 资产。这些资源及共享 Scheme 保留在源码中；构建与验证产物留在 `.build/`、`dist/` 等忽略目录。
- 签名和公证沿用现有脚本与发布文档，签名身份通过 `FILETO_SIGN_IDENTITY` 提供；凭据、私钥和证书密码不写入源码或文档。

## 完成与验证标准

- 修改核心行为时，用 `FakeWorkspace` 添加或调整相关行为测试，覆盖受影响的冲突、失败、取消、未验证或恢复边界，然后运行核心测试。
- 修改 Swift 源码后至少完成 SwiftPM 编译；修改应用资源、Info.plist、Xcode 配置或打包脚本时，另验证完整应用包及签名，不能仅靠裸可执行文件编译。
- 系统关联行为变化需要隔离系统验证；界面变化需要相关真实桌面操作验收。环境或用户会话不具备条件时，明确列出尚未完成的验证，不宣称通过。
- 纯文档修改检查命令、路径和链接即可。更新受影响的使用说明；新验收结果注明日期、平台与执行范围，历史记录不能当作本轮证据。

## 文档公开范围

`docs/` 根目录及 `docs/screenshots/` 只保留适合 GitHub 公开的稳定说明和展示素材。本机排查过程、历史验收证据、内部备注与图标生成提示词放入 `docs/local/`，该目录由 Git 忽略。公开文档须独立可读，链接仅指向会提交的文件。

## 按需阅读

- [docs/UX_FEEDBACK.md](docs/UX_FEEDBACK.md)：新增或修改操作提示、错误文案、进度、确认和结果展示时先阅读，按统一提示规范实现与审查。
- [README.md](README.md)：修改构建入口、使用流程或发布方式时阅读，并同步对用户的说明。
- [docs/verification.md](docs/verification.md)：修改关联规则、历史、恢复或系统验证时先阅读，了解测试流程与平台限制。
- [docs/icon-design.md](docs/icon-design.md)：修改图标、应用身份、Dock 或台前调度行为时先阅读，了解资源生成、完整应用包及桌面验证要求。

本机历史证据位于 `docs/local/verification.md`，图标排查和生成提示词位于 `docs/local/icon-design.md`；需要追溯本机验证或排查过程时读取（仅在本地存在）。

本文件的组织参考 [OpenAI AGENTS.md 指南](https://learn.chatgpt.com/docs/agent-configuration/agents-md)。仅维护稳定的项目约定，公开说明与本机验收证据按上述目录分别维护。
