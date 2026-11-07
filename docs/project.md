# MoonDTA：范围与本地交付记录

日期：2026-11-07。版本：0.1.0。状态：本地开发与验证，尚未发布或申报。

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

## 实际验证记录

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
- 模块使用本地占位 namespace `local/moondta`。正式 namespace、GitHub owner 和仓库地址待项目发布阶段确定。
- `tests/package_consumer.py` 已检查实际 zip 内容，并从解包后的库建立独立 JS/Wasm GC 消费工程，公开 API 测试通过。
- 尚未执行：公开仓库发布、远端 CI、Mooncakes 发布与 registry 安装验证、赛事报名及官方审核。

## 申报简介草稿

MoonDTA 是面向统计数据交换的 MoonBit Stata DTA 118/119 读写库。项目参考 ReadStat 的公开实现，
在 MoonBit 中重写二进制解析、类型及缺失值编码、元数据和长字符串处理；提供按需选列/批次读取、
带元数据的 JSON 交换和命令行工具。验证结合 pandas、ReadStat 和 Stata 官方样本，
覆盖 Unicode、全部扩展缺失值、大小端以及 65,537 列宽表。项目当前完成本地实现与验证，
发布身份、公开仓库及当期正式报名信息尚未填写。使用 AI 辅助开发，来源和验证边界公开记录。

本文件不构成十一月赛事规则核验或官方通过证明；后续申报按当期规则另行核对。
