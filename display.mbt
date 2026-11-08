///|
/// A concise storage name using Stata terminology.
pub fn Storage::display_name(self : Storage) -> String {
  match self {
    Byte => "byte"
    Int16 => "int"
    Int32 => "long"
    Float32 => "float"
    Float64 => "double"
    Str(n) => "str\{n}"
    StrL => "strL"
  }
}

///|
fn display_text(s : String, max_chars : Int) -> String {
  let builder = StringBuilder()
  let mut count = 0
  for ch in s.iter() {
    if count == max_chars {
      builder.write_string("…")
      break
    }
    builder.write_char(ch)
    count += 1
  }
  // JSON escaping keeps control characters inside one terminal/table row.
  Json::string(builder.to_string()).stringify().replace(old="|", new="\\|")
}

///|
fn label_key(value : Value) -> Int? {
  match value {
    Integer(n) => Some(n)
    Missing(n) => Some(2147483621 + n)
    Number(n) =>
      if n >= -2147483647.0 && n <= 2147483620.0 && n.to_int().to_double() == n {
        Some(n.to_int())
      } else {
        None
      }
    _ => None
  }
}

///|
fn display_value(value : Value, max_chars : Int) -> String {
  match value {
    Integer(n) => n.to_string()
    Number(n) =>
      if n.reinterpret_as_uint64() == 0x8000000000000000UL {
        "-0"
      } else {
        n.to_string()
      }
    Missing(0) => "."
    Missing(n) => "." + (96 + n).unsafe_to_char().to_string()
    Text(s) => display_text(s, max_chars)
    Binary(b) => "<binary \{b.length()} bytes>"
  }
}

///|
/// Human-readable Markdown table. Dates stay numeric; display formats are not
/// evaluated. Quoted text is escaped and abbreviated by Unicode code point.
pub fn Reader::preview(
  self : Reader,
  offset? : Int = 0,
  limit? : Int = 10,
  columns? : Array[Int],
  max_chars? : Int = 60,
  labels? : Bool = true,
) -> String raise DtaError {
  if offset < 0 || offset > self.count || limit < 0 || max_chars < 1 {
    invalid(0, "invalid preview range or text width")
  }
  let remaining = self.count - offset
  let count = if limit < remaining { limit } else { remaining }
  let indices = self.indices(columns)
  let rows = self.read_rows(offset~, limit=count, columns=indices)
  let sets : Map[String, Map[Int, String]] = Map([])
  if labels {
    for set in self.metadata.value_labels {
      let entries : Map[Int, String] = Map([])
      for entry in set.entries {
        entries[entry.value] = entry.text
      }
      sets[set.name] = entries
    }
  }
  let out = StringBuilder()
  out.write_string(
    "Rows \{offset + (if count == 0 { 0 } else { 1 })}–\{offset + count} of \{self.count}\n\n| Row |",
  )
  for i in indices {
    out.write_string(" \{display_text(self.metadata.columns[i].name, 32)} |")
  }
  out.write_string("\n| --- |")
  for _ in indices {
    out.write_string(" --- |")
  }
  for r, row in rows {
    out.write_string("\n| \{offset + r + 1} |")
    for j, value in row {
      out.write_string(" \{display_value(value, max_chars)}")
      let col = self.metadata.columns[indices[j]]
      if sets.get(col.value_labels) is Some(entries) &&
        label_key(value) is Some(key) &&
        entries.get(key) is Some(label) {
        out.write_string(" (\{display_text(label, max_chars)})")
      }
      out.write_string(" |")
    }
  }
  out.write_string("\n")
  out.to_string()
}

///|
/// Metadata dictionary in Markdown; does not decode any row or strL payload.
/// Full value-label definitions and characteristic bytes remain in inspect_json.
pub fn Reader::describe(self : Reader) -> String {
  let s = self.metadata
  let out = StringBuilder()
  let endian = if s.endian == Little { "little" } else { "big" }
  out.write_string(
    "DTA \{s.version}, \{endian} endian, \{self.count} rows, \{s.columns.length()} variables\n",
  )
  out.write_string(
    "Dataset label: \{display_text(s.label, 80)}\nTimestamp: \{display_text(s.timestamp, 17)}\n",
  )
  out.write_string(
    "Characteristics: \{s.characteristics.length()}\n\n| # | Variable | Storage | Variable label | Format | Value labels | Sort position |\n| --- | --- | --- | --- | --- | --- | --- |",
  )
  let positions : Map[Int, Int] = Map([])
  for i, col in s.sort_order {
    positions[col] = i + 1
  }
  for i, col in s.columns {
    let order = match positions.get(i + 1) {
      Some(n) => n.to_string()
      None => ""
    }
    out.write_string(
      "\n| \{i + 1} | \{display_text(col.name, 32)} | \{col.storage.display_name()} | \{display_text(col.label, 80)} | \{display_text(col.format, 56)} | \{display_text(col.value_labels, 32)} | \{order} |",
    )
  }
  for set in s.value_labels {
    out.write_string(
      "\n\nValue labels \{display_text(set.name, 32)} (\{set.entries.length()} entries)\n\n| Value | Label |\n| --- | --- |",
    )
    for entry in set.entries {
      let value : Value = if entry.value >= 2147483621 {
        Missing(entry.value - 2147483621)
      } else {
        Integer(entry.value)
      }
      out.write_string(
        "\n| \{display_value(value, 60)} | \{display_text(entry.text, 120)} |",
      )
    }
  }
  out.write_string("\n")
  out.to_string()
}
