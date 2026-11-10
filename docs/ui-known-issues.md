# 已知界面问题

这里是**排查过、但还没改**的问题，每条都写了结论和复现方式，避免下次从头再来一遍。

## 分支弹层的搜索框：输入后弹层消失（虚惊一场，不是产品缺陷）

**现象**：UI 测试里点开分支弹层，点进搜索框，输入任意字符，弹层消失、搜索框不存在。

**结论**：这不是用户会遇到的 bug。给 `ContentView+Branches.swift` 里的每个关闭点
加上带标签的埋点（写自己的 UserDefaults 域，因为 XCUITest 拉起的 app 的
stdout/stderr 不进统一日志），复现一次后读到的唯一一条关闭来源是：

```
L192   →   NSApplication.didResignActiveNotification  { showPopover = false }
```

也就是说：XCUITest 的按键是由**测试 runner**（另一个 app）合成的，输入时宿主 app
被置为非活动，而弹层按设计会在 app 失去活动状态时关闭——和真实 popover 的行为一致。
真实用户在自己窗口里打字不会触发这条。

**给后续的提醒**：想用 UI 测试验证这个搜索框，必须在输入前后重新 `activate()`，
或者给测试一个显式的「保持弹层」开关。`testBranchesPopoverStaysUsableWithManyBranches`
因此只锁「150 个分支装得下」，不锁搜索。

**排查过程中排除的假设**：分支数量（5 个也复现）、搜索逻辑本身（文字确实进了输入框）、
布局反馈回路（一度以为 overlay 每秒重算二十多次，后来发现那是我自己的埋点在
view body 里写 UserDefaults 造成的抖动，卸掉埋点后 app 空闲 CPU 约 0%）。

## 分支弹层列表未虚拟化

150 个分支会全部实例化进无障碍树，坐标一直排到 4400 pt（可视区高度只有 380 pt）。
试过换成 `LazyVStack`：筛选把列表收窄时弹层会被关掉，已回退。虚拟化需要和浮层的
定位/关闭逻辑一起改，见 `Arbor/Dialogs/Dialogs+BranchesPopover.swift` 里的注释。
