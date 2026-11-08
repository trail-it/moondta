///|
priv struct Cursor {
  bytes : Bytes
  mut pos : Int
  end : Int
  mut endian : Endian
}

///|
fn Cursor::new(
  bytes : Bytes,
  endian : Endian,
  start? : Int = 0,
  end? : Int = bytes.length(),
) -> Cursor {
  { bytes, pos: start, end, endian, }
}

///|
fn Cursor::take(self : Cursor, n : Int) -> BytesView raise DtaError {
  if n < 0 || self.pos > self.end || n > self.end - self.pos {
    invalid(self.pos, "truncated section (need \{n} bytes)")
  }
  let start = self.pos
  self.pos += n
  self.bytes[start:self.pos]
}

///|
fn Cursor::tag(self : Cursor, s : String) -> Unit raise DtaError {
  let expected = @utf8.encode(s)
  let start = self.pos
  if self.take(expected.length()) != expected[:] {
    invalid(start, "expected \{s}")
  }
}

///|
fn Cursor::uint(self : Cursor, n : Int) -> UInt64 raise DtaError {
  let b = self.take(n)
  let mut value : UInt64 = 0
  for i in 0..<n {
    let shift = if self.endian == Little { i * 8 } else { (n - i - 1) * 8 }
    value = value | (b[i].to_uint64() << shift)
  }
  value
}

///|
fn Cursor::size(self : Cursor, n : Int) -> Int raise DtaError {
  let p = self.pos
  let value = self.uint(n)
  if value > 2147483647UL {
    invalid(p, "size exceeds in-memory implementation limit")
  }
  value.to_int()
}

///|
fn decode_utf8(b : BytesView, pos : Int) -> String raise DtaError {
  @utf8.decode(b, ignore_bom=true) catch {
    _ => raise Invalid(offset=pos, message="invalid UTF-8")
  }
}

///|
fn Cursor::text(self : Cursor, n : Int) -> String raise DtaError {
  let p = self.pos
  decode_utf8(self.take(n), p)
}

///|
fn Cursor::cstring(
  self : Cursor,
  n : Int,
  terminated? : Bool = true,
) -> String raise DtaError {
  let p = self.pos
  let b = self.take(n)
  let mut len = 0
  while len < n && b[len] != 0 {
    len += 1
  }
  if terminated && len == n {
    invalid(p, "missing NUL terminator")
  }
  decode_utf8(b[:len], p)
}

///|
priv struct Sink {
  bytes : @buffer.Buffer
  endian : Endian
}

///|
fn Sink::new(endian : Endian) -> Sink {
  { bytes: @buffer.Buffer(), endian, }
}

///|
fn Sink::raw(self : Sink, bytes : BytesView) -> Unit {
  self.bytes.write_bytes(bytes)
}

///|
fn Sink::append(self : Sink, other : Sink) -> Unit {
  self.bytes.write_iter(other.bytes.view().iter())
}

///|
fn Sink::text(self : Sink, s : String) -> Unit {
  self.raw(@utf8.encode(s)[:])
}

///|
fn Sink::uint(self : Sink, value : UInt64, n : Int) -> Unit {
  for i in 0..<n {
    let shift = if self.endian == Little { i * 8 } else { (n - i - 1) * 8 }
    self.bytes.write_byte((value >> shift).to_byte())
  }
}

///|
fn Sink::fixed(self : Sink, s : String, n : Int) -> Unit raise DtaError {
  let b = @utf8.encode(s)
  if b.length() >= n {
    invalid(0, "text exceeds fixed field width \{n - 1}")
  }
  self.raw(b[:])
  for _ in b.length()..<n {
    self.bytes.write_byte(0)
  }
}

///|
fn checked_product(a : Int, b : Int, offset : Int) -> Int raise DtaError {
  let n = a.to_uint64() * b.to_uint64()
  if n > 2147483647UL {
    invalid(offset, "size exceeds in-memory implementation limit")
  }
  n.to_int()
}
