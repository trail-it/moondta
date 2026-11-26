# MoonDTA

用 MoonBit 读取、检查和生成 **Stata DTA 118/119** 文件，面向问卷、社会科学及统计数据交换。
核心解析与编码不依赖 Python、Stata 或 ReadStat；Node.js 仅为命令行提供文件读写。

Mooncakes 模块名为 `trail-it/moondta`，本页对应版本 `0.4.0`。

## 已实现

| 能力 | 范围 |
|---|---|
| 文件版本 | 118、119，LSF/MSF 两种字节序 |
| 数值 | byte、int、long、float、double，保留存储类型 |
| 缺失 | 普通 `.` 和 `.a`–`.z` 共 27 种，独立于正常数值 |
| 字符串 | UTF-8 str1–str2045、文本 strL、二进制 strL |
| 元数据 | 数据集标签、变量标签、取值标签（包括缺失值标签）、显示格式、时间戳、排序列 |
| characteristics | 保留变量/数据集属性及原始 payload，包含 notes 和语言属性 |
| 读取 | 打开时解析元数据和 strL 位置索引，按指定行区间与列编号解码；strL 按需解码，批次内复用共享对象 |
| 预览 | 可读的数据表及数据字典，展示普通数值、负零、标签和扩展缺失值 |
| 交换 | 带类型及元数据的 JSON 和 JSON Lines 双向交换，浮点位模式保留负零 |
| 错误 | 有界读取、map/长度/UTF-8/引用检查，返回带字节位置的 `DtaError` |

日期和时间保留为 **数值 + Stata 显示格式**（例如 `%td`），不转换时区或解释统计语义。

## 快速运行

验证工具链：`moon 0.1.20260915`、`moonc v0.10.13+cbb11c36f`，Node.js 24。

在项目根目录运行（PowerShell、bash 均可）：

```sh
moon build --target js
node _build/js/debug/build/cmd/main/main.js import examples/survey.json _build/survey.dta
node _build/js/debug/build/cmd/main/main.js inspect _build/survey.dta
node _build/js/debug/build/cmd/main/main.js describe _build/survey.dta
node _build/js/debug/build/cmd/main/main.js preview _build/survey.dta --columns 回答,score,备注
node _build/js/debug/build/cmd/main/main.js verify _build/survey.dta --batch-size 2
node _build/js/debug/build/cmd/main/main.js select _build/survey.dta _build/selected.dta --columns id,回答 --offset 1 --limit 2
node _build/js/debug/build/cmd/main/main.js convert _build/survey.dta _build/survey119.dta --version 119 --endian big
node _build/js/debug/build/cmd/main/main.js export _build/survey119.dta _build/restored.json
```

所有输出路径必须尚不存在，避免覆盖输入或已有结果。成功退出码为 0，错误为 1。
示例包含中文、取值标签、`.a`、普通缺失和负零；评分 `1.5` 在 JSON 中用位模式表示。

`inspect` 只检查结构与元数据，**不会验证每个数据单元格或解码 strL 内容**；
用 `verify` 扫描全部行及所有 strL 对象（包括未被行引用的对象）。
`export` 也支持 `--columns`、`--offset`、`--limit`。列名使用逗号分隔，顺序即输出顺序。
`select` 会重映射排序列编号，仅保留仍有效的排序前缀，保留数据集属性和被选变量属性。
所有取值标签定义均保留，包括暂时未被引用的定义。

`preview` 默认显示前 10 行，每个文本最多 60 个 Unicode 字符；支持 `--columns`、`--offset`、
`--limit`、`--width` 和 `--labels on|off`。文字中的换行、控制字符和表格分隔符会转义，
长文字用省略号表示，二进制显示字节数。缩略仅影响展示。标签附在原始值之后，例如
`1 ("是")`、`.a ("拒绝回答")`，未定义标签的值仍显示数值。
预览不执行 Stata 显示格式，日期仍显示原始数值。

`describe` 显示数据集信息、变量类型/标签/格式、排序位置及取值标签定义，无需读取数据行。
需要完整机器可读内容时使用 `inspect` 或 `export`。

## 库 API

### 用 JSON Lines 往返交换 DTA

从当前源码构建 CLI 后运行。

```sh
node _build/js/debug/build/cmd/main/main.js export-jsonl _build/survey.dta _build/survey.jsonl --batch-size 256
node _build/js/debug/build/cmd/main/main.js import-jsonl _build/survey.jsonl _build/from-lines.dta --version 119 --endian big
```

`export-jsonl` 支持 `--columns`、`--offset`、`--limit`，行范围遵循 `export` 的边界检查。
第一行包含 `moondta_jsonl: 1`、选中行数 `rows` 和完整投影后 `schema`。
其后每行是一个使用现有类型标记的单元格数组，字符串中的换行按 JSON 转义。
空结果只包含头行。格式使用 UTF-8，每行以 LF 结尾。

核心 API `reader.export_jsonl(write, offset?, limit?, columns?, batch_size?)` 将每个完整行字符串
交给 `write` 回调，字符串包含结尾 LF。默认每批解码 256 行，仅保留当前批次和当前输出行。
回调错误与解码错误立即传给调用者，库的调用者负责处置部分输出。
CLI 独占创建输出文件，失败时清理本次创建的文件。已有文件保留。
输入 DTA 字节仍驻留内存，单条超长文本或二进制也会影响峰值内存。

Python 消费示例逐行保留类型标记，适合接入自己的数据处理流程。

```python
import json
with open("_build/survey.jsonl", encoding="utf-8") as stream:
    metadata = json.loads(next(stream))
    for line in stream:
        row = json.loads(line)
        print(row)
```

`import-jsonl` 接受 LF、CRLF 及没有末尾换行的 UTF-8 文件。文件头声明行数，每条记录的单元格数必须与列数一致。遇到截断、额外记录、无效 UTF-8 或错误的单元格标记，会报告行号。默认保留源版本及字节序，写入时可用 `--version` 和 `--endian` 指定目标格式。

从 0.4.0 起，`import-jsonl` 按 64 KiB 读入文件，逐行编码并分块写入 DTA。峰值内存受表结构、最长一行、读写缓冲区和固定容量的 strL 索引缓存影响。CLI 每条 JSONL 记录上限为 512 MiB，文件可以更大。

命令在目标目录暂存正在写入的 DTA 和唯一 strL 对象。相同类型及内容复用第一次出现的引用，文本和二进制分开比较。核对行数后，命令写入对象区、取值标签和段偏移表，再独占安装目标文件。磁盘需容纳 DTA 和临时对象。支持硬链接的文件系统可以直接安装，其他受支持的文件系统使用独占复制。普通读写或校验错误会清理临时文件，已有目标受保护。

库接口 `@dta.write_jsonl(next_line, write_at, scratch~, version?, endian?)` 可接入自己的存储。`next_line()` 在输入结束时返回 `None`。`write_at` 接受零起始的 64 位位置和完整字节块，最后一次写入回填 112 字节的偏移表。`ScratchFile` 提供按位置读写的回调，必须读满指定长度并写完整块，失败时抛错。调用者提供初始为空的输出、独立的临时存储，并负责资源清理。需要可编辑的内存数据集时可使用 `@dta.from_jsonl(next_line)`。单文档 JSON 对应 `export` 和 `import`。

### 安装已发布库

在自己的 MoonBit 工程里添加依赖，再在包配置中设置别名。

```sh
moon add trail-it/moondta@0.4.0
```

```moonbit
// moon.pkg
import {
  "trail-it/moondta" @dta,
}
```

以下用法由公开接口测试覆盖：

```moonbit
let schema = @dta.Schema::new([
  @dta.Column::new("id", @dta.Int32),
  @dta.Column::new("备注", @dta.StrL, label="访谈记录"),
], label="示例")
let dataset : @dta.Dataset = {
  schema,
  rows: [
    [@dta.Integer(1), @dta.Text("中文😀")],
    [@dta.Missing(1), @dta.Text("")],
  ],
}
let bytes = @dta.encode(dataset)
let reader = @dta.open(bytes)
let batch = reader.read_rows(offset=1, limit=1, columns=[0])
// batch == [[Missing(1)]]，即 .a
let selected = reader.column_indices(["备注"])
reader.each_batch((start, rows) => {
  println("从第 \{start} 行起处理 \{rows.length()} 行")
}, columns=selected, batch_size=256)
```

上述代码放在可抛错的函数或测试内。`Schema::new` 可指定版本、字节序、标签、时间戳、
排序信息、取值标签和 characteristics。完整公开签名见 [pkg.generated.mbti](pkg.generated.mbti)。

- `open(Bytes) -> Reader`：结构检查并索引。`schema()` 返回独立元数据副本，`row_count()` 返回行数。
- `column_count()` 返回变量数，`column_indices(names)` 按给定顺序解析变量名。未知名称和重复名称会报错。
- `each_batch(visit, offset?, limit?, columns?, batch_size?)` 将零起始的绝对行偏移与该批行传给回调。空范围不调用回调，回调报错立即停止。
- `read_rows(offset?, limit?, columns?)`：零起始行/列索引；越界、负数和重复列报错；省略 limit 读取剩余行。
- `read()`：完整 Dataset；`select(columns, offset?, limit?)`：带投影后元数据的 Dataset。
- `verify(batch_size?)`：逐批校验全部行和所有 strL 对象，默认每批 256 行。
- `preview(offset?, limit?, columns?, max_chars?, labels?)` / `describe()`：返回可读 Markdown 表格。
- `encode(Dataset) -> Bytes`：严格按声明类型写入，不猜测列类型或静默改名/截断。
- `Dataset::to_exchange()` / `from_exchange(Json)`：转换为/从 JSON。
  `from_exchange` 检查交换结构和元数据，`encode` 进一步检查单元格与存储类型是否匹配。

`Integer` 对应 byte/int/long；`Number` 对应 float/double；`Missing(0..26)` 对应数值缺失。
`Text` 对应 str#/strL，`Binary` 仅对应 strL。空字符串使用 `Text("")`，不使用数值 Missing。
Float32 写入会按 IEEE binary32 舍入；NaN、Infinity、溢出及保留编码报错。
时间戳可为空，或使用 `dd Mon yyyy hh:mm`；校验月份、实际日历日期（含闰年）、小时和分钟。
单数字日期也接受前导空格，例如 ` 7 Nov 2026 12:00`。
整数可用范围分别为 `[-127,100]`、`[-32767,32740]`、`[-2147483647,2147483620]`。
取值标签的缺失键按 Stata long 编码保存：`.` 为 2147483621，`.z` 为 2147483647。

## JSON 交换约定

[examples/survey.json](examples/survey.json) 是完整可编辑示例。顶层 `moondta_exchange` 必须是 1。
`schema` 保存元数据；`rows` 为行数组，每个单元格只有一个键：

| 内容 | JSON |
|---|---|
| 整数 | `{"int": 42}` |
| 浮点 | `{"number_bits": "3ff8000000000000"}`（binary64 的十六进制位模式，值为 1.5） |
| 字符串 | `{"text": "中文"}` |
| 二进制 | `{"binary": [0, 255, 128]}` |
| 缺失 | `{"missing": 0}` 为 `.`；1–26 为 `.a`–`.z` |

存储类型为 `"Byte"`、`"Int16"`、`"Int32"`、`"Float32"`、`"Float64"`、
`["Str", 字节宽度]`、`"StrL"`。字节序为 `"Little"` 或 `"Big"`。
characteristic 的 `data` 为字节数组，包含原始结尾 NUL（若有）。
此格式保留 DTA 元数据与类型；普通 CSV 无法表达这些区别，因此未把 CSV 作为无损交换格式。

## 验证

```sh
moon fmt --check
moon check --target js --deny-warn
moon check --target wasm-gc --deny-warn
moon test --target js
moon test --target wasm-gc
moon build --target js
python -m pip install -r tests/requirements.txt
python tests/interop.py
python tests/compat_interop.py
python tests/jsonl_interop.py
python tests/streaming_import.py
python tests/wide.py
python tests/package_consumer.py
# 可选：下载 Stata Press 示例（保存在被忽略的 tests/generated/）
python tests/interop.py --official
```

建议在独立 Python 虚拟环境中安装测试依赖。外部验证包括 pandas 双向读写、ReadStat 读取和写入、
全部缺失编码、大小端、65,537 列 119 文件、CLI 失败时不覆盖文件。
官方样本为独立真实文件，程序生成数据为合成样本，两者分别记录。
当前结果、来源及交付边界见 [docs/project.md](docs/project.md)。

性能实测见 [docs/benchmarks.md](docs/benchmarks.md)。11 月 7 日同机单次测试中，约 32 MiB 长文本文件的
转换峰值内存从 0.1.0 的 1,739 MiB 降至 268 MiB；11 月 8 日加入写入去重后该场景约 269 MiB，
约 128 MiB 的全不重复长文本转换约 856 MiB，另验证了 200,000 行数值数据。
性能脚本独立于正确性测试，不将机器相关的耗时设为 CI 门槛：

```sh
python tests/benchmark.py --sizes 8 32 128 --output _build/benchmark.json
```

## 边界

- 仅支持 118/119；114/117、SAS/SPSS、统计运算、Stata 命令解释器不在范围内。
- `open` 在内存中持有 DTA 字节和 strL 位置索引，分批读取减少已解码行的内存。`encode(Dataset)`、完整转换和单文档 JSON 交换在内存中完成。
- `import-jsonl` 使用 64 位输出偏移，JSONL 头中声明的行数上限为 2,147,483,647。其他 CLI 命令仍限制单个输入文件为 512 MiB，内存版 Reader 使用有符号 32 位索引。118 限 32,767 列，119 限 120,000 列。
- 保留语义，不承诺文件字节完全相同：写出会重建 map、strL 引用和标签布局；未引用的 strL 对象、
  字段填充字节、EOF 后的换行不作为数据保存。可接受 EOF 后单个 LF 或 CRLF，其余尾随内容报错。
- 保留自定义显示格式和 characteristics，但不执行格式、不解释应用私有属性。
  调整行数据时调用者负责维护真实的排序声明及应用私有属性。
- 核心已验证 JS 和 Wasm GC；CLI 已在 Windows 和真实 Ubuntu 主机的 Node.js 环境运行。
  具体工具版本见验证记录。未声明 Native 或真实 Stata 程序验收。

## 许可

MIT。项目是参考 ReadStat v1.1.9 格式实现的 MoonBit 重写，独立 API 与 JSON 交换由本项目实现。
来源、第三方许可、合成/外部样本及 AI 辅助说明见 [THIRD_PARTY.md](THIRD_PARTY.md)。
