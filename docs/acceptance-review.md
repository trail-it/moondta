# MoonDTA 工程验收复核

复核日期为 2026-11-26，目标账号为 `trail-it`，默认分支为 `main`。

## 0.3.0 发布前复核

截至 `c993d42`，主分支已有 13 个提交，其中 12 个由 `trail-it` 署名。原有历史保留。下面是本轮逐项可检查的变更。

| 交付内容 | 提交 |
|---|---|
| 阻止类型化整数、缺失标记和二进制字节被静默截断 | `72abba1` |
| 公开按名称选列及分批读取接口 | `27c9fb4`、`c78a6c3` |
| 从逐行输入恢复 Dataset，并通过命令行写回 DTA | `6e2f0fa`、`fc1d531` |
| 全文件校验逐个检查文本对象与引用，避免复制二进制数据 | `9fa3759` |
| 读取单文档 JSON 时立即检查版本和行宽 | `f133ead` |
| 修复空数据集和末尾预览显示虚假行范围 | `c993d42` |

JS 和 Wasm GC 各 24 项测试通过。pandas 读回了 JSONL 写出的 DTA，覆盖两种版本、两种字节序、投影顺序和中文长文本。截断、错行宽和无效 UTF-8 输入均报告行号。更多复现步骤见 [使用指南](../README.md)。

## 首轮分批导出复核（历史记录）

以下数量、对外发布状态和待办均对应提交 `a7b5c8a` 之前的首轮评估。当时 Mooncakes 的发布版本为 0.2.0。

## 完成度与工程规模

按 MoonBit 项目交付 skill 的工程标准，项目已经形成完整的数据格式库和工具链。
核心包含 DTA 118/119 的结构解析与编码、两种字节序、数值与扩展缺失值、UTF-8、
文本及二进制 strL、元数据保存、投影读取和 JSON 交换，提供公开库 API 与 Node CLI。
这些能力共同支撑读取、检查、选择、交换、写回的实际流程，工程规模成立。

本次将下一阶段重点放在大量行的导出内存上，增加 `Reader::export_jsonl` 和 CLI `export-jsonl`。
元数据首行与逐行类型编码复用现有交换语义，逐批解码和逐行写出减少全量中间对象。
调用者可按行处理结果，CLI 在解码或目标写入失败时清理本次输出。

按当前源码文件统计，MoonBit 实现（根目录非测试 `.mbt` 与 `cmd`）为 8 文件、1,921 物理行，
其中约 1,696 行为非空且不以 `//` 开头的行。MoonBit 测试为 6 文件、601 物理行，
生成的公开接口单列为 106 行，Python 验证辅助为 6 文件、507 物理行。
上述为文本统计，非空非注释口径只排除整行注释，是近似值，未将生成接口或外部验证代码计为核心实现。

本次工作前有 3 个真实提交，分别覆盖初始 codec/CLI、0.2.0 完善和公开分发准备。
本次按连贯功能形成一次提交，包含 JSONL、回归与工程复核，不以拆提交增加数量。

## 当期来源与审核边界

2026-11-26 查阅 [官方赛事主页](https://moonbitlang.github.io/Hackathon2026/) 和其
[公开页面源码](https://github.com/moonbitlang/Hackathon2026/blob/9d9c17a92d0b7e285f7ebb61df68f5c1849d732f/src/App.tsx)。
当前页面标明十一月赛，强调 MoonBit 主要实现、公开持续开发记录、README、示例、测试、
可解释的 AI 协助及真实需求。本次读取的页面没有列出统一代码行数或 commits 数字下限。

skill 保存的“至少 10 个有效 commits”来自其他项目的用户材料，适用本项目仍需赛事方具体要求。
如本项目也收到该要求，当前记录尚不足 10 个。应保留真实后续开发，而非补造历史。
本报告是工程复核，官方审核与报名回执仍需对应结果。

## 验证证据

| 范围 | 结果与证据 |
|---|---|
| 0.2.0 发布 | [源码](https://github.com/trail-it/moondta/tree/v0.2.0)、[确切包](https://mooncakes.io/docs/trail-it/moondta@0.2.0) |
| 0.2.0 公开 CI | [d9d4d18 的 Windows/Ubuntu CI](https://github.com/trail-it/moondta/actions/runs/42480441474) 成功 |
| 本次工具链 | Windows，moon 0.1.20260915，moonc/core v0.10.13+cbb11c36f，Node v24.19.0 |
| 本次核心检查 | 格式检查、JS/Wasm GC 的 deny-warn 检查、JS CLI 构建通过 |
| 本次核心测试 | JS/Wasm GC 各 19 个测试块通过，库外独立消费各 1 个公开 API 测试通过 |
| JSONL 独立对照 | `tests/jsonl_interop.py` 使用 pandas 生成 118/119 × 两字节序，核对全部行、选列顺序、批次 1/256/1024、边界与空结果 |
| 类型与失败路径 | 负零、缺失值、标签、二进制、中文及换行，目标已存在、迟发解码错误和注入写入错误后的清理均通过 |
| 既有交换行为 | `tests/interop.py` 与 `tests/compat_interop.py` 回归通过 |
| 归档可用性 | 实际 0.3.0 zip 从独立工程编译并调用新增公开 API，排除本地缓存与数据 |
| 本次 Linux 实机 | 2026-11-26，Linux 7.0.0-44-generic x86_64，独立临时目录，项目锁定工具链、Node v22.22.1、Python 3.14.4；格式、双后端检查、各 19 个测试、JSONL 与既有互操作脚本、实际包消费均通过 |
| 0.3.0 功能提交 | [d67868b](https://github.com/trail-it/moondta/commit/d67868b)，[对应双平台 CI](https://github.com/trail-it/moondta/actions/runs/45756476645) |

性能比较使用同一份 200,000 行、8 个 double 列的合成 DTA（约 12.21 MiB），
每个命令单独启动 Node 进程，默认 JSONL 批次 256。
单次观测中普通 JSON 导出峰值约 1,685 MiB，JSONL 约 123 MiB，下降约 92.7%。
普通 JSON 带缩进、JSONL 紧凑写行，耗时和输出体积也受格式影响，详见 [性能记录](benchmarks.md)。
同一输入在 Linux 实机复测，普通 JSON 峰值 1,626.8 MiB，JSONL 115.9 MiB，单次观测下降约 92.9%。

## 三个完整使用流程

1. 问卷核验。对来源 DTA 执行 `verify`，用 `describe` 核对变量与标签，再用 `preview` 检查扩展缺失值。
   通过 `select` 输出目标行列，pandas/ReadStat 再读取核对类型与标签。
2. 数据交换。将 118 文件转换为 119 大端文件，保留标签、显示格式和属性，再导出带类型 JSON，
   修改后通过 `import` 写回并执行完整校验。
3. 分批处理。用 `export-jsonl --columns ... --batch-size 256` 输出元数据和类型化数据行，
   Python 读取头行后逐行处理，用行数及 schema 检查列对应关系，无需加载完整 JSON 文档。

## 来源、限制及后续

核心为参考 ReadStat v1.1.9 的 MoonBit 重写，保留 MIT 许可，独立 API 和交换格式由项目实现。
Python/pandas/ReadStat 负责测试对照，Node 负责 CLI 文件 I/O。来源和 AI 协助见 [第三方说明](../THIRD_PARTY.md)。

当前输入文件仍完整驻留内存，完整 DTA 转换仍构造 Dataset，超大单行内容也有内存成本。
JSONL 是导出能力，现有 `import` 使用单文档交换格式。真实 Stata 应用验收、Native 后端、
≥2 GiB 文件和磁盘流式 DTA 编解码仍未覆盖，后续根据使用需求确定。
报名资料、官方审核和当期截止时间按赛事方通知处理。
