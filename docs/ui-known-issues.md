# 已知界面问题

这里是**已复现、但还没定位到根因**的问题。每条都写了复现方式，避免下次从头再查一遍。

## 分支弹层的搜索框一输入就关闭弹层

**现象**：点开顶栏的分支弹层，点进搜索框（弹层还在），输入任意字符，弹层整个消失，
搜索框随之不存在。

**复现**：UI 测试里 100% 复现。

```swift
let field = session.app.descendants(matching: .any)["branches-popover-search"].firstMatch
field.click()
field.typeText("feature")   // 之后 field.exists == false
```

**已排除**：

| 假设 | 怎么排除的 |
| --- | --- |
| 分支太多导致 | 5 个分支同样复现 |
| 搜索逻辑本身 | 点击后弹层仍在，输入后才消失；输入的文字确实进入了搜索框 |
| app 失去焦点触发了「弹层随窗口失活关闭」 | 输入前 `app.activate()`，弹层先确认仍在，输入后仍旧关闭 |
| 点击穿透到底下的「点外部关闭」手势 | 把背景的 `onTapGesture` 去掉后，弹层连打开都做不到了（那个手势同时参与了打开时的布局稳定判定），无法用 A/B 定论 |

**带标签日志的结论**：给 `ContentView+Branches.swift` 里全部 48 处
`showPopover = false` 换成 `closeBranchPopup("<行号>")`，在 `ARBOR_BRANCH_POPUP_TRACE=1`
下复现一次，统一日志里**一条都没有触发**。所以不是关闭逻辑把人关掉的——是浮层
自己不再渲染了。

这一层挂在 `.overlayPreferenceValue(BranchPopupAnchorKey.self)` 上，而 `showPopover`
始终是 true。输入让列表收窄后浮层消失，最可能是 overlay preference 的锚点在这条
路径上失效/被重建，而不是有人调用关闭。下一步该查
`ContentView+Layout.swift` 的 `overlayPreferenceValue` 与 chip 上那个
`BranchPopupAnchorKey` 的 GeometryReader 在输入期间是否重新求值。

**影响**：如果用户在真机上遇到同一行为，分支搜索等于不可用——这是当前最明显的
「不如参考实现」的地方（参考的菜单搜索是可用的）。

## 分支弹层列表未虚拟化

150 个分支会全部实例化进无障碍树，坐标一直排到 4400 pt（可视区高度只有 380 pt）。
试过换成 `LazyVStack`：筛选把列表收窄时弹层会被关掉，已回退。虚拟化需要和浮层的
定位/关闭逻辑一起改，见 `Arbor/Dialogs/Dialogs+BranchesPopover.swift` 里的注释。

`ui-smoke/ArborUISmokeUITests.swift` 的
`testBranchesPopoverStaysUsableWithManyBranches` 锁住了「150 个分支能完整装下」，
但没有锁搜索行为——因为搜索在当前实现下不可靠驱动。
