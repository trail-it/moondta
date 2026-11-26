///|
// The on-disk index uses one 32-byte record per GSO in file order. Each
// bucket is a chain of biased record offsets; zero denotes the empty chain.
priv struct ObjectIndex {
  heads : FixedArray[Int64]
  output : StreamOutput
  scratch : ScratchFile
  mut largest : UInt64
}

///|
fn ObjectIndex::new(file : ScratchFile, has_objects : Bool) -> ObjectIndex {
  {
    heads: FixedArray::make(if has_objects { 65536 } else { 0 }, 0L),
    output: { sink: Sink::new(Little), write_at: file.write_at, written: 0L, },
    scratch: file,
    largest: 0UL,
  }
}

///|
fn object_key(key : (UInt64, UInt64)) -> UInt64 {
  (key.1 << 32) | key.0
}

///|
fn indexed_object(record : BytesView) -> FileObject {
  {
    start: decode_uint(record[8:16], Little).reinterpret_as_int64(),
    length: decode_uint(record[16:20], Little).to_int(),
    kind: record[20].to_int(),
  }
}

///|
fn ObjectIndex::find(
  self : ObjectIndex,
  key : UInt64,
) -> (Int64, FileObject)? raise {
  if self.heads.length() == 0 {
    return None
  }
  let mut link = self.heads[key.hash() & (self.heads.length() - 1)]
  while link != 0L {
    let pos = link - 1L
    let bytes = if pos < self.output.written {
      self.scratch.read_exact(pos, 32)
    } else {
      let start = (pos - self.output.written).to_int()
      let pending = self.output.sink.bytes.view()
      Bytes::makei(32, i => pending[start + i])
    }
    if decode_uint(bytes[:8], Little) == key {
      return Some((pos, indexed_object(bytes[:])))
    }
    link = decode_uint(bytes[24:32], Little).reinterpret_as_int64()
  }
  None
}

///|
fn ObjectIndex::add(
  self : ObjectIndex,
  key : UInt64,
  object : FileObject,
) -> Unit raise {
  // Canonical writers introduce keys in row order. A new maximum cannot
  // duplicate any earlier key. Other orders use exact on-disk lookup.
  if key > self.largest {
    self.largest = key
  } else if self.find(key) is Some(_) {
    file_error(object.start, "duplicate strL key")
  }
  let bucket = key.hash() & (self.heads.length() - 1)
  let previous = self.heads[bucket]
  self.heads[bucket] = self.output.length() + 1L
  let sink = self.output.sink
  sink.uint(key, 8)
  sink.uint(object.start.reinterpret_as_uint64(), 8)
  sink.uint(object.length.to_uint64(), 4)
  sink.uint(object.kind.to_uint64(), 4)
  sink.uint(previous.reinterpret_as_uint64(), 8)
  self.output.flush_block()
}

///|
fn ObjectIndex::cursor(self : ObjectIndex) -> FileCursor {
  let input = random_input(
    self.output.written,
    self.scratch.read_at,
    "strL index",
  )
  input.cursor(Little, start=0L, end=input.length)
}

///|
priv struct ObjectLookup {
  index : ObjectIndex
  records : FileCursor
  hot : FixedArray[(UInt64, FileObject)?]
  mut seeked : Bool
}

///|
fn ObjectLookup::resolve(
  self : ObjectLookup,
  key : UInt64,
  ref_pos : Int64,
) -> FileObject raise {
  let slot = key.hash() & (self.hot.length() - 1)
  if self.hot[slot] is Some((prior, object)) && key == prior {
    return object
  }
  // Reading the records in encounter order amortizes I/O for distinct keys.
  if self.records.pos < self.records.end {
    let pos = self.records.pos
    let in_window = pos - self.records.window_start
    let record = if self.seeked &&
      (
        in_window < 0L ||
        in_window > (self.records.window.length() - 32).to_int64()
      ) {
      // Confirm locality with a single record before reading a full window.
      self.records.pos += 32L
      self.index.scratch.read_exact(pos, 32)[:]
    } else {
      self.records.take(32)
    }
    if decode_uint(record[:8], Little) == key {
      let object = indexed_object(record)
      self.seeked = false
      self.hot[slot] = Some((key, object))
      return object
    }
    self.records.pos = pos
  }
  guard self.index.find(key) is Some((pos, object)) else {
    file_error(ref_pos, "unresolved strL reference")
  }
  self.records.pos = pos + 32L
  self.seeked = true
  self.hot[slot] = Some((key, object))
  object
}
