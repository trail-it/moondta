///|
/// An indexed view of an in-memory DTA file. Rows are decoded on demand.
pub struct Reader {
  priv bytes : Bytes
  priv metadata : Schema
  priv count : Int
  priv data_start : Int
  priv row_width : Int
  priv column_offsets : Array[Int]
  priv strls : Map[(UInt64, UInt64), Value]
}

///|
fn section(
  bytes : Bytes,
  offsets : Array[Int],
  index : Int,
  name : String,
  endian : Endian,
) -> Cursor raise DtaError {
  let c = Cursor::new(
    bytes,
    endian,
    start=offsets[index],
    end=offsets[index + 1],
  )
  c.tag("<\{name}>")
  let end = c.end - name.length() - 3
  if end < c.pos {
    invalid(c.pos, "section too short: \{name}")
  }
  let tail = Cursor::new(bytes, endian, start=end, end=c.end)
  tail.tag("</\{name}>")
  Cursor::new(bytes, endian, start=c.pos, end~)
}

///|
fn finished(c : Cursor) -> Unit raise DtaError {
  if c.pos != c.end {
    invalid(c.pos, "unexpected bytes in section")
  }
}

///|
/// Validate the map and metadata, index strLs, and defer row decoding.
pub fn open(bytes : Bytes) -> Reader raise DtaError {
  let c = Cursor::new(bytes, Little)
  c.tag("<stata_dta><header><release>")
  let version = match c.text(3) {
    "118" => 118
    "119" => 119
    _ =>
      raise Invalid(
        offset=c.pos - 3,
        message="only DTA 118 and 119 are supported",
      )
  }
  c.tag("</release><byteorder>")
  c.endian = match c.text(3) {
    "LSF" => Little
    "MSF" => Big
    _ => raise Invalid(offset=c.pos - 3, message="invalid byte order")
  }
  let endian = c.endian
  c.tag("</byteorder><K>")
  let k = c.size(if version == 118 { 2 } else { 4 })
  if (version == 118 && k > 32767) || k > 120000 {
    invalid(c.pos, "variable count exceeds DTA version limit")
  }
  c.tag("</K><N>")
  let count = c.size(8)
  if k == 0 && count != 0 {
    invalid(c.pos, "observations require at least one variable")
  }
  c.tag("</N><label>")
  let label_len = c.size(2)
  if label_len > 320 {
    invalid(c.pos, "dataset label exceeds 320 UTF-8 bytes")
  }
  let label = c.text(label_len)
  c.tag("</label><timestamp>")
  let timestamp_len = c.size(1)
  let timestamp = c.text(timestamp_len)
  c.tag("</timestamp></header>")
  let map_start = c.pos
  c.tag("<map>")
  let offsets = Array::makei(14, _ => c.size(8))
  c.tag("</map>")
  if offsets[0] != 0 ||
    offsets[1] != map_start ||
    offsets[2] != c.pos ||
    offsets[13] > bytes.length() {
    invalid(
      map_start,
      "map mismatch: start=\{offsets[0]}, map=\{offsets[1]} (expected \{map_start}), types=\{offsets[2]} (expected \{c.pos}), end=\{offsets[13]} (file \{bytes.length()})",
    )
  }
  for i in 1..<14 {
    if offsets[i] <= offsets[i - 1] || offsets[i] > bytes.length() {
      invalid(map_start, "map offsets are not ordered within file")
    }
  }
  // Stata's official examples include a newline beyond the logical EOF in map[13].
  let trailer = bytes[offsets[13]:]
  if !trailer.is_empty() && trailer != b"\n"[:] && trailer != b"\r\n"[:] {
    invalid(offsets[13], "unexpected bytes after logical end of file")
  }
  let tail = Cursor::new(bytes, endian, start=offsets[12], end=offsets[13])
  tail.tag("</stata_dta>")
  finished(tail)
  let types = section(bytes, offsets, 2, "variable_types", endian)
  if types.end - types.pos != checked_product(k, 2, types.pos) {
    invalid(types.pos, "wrong variable_types size")
  }
  let storages = Array::makei(k, _ => {
    storage_from_code(types.size(2), types.pos - 2)
  })
  let names = section(bytes, offsets, 3, "varnames", endian)
  let varnames = Array::makei(k, _ => names.cstring(129))
  finished(names)
  let sorts = section(bytes, offsets, 4, "sortlist", endian)
  let sort_order : Array[Int] = []
  let sorted_columns : Map[Int, Bool] = Map([])
  let mut stopped = false
  for _ in 0..<(k + 1) {
    let n = sorts.size(if version == 118 { 2 } else { 4 })
    if n == 0 {
      stopped = true
    } else {
      if stopped || n > k || sorted_columns.contains(n) {
        invalid(sorts.pos, "invalid sort list")
      }
      sorted_columns[n] = true
      sort_order.push(n)
    }
  }
  if !stopped {
    invalid(sorts.pos, "unterminated sort list")
  }
  finished(sorts)
  let formats = section(bytes, offsets, 5, "formats", endian)
  let fmts = Array::makei(k, _ => formats.cstring(57))
  finished(formats)
  let labels = section(bytes, offsets, 6, "value_label_names", endian)
  let labelnames = Array::makei(k, _ => labels.cstring(129))
  finished(labels)
  let varlabels = section(bytes, offsets, 7, "variable_labels", endian)
  let columns = Array::makei(k, i => Column::{
    name: varnames[i],
    storage: storages[i],
    format: fmts[i],
    value_labels: labelnames[i],
    label: varlabels.cstring(321),
  })
  finished(varlabels)
  let ch = section(bytes, offsets, 8, "characteristics", endian)
  let characteristics : Array[Characteristic] = []
  while ch.pos < ch.end {
    ch.tag("<ch>")
    let len = ch.size(4)
    if len < 258 || len > ch.end - ch.pos {
      invalid(ch.pos, "invalid characteristic length")
    }
    let variable = ch.cstring(129)
    let name = ch.cstring(129)
    let data = ch.take(len - 258).to_owned()
    ch.tag("</ch>")
    characteristics.push({ variable, name, data, })
  }
  let data = section(bytes, offsets, 9, "data", endian)
  let column_offsets : Array[Int] = []
  let mut row_width = 0
  for col in columns {
    column_offsets.push(row_width)
    row_width += col.storage.width()
  }
  if checked_product(row_width, count, data.pos) != data.end - data.pos {
    invalid(data.pos, "row count and storage widths do not match data size")
  }
  let gso = section(bytes, offsets, 10, "strls", endian)
  let strls : Map[(UInt64, UInt64), Value] = Map([])
  while gso.pos < gso.end {
    gso.tag("GSO")
    let v = gso.uint(4)
    let o = gso.uint(8)
    if v == 0 || v > k.to_uint64() || o == 0 || o > count.to_uint64() {
      invalid(gso.pos, "strL key outside dataset")
    }
    if strls.contains((v, o)) {
      invalid(gso.pos, "duplicate strL key")
    }
    let kind = gso.size(1)
    let len = gso.size(4)
    let payload = gso.take(len)
    let value = match kind {
      129 => Binary(payload.to_owned())
      130 => {
        if len == 0 || payload[len - 1] != 0 {
          invalid(gso.pos - len, "strL text must end in NUL")
        }
        for i in 0..<(len - 1) {
          if payload[i] == 0 {
            invalid(gso.pos - len + i, "strL text contains embedded NUL")
          }
        }
        Text(decode_utf8(payload[:len - 1], gso.pos - len))
      }
      _ => raise Invalid(offset=gso.pos - len - 5, message="unknown strL kind")
    }
    strls[(v, o)] = value
  }
  let vl = section(bytes, offsets, 11, "value_labels", endian)
  let value_labels : Array[LabelSet] = []
  while vl.pos < vl.end {
    vl.tag("<lbl>")
    let len = vl.size(4)
    let name = vl.cstring(129)
    ignore(vl.take(3))
    let table_start = vl.pos
    let n = vl.size(4)
    let text_len = vl.size(4)
    let needed = n.to_uint64() * 8UL + 8UL + text_len.to_uint64()
    if needed != len.to_uint64() || len > vl.end - table_start {
      invalid(table_start, "invalid value-label table size")
    }
    let positions = Array::makei(n, _ => vl.size(4))
    let values = Array::makei(n, _ => vl.uint(4).to_int())
    let text_start = vl.pos
    ignore(vl.take(text_len))
    let entries = Array::makei(n, i => {
      if positions[i] >= text_len {
        invalid(text_start, "value-label offset outside text table")
      }
      let t = Cursor::new(
        bytes,
        endian,
        start=text_start + positions[i],
        end=text_start + text_len,
      )
      LabelEntry::{ value: values[i], text: t.cstring(t.end - t.pos), }
    })
    vl.tag("</lbl>")
    value_labels.push({ name, entries, })
  }
  let metadata : Schema = {
    version,
    endian,
    label,
    timestamp,
    columns,
    sort_order,
    value_labels,
    characteristics,
  }
  validate_schema(metadata)
  {
    bytes,
    metadata,
    count,
    data_start: data.pos,
    row_width,
    column_offsets,
    strls,
  }
}

///|
pub fn Reader::row_count(self : Reader) -> Int {
  self.count
}

///|
pub fn Reader::schema(self : Reader) -> Schema {
  clone_schema(self.metadata)
}

///|
fn clone_schema(s : Schema) -> Schema {
  {
    ..s,
    columns: s.columns.copy(),
    sort_order: s.sort_order.copy(),
    characteristics: s.characteristics.copy(),
    value_labels: s.value_labels.map(v => { ..v, entries: v.entries.copy(), }),
  }
}

///|
/// Decode a bounded row range and optional zero-based column indices in requested order.
pub fn Reader::read_rows(
  self : Reader,
  offset? : Int = 0,
  limit? : Int = self.count - offset,
  columns? : Array[Int],
) -> Array[Array[Value]] raise DtaError {
  if offset < 0 ||
    offset > self.count ||
    limit < 0 ||
    limit > self.count - offset {
    invalid(0, "row range outside dataset")
  }
  let indices = self.indices(columns)
  Array::makei(limit, r => {
    let base = self.data_start + (offset + r) * self.row_width
    indices.map(i => {
      let c = Cursor::new(
        self.bytes,
        self.metadata.endian,
        start=base + self.column_offsets[i],
      )
      self.read_cell(c, self.metadata.columns[i].storage)
    })
  })
}

///|
fn Reader::indices(
  self : Reader,
  selected : Array[Int]?,
) -> Array[Int] raise DtaError {
  let indices = selected.unwrap_or_else(() => {
    Array::makei(self.metadata.columns.length(), i => i)
  })
  let seen : Map[Int, Bool] = Map([])
  for i in indices {
    if i < 0 || i >= self.metadata.columns.length() || seen.contains(i) {
      invalid(0, "invalid or duplicate column index")
    }
    seen[i] = true
  }
  indices
}

///|
pub fn Reader::read(self : Reader) -> Dataset raise DtaError {
  { schema: self.schema(), rows: self.read_rows(), }
}

///|
/// Select variables, retaining dataset characteristics, applicable variable
/// characteristics, and all label definitions. Invalidated sort suffixes are removed.
pub fn Reader::select(
  self : Reader,
  columns : Array[Int],
  offset? : Int = 0,
  limit? : Int = self.count - offset,
) -> Dataset raise DtaError {
  let indices = self.indices(Some(columns))
  if indices.is_empty() && limit > 0 {
    invalid(0, "cannot select zero variables from nonempty rows")
  }
  let s = self.schema()
  let selected = indices.map(i => s.columns[i])
  let positions : Map[Int, Int] = Map([])
  for i, old in indices {
    positions[old + 1] = i + 1
  }
  let sort_order : Array[Int] = []
  for old in s.sort_order {
    match positions.get(old) {
      Some(new) => sort_order.push(new)
      None => break
    }
  }
  let characteristics = s.characteristics.filter(c => {
    c.variable == "_dta" || selected.any(col => col.name == c.variable)
  })
  {
    schema: { ..s, columns: selected, sort_order, characteristics, },
    rows: self.read_rows(offset~, limit~, columns=indices),
  }
}

///|
fn Reader::read_cell(
  self : Reader,
  c : Cursor,
  storage : Storage,
) -> Value raise DtaError {
  let p = c.pos
  match storage {
    Str(n) => Text(c.cstring(n, terminated=false))
    StrL => {
      let vlen = if self.metadata.version == 118 { 2 } else { 3 }
      let v = c.uint(vlen)
      let o = c.uint(8 - vlen)
      if v == 0 && o == 0 {
        Text("")
      } else {
        match self.strls.get((v, o)) {
          Some(value) => value
          None => raise Invalid(offset=p, message="unresolved strL reference")
        }
      }
    }
    Byte | Int16 | Int32 => {
      let w = storage.width()
      let raw = c.uint(w).to_int()
      let value = if w == 1 {
        raw << 24 >> 24
      } else if w == 2 {
        raw << 16 >> 16
      } else {
        raw
      }
      let missing = match storage {
        Byte => 101
        Int16 => 32741
        _ => 2147483621
      }
      if value >= missing {
        Missing(value - missing)
      } else {
        let min = match storage {
          Byte => -127
          Int16 => -32767
          _ => -2147483647
        }
        if value < min {
          invalid(p, "integer uses reserved minimum")
        }
        Integer(value)
      }
    }
    Float32 | Float64 => {
      let raw = c.uint(storage.width())
      let (base, step, max) : (UInt64, UInt64, UInt64) = if storage == Float32 {
        (0x7f000000UL, 0x800UL, 0x7effffffUL)
      } else {
        (0x7fe0000000000000UL, 0x10000000000UL, 0x7fdfffffffffffffUL)
      }
      let signless = if storage == Float32 {
        raw & 0x7fffffffUL
      } else {
        raw & 0x7fffffffffffffffUL
      }
      if raw >= base && raw <= base + 26UL * step && (raw - base) % step == 0 {
        Missing(((raw - base) / step).to_int())
      } else {
        if signless > max {
          invalid(p, "invalid or noncanonical floating-point value")
        }
        let number = if storage == Float32 {
          Float::reinterpret_from_uint(raw.to_uint()).to_double()
        } else {
          raw.reinterpret_as_double()
        }
        Number(number)
      }
    }
  }
}
