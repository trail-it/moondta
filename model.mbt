///|
pub(all) suberror DtaError {
  Invalid(offset~ : Int, message~ : String)
} derive(Debug)

///|
pub(all) enum Endian {
  Little
  Big
} derive(Debug, Eq, ToJson, @json.FromJson)

///|
pub(all) enum Storage {
  Byte
  Int16
  Int32
  Float32
  Float64
  Str(Int)
  StrL
} derive(Debug, Eq, ToJson, @json.FromJson)

///|
/// Missing(0) is '.', Missing(1..26) is '.a' through '.z'.
/// Binary is supported only by strL; dates remain numeric with a column format.
pub(all) enum Value {
  Integer(Int)
  Number(Double)
  Text(String)
  Binary(Bytes)
  Missing(Int)
} derive(Debug, Eq)

///|
pub(all) struct Column {
  name : String
  storage : Storage
  label : String
  format : String
  value_labels : String
} derive(Debug, Eq, ToJson, @json.FromJson)

///|
/// Keys use Stata long encoding, including 2147483621..2147483647 for missings.
pub(all) struct LabelEntry {
  value : Int
  text : String
} derive(Debug, Eq, ToJson, @json.FromJson)

///|
pub(all) struct LabelSet {
  name : String
  entries : Array[LabelEntry]
} derive(Debug, Eq, ToJson, @json.FromJson)

///|
/// Raw characteristic payload, including any terminating NUL. This preserves
/// dataset notes and application-specific attributes without interpretation.
pub(all) struct Characteristic {
  variable : String
  name : String
  data : Bytes
} derive(Debug, Eq)

///|
pub(all) struct Schema {
  version : Int
  endian : Endian
  label : String
  timestamp : String
  columns : Array[Column]
  // One-based column indices; the on-disk terminating zero is implicit.
  sort_order : Array[Int]
  value_labels : Array[LabelSet]
  characteristics : Array[Characteristic]
} derive(Debug, Eq)

///|
pub(all) struct Dataset {
  schema : Schema
  rows : Array[Array[Value]]
} derive(Debug, Eq)

///|
pub fn Column::new(
  name : String,
  storage : Storage,
  label? : String = "",
  format? : String = "",
  value_labels? : String = "",
) -> Column {
  let format = if format != "" {
    format
  } else {
    match storage {
      Str(_) | StrL => "%9s"
      Float32 => "%9.0g"
      Float64 => "%10.0g"
      _ => "%12.0g"
    }
  }
  { name, storage, label, format, value_labels, }
}

///|
pub fn Schema::new(
  columns : Array[Column],
  version? : Int = 118,
  endian? : Endian = Little,
  label? : String = "",
  timestamp? : String = "",
  sort_order? : Array[Int] = [],
  value_labels? : Array[LabelSet] = [],
  characteristics? : Array[Characteristic] = [],
) -> Schema {
  {
    version,
    endian,
    label,
    timestamp,
    columns,
    sort_order,
    value_labels,
    characteristics,
  }
}

///|
fn invalid(offset : Int, message : String) -> Unit raise DtaError {
  raise Invalid(offset~, message~)
}

///|
pub fn Storage::width(self : Storage) -> Int raise DtaError {
  match self {
    Byte => 1
    Int16 => 2
    Int32 | Float32 => 4
    Float64 | StrL => 8
    Str(n) => {
      if n < 1 || n > 2045 {
        invalid(0, "str# width must be 1..2045")
      }
      n
    }
  }
}

///|
fn Storage::code(self : Storage) -> Int {
  match self {
    Byte => 65530
    Int16 => 65529
    Int32 => 65528
    Float32 => 65527
    Float64 => 65526
    StrL => 32768
    Str(n) => n
  }
}

///|
fn storage_from_code(n : Int, offset : Int) -> Storage raise DtaError {
  match n {
    65530 => Byte
    65529 => Int16
    65528 => Int32
    65527 => Float32
    65526 => Float64
    32768 => StrL
    1..=2045 => Str(n)
    _ => raise Invalid(offset~, message="unknown storage code \{n}")
  }
}
