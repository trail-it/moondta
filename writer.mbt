///|
priv enum StrLContent {
  Text(String)
  Binary(Bytes)
} derive(Eq, Hash)

///|
fn check_text(
  text : String,
  max_chars : Int,
  max_bytes : Int,
  what : String,
) -> Unit raise DtaError {
  if text.contains("\u0000") ||
    text.iter().count() > max_chars ||
    @utf8.encode(text).length() > max_bytes {
    invalid(0, "invalid or overlong \{what}")
  }
}

///|
fn check_name(name : String, what : String) -> Unit raise DtaError {
  check_text(name, 32, 128, what)
  if name.is_empty() {
    invalid(0, "empty \{what}")
  }
  for i, ch in name.to_array() {
    if ch.to_int() < 128 &&
      !((ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      ch == '_' ||
      (i > 0 && ch >= '0' && ch <= '9')) {
      invalid(0, "invalid ASCII character in \{what}")
    }
  }
}

///|
fn validate_schema(s : Schema) -> Unit raise DtaError {
  if s.version != 118 && s.version != 119 {
    invalid(0, "only DTA 118 and 119 are supported")
  }
  let k = s.columns.length()
  if k > (if s.version == 118 { 32767 } else { 120000 }) {
    invalid(0, "too many variables for DTA version")
  }
  check_text(s.label, 80, 320, "dataset label")
  check_text(s.timestamp, 17, 17, "timestamp")
  validate_timestamp(s.timestamp)
  let names : Map[String, Bool] = Map([])
  for col in s.columns {
    check_name(col.name, "variable name")
    let reserved = [
      "_all", "_b", "byte", "_coef", "_cons", "double", "float", "if", "in", "int",
      "long", "_n", "_N", "_pi", "_pred", "_rc", "_skip", "strL", "using", "with",
    ]
    if reserved.contains(col.name) ||
      (
        col.name.length() > 3 &&
        col.name.has_prefix("str") &&
        col.name[3] >= '0' &&
        col.name[3] <= '9'
      ) {
      invalid(0, "reserved variable name: \{col.name}")
    }
    if col.name == "_dta" || names.contains(col.name) {
      invalid(0, "duplicate or reserved variable name: \{col.name}")
    }
    names[col.name] = true
    ignore(col.storage.width())
    check_text(col.label, 80, 320, "variable label")
    check_text(col.format, 56, 56, "display format")
    if col.value_labels != "" {
      check_name(col.value_labels, "value-label name")
    }
    if (col.storage is Str(_) || col.storage == StrL) && col.value_labels != "" {
      invalid(0, "string variables cannot have numeric value labels")
    }
  }
  let sorts : Map[Int, Bool] = Map([])
  for n in s.sort_order {
    if n < 1 || n > k || sorts.contains(n) {
      invalid(0, "invalid sort order")
    }
    sorts[n] = true
  }
  let labels : Map[String, Bool] = Map([])
  for set in s.value_labels {
    check_name(set.name, "value-label name")
    if labels.contains(set.name) {
      invalid(0, "duplicate label definition")
    }
    labels[set.name] = true
    let values : Map[Int, Bool] = Map([])
    for entry in set.entries {
      if values.contains(entry.value) || entry.value == -2147483648 {
        invalid(0, "duplicate or invalid value-label key")
      }
      values[entry.value] = true
      check_text(entry.text, 32000, 128000, "value-label text")
    }
  }
  // Undefined label names are legal Stata metadata and are retained.
  let chars : Map[(String, String), Bool] = Map([])
  for ch in s.characteristics {
    check_name(ch.variable, "characteristic variable")
    check_name(ch.name, "characteristic name")
    if ch.variable != "_dta" && !names.contains(ch.variable) {
      invalid(0, "characteristic refers to unknown variable")
    }
    if chars.contains((ch.variable, ch.name)) {
      invalid(0, "duplicate characteristic")
    }
    chars[(ch.variable, ch.name)] = true
  }
}

///|
/// Encode a complete dataset. Finite Number values in Float32 columns are
/// rounded to IEEE binary32; overflows and invalid cell/storage pairs raise.
/// Identical strL contents share their first reference within this call;
/// text and binary contents are deduplicated separately.
pub fn encode(dataset : Dataset) -> Bytes raise DtaError {
  let s = dataset.schema
  validate_schema(s)
  let k = s.columns.length()
  let n = dataset.rows.length()
  if k == 0 && n != 0 {
    invalid(0, "observations require at least one variable")
  }
  let mut row_width = 0
  for c in s.columns {
    row_width += c.storage.width()
  }
  ignore(checked_product(row_width, n, 0))
  let w = Sink::new(s.endian)
  let offsets = Array::make(14, 0)
  w.text("<stata_dta><header><release>\{s.version}</release><byteorder>")
  w.text(if s.endian == Little { "LSF" } else { "MSF" })
  w.text("</byteorder><K>")
  let k_width = if s.version == 118 { 2 } else { 4 }
  w.uint(k.to_uint64(), k_width)
  w.text("</K><N>")
  w.uint(n.to_uint64(), 8)
  w.text("</N><label>")
  let label = @utf8.encode(s.label)
  w.uint(label.length().to_uint64(), 2)
  w.raw(label[:])
  w.text("</label><timestamp>")
  let timestamp = @utf8.encode(s.timestamp)
  w.uint(timestamp.length().to_uint64(), 1)
  w.raw(timestamp[:])
  w.text("</timestamp></header>")
  offsets[1] = w.bytes.length()
  w.text("<map>")
  let map_start = w.bytes.length()
  for _ in 0..<14 {
    w.uint(0, 8)
  }
  w.text("</map>")
  offsets[2] = w.bytes.length()
  w.text("<variable_types>")
  for c in s.columns {
    w.uint(c.storage.code().to_uint64(), 2)
  }
  w.text("</variable_types>")
  offsets[3] = w.bytes.length()
  w.text("<varnames>")
  for c in s.columns {
    w.fixed(c.name, 129)
  }
  w.text("</varnames>")
  offsets[4] = w.bytes.length()
  w.text("<sortlist>")
  for col in s.sort_order {
    w.uint(col.to_uint64(), k_width)
  }
  for _ in s.sort_order.length()..<(k + 1) {
    w.uint(0, k_width)
  }
  w.text("</sortlist>")
  offsets[5] = w.bytes.length()
  w.text("<formats>")
  for c in s.columns {
    w.fixed(c.format, 57)
  }
  w.text("</formats>")
  offsets[6] = w.bytes.length()
  w.text("<value_label_names>")
  for c in s.columns {
    w.fixed(c.value_labels, 129)
  }
  w.text("</value_label_names>")
  offsets[7] = w.bytes.length()
  w.text("<variable_labels>")
  for c in s.columns {
    w.fixed(c.label, 321)
  }
  w.text("</variable_labels>")
  offsets[8] = w.bytes.length()
  w.text("<characteristics>")
  for ch in s.characteristics {
    w.text("<ch>")
    w.uint(ch.data.length().to_uint64() + 258UL, 4)
    w.fixed(ch.variable, 129)
    w.fixed(ch.name, 129)
    w.raw(ch.data[:])
    w.text("</ch>")
  }
  w.text("</characteristics>")
  offsets[9] = w.bytes.length()
  w.text("<data>")
  let gso = Sink::new(s.endian)
  let shared : Map[StrLContent, (Int, Int)] = Map([])
  for r, row in dataset.rows {
    if row.length() != k {
      invalid(w.bytes.length(), "row \{r} has wrong number of cells")
    }
    for col, value in row {
      write_cell(
        w,
        gso,
        shared,
        s.columns[col].storage,
        value,
        s.version,
        col + 1,
        r + 1,
      )
    }
  }
  w.text("</data>")
  offsets[10] = w.bytes.length()
  w.text("<strls>")
  w.append(gso)
  w.text("</strls>")
  offsets[11] = w.bytes.length()
  w.text("<value_labels>")
  for set in s.value_labels {
    let entries = set.entries.copy()
    entries.sort_by((a, b) => a.value.compare(b.value))
    let txt = Sink::new(s.endian)
    let positions : Array[Int] = []
    for entry in entries {
      positions.push(txt.bytes.length())
      txt.text(entry.text)
      txt.uint(0, 1)
    }
    let table_len = 8UL +
      8UL * entries.length().to_uint64() +
      txt.bytes.length().to_uint64()
    if table_len > 2147483647UL {
      invalid(w.bytes.length(), "value-label table too large")
    }
    w.text("<lbl>")
    w.uint(table_len, 4)
    w.fixed(set.name, 129)
    w.uint(0, 3)
    w.uint(entries.length().to_uint64(), 4)
    w.uint(txt.bytes.length().to_uint64(), 4)
    for pos in positions {
      w.uint(pos.to_uint64(), 4)
    }
    for entry in entries {
      w.uint(entry.value.to_uint64(), 4)
    }
    w.append(txt)
    w.text("</lbl>")
  }
  w.text("</value_labels>")
  offsets[12] = w.bytes.length()
  w.text("</stata_dta>")
  offsets[13] = w.bytes.length()
  let map_bytes = Sink::new(s.endian)
  for pos in offsets {
    map_bytes.uint(pos.to_uint64(), 8)
  }
  let body = w.bytes.view()
  let mapping = map_bytes.bytes.view()
  Bytes::makei(body.length(), i => {
    if i >= map_start && i < map_start + mapping.length() {
      mapping[i - map_start]
    } else {
      body[i]
    }
  })
}

///|
fn write_cell(
  w : Sink,
  gso : Sink,
  shared : Map[StrLContent, (Int, Int)],
  storage : Storage,
  value : Value,
  version : Int,
  col : Int,
  row : Int,
) -> Unit raise DtaError {
  let p = w.bytes.length()
  match (storage, value) {
    (Str(n), Text(text)) => {
      let b = @utf8.encode(text)
      if b.length() > n || text.contains("\u0000") {
        invalid(
          p,
          "fixed string too long or contains NUL at row \{row}, column \{col}",
        )
      }
      w.raw(b[:])
      for _ in b.length()..<n {
        w.uint(0, 1)
      }
    }
    (StrL, Text("")) => w.uint(0, 8)
    (StrL, Text(_) | Binary(_)) => {
      let vlen = if version == 118 { 2 } else { 3 }
      let content : StrLContent = match value {
        Text(t) => Text(t)
        Binary(b) => Binary(b)
        _ => abort("unreachable")
      }
      // Reuse the first row/column reference across all strL columns. Keep
      // text and binary separate even when their encoded bytes are identical.
      if shared.get(content) is Some((v, o)) {
        w.uint(v.to_uint64(), vlen)
        w.uint(o.to_uint64(), 8 - vlen)
        return
      }
      w.uint(col.to_uint64(), vlen)
      w.uint(row.to_uint64(), 8 - vlen)
      let (kind, payload) = match value {
        Text(t) => {
          if t.contains("\u0000") {
            invalid(p, "strL text contains NUL; use Binary")
          }
          (130, @utf8.encode(t + "\u0000"))
        }
        Binary(b) => (129, b)
        _ => abort("unreachable")
      }
      gso.text("GSO")
      gso.uint(col.to_uint64(), 4)
      gso.uint(row.to_uint64(), 8)
      gso.uint(kind.to_uint64(), 1)
      gso.uint(payload.length().to_uint64(), 4)
      gso.raw(payload[:])
      shared[content] = (col, row)
    }
    (Byte | Int16 | Int32, Integer(n)) => {
      let (min, max) = match storage {
        Byte => (-127, 100)
        Int16 => (-32767, 32740)
        _ => (-2147483647, 2147483620)
      }
      if n < min || n > max {
        invalid(p, "integer outside storage range at row \{row}, column \{col}")
      }
      w.uint(n.to_uint64(), storage.width())
    }
    (Float32 | Float64, Number(n)) => {
      let raw = if storage == Float32 {
        Float::from_double(n).reinterpret_as_uint().to_uint64()
      } else {
        n.reinterpret_as_uint64()
      }
      let (mask, max) : (UInt64, UInt64) = if storage == Float32 {
        (0x7fffffffUL, 0x7effffffUL)
      } else {
        (0x7fffffffffffffffUL, 0x7fdfffffffffffffUL)
      }
      if (raw & mask) > max {
        invalid(p, "floating-point value outside Stata range")
      }
      w.uint(raw, storage.width())
    }
    (Byte | Int16 | Int32 | Float32 | Float64, Missing(tag)) => {
      if tag < 0 || tag > 26 {
        invalid(p, "missing tag must be 0..26")
      }
      let (base, step) : (UInt64, UInt64) = match storage {
        Byte => (101, 1)
        Int16 => (32741, 1)
        Int32 => (2147483621, 1)
        Float32 => (0x7f000000UL, 0x800UL)
        _ => (0x7fe0000000000000UL, 0x10000000000UL)
      }
      w.uint(base + tag.to_uint64() * step, storage.width())
    }
    _ =>
      invalid(
        p,
        "cell does not match declared storage at row \{row}, column \{col}",
      )
  }
}
