///|
/// An indexed view of an in-memory DTA file. Rows are decoded on demand.
pub struct Reader {
  priv bytes : Bytes
  priv metadata : Schema
  priv count : Int
  priv data_start : Int
  priv row_width : Int
  priv column_offsets : Array[Int]
  priv strls : Map[(UInt64, UInt64), StrLObject]
}

///|
priv struct StrLObject {
  kind : Int
  start : Int
  length : Int
}

///|
/// Validate the map and metadata, index strLs, and defer row decoding.
pub fn open(bytes : Bytes) -> Reader raise DtaError {
  let input : DtaInput = {
    length: bytes.length().to_int64(),
    read_view: (pos, n) => bytes[pos.to_int():pos.to_int() + n],
  }
  try {
    let layout = input.layout()
    let strls = Map([])
    while layout.objects.pos < layout.objects.end {
      let (key, object) = layout.next_object()
      if strls.contains(key) {
        file_error(object.start, "duplicate strL key")
      }
      strls[key] = StrLObject::{
        kind: object.kind,
        start: object.start.to_int(),
        length: object.length,
      }
    }
    {
      bytes,
      metadata: layout.metadata,
      count: layout.count,
      data_start: layout.data_start.to_int(),
      row_width: layout.row_width,
      column_offsets: layout.column_offsets,
      strls,
    }
  } catch {
    InvalidFile(offset~, message~) =>
      raise Invalid(offset=offset.to_int(), message~)
  }
}

///|
pub fn Reader::row_count(self : Reader) -> Int {
  self.count
}

///|
/// Number of variables, without copying metadata.
pub fn Reader::column_count(self : Reader) -> Int {
  self.metadata.columns.length()
}

///|
/// Resolve exact variable names into zero-based indices in caller order.
pub fn Reader::column_indices(
  self : Reader,
  names : Array[String],
) -> Array[Int] raise DtaError {
  self.metadata.named_indices(names)
}

///|
fn Schema::named_indices(
  self : Schema,
  names : Array[String],
) -> Array[Int] raise DtaError {
  let lookup : Map[String, Int] = Map([])
  for i, col in self.columns {
    lookup[col.name] = i
  }
  names.map(name => {
    guard lookup.get(name) is Some(i) else {
      raise Invalid(offset=0, message="unknown or duplicate variable: \{name}")
    }
    lookup.remove(name)
    i
  })
}

///|
fn Reader::read_strl(
  self : Reader,
  object : StrLObject,
) -> Value raise DtaError {
  let payload = self.bytes[object.start:object.start + object.length]
  if object.kind == 129 {
    return Binary(payload.to_owned())
  }
  for i in 0..<(object.length - 1) {
    if payload[i] == 0 {
      invalid(object.start + i, "strL text contains embedded NUL")
    }
  }
  Text(decode_utf8(payload[:object.length - 1], object.start))
}

///|
fn Cursor::strl_key(
  c : Cursor,
  version : Int,
) -> (UInt64, UInt64) raise DtaError {
  let vlen = if version == 118 { 2 } else { 3 }
  let variable = c.uint(vlen)
  let observation = c.uint(8 - vlen)
  (variable, observation)
}

///|
/// Scan every strL object (including unreferenced objects) and every cell.
/// Validate each text payload once, then scan cells and strL references in file order.
pub fn Reader::verify(
  self : Reader,
  batch_size? : Int = 256,
) -> Unit raise DtaError {
  if batch_size < 1 {
    invalid(0, "batch size must be positive")
  }
  for object in self.strls.values() {
    // Binary data has no encoding constraints; open already checked its bounds.
    if object.kind != 129 {
      ignore(self.read_strl(object))
    }
  }
  let mut offset = 0
  let cache = Map([])
  while offset < self.count {
    let remaining = self.count - offset
    let limit = if batch_size < remaining { batch_size } else { remaining }
    let c = Cursor::new(
      self.bytes,
      self.metadata.endian,
      start=self.data_start + offset * self.row_width,
    )
    for _ in 0..<limit {
      for col in self.metadata.columns {
        if col.storage == StrL {
          let p = c.pos
          let key = c.strl_key(self.metadata.version)
          if key != (0UL, 0UL) && !self.strls.contains(key) {
            invalid(p, "unresolved strL reference")
          }
        } else {
          ignore(self.read_cell(c, col.storage, cache))
        }
      }
    }
    offset += limit
  }
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
  check_range(self.count, offset, limit)
  self.decode_rows(offset, limit, self.metadata.indices(columns))
}

///|
fn check_range(count : Int, offset : Int, limit : Int) -> Unit raise DtaError {
  if offset < 0 || offset > count || limit < 0 || limit > count - offset {
    invalid(0, "row range outside dataset")
  }
}

///|
/// Visit decoded row batches, starting at their absolute zero-based offset.
/// Column indices are snapshotted before the first callback. An empty range emits no batches.
pub fn Reader::each_batch(
  self : Reader,
  visit : (Int, Array[Array[Value]]) -> Unit raise,
  offset? : Int = 0,
  limit? : Int = self.count - offset,
  columns? : Array[Int],
  batch_size? : Int = 256,
) -> Unit raise {
  check_range(self.count, offset, limit)
  if batch_size <= 0 {
    invalid(0, "batch size must be positive")
  }
  let indices = self.metadata.indices(columns).copy()
  let mut pos = offset
  let end = offset + limit
  while pos < end {
    let size = if end - pos < batch_size { end - pos } else { batch_size }
    visit(pos, self.decode_rows(pos, size, indices))
    pos += size
  }
}

///|
fn Reader::decode_rows(
  self : Reader,
  offset : Int,
  limit : Int,
  indices : Array[Int],
) -> Array[Array[Value]] raise DtaError {
  // Reuse shared objects only for this batch; Reader never retains decoded text.
  let cache : Map[(UInt64, UInt64), Value] = Map([])
  Array::makei(limit, r => {
    let base = self.data_start + (offset + r) * self.row_width
    indices.map(i => {
      let c = Cursor::new(
        self.bytes,
        self.metadata.endian,
        start=base + self.column_offsets[i],
      )
      self.read_cell(c, self.metadata.columns[i].storage, cache)
    })
  })
}

///|
fn Schema::indices(
  self : Schema,
  selected : Array[Int]?,
) -> Array[Int] raise DtaError {
  let indices = selected.unwrap_or_else(() => {
    Array::makei(self.columns.length(), i => i)
  })
  let seen : Map[Int, Bool] = Map([])
  for i in indices {
    if i < 0 || i >= self.columns.length() || seen.contains(i) {
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
  let indices = self.metadata.indices(Some(columns))
  if indices.is_empty() && limit > 0 {
    invalid(0, "cannot select zero variables from nonempty rows")
  }
  {
    schema: self.metadata.project(indices),
    rows: self.read_rows(offset~, limit~, columns=indices),
  }
}

///|
fn Schema::project(self : Schema, indices : Array[Int]) -> Schema {
  let s = clone_schema(self)
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
  { ..s, columns: selected, sort_order, characteristics, }
}

///|
fn Reader::read_cell(
  self : Reader,
  c : Cursor,
  storage : Storage,
  cache : Map[(UInt64, UInt64), Value],
) -> Value raise DtaError {
  if storage == StrL {
    let p = c.pos
    let key = c.strl_key(self.metadata.version)
    if key == (0UL, 0UL) {
      Text("")
    } else {
      if cache.get(key) is Some(value) {
        return value
      }
      match self.strls.get(key) {
        Some(object) => {
          let value = self.read_strl(object)
          cache[key] = value
          value
        }
        None => raise Invalid(offset=p, message="unresolved strL reference")
      }
    }
  } else {
    c.inline_cell(storage)
  }
}

///|
fn Cursor::inline_cell(c : Cursor, storage : Storage) -> Value raise DtaError {
  let p = c.pos
  match storage {
    Str(n) => Text(c.cstring(n, terminated=false))
    StrL => raise Invalid(offset=p, message="strL requires an object index")
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
