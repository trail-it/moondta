///|
priv struct CachedStrL {
  kind : Int
  bytes : Bytes
  key : (Int, Int)
}

///|
// Scratch records contain an 8-byte chain link and 4-byte hash, followed by
// the actual DTA GSO header (20 bytes) and payload. Links are biased by one
// so that zero denotes an empty bucket. All fields use the target byte order.
priv struct StrLSpool {
  file : ScratchFile
  endian : Endian
  heads : FixedArray[Int64]
  cache : FixedArray[CachedStrL?]
  mut size : Int64
}

///|
fn StrLSpool::new(
  file : ScratchFile,
  endian : Endian,
  has_strls : Bool,
) -> StrLSpool {
  {
    file,
    endian,
    size: 0L,
    heads: FixedArray::make(if has_strls { 65536 } else { 0 }, 0L),
    cache: FixedArray::make(if has_strls { 1024 } else { 0 }, None),
  }
}

///|
fn ScratchFile::read_exact(
  self : ScratchFile,
  pos : Int64,
  size : Int,
) -> Bytes raise {
  let bytes = (self.read_at)(pos, size)
  if bytes.length() != size {
    fail("short strL scratch read")
  }
  bytes
}

///|
fn StrLSpool::matches(
  self : StrLSpool,
  pos : Int64,
  payload : Bytes,
) -> Bool raise {
  let mut i = 0
  while i < payload.length() {
    let n = (payload.length() - i).min(STREAM_BLOCK)
    let bytes = self.file.read_exact(pos + i.to_int64(), n)
    if bytes[:] != payload[i:i + n] {
      return false
    }
    i += n
  }
  true
}

///|
fn StrLSpool::intern(
  self : StrLSpool,
  kind : Int,
  payload : Bytes,
  key : (Int, Int),
) -> (Int, Int) raise {
  let hash = payload.hash()
  // At most 1 MiB of payloads. Cold lookups always consult the disk chain.
  let slot = hash & (self.cache.length() - 1)
  let small = payload.length() <= 1024
  if small &&
    self.cache[slot] is Some(hit) &&
    hit.kind == kind &&
    hit.bytes == payload {
    return hit.key
  }
  let bucket = hash & (self.heads.length() - 1)
  let mut link = self.heads[bucket]
  while link != 0L {
    let pos = link - 1L
    let header = self.file.read_exact(pos, 32)
    let c = Cursor::new(header, self.endian)
    link = c.uint(8).reinterpret_as_int64()
    if c.uint(4).to_int() != hash {
      continue
    }
    c.pos += 3 // GSO
    let col = c.uint(4).to_int()
    let row = c.uint(8).to_int()
    let stored_kind = c.uint(1).to_int()
    let length = c.uint(4).to_int()
    if stored_kind == kind &&
      length == payload.length() &&
      self.matches(pos + 32L, payload) {
      let found = (col, row)
      if small {
        self.cache[slot] = Some({ kind, bytes: payload, key: found, })
      }
      return found
    }
  }
  let header = Sink::new(self.endian)
  header.uint(self.heads[bucket].reinterpret_as_uint64(), 8)
  header.uint(hash.to_uint64(), 4)
  write_gso_header(header, key, kind, payload.length())
  (self.file.write_at)(self.size, header.bytes.to_bytes())
  if !payload.is_empty() {
    (self.file.write_at)(self.size + 32L, payload)
  }
  self.heads[bucket] = self.size + 1L
  self.size += 32L + payload.length().to_int64()
  if small {
    self.cache[slot] = Some({ kind, bytes: payload, key, })
  }
  key
}

///|
fn StrLSpool::copy_objects(
  self : StrLSpool,
  output : StreamOutput,
) -> Unit raise {
  let mut pos = 0L
  while pos < self.size {
    let header = self.file.read_exact(pos + 12L, 20)
    let cursor = Cursor::new(header, self.endian, start=16)
    let mut remaining = cursor.size(4)
    output.sink.raw(header[:])
    pos += 32L
    while remaining > 0 {
      let n = remaining.min(STREAM_BLOCK)
      output.sink.raw(self.file.read_exact(pos, n)[:])
      pos += n.to_int64()
      remaining -= n
      output.flush_block()
    }
    output.flush_block()
  }
}
