///|
priv struct WireCharacteristic {
  variable : String
  name : String
  data : Array[Int]
} derive(ToJson, @json.FromJson)

///|
priv struct WireSchema {
  version : Int
  endian : Endian
  label : String
  timestamp : String
  columns : Array[Column]
  sort_order : Array[Int]
  value_labels : Array[LabelSet]
  characteristics : Array[WireCharacteristic]
} derive(ToJson, @json.FromJson)

///|
priv struct WireDataset {
  moondta_exchange : Int
  schema : WireSchema
  rows : Array[Array[Json]]
} derive(ToJson)

///|
fn wire_schema(s : Schema) -> WireSchema {
  {
    version: s.version,
    endian: s.endian,
    label: s.label,
    timestamp: s.timestamp,
    columns: s.columns,
    sort_order: s.sort_order,
    value_labels: s.value_labels,
    characteristics: s.characteristics.map(c => {
      variable: c.variable,
      name: c.name,
      data: c.data.to_array().map(b => b.to_int()),
    }),
  }
}

///|
/// Metadata-only JSON for inspection; no row data is decoded.
pub fn Reader::inspect_json(self : Reader) -> Json {
  {
    "rows": self.count,
    "row_bytes": self.row_width,
    "schema": ToJson::to_json(wire_schema(self.metadata)),
  }
}

///|
/// A versioned, metadata-preserving JSON interchange. Floating-point cells
/// carry IEEE binary64 bits as hex strings, preserving negative zero exactly.
pub fn Dataset::to_exchange(self : Dataset) -> Json {
  let wire : WireDataset = {
    moondta_exchange: 1,
    schema: wire_schema(self.schema),
    rows: self.rows.map(row => row.map(value_to_wire)),
  }
  ToJson::to_json(wire)
}

///|
fn value_to_wire(value : Value) -> Json {
  match value {
    Integer(n) => { "int": n }
    Number(n) =>
      { "number_bits": n.reinterpret_as_uint64().to_string(radix=16) }
    Text(t) => { "text": t }
    Binary(b) => { "binary": b.to_array().map(x => x.to_int()).to_json() }
    Missing(m) => { "missing": m }
  }
}

///|
/// Emit a metadata header followed by one typed row per line, including LF.
/// Decoded rows are retained only for the current batch. Input bytes stay in memory.
/// Sink and decoding errors propagate immediately; the sink owns partial-output cleanup.
pub fn Reader::export_jsonl(
  self : Reader,
  write : (String) -> Unit raise,
  offset? : Int = 0,
  limit? : Int = self.count - offset,
  columns? : Array[Int],
  batch_size? : Int = 256,
) -> Unit raise {
  check_range(self.count, offset, limit)
  if batch_size < 1 {
    invalid(0, "batch size must be positive")
  }
  let indices = self.metadata.indices(columns).copy()
  if indices.is_empty() && limit > 0 {
    invalid(0, "cannot select zero variables from nonempty rows")
  }
  write(jsonl_header_line(self.metadata.project(indices), limit))
  self.each_batch(
    (_, rows) => {
      for row in rows {
        write(jsonl_row_line(row))
      }
    },
    offset~,
    limit~,
    columns=indices,
    batch_size~,
  )
}

///|
fn jsonl_header_line(schema : Schema, limit : Int) -> String {
  let header : Json = {
    "moondta_jsonl": 1,
    "rows": limit,
    "schema": ToJson::to_json(wire_schema(schema)),
  }
  header.stringify() + "\n"
}

///|
fn jsonl_row_line(row : Array[Value]) -> String {
  row.map(value_to_wire).to_json().stringify() + "\n"
}

///|
fn bytes_from_ints(a : Array[Int]) -> Bytes raise DtaError {
  Bytes::makei(a.length(), i => {
    if a[i] < 0 || a[i] > 255 {
      invalid(0, "JSON byte must be 0..255")
    }
    a[i].to_byte()
  })
}

///|
fn exact_int(json : Json) -> Int raise DtaError {
  guard json is Number(n, ..) &&
    n >= -2147483648.0 &&
    n <= 2147483647.0 &&
    n.to_int().to_double() == n else {
    raise Invalid(offset=0, message="expected an exact 32-bit integer")
  }
  n.to_int()
}

///|
fn parse_bits(s : String) -> UInt64 raise DtaError {
  if s.length() < 1 || s.length() > 16 {
    invalid(0, "number_bits needs 1..16 hexadecimal digits")
  }
  let mut result : UInt64 = 0
  for ch in s.iter() {
    let n = match ch {
      '0'..='9' => ch.to_int() - 48
      'a'..='f' => ch.to_int() - 87
      'A'..='F' => ch.to_int() - 55
      _ => raise Invalid(offset=0, message="invalid hexadecimal number_bits")
    }
    result = (result << 4) | n.to_uint64()
  }
  result
}

///|
/// Parse exchange version 1. Schema and wire types are checked here; encode
/// additionally validates each cell against its declared storage type.
pub fn from_exchange(json : Json) -> Dataset raise DtaError {
  guard json
    is {
      "moondta_exchange": version,
      "schema": raw_schema,
      "rows": Array(raw_rows),
      ..
    } else {
    raise Invalid(
      offset=0,
      message="expected exchange header, schema and row array",
    )
  }
  if exact_int(version) != 1 {
    invalid(0, "unsupported MoonDTA exchange version")
  }
  let wire_schema : WireSchema = @json.from_json(raw_schema) catch {
    e => raise Invalid(offset=0, message="invalid exchange schema: \{e}")
  }
  let schema = parse_wire_schema(wire_schema)
  let rows = raw_rows.map(row => row_from_wire(row, schema.columns.length()))
  { schema, rows, }
}

///|
fn parse_wire_schema(s : WireSchema) -> Schema raise DtaError {
  let schema : Schema = {
    version: s.version,
    endian: s.endian,
    label: s.label,
    timestamp: s.timestamp,
    columns: s.columns,
    sort_order: s.sort_order,
    value_labels: s.value_labels,
    characteristics: s.characteristics.map(c => {
      variable: c.variable,
      name: c.name,
      data: bytes_from_ints(c.data),
    }),
  }
  validate_schema(schema)
  schema
}

///|
fn row_from_wire(row : Json, width : Int) -> Array[Value] raise DtaError {
  guard row is Array(cells) else {
    raise Invalid(offset=0, message="expected a row array")
  }
  if width == 0 || cells.length() != width {
    invalid(0, "row width differs from schema or schema has no columns")
  }
  cells.map(value_from_wire)
}

///|
fn value_from_wire(j : Json) -> Value raise DtaError {
  guard j is Object(obj) && obj.length() == 1 else {
    raise Invalid(
      offset=0,
      message="exchange cell must have exactly one type key",
    )
  }
  match j {
    { "int": v, .. } => Integer(exact_int(v))
    { "number_bits": String(s), .. } =>
      Number(parse_bits(s).reinterpret_as_double())
    { "text": String(s), .. } => Text(s)
    { "binary": Array(bytes), .. } =>
      Binary(bytes_from_ints(bytes.map(exact_int)))
    { "missing": m, .. } => {
      let tag = exact_int(m)
      if tag < 0 || tag > 26 {
        invalid(0, "missing tag must be 0..26")
      }
      Missing(tag)
    }
    _ => raise Invalid(offset=0, message="invalid exchange cell")
  }
}

///|
/// Read exchange lines from a source. The first line supplies the projected schema
/// and row count. One array follows per row. The returned dataset retains its rows;
/// encode checks representability in the declared DTA storage types.
pub fn from_jsonl(next_line : () -> String? raise) -> Dataset raise {
  let (schema, count) = jsonl_header(next_line)
  let rows = []
  visit_jsonl_rows(next_line, count, schema.columns.length(), (_, row) => {
    rows.push(row)
  })
  { schema, rows, }
}

///|
fn jsonl_header(next_line : () -> String? raise) -> (Schema, Int) raise {
  guard next_line() is Some(first) else { fail("JSONL line 1: missing header") }
  try {
    guard @json.parse(first)
      is { "moondta_jsonl": version, "rows": size, "schema": raw, .. } else {
      fail("expected header with moondta_jsonl, rows and schema")
    }
    if exact_int(version) != 1 {
      fail("unsupported JSONL version")
    }
    let count = exact_int(size)
    if count < 0 {
      fail("negative row count")
    }
    let schema = parse_wire_schema(@json.from_json(raw))
    if count > 0 && schema.columns.is_empty() {
      fail("rows require columns")
    }
    (schema, count)
  } catch {
    e => fail("JSONL line 1: \{e}")
  }
}

///|
fn visit_jsonl_rows(
  next_line : () -> String? raise,
  count : Int,
  width : Int,
  visit : (Int, Array[Value]) -> Unit raise,
) -> Unit raise {
  for i in 0..<count {
    let n = i.to_int64() + 2L
    guard next_line() is Some(line) else {
      fail("JSONL line \{n}: expected a row, found EOF")
    }
    let row = row_from_wire(@json.parse(line), width) catch {
      e => fail("JSONL line \{n}: \{e}")
    }
    visit(i + 1, row)
  }
  if next_line() is Some(_) {
    fail("JSONL line \{count.to_int64() + 2L}: extra record")
  }
}
