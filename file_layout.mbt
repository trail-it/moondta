///|
priv struct DtaLayout {
  metadata : Schema
  count : Int
  data_start : Int64
  row_width : Int
  column_offsets : Array[Int]
  objects : FileCursor
}

///|
fn DtaInput::section(
  self : DtaInput,
  offsets : Array[Int64],
  i : Int,
  name : String,
  endian : Endian,
) -> FileCursor raise DtaFileError {
  let start = offsets[i]
  let end = offsets[i + 1]
  let c = self.cursor(endian, start~, end~)
  c.tag("<\{name}>")
  let content_start = c.pos
  let content_end = end - (name.length() + 3).to_int64()
  if content_end < content_start {
    file_error(content_start, "section too short: \{name}")
  }
  c.pos = content_end
  c.tag("</\{name}>")
  self.cursor(endian, start=content_start, end=content_end)
}

///|
fn DtaInput::layout(input : DtaInput) -> DtaLayout raise DtaFileError {
  let c = input.cursor(Little, start=0L, end=input.length)
  c.tag("<stata_dta><header><release>")
  let version = match c.text(3) {
    "118" => 118
    "119" => 119
    _ => file_error(c.pos - 3L, "only DTA 118 and 119 are supported")
  }
  c.tag("</release><byteorder>")
  c.endian = match c.text(3) {
    "LSF" => Little
    "MSF" => Big
    _ => file_error(c.pos - 3L, "invalid byte order")
  }
  let endian = c.endian
  c.tag("</byteorder><K>")
  let k = c.size(if version == 118 { 2 } else { 4 })
  if (version == 118 && k > 32767) || k > 120000 {
    file_error(c.pos, "variable count exceeds DTA version limit")
  }
  c.tag("</K><N>")
  let count = c.size(8)
  if k == 0 && count != 0 {
    file_error(c.pos, "observations require at least one variable")
  }
  c.tag("</N><label>")
  let label_len = c.size(2)
  if label_len > 320 {
    file_error(c.pos, "dataset label exceeds 320 UTF-8 bytes")
  }
  let label = c.text(label_len)
  c.tag("</label><timestamp>")
  let timestamp_len = c.size(1)
  let timestamp = c.text(timestamp_len)
  c.tag("</timestamp></header>")
  let map_start = c.pos
  c.tag("<map>")
  let offsets = Array::makei(14, _ => {
    let pos = c.uint(8)
    if pos > input.length.reinterpret_as_uint64() {
      file_error(map_start, "map offset outside file")
    }
    pos.reinterpret_as_int64()
  })
  c.tag("</map>")
  if offsets[0] != 0L ||
    offsets[1] != map_start ||
    offsets[2] != c.pos ||
    offsets[13] > input.length {
    file_error(
      map_start,
      "map mismatch: start=\{offsets[0]}, map=\{offsets[1]} (expected \{map_start}), types=\{offsets[2]} (expected \{c.pos}), end=\{offsets[13]} (file \{input.length})",
    )
  }
  for i in 1..<14 {
    if offsets[i] <= offsets[i - 1] || offsets[i] > input.length {
      file_error(map_start, "map offsets are not ordered within file")
    }
  }
  // Stata's official examples include a newline beyond the logical EOF in map[13].
  let extra = input.length - offsets[13]
  if extra > 2L {
    file_error(offsets[13], "unexpected bytes after logical end of file")
  }
  let trailer = (input.read_view)(offsets[13], extra.to_int())
  if !trailer.is_empty() && trailer != b"\n"[:] && trailer != b"\r\n"[:] {
    file_error(offsets[13], "unexpected bytes after logical end of file")
  }
  let tail = input.cursor(endian, start=offsets[12], end=offsets[13])
  tail.tag("</stata_dta>")
  tail.finished()
  let types = input.section(offsets, 2, "variable_types", endian)
  if types.end - types.pos != k.to_int64() * 2L {
    file_error(types.pos, "wrong variable_types size")
  }
  let storages = Array::makei(k, _ => {
    let code = types.size(2)
    storage_from_code(code, 0) catch {
      Invalid(message~, ..) => file_error(types.pos - 2L, message)
    }
  })
  let names = input.section(offsets, 3, "varnames", endian)
  let varnames = Array::makei(k, _ => names.cstring(129))
  names.finished()
  let sorts = input.section(offsets, 4, "sortlist", endian)
  let sort_order : Array[Int] = []
  let sorted_columns : Map[Int, Bool] = Map([])
  let mut stopped = false
  for _ in 0..<(k + 1) {
    let n = sorts.size(if version == 118 { 2 } else { 4 })
    if n == 0 {
      stopped = true
    } else {
      if stopped || n > k || sorted_columns.contains(n) {
        file_error(sorts.pos, "invalid sort list")
      }
      sorted_columns[n] = true
      sort_order.push(n)
    }
  }
  if !stopped {
    file_error(sorts.pos, "unterminated sort list")
  }
  sorts.finished()
  let formats = input.section(offsets, 5, "formats", endian)
  let fmts = Array::makei(k, _ => formats.cstring(57))
  formats.finished()
  let labels = input.section(offsets, 6, "value_label_names", endian)
  let labelnames = Array::makei(k, _ => labels.cstring(129))
  labels.finished()
  let varlabels = input.section(offsets, 7, "variable_labels", endian)
  let columns = Array::makei(k, i => Column::{
    name: varnames[i],
    storage: storages[i],
    format: fmts[i],
    value_labels: labelnames[i],
    label: varlabels.cstring(321),
  })
  varlabels.finished()
  let ch = input.section(offsets, 8, "characteristics", endian)
  let characteristics : Array[Characteristic] = []
  while ch.pos < ch.end {
    ch.tag("<ch>")
    let len = ch.size(4)
    if len < 258 || len.to_int64() > ch.end - ch.pos {
      file_error(ch.pos, "invalid characteristic length")
    }
    let variable = ch.cstring(129)
    let name = ch.cstring(129)
    let data = ch.take(len - 258).to_owned()
    ch.tag("</ch>")
    characteristics.push({ variable, name, data, })
  }
  let data = input.section(offsets, 9, "data", endian)
  let column_offsets : Array[Int] = []
  let mut row_width = 0
  for col in columns {
    column_offsets.push(row_width)
    row_width += col.storage.width() catch {
      Invalid(message~, ..) => file_error(data.pos, message)
    }
  }
  if row_width.to_int64() * count.to_int64() != data.end - data.pos {
    file_error(data.pos, "row count and storage widths do not match data size")
  }
  let vl = input.section(offsets, 11, "value_labels", endian)
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
    if needed != len.to_uint64() || len.to_int64() > vl.end - table_start {
      file_error(table_start, "invalid value-label table size")
    }
    let positions = Array::makei(n, _ => vl.size(4))
    let values = Array::makei(n, _ => vl.uint(4).to_int())
    let text_start = vl.pos
    vl.skip(text_len.to_int64())
    let t = input.cursor(
      endian,
      start=text_start,
      end=text_start + text_len.to_int64(),
    )
    let entries = Array::makei(n, i => {
      if positions[i] >= text_len {
        file_error(text_start, "value-label offset outside text table")
      }
      t.pos = text_start + positions[i].to_int64()
      LabelEntry::{ value: values[i], text: t.label_text(), }
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
  validate_schema(metadata) catch {
    Invalid(offset~, message~) => file_error(offset.to_int64(), message)
  }
  {
    metadata,
    count,
    data_start: data.pos,
    row_width,
    column_offsets,
    objects: input.section(offsets, 10, "strls", endian),
  }
}

///|
priv struct FileObject {
  kind : Int
  start : Int64
  length : Int
}

///|
fn DtaLayout::next_object(
  self : DtaLayout,
) -> ((UInt64, UInt64), FileObject) raise DtaFileError {
  let c = self.objects
  c.tag("GSO")
  let v = c.uint(4)
  let o = c.uint(8)
  if v == 0 ||
    v > self.metadata.columns.length().to_uint64() ||
    o == 0 ||
    o > self.count.to_uint64() {
    file_error(c.pos, "strL key outside dataset")
  }
  let kind = c.size(1)
  let length = c.size(4)
  let start = c.pos
  c.skip(length.to_int64())
  match kind {
    129 => ()
    130 => {
      if length == 0 {
        file_error(start, "strL text must end in NUL")
      }
      c.pos -= 1L
      if c.uint(1) != 0 {
        file_error(start, "strL text must end in NUL")
      }
    }
    _ => file_error(start - 5L, "unknown strL kind")
  }
  ((v, o), { kind, start, length, })
}
