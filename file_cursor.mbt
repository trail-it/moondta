///|
/// An invalid file or input read failure at an absolute, zero-based byte offset.
pub(all) suberror DtaFileError {
  InvalidFile(offset~ : Int64, message~ : String)
} derive(Debug)

///|
fn[T] file_error(pos : Int64, message : String) -> T raise DtaFileError {
  raise InvalidFile(offset=pos, message~)
}

///|
priv struct DtaInput {
  length : Int64
  read_view : (Int64, Int) -> BytesView raise DtaFileError
}

///|
priv struct FileCursor {
  input : DtaInput
  mut pos : Int64
  end : Int64
  mut endian : Endian
  mut window : BytesView
  mut window_start : Int64
}

///|
fn DtaInput::cursor(
  self : DtaInput,
  endian : Endian,
  start~ : Int64,
  end~ : Int64,
) -> FileCursor {
  { input: self, endian, pos: start, end, window: b""[:], window_start: 0L, }
}

///|
fn FileCursor::skip(self : FileCursor, n : Int64) -> Unit raise DtaFileError {
  if n < 0L || n > self.end - self.pos {
    file_error(self.pos, "truncated DTA section")
  }
  self.pos += n
}

///|
fn FileCursor::take(self : FileCursor, n : Int) -> BytesView raise DtaFileError {
  let start = self.pos
  self.skip(n.to_int64())
  if n == 0 {
    return b""[:]
  }
  let in_window = start - self.window_start
  if in_window >= 0L && in_window <= (self.window.length() - n).to_int64() {
    let i = in_window.to_int()
    return self.window[i:i + n]
  }
  if n > STREAM_BLOCK {
    // Only materialize fields that the public schema or an exported row must retain.
    let buffer = @buffer.Buffer()
    let mut i = 0
    while i < n {
      let size = (n - i).min(STREAM_BLOCK)
      buffer.write_bytes((self.input.read_view)(start + i.to_int64(), size))
      i += size
    }
    return buffer.to_bytes()[:]
  }
  let size = (self.end - start).min(STREAM_BLOCK.to_int64()).to_int()
  self.window = (self.input.read_view)(start, size)
  self.window_start = start
  self.window[:n]
}

///|
fn FileCursor::tag(self : FileCursor, tag : String) -> Unit raise DtaFileError {
  let pos = self.pos
  let expected = @utf8.encode(tag)
  if self.take(expected.length()) != expected[:] {
    file_error(pos, "expected \{tag}")
  }
}

///|
fn FileCursor::uint(self : FileCursor, n : Int) -> UInt64 raise DtaFileError {
  decode_uint(self.take(n), self.endian)
}

///|
fn FileCursor::size(self : FileCursor, n : Int) -> Int raise DtaFileError {
  let pos = self.pos
  let value = self.uint(n)
  if value > 2147483647UL {
    file_error(pos, "field size exceeds supported integer range")
  }
  value.to_int()
}

///|
fn file_text(bytes : BytesView, pos : Int64) -> String raise DtaFileError {
  @utf8.decode(bytes, ignore_bom=true) catch {
    _ => file_error(pos, "invalid UTF-8")
  }
}

///|
fn FileCursor::text(self : FileCursor, n : Int) -> String raise DtaFileError {
  let start = self.pos
  file_text(self.take(n), start)
}

///|
fn FileCursor::cstring(self : FileCursor, n : Int) -> String raise DtaFileError {
  let start = self.pos
  let bytes = self.take(n)
  guard bytes.find(b"\x00"[:]) is Some(i) else {
    file_error(start, "missing NUL terminator")
  }
  file_text(bytes[:i], start)
}

///|
fn FileCursor::label_text(self : FileCursor) -> String raise DtaFileError {
  let start = self.pos
  let result = @buffer.Buffer()
  // validate_schema permits at most 128000 UTF-8 bytes per label.
  while self.pos < self.end {
    let size = (self.end - self.pos).min(4096L).to_int()
    let part = self.take(size)
    if part.find(b"\x00"[:]) is Some(i) {
      if result.is_empty() {
        return file_text(part[:i], start)
      }
      result.write_bytes(part[:i])
      return file_text(result.to_bytes()[:], start)
    }
    if self.pos - start > 128000L {
      file_error(start, "overlong value-label text")
    }
    result.write_bytes(part)
  }
  file_error(start, "missing NUL terminator")
}

///|
fn FileCursor::finished(self : FileCursor) -> Unit raise DtaFileError {
  if self.pos != self.end {
    file_error(self.pos, "unexpected bytes in section")
  }
}
