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

CI 里已经接上（`.github/workflows/ui-smoke.yml`），现在是 `--report` 只报告不失败：
runner 的窗口尺寸未知，先用几次真实输出看清噪声，再去掉 `--report` 变成卡口。

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
