# 来源与许可

MoonDTA 是基于公开格式及成熟实现重新设计的 MoonBit DTA 118/119 读写库。
项目分类为**参考实现重写**：不是整个 ReadStat 的移植，也不通过 FFI 调用 ReadStat。

## ReadStat

- 固定参考版本：[WizardMac/ReadStat v1.1.9](https://github.com/WizardMac/ReadStat/tree/v1.1.9/src/stata)。
- 参考范围：`readstat_dta.h` 的类型/缺失值编码，`readstat_dta.c` 的版本字段宽度，
  `readstat_dta_read.c` / `readstat_dta_write.c` 的 section、GSO、标签、characteristic 布局及变量名规则。
- 测试设计参考：该版本 `src/test/test_list.h` 的 Unicode 和 tagged missing 场景。
- 许可证：MIT，Copyright (c) 2013–2016 Evan Miller (except where otherwise noted)。
  完整许可保存在 [third_party/ReadStat-LICENSE](third_party/ReadStat-LICENSE)。
- MoonBit 自行实现：有界游标、map 校验、类型模型、119 的 3+5 字节 strL 引用、
  二进制 strL、延迟行解码、列投影、特征元数据保存、JSON 交换、错误路径与 CLI。

## 独立对照工具

- [pandas 3.0.1](https://github.com/pandas-dev/pandas/tree/v3.0.1/pandas/io/stata.py)：
  BSD-3-Clause；仅作开发环境中的布局核对及独立生成/读取工具，不随包附带其源代码。
- [pyreadstat 1.3.5](https://github.com/Roche/pyreadstat)：MIT；测试时调用其 ReadStat 后端。
  发布库及 CLI 不需要 Python、pandas 或 pyreadstat。
- MoonBit core 的 UTF-8、JSON、集合和基础类型能力通过标准库复用。

## 样本与开发说明

- 仓库的 `examples/survey.json` 和程序生成样本均为合成数据。
- [Stata Press 官方示例](https://www.stata-press.com/data/r18/u.html) 仅下载到被忽略的
  `tests/generated/`，不随 Git 或包重新分发；来源与用途保留在测试脚本中。
- 本项目使用 AI 辅助设计、编码和测试。验证结论以实际命令和外部对照结果为准；
  不把代码生成本身作为兼容性证据。
