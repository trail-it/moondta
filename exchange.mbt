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
} derive(ToJson, @json.FromJson)

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
    rows: self.rows.map(row => {
      row.map(v => {
        match v {
          Integer(n) => { "int": n }
          Number(n) =>
            { "number_bits": n.reinterpret_as_uint64().to_string(radix=16) }
          Text(t) => { "text": t }
          Binary(b) => { "binary": b.to_array().map(x => x.to_int()).to_json() }
          Missing(m) => { "missing": m }
        }
      })
    }),
  }
  ToJson::to_json(wire)
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
  let wire : WireDataset = @json.from_json(json) catch {
    e => raise Invalid(offset=0, message="invalid exchange document: \{e}")
  }
  if wire.moondta_exchange != 1 {
    invalid(0, "unsupported MoonDTA exchange version")
  }
  let s = wire.schema
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
  let rows = wire.rows.map(row => {
    row.map(j => {
      guard j is Object(obj) && obj.length() == 1 else {
        raise Invalid(
          offset=0,
          message="exchange cell must have exactly one type key",
        )
      }
      try {
        match j {
          { "int": v, .. } => Integer(@json.from_json(v))
          { "number_bits": String(s), .. } =>
            Number(parse_bits(s).reinterpret_as_double())
          { "text": String(s), .. } => Text(s)
          { "binary": b, .. } => Binary(bytes_from_ints(@json.from_json(b)))
          { "missing": m, .. } => {
            let tag : Int = @json.from_json(m)
            if tag < 0 || tag > 26 {
              invalid(0, "missing tag must be 0..26")
            }
            Missing(tag)
          }
          _ => raise Invalid(offset=0, message="invalid exchange cell")
        }
      } catch {
        Invalid(offset~, message~) => raise Invalid(offset~, message~)
        e => raise Invalid(offset=0, message="invalid exchange cell: \{e}")
      }
    })
  })
  { schema, rows, }
}
