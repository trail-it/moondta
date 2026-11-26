///|
/// A seekable DTA source. The caller keeps both files available until the
/// last operation completes. Row and object payloads are decoded on demand.
pub struct StreamReader {
  priv input : DtaInput
  priv layout : DtaLayout
  priv index : ObjectIndex
}

///|
fn random_input(
  length : Int64,
  read_at : (Int64, Int) -> Bytes raise,
  name : String,
) -> DtaInput {
  {
    length,
    read_view: (pos, n) => {
      let bytes = read_at(pos, n) catch {
        e => file_error(pos, "\{name} read failed: \{e}")
      }
      if bytes.length() != n {
        file_error(pos, "short \{name} read")
      }
      bytes[:]
    },
  }
}

///|
/// Open a stable random-access DTA source with 64-bit file offsets. Reads
/// request at most 64 KiB and must return exactly the requested bytes. Each
/// long object uses 32 scratch bytes. Supply separate, private scratch
/// storage for each reader and discard it after use, including on error.
pub fn open_stream(
  length : Int64,
  read_at : (Int64, Int) -> Bytes raise,
  scratch~ : ScratchFile,
) -> StreamReader raise {
  if length < 0L {
    file_error(0L, "negative file size")
  }
  let input = random_input(length, read_at, "DTA")
  let layout = input.layout()
  let index = ObjectIndex::new(scratch, layout.objects.pos < layout.objects.end)
  while layout.objects.pos < layout.objects.end {
    let (key, object) = layout.next_object()
    index.add(object_key(key), object)
  }
  index.output.flush()
  { input, layout, index, }
}

///|
pub fn StreamReader::row_count(self : StreamReader) -> Int {
  self.layout.count
}

///|
pub fn StreamReader::column_count(self : StreamReader) -> Int {
  self.layout.metadata.columns.length()
}

///|
pub fn StreamReader::schema(self : StreamReader) -> Schema {
  clone_schema(self.layout.metadata)
}

///|
pub fn StreamReader::column_indices(
  self : StreamReader,
  names : Array[String],
) -> Array[Int] raise DtaError {
  self.layout.metadata.named_indices(names)
}

///|
fn text_part(bytes : BytesView, start : Int64) -> String raise DtaFileError {
  if bytes.find(b"\x00"[:]) is Some(i) {
    file_error(start + i.to_int64(), "strL text contains embedded NUL")
  }
  file_text(bytes, start)
}

///|
fn FileCursor::validate_text(
  self : FileCursor,
  object : FileObject,
) -> Unit raise DtaFileError {
  let end = object.start + (object.length - 1).to_int64()
  self.pos = object.start
  while self.pos < end {
    let start = self.pos
    let n = (end - start).min(STREAM_BLOCK.to_int64()).to_int()
    let chunk = self.take(n)
    let mut used = n
    if self.pos < end && chunk[n - 1].to_int() >= 128 {
      // Leave the last non-ASCII scalar to the next block, with at most
      // three continuation bytes. The decoder rejects malformed runs.
      let mut i = n - 1
      while i > n - 4 && (chunk[i].to_int() & 0xc0) == 0x80 {
        i -= 1
      }
      used = i
      self.pos = start + used.to_int64()
    }
    ignore(text_part(chunk[:used], start))
  }
}

///|
fn FileCursor::object_value(
  self : FileCursor,
  object : FileObject,
) -> Value raise DtaFileError {
  self.pos = object.start
  if object.kind == 129 {
    return Binary(self.take(object.length).to_owned())
  }
  Text(text_part(self.take(object.length - 1), object.start))
}

///|
fn StreamReader::scan_rows(
  self : StreamReader,
  offset : Int,
  limit : Int,
  columns : Array[Int],
  batch_size : Int,
  emit : ((Array[Value]) -> Unit raise)?,
) -> Unit raise {
  let layout = self.layout
  let endian = layout.metadata.endian
  let width = layout.row_width.to_int64()
  let data = self.input.cursor(
    endian,
    start=layout.data_start,
    end=layout.data_start + layout.count.to_int64() * width,
  )
  let payload = self.input.cursor(endian, start=0L, end=layout.objects.end)
  let lookup : ObjectLookup = {
    index: self.index,
    records: self.index.cursor(),
    hot: FixedArray::make(1024, None),
    seeked: false,
  }
  let mut base = layout.data_start + offset.to_int64() * width
  let mut remaining = limit
  while remaining > 0 {
    let count = remaining.min(batch_size)
    for _ in 0..<count {
      let row : Array[Value] = []
      for i in columns {
        let storage = layout.metadata.columns[i].storage
        let pos = base + layout.column_offsets[i].to_int64()
        data.pos = pos
        let bytes = data.take(storage.width())
        let start = bytes.start_offset()
        let cell = Cursor::new(
          bytes.data(),
          endian,
          start~,
          end=start + bytes.length(),
        )
        try {
          if storage == StrL {
            let reference = cell.strl_key(layout.metadata.version)
            if reference.1 > layout.count.to_uint64() {
              file_error(pos, "unresolved strL reference")
            }
            let key = object_key(reference)
            if key == 0UL {
              if emit is Some(_) {
                row.push(Text(""))
              }
            } else {
              let object = lookup.resolve(key, pos)
              if emit is Some(_) {
                row.push(payload.object_value(object))
              }
            }
          } else {
            let value = cell.inline_cell(storage)
            if emit is Some(_) {
              row.push(value)
            }
          }
        } catch {
          Invalid(offset=within, message~) =>
            file_error(pos + (within - start).to_int64(), message)
          e => raise e
        }
      }
      if emit is Some(write) {
        write(row)
      }
      base += width
    }
    remaining -= count
  }
}

///|
/// Validate every cell, reference and text object, including unreferenced
/// text. Payload validation proceeds in bounded UTF-8 blocks.
pub fn StreamReader::verify(
  self : StreamReader,
  batch_size? : Int = 256,
) -> Unit raise {
  if batch_size < 1 {
    invalid(0, "batch size must be positive")
  }
  let records = self.index.cursor()
  let payload = self.input.cursor(
    self.layout.metadata.endian,
    start=0L,
    end=self.layout.objects.end,
  )
  while records.pos < records.end {
    let object = indexed_object(records.take(32))
    if object.kind == 130 {
      payload.validate_text(object)
    }
  }
  let columns = Array::makei(self.column_count(), i => i)
  self.scan_rows(0, self.row_count(), columns, batch_size, None)
}

///|
/// Emit a projected header and one line per selected row. Memory includes
/// schema metadata, bounded read windows, and the largest exported row.
pub fn StreamReader::export_jsonl(
  self : StreamReader,
  write : (String) -> Unit raise,
  offset? : Int = 0,
  limit? : Int = self.layout.count - offset,
  columns? : Array[Int],
  batch_size? : Int = 256,
) -> Unit raise {
  check_range(self.layout.count, offset, limit)
  if batch_size < 1 {
    invalid(0, "batch size must be positive")
  }
  let indices = self.layout.metadata.indices(columns).copy()
  if indices.is_empty() && limit > 0 {
    invalid(0, "cannot select zero variables from nonempty rows")
  }
  write(jsonl_header_line(self.layout.metadata.project(indices), limit))
  self.scan_rows(
    offset,
    limit,
    indices,
    batch_size,
    Some(row => write(jsonl_row_line(row))),
  )
}
