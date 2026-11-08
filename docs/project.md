# MoonDTA 项目与验证记录

日期为 2026-11-08，当前版本为 0.2.0。

## 0.2.0 本地完善

- 时间戳新增日历有效性校验：月份、闰年/闰世纪、日、小时、分钟及格式；接受合法的空时间戳和空格补齐日期。
- strL 改为位置索引与按需解码；共享内容在单批次内复用。新增 `Reader::verify` 扫描所有行和未引用的 strL，
  使延迟解码不会影响完整校验能力。`open` / `inspect` 的工作限于结构和元数据检查。
- Writer 改用连续字节缓冲区，去掉 section 合并和 Node 输入的多余副本。
- Writer 在单次写入内跨行、跨列去重 strL，使用首次出现位置作为共享引用；文本和二进制分别识别，
  空文本继续使用零引用，空二进制仍保存为二进制对象。共享文本样本的 1,025 行、两列仅写出 3 个对象，
  118/119 输出分别为 41,260 / 41,274 字节，大小与 pandas 原文件一致；二进制样本的 3 次引用只写出 1 个对象。
- 新增 `preview` 表格预览与 `describe` 数据字典，同时提供对应库 API；显示普通数值、负零、中文取值标签和 `.a` 等缺失值。
- 新增独立兼容性脚本，验证 118/119 × 大小端下跨列共享 strL、1,025 行与批次边界、部分取值有标签、
  二进制 GSO 原始字节及读写、CLI 展示和错误选项。
- Windows 核心 JS/Wasm GC 各 17 个测试块通过；公开 API 测试覆盖新增预览、字典和完整校验。
  `tests/interop.py --official` 与 `tests/compat_interop.py` 均通过。
- 0.2.0 已重新运行 65,537 列宽表回归：119 大小端、高列编号 strL 读写以及拒绝降到 118 均通过。
- 新增 Stata 官方 [auto2.dta](https://www.stata-press.com/data/r18/auto2.dta) 实际文件验证，
  74 行、12 列，完整读写后与 pandas 核对；官方数据留在被忽略的本地样本目录。
- 实测 8/32/128 MiB 长文本和 200,000 行数值数据。32 MiB 长文本转换峰值内存从 1,739 MiB 降至 268 MiB，
  详细方法、原始结果与容量边界见 [benchmarks.md](benchmarks.md)。
- CI 配置已纳入新增兼容性脚本。正式 namespace、公开仓库、远端 CI、注册表发布及安装验证按用户选择留到发布阶段。
- 实际 `local-moondta-0.2.0.zip` 已从独立工程消费，JS/Wasm GC 各 1 个公开 API 消费测试通过；
  本地依赖、下载数据和构建中间文件不在归档中。
- 本次本地提交身份按用户指定设置为 `trail-it`，使用该账号的 GitHub noreply 邮箱；
  既有 0.1.0 提交保留原作者与历史。该设置不代表已授权远程发布。

### Linux 主机验证（2026-11-08）

在 Ubuntu 26.04.1 LTS / Linux 7.0.0-42-generic x86_64 主机上运行，
使用独立临时目录和 Python 虚拟环境，没有修改主机原有项目或全局工具链。

- MoonBit 与本地项目锁定版本一致：moon 0.1.20260915，moonc v0.10.13+cbb11c36f，core 同版本；
  Node.js v22.22.1，Python 3.14.4，pandas 3.0.1，pyreadstat 1.3.5。
- `moon fmt --check`、JS/Wasm GC 的 `moon check --deny-warn` 通过；两后端各 17 个测试块通过，JS CLI 构建通过。
- `tests/interop.py --official` 和 `tests/compat_interop.py` 通过：包括 118/119 大小端、全部数值缺失编码、
  ReadStat 双向核对、官方 auto/auto2、共享文本/二进制去重和 CLI 展示。
- `tests/wide.py` 通过：65,537 列、119 大小端、高编号 strL 和拒绝降到 118。
- `tests/package_consumer.py` 通过：实际归档排除缓存，独立消费工程 JS/Wasm GC 各 1 个测试通过。
  最初以分发包解压建立验证目录，缺少不随包分发的 `.gitignore` / `.moonignore`，导致重新打包时缓存检查失败；
  补齐源工程这两个文件后重新运行并通过，项目代码没有因此修改。
- 主机预装 moonc v0.10.14 的首次严格检查触发了新增的 trait 方法弃用提示，因此正式验证改用项目锁定工具链。
  本次没有迁移新版编译器语法，也不将该首次检查记为通过。

这是真实 Linux 主机验证，不是 GitHub Actions 运行或真实 Stata 程序验收。

下方保留 0.1.0 的初始范围与验证历史，新增能力以上述 0.2.0 记录和当前 README 为准。

## 项目定位

为问卷、社会科学和统计数据工具提供可复用的 MoonBit Stata DTA 118/119 读写能力。
典型流程：检查文件结构与标签 → 选取变量/行 → 保留类型、缺失及元数据交换 → 写回 DTA。
不实现统计模型、Stata 语言、其他统计文件格式或旧版 DTA。

2026-11-07 调研了 Mooncakes 包元数据及 GitHub 的 MoonBit 名称、topic、README 搜索。
当时本地索引包含 3,632 条包记录，未找到提供相同 DTA 118/119 读写能力的包；
这只是该检索范围内的结果，并非不存在其他实现的保证。
相邻项目 MoonXPT 处理 SAS XPORT V5，文件语义与本项目不同。
上游来源与重写贡献记录在 [THIRD_PARTY.md](../THIRD_PARTY.md)。

## 能力与验收

| 目标能力 | 实现 | 验收证据 |
|---|---|---|
| 118/119 读写 | 版本字段、map、section、大小端 | pandas 四组合双向读写 |
| 数值与缺失 | 5 种数值存储、27 种缺失 | pandas + ReadStat 核对全部组合 |
| UTF-8 | 变量名、内容、标签和长字符串 | 中英文、emoji、超过 2,045 字节的 strL |
| 元数据 | 标签、格式、sortlist、characteristics | 官方 auto 的 note/语言属性/排序和取值标签往返 |
| strL | 文本/二进制、版本相关引用宽度 | 文本外部对照；二进制合成向量/格式检查 |
| 宽表 | 119 的 32 位列数和 3+5 字节引用 | pandas 生成 65,537 列，双字节序读写和高编号 strL |
| 选列、行区间、批次 | Reader 索引和按需解码 | API 投影/范围检查、CLI 分批验证 |
| JSON 交换 | 带类型数据与完整 Schema | 往返、负零、缺失与原始属性字节验证 |
| 错误行为 | 有界游标、类型及引用检查 | 每字节截断、map/标签/UTF-8/strL/数值错误，600 次确定性字节变异 |
| 可使用性 | 库 API + Node CLI | 公开 API 测试、README 示例、实际归档独立消费者 |

## 0.1.0 实际验证记录（历史）

本机 Windows，核心分别使用 JS 和 Wasm GC；CLI 使用 Node.js v24.19.0。

- 工具链：moon 0.1.20260915 (2e1a46d)，moonc v0.10.13+cbb11c36f；core 0.10.13+cbb11c36f。
- Python 3.12.7；pandas 3.0.1；pyreadstat 1.3.5。Python 仅用于测试。
- `moon fmt --check`、JS/Wasm GC 的 `moon check --deny-warn` 已通过。
- JS/Wasm GC 测试各 12 个测试块，内部包含参数组合和循环验证；不将这些重复计为独立测试数量。
- `tests/interop.py`：pandas → MoonDTA → pandas/ReadStat；ReadStat → MoonDTA → pandas。
  覆盖 118/119 × 两字节序、5 种数值类型 × 27 种缺失、日期格式、中文标签、长字符串和 CLI 错误行为。
- `tests/wide.py`：65,537 列、两字节序均通过；尝试降到 118 被拒绝，未创建输出。
- 官方样本：[auto.dta](https://www.stata-press.com/data/r18/auto.dta)，74 行、12 列，
  完整导出/写回后与 pandas 核对；其 EOF 后的换行触发并修复了一处兼容性问题，现有专门回归测试。
- 官方 [datexmpl2.dta](https://www.stata-press.com/data/r18/datexmpl2.dta) 实际是 117，
  验证的是明确拒绝旧格式，不计为支持的正向样本。
- 另尝试取得 nlswork，但下载多次超时，未作为验证证据。
- `.github/workflows/ci.yml` 已准备 Windows/Linux 检查配置，远端 CI 尚未运行。

结构检查与整文件验证有区别：`open` / `inspect` 不扫描所有行；`read` 或 `verify` 才检查所有单元格。
Wasm GC 测试验证核心算法，文件 I/O 只在 Node CLI 中实现。未在真实 Stata 程序内打开文件，
未进行 512 MiB 上限容量测试，未声明磁盘流式读写或 Native 后端支持。

## 来源和分发

- 采用 MIT；保留 ReadStat v1.1.9 的 MIT 许可。参考实现重写与宿主 I/O 的边界已说明。
- 自有示例是合成数据。官方数据、本地虚拟环境、构建缓存不进入 Git 或 Mooncakes 归档。
- 正式模块为 `trail-it/moondta`，源码仓库为 [trail-it/moondta](https://github.com/trail-it/moondta)。
- `tests/package_consumer.py` 已检查实际 zip 内容，并从解包后的库建立独立 JS/Wasm GC 消费工程，公开 API 测试通过。
- 赛事报名及官方审核待进行。

## 申报简介草稿

MoonDTA 是面向统计数据交换的 MoonBit Stata DTA 118/119 读写库。项目参考 ReadStat 的公开实现，
在 MoonBit 中重写二进制解析、类型及缺失值编码、元数据和长字符串处理；提供按需选列/批次读取、
带元数据的 JSON 交换和命令行工具。验证结合 pandas、ReadStat 和 Stata 官方样本，
覆盖 Unicode、全部扩展缺失值、大小端以及 65,537 列宽表。项目当前完成本地实现与验证，
当期正式报名信息待填写。使用 AI 辅助开发，来源和验证边界公开记录。

本文件不构成十一月赛事规则核验或官方通过证明；后续申报按当期规则另行核对。
