# Sys Cleaner 开发约定

## 鼠标交互

- App 中可点击的按钮在鼠标悬停时应有可见的高亮反馈；禁用按钮不显示可点击高亮。
- 新增自绘按钮、列表图标按钮或菜单触发按钮时使用统一的 `hoverHighlight()` 修饰器；系统弹窗、菜单项和已提供系统悬停效果的控件沿用 macOS 原生反馈。
- 同一个按钮同时使用 `hoverHighlight()` 和 `.disabled(...)` 时，将 `hoverHighlight()` 放在 `.disabled(...)` 之前，让禁用状态传入高亮修饰器。
- 修改按钮交互后，在实际 App 中检查浅色和深色外观下的悬停、移出及禁用状态。

## 完成后的 App 验证

- 每次完成 App 代码或资源改动后，使用仓库的 `DerivedData` 重新构建 **Sys Cleaner** scheme：
  `xcodebuild -project SysCleaner.xcodeproj -scheme 'Sys Cleaner' -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build`。
- 构建成功后，关闭正在运行的旧版 Sys Cleaner，再打开 `DerivedData/Build/Products/Debug/Sys Cleaner.app`。不要只打开另一个临时构建来代替更新用户正在使用的 App。
- 在重新打开的 App 中检查本次改动对应的实际页面和交互；报告时区分构建通过与运行界面验证，并给出打开的 App 路径。如果构建或打开失败，明确报告，不要声称用户正在运行的 App 已更新。
