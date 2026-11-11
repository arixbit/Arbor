# 界面对账：Arbor vs 参考实现

Arbor 复刻的是另一个 IDE 的 Git 工作台，所以「这个按钮该不该在、在不在同一个
位置」没法靠单元测试保证，只能两侧比。这件事过去是人工的：`docs/visual-baseline.md`
里的 C1–C9 / L1–L8 每一行都是有人盯着两张截图手写出来的，每次发版重来一遍。

现在改成一条命令：

```sh
./scripts/ui-parity.sh --reference
```

## 两层，各回答一个问题

| 层 | 工具 | 回答 |
| --- | --- | --- |
| 控件 | `scripts/ui-parity.py` | **该有的东西在不在、在不在同一个地方** |
| 像素 | `scripts/ui-parity-diff.swift` | **哪里看起来不一样** |

顺序不能反。像素比对会把字体渲染、图标风格、抗锯齿的差别全部报成差异，两套
运行时（AppKit vs JetBrains Runtime）本来就不会画得一样；而一个按钮的
accessibility label 不会因为换了运行时就不一样。所以先用控件层定位到具体控件，
再用像素热图确认视觉表现。

## 控件层

两侧的无障碍树由 `ui-smoke/ArborUIParityUITests.swift` 导出（测试跑在沙箱里，
树以 XCTAttachment 形式返回，脚本从 xcresult 里取出来），存到
`build/parity/tree/{arbor,rebased}-{commit,log}.txt`。比对按「类别 + 归一化名字」
配对，输出五类结论：

| 类别 | 含义 | 典型缺陷 |
| --- | --- | --- |
| 参考有 · Arbor 缺 | 参考实现里点得到，Arbor 没有入口 | 按钮没做、菜单项漏了 |
| 参考侧坐标不可用 | 名字对不上，但参考平台没给坐标 | 表格单元格、隐藏控件，需人工判断 |
| Arbor 多出来 | Arbor 有、参考没有 | 多一行标题、多一个分组 |
| 位置不一致 | 同名控件偏了 > 3 pt | 栏宽、换行、间距 |
| 尺寸不一致 | 同名控件尺寸差 > 3 pt | 输入框过窄、按钮被裁 |
| 可用状态不一致 | 参考可点、Arbor 灰着（或反之） | 条件判断写错 |

名字归一化会去掉省略号（`Commit…` = `Commit`）和快捷键后缀，大小写不敏感。
坐标统一减掉窗口原点，两侧画布才能逐点相减。顶层分栏（左栏多宽、右栏从哪开始）
单独列一张表，对应 C2c / C2d / L1 这类整体布局问题。

报告：`build/parity/<surface>-controls.html`，`--markdown` 额外写出可直接粘进
`docs/visual-baseline.md` 的表格。

## 像素层

同一窗口尺寸（1642×1015 @2x）的两张截图，两块指标：

- **逐像素差异**：回答「像不像」。字体不同会把它放大到百分之几，只当风格信号看。
- **块均值差异**：按 16 pt 分块比较平均颜色，文字形状不再重要，块差异意味着
  东西移动、缩放、出现或消失。差异块聚成区域，按面积排序。

工具会先算两侧平均亮度：**深色截图对浅色截图直接判为不可比**并给出警告，而不是
报一个 99% 的假结果——`docs/images/baseline` 里的 log 两张就是这种情况，重拍前
先统一系统外观。

报告：`build/parity/<surface>-diff.html`，含拖动对比、差异热图和区域清单（pt 坐标）。

### 覆盖的界面

| 界面 | 参考对账 | 快照基线（浅色） | 快照基线（深色） |
| --- | --- | --- | --- |
| Commit | 需要 Rebased 停在 Commit 工具窗 | 198 节点 | 198 节点 |
| Log | 需要 Rebased 停在 Log 工具窗 | 149 节点 | 149 节点 |
| Settings | 需要 Rebased 打开同名设置页 | 152 节点 | — |
| Branches 弹层 | 需要 Rebased 打开 Branches… | 37 节点（裁剪） | — |
| Stash 面板 | 需要 Rebased 打开 Show Git Stash | 17 节点（裁剪） | — |

快照基线覆盖的界面比参考对账多，因为它不需要参考 App：每加一个界面，发版前的
自动检查就多一块。新增界面只要在 `ArborUIParityUITests` 里多导一份树。

两个导出的坑，都是实测出来的：

- **独立窗口（Settings）**：问那个 window 元素要 `debugDescription` 只会得到嵌套的
  window 行。要用观察根——`openSettings()` 已经把观察根切到设置窗口。
- **popover（分支面板）暂时没纳入**：popover 的内容挂在主窗口的子树里，导它等于把
  整个窗口导一遍（445 行，其中 198 行和 commit 基线重复），主窗口一改两条基线都红，
  维护成本翻倍。真要做需要先从导出里剪出 popover 子树。

## 发版前：和上一次批准的界面比

参考对比需要 Rebased 在场，只能本地跑；发版前那个「我打开看一眼」的工序靠它解决不了。
`scripts/ui-snapshot.sh` 补上这一环：把 Arbor 自己的控件树归一化后提交进仓库，
每次比对的是「上个批准的样子」。

```sh
./scripts/ui-snapshot.sh            # 检查，漂移就失败并列出差异
./scripts/ui-snapshot.sh --update   # 认可当前界面，重写 ui-smoke/snapshots/
```

基线长这样，一个控件一行，可以直接 diff 和 review：

```
window	Arbor	0,0 1642×1015 [Disabled|Keyboard Focused]
      button	Refresh log	1294,92 12×14
      button	Commit	12,58 16×13 [Disabled]
      menubutton	<fixture>	<varies>
```

能稳定提交的前提是两条：

1. **归一化**：对象地址、pid、每次都不同的 fixture 名、容器绝对路径、本地时区
   日期、提交 hash 全部抹平，坐标减去窗口原点。
2. **带容差地比**：含可变文案的节点不记坐标（`<varies>`）——fixture 名是随机 8 位
   十六进制，在比例字体下宽度是 210 还是 213 pt 取决于抽到哪几个字符，它右边的按钮
   就跟着平移 2-3 pt。其余节点的位置对比有 4 pt 容差。实测连续 7 次导出一致。

画布尺寸不同时（比如 CI runner 的显示器更窄）只比结构，坐标不计。

确认是本意后跑 `--update` 重写基线，并在提交信息里说明改了什么。

CI 里已经接上（`.github/workflows/ui-smoke.yml`），是**严格**的：同一块画布下的漂移
直接失败。runner 的显示器更窄时窗口会被裁窄、控件跟着重排，那种情况下脚本只比结构、
只报告不失败——比对环境不支持的事不该拦人。实测：同画布改名 → 退出码 1，异画布改名
→ 退出码 0。

## 缺口清单

对账报出「参考有、Arbor 缺」之后，还要回答「这些是不是真的没做」。`scripts/ui-triage.py`
把每个缺失的名字回查 Arbor 的源码和本地化表：

- 源码里出现过 → 功能在做，只是叫法或入口位置不同，不是缺口（实测 68 条里 54 条属这类）
- 一次都没出现 → 进 `docs/ui-gaps.md`，并且**必须在 `scripts/ui-gaps-baseline.txt` 里
  给一次结论**：`to-build` / `design-difference` / `naming` / `out-of-scope`

没有结论时脚本直接失败，所以清单不会越挂越长、也不会有人再一眼扫过去就跳过。
这个模式和 `scripts/audit-user-surface.py` 的 baseline 是同一套：脚本拦住漏判，
判断仍然是人给。

```sh
./scripts/ui-parity.sh --reference      # 重新对账
python3 scripts/ui-triage.py --write-doc docs/ui-gaps.md
```

## 现有的界面基线

`--reference` 要求 Rebased 已经在运行，并且已经在它里面打开了 visual-fixture 项目：

```sh
./scripts/make-ui-fixture.sh /tmp/visual-fixture
open -a Rebased /tmp/visual-fixture        # 首次需要在 Rebased 里信任该项目
./scripts/ui-parity.sh --reference
```

只跑 Arbor 侧（CI 里可用）就去掉 `--reference`。

## 把参考对账扩到别的界面：卡在哪

参考对账目前只覆盖 Commit 和 Log 两个工具窗，因为导出只抓主窗口的树，而那两个
必须在场。想把 Branches / Stash 也纳入，先要解决「怎么让参考侧切界面」。

**安全做法是走菜单，不是点坐标。** 实测这些菜单项都可以点，而且都是幂等的视图操作，
不会改动仓库：

| 目标 | 菜单路径 |
| --- | --- |
| 日志 | Git → Show Git Log |
| 贮藏 | Git → Show Git Stash |
| 分支 | Git → Branches… |
| 工具窗 | View → Tool Windows → Commit / Git / Project / … |

点坐标有真实风险：活动栏和面板里都可能有叫 `Commit` 的按钮，其中一个是提交动作本身。

**卡点已经从「怎么切」变成「抓哪里」，而且前半段解决了。** 菜单点下去之后：

| 菜单项 | 结果 |
| --- | --- |
| Git → Branches… | 打开一个独立窗口（实测 375×353、无标题、不在主窗口树里）|
| Git → Show Git Stash | 不开新窗口，在原工具窗里换视图 |

对 Branches 已经用「动作前后的窗口集合差集」把它找出来并单独导出了
（`rebased-branches`，62 行，里面是 `Branches Tree` / `Commit…` / `New Branch…`），
比点坐标安全，也比导整棵树干净。Show Git Stash 还需要先确认它把内容放在哪一层。

**Arbor 侧暂时导不出干净的子树**：给它加了一个稳定的容器标识
（`branches-popover-panel`，`accessibilityElement(children: .contain)`），但
`debugDescription` 里这个容器下面没有子节点——子控件被暴露在**窗口层级**上，
不是嵌套在容器里。整棵树 483 行，按容器标识剪子树只能剪出 1 行。

所以 Branches 这一对的形态是：参考是**独立窗口**（62 行，干净的子树），Arbor 是
**窗口内浮层**（只能在整窗树里认出来）。要真比，需要给对账工具加一个「按矩形裁剪」
的选项，把浮层区域从整窗树里切出来；那是工具的下一个功能，不是一天的补丁。

**裁剪能力已经加上**：导出可以在首行带 `#CLIP x,y,w,h`（窗口相对坐标），
`ui-parity.py` 只保留落在这块矩形里的节点。Arbor 侧的分支弹层现在能导出了
（`arbor-branches`，37 个节点），和对面的参考窗口（33 个节点）比出 30% 的配对率。

**Stash 的参考侧也打通了**：`Git → Show Git Stash` 不开新窗口，而是在主窗口里
加一块 `Stash Tool Window`（Group，无标识、只有 label，所以得按 label 的谓词查）。
实测这块可以按它自己的边框裁剪导出（`rebased-stash`，里面是 `Stashes` 大纲）。

Arbor 侧的 `arbor-stash` 也导出了（切到提交面板的 Stash 标签，按左侧列表的滚动区
裁剪）。比对结果很浅，0% 配对，但暴露了一个真实差异：

| 参考的 Stash 工具窗 | Arbor 的贮藏面板 |
| --- | --- |
| Stashes 大纲 + Changes 大纲 | 只有 `Stashes, 1` / `Shelves, 0` 两个分组标题 |
| 工具栏 Show Diff / Group By / Expand All / Collapse All | 只有 `Filter` 菜单 |
| Apply / Pop 常驻按钮（78×34）| 没有常驻按钮，动作在行的菜单里 |

也就是说：参考把「应用 / 弹出」放在面板底部常驻，Arbor 把它藏进了每行的菜单。
这不是等价的操作成本——参考两步，Arbor 要先展开、再进菜单。

**已修两处**：

1. 贮藏面板底部加了常驻的 `Apply` / `Pop`，作用于选中的 stash，没选中时是灰的。
2. 面板顶部加了工具栏：`Show Diff` / `Expand All` / `Collapse All`。

配对率 0% → 17% → **42%**。还剩的差异都解释得清：参考的 `Commit`/`Stash` 标签页、
`Options`/`Hide` 在裁剪区之外；`Stashes` 是 Arbor 的 `Stashes, 1` 按钮（命名）；
`Group By` 没做（Arbor 的贮藏列表是平的，没有可分组维度）；`Changes` 大纲是参考
在选中 stash 后列出的文件清单，Arbor 用的是预览面板——那是结构差异，不是缺按钮。

试做过这一条，**没做成**：Arbor 的贮藏行是用 `HStack` + `onTapGesture` 实现的，
在无障碍树里不是 Button；选中它才会触发预览、diff 文本才会加载，而「Changes」清单
是从 diff 文本里解析出来的。自动化的点击落不到那个手势上，导出的树里没有清单，
配对率反而从 42% 掉到 25%。改动已回退。

要做这一条，得先解决两件事：贮藏行要有稳定的可点身份（Button 或显式标识），
以及「选中即加载 diff」这条链在无预览时也能拿到文件清单（例如引擎直接给
`stashFiles`，而不是让前端解析 diff 文本）。

另外导出范围本身也浅：Arbor 的 Stashes 分组默认收起时，裁剪区里只有标题行。展开
状态属于用户偏好，测试不去替用户改。

**分支弹层和贮藏面板现在也进基线了。** 之前跳过它们，是因为浮层在两次导出间的
无障碍树**深度**会变（SwiftUI 重建时父容器有时在、有时不在），逐行比缩进必然全红。
解决办法是：裁剪导出的界面拍平后再比——这类界面的判据是「哪些控件、在什么位置」，
不是「嵌了几层」。结构差异的比较也改成不含深度。

## 已知限制

以下都是实测出来的，不是推测。

- **参考侧只导出当前屏幕上的界面。** 导出器读窗口标题来判断这是 Commit 还是
  Log（标题写着 `visual-fixture – Log`），不替用户点按钮切界面——在别人的 IDE
  里盲点坐标可能点到提交按钮。要比 Commit，就先在 Rebased 里把 Commit 工具窗打开。
- **两侧画布要一样大。** 窗口尺寸差 42 pt，右边所有控件的横坐标就全歪（实测
  1600×1015 vs 1642×1015，屏幕宽度限住了）。脚本会打印这个警告。
- **参考侧的表格单元格不可信。** JetBrains 的 JTable 对每一行都报同一个文本
  （实测 6 行全是 `Initial commit`），且坐标是 `(-200, -59)` 这种哨兵值。这类节点
  归到「参考侧坐标不可用」，不参与位置比对。
- **两边的文案不是同一个语言环境。** 参考跑在中文环境（`01/01/24 下午5:00`），
  Arbor 被测试强制成英文（`05/01/24 5:00 PM`）。日期、数字格式类文案必然对不上。
- **叫法不同就对不上。** 参考的 `Update Project...` 和 Arbor 的 `Update` 归一化后
  仍不相等，会被列进「缺」。要降低噪声需要一张别名表（`参考 label → Arbor label`），
  这是下一步该做的，不是调参能解决的。
- **IDE 宿主能力永远是「缺」。** `Search Everywhere`、`IDE and Project Settings`
  这类是 IntelliJ 平台自带入口，Arbor 不该复刻；`docs/audit-user-surface.py` 的
  baseline 已经把这类判为 `out-of-scope`，界面对账还没有读那份结论。
- **图标按钮无法配对。** 没有 label 的按钮在树里没有名字，`image` 角色被排除。
- **像素层对主题、缩放、窗口尺寸敏感。** 两侧必须在同一外观模式、同一窗口尺寸下采集。
