///|
/// Temporary random-access storage for write_jsonl or open_stream. Reads must return the
/// requested number of bytes, writes must complete or raise. The caller owns
/// this file and its cleanup. It must be distinct from the source and output.
pub(all) struct ScratchFile {
  read_at : (Int64, Int) -> Bytes raise
  write_at : (Int64, Bytes) -> Unit raise
}

///|
const STREAM_BLOCK : Int = 65536

///|
priv struct StreamOutput {
  sink : Sink
  write_at : (Int64, Bytes) -> Unit raise
  mut written : Int64
}

///|
fn StreamOutput::length(self : StreamOutput) -> Int64 {
  self.written + self.sink.bytes.length().to_int64()
}

///|
fn StreamOutput::flush(self : StreamOutput) -> Unit raise {
  if self.sink.bytes.length() > 0 {
    let bytes = self.sink.bytes.to_bytes()
    (self.write_at)(self.written, bytes)
    self.written += bytes.length().to_int64()
    self.sink.bytes.reset()
  }
}

///|
fn StreamOutput::flush_block(self : StreamOutput) -> Unit raise {
  if self.sink.bytes.length() >= STREAM_BLOCK {
    self.flush()
  }
}

///|
/// Encode JSONL directly into an initially empty output. Writes are sequential
/// except for the final 112-byte map patch. Long objects share their first
/// reference and spill to scratch in encounter order. Scratch is unused when
/// there are no long objects. On error the caller must discard partial output.
pub fn write_jsonl(
  next_line : () -> String? raise,
  write_at : (Int64, Bytes) -> Unit raise,
  scratch~ : ScratchFile,
  version? : Int,
  endian? : Endian,
) -> Unit raise {
  let (original, count) = jsonl_header(next_line)
  let schema = {
    ..original,
    version: version.unwrap_or(original.version),
    endian: endian.unwrap_or(original.endian),
  }
  if original.version != schema.version {
    validate_schema(schema)
  }
  let offsets = Array::make(14, 0L)
  let sink = Sink::new(schema.endian)
  let output : StreamOutput = { sink, write_at, written: 0L, }
  let map_start = write_header(sink, schema, count, offsets)
  output.flush()
  let spool = StrLSpool::new(
    scratch,
    schema.endian,
    schema.columns.any(c => c.storage == StrL),
  )
  visit_jsonl_rows(next_line, count, schema.columns.length(), (row, cells) => {
    for col, cell in cells {
      let storage = schema.columns[col].storage
      try {
        if storage == StrL {
          let key = match
            strl_content(cell, sink.bytes.length(), col + 1, row) {
            None => (0, 0)
            Some(content) => {
              let (kind, payload) = content.payload(sink.bytes.length())
              spool.intern(kind, payload, (col + 1, row))
            }
          }
          write_reference(sink, schema.version, key)
        } else {
          write_inline_cell(sink, storage, cell, col + 1, row)
        }
      } catch {
        DtaError::Invalid(message~, ..) =>
          fail(
            "JSONL line \{row.to_int64() + 1L}: column \{col + 1}: \{message}",
          )
        e => raise e
      }
    }
    output.flush_block()
  })
  sink.text("</data>")
  offsets[10] = output.length()
  sink.text("<strls>")
  spool.copy_objects(output)
  sink.text("</strls>")
  offsets[11] = output.length()
  write_value_labels(sink, schema)
  offsets[12] = output.length()
  sink.text("</stata_dta>")
  offsets[13] = output.length()
  output.flush()
  write_at(map_start.to_int64(), encode_map(schema.endian, offsets))
}
