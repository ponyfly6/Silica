# 原生 diff 选型与小规模验证

日期：2026-11-13。结论：第一版保留基础审阅 diff，复用 Git 的文本差异计算，AppKit 做只读显示；尚未向应用接入新依赖或界面。

## 做到什么程度

需要回答“这次任务具体改了哪些行”，并让用户复制、定位和继续修改。第一版只做统一格式、前后行号、增删背景色、默认 3 行上下文和打开文件。

双栏同步、三方合并、逐块接受／拒绝、语义移动检测、自动回滚和完整 Git 客户端后置。执行摘要不能替代差异，基础 diff 本身并不意味着产品向传统 IDE 扩张。

计算引擎、显示视图、比较基线是三层独立职责。用 C 实现或 Git 子进程计算，界面仍然可以是 SwiftUI / AppKit；原生界面不要求所有算法必须由 Swift 重写。

## 候选评估

| 候选 | 能力 / 许可证标识 | 本项目判断 |
| --- | --- | --- |
| Git `diff --no-index` | 两份文件／目录比较，无需 Git 仓库；支持 Myers / patience / histogram，输出 unified patch；GPLv2 | 首版采用独立命令调用，复用成熟计算；有进程开销和 Git 可执行文件依赖，仍需要自己的原生显示 |
| libgit2 `git_diff_buffers` | C API，直接比较两个内存 buffer，输出 hunk / line 回调；GPLv2 + linking exception | 适合日后随应用内置的引擎，省掉每文件起进程；增加 C 桥接、构建与维护成本，本轮未编译或实测 |
| Swift 标准库 `CollectionDifference` | 可按行数组比较，无额外依赖；官方文档给出最坏 O(n×m) | 少量修改非常快，适合作为小文件方案；大范围改写耗时明显，不作为无边界的通用首选；不提供代码审阅 UI |
| TextDiff 1.3.0 / b5815ad | MIT；SwiftUI + AppKit，词级／字符细化、合并显示，支持预计算结果 | 原生但更适合短文本变更；空白处理和不可选择文本不适合直接作为代码审阅器 |
| Differ | MIT；Swift collection diff / patch，Myers 类算法 | 可以算数据差异，没有现成原生代码审阅器；本轮未实测，无需仅为替代标准库再引入它 |
| DifferenceKit | Apache-2.0；面向 collection / table view 的 Heckel diff、移动与更新 | 主要解决列表刷新；其列表基准不能证明代码审阅的 hunk 质量或性能，不选为代码 diff 组件 |

### TextDiff 的具体不匹配

检查了仓库提交 `b5815ad2cf18a875776ff4b4f124bbdfb2134b1d`。README 明确说明：使用 NLTokenizer 词级分词、空白变化保留 updated 的布局且显示为中性、显示文本不可选择。

其原生显示不是 Git 风格的前后行号／hunk 查看器。当前性能测试主要是 200、500、1,000 个单词的布局，不足以证明大型代码文件适配。Myers 实现为回溯保存各轮 frontier，较大编辑距离的内存表现仍需专门测试；本轮未跑这种极端压力。

使用未修改的引擎源文件做了缩进样例验证：

```python
# before
def run():
    work()

# after
def run():
work()
```

`TextDiffEngine.diff(..., mode: .token)` 的非 equal segment 数为 **0**。这与其文案差异的显示目标一致，却无法满足 Python／YAML 等代码审阅要求。本轮未测 TextDiff 的窗口渲染、选择与滚动；不可选择的结论来自其 README。

## 本机小规模计时

环境：Apple M5、macOS 27.2.1、Git 2.54.0、Swift 6.4.2。工具链环境取实际执行主机信息，测试日期采用本聊天日期。Swift 探针由 `swiftc -O` 编译，独立于应用构建。TextDiff 只编译未修改的 engine 文件，没有安装完整 SwiftPM UI 包。

每组 3 次，报告中位数。合成内容每行 `let value_000000 = calculate(000000)`；零散修改是均匀分布的 10 行替换，全部改写是每行替换标识符与调用。测试前写好输入文件。

| 场景 | Git histogram | Swift 行级差异 | TextDiff 词级差异 |
| --- | ---: | ---: | ---: |
| 1,000 行，改 10 行 | 8.723 ms | 0.186 ms | 5.019 ms |
| 10,000 行，改 10 行（原文 370 KB） | 5.974 ms | 0.648 ms | 26.884 ms |
| 100,000 行，改 10 行（原文 3.7 MB） | 21.039 ms | 6.165 ms | 未测 |
| 1,000 行，全部改写 | 4.459 ms | 21.060 ms | 未测 |
| 10,000 行，全部改写 | 7.699 ms | 1,708.592 ms | 未测 |

计时范围有区别，不能解释为等价产品的全面排名：

- Git 包含每次进程启动、两文件读取与完整 patch 的捕获；保留状态码 1 为“存在差异”的正常结果。
- Swift 不包括进程启动、文件读取和按行切分；包含 `difference(from:)` 与 `applying` 重建正确性检查。还未计入 hunk 分组或显示。
- TextDiff 不包括文件读取，包含原文分词与 `diff` segment 生成；输出粒度与 Git / Swift 行级结果不同。
- 未测峰值内存、冷启动与系统缓存控制、UI 布局／滚动、高度重复代码、超长单行、全部换行格式变化或所有编码。100,000 行输入超出当前 v1 的单文件完整捕获上限，只用于引擎观察。
- 1,000 行的 Git 数值高于 10,000 行体现启动／缓存噪声；3 次样本只能作为选型探针，不能给出产品延迟承诺。

原始数值与计时范围见 [diff-engine-benchmark.json](diff-engine-benchmark.json)。

Git 命令形态：

```text
git --no-pager diff --no-index --no-ext-diff --no-textconv --no-color
    --diff-algorithm=histogram --unified=3 -- before.swift after.swift
```

测试运行在项目外的快照目录，禁用全局／系统 Git 配置与系统 attributes，避免用户设置影响算法或运行外部 diff。正式实现同样需要隔离配置和环境，不使用 `-w` 等忽略空白选项。

## 接入决定

1. `TurnChangeStore` 保持负责快照与归属。选文件时按需比较任务前后快照，不直接拿当前工作区相对 HEAD 的变化冒充本轮 diff。
2. 新建小型 `TextDiffService`，第一实现 `GitDiffEngine`；接收快照路径与显示路径，返回 typed hunk / line 模型。实现正好覆盖现有需求，不搭建通用 diff 插件体系。
3. Git 通过绝对可执行路径和参数数组启动；cwd 是私有快照目录。禁用外部 diff、textconv、颜色和非预期配置；限制运行时间、输出量和并发。状态码 0 / 1 正常，其他状态按失败处理。
4. 连接诊断检查 Git 可用性。不能假定每台 Mac 都安装可用 Git；缺失时给出选择路径／安装提示，不声称系统永远自带可用版本，也不静默省略差异。
5. 只读 `NSScrollView + NSTextView` 包在 SwiftUI 中，保留文本选择和复制；自定义 gutter 显示 old / new 行号。复用现有主题、字体、颜色与原生快捷键，背景色与语法前景色分开。第一版不用 WebView／Monaco／diff2html，也不替换主编辑器。
6. 默认展示 3 行上下文，大文件与大 patch 限额并有缺口标记；结果按前后 hash 缓存，计算与解析离开主线程。实际流畅性另测 native rendering，不能只根据算法计时推断。
7. 若需要免 Git 安装、内存 buffer 比较或批量小文件吞吐，单独验证 libgit2；其原生 C API 不会影响 AppKit 原生界面。正式集成时固定版本并保留相应许可文件，不能把 linking exception 简写成 MIT。

## 一手资料

- [Git diff 官方文档](https://git-scm.com/docs/git-diff)
- [libgit2 buffer diff API](https://libgit2.org/docs/reference/main/diff/git_diff_buffers.html)
- [libgit2 license](https://github.com/libgit2/libgit2/blob/main/COPYING)
- [Swift difference 官方复杂度说明](https://developer.apple.com/documentation/swift/bidirectionalcollection/difference(from:by:))
- [TextDiff 固定提交的 README](https://github.com/iSapozhnik/TextDiff/blob/b5815ad2cf18a875776ff4b4f124bbdfb2134b1d/README.md)
- [TextDiff 空白处理实现](https://github.com/iSapozhnik/TextDiff/blob/b5815ad2cf18a875776ff4b4f124bbdfb2134b1d/Sources/TextDiff/TextDiffEngine.swift)
- [Differ](https://github.com/tonyarnold/Differ)
- [DifferenceKit](https://github.com/ra1028/DifferenceKit)
