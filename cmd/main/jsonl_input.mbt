///|
extern "js" fn open_input(path : String) -> Int? =
  #| path => {
  #|   const fs = require('node:fs');
  #|   let fd;
  #|   try {
  #|     fd = fs.openSync(path, fs.constants.O_RDONLY | (fs.constants.O_NONBLOCK || 0));
  #|     const stat = fs.fstatSync(fd);
  #|     if (stat.isFile()) return fd;
  #|   } catch {}
  #|   if (fd !== undefined) { try { fs.closeSync(fd); } catch {} }
  #|   return undefined;
  #| }

///|
extern "js" fn read_chunk(fd : Int) -> Bytes? =
  #| fd => {
  #|   try {
  #|     const buffer = Buffer.allocUnsafe(64 * 1024);
  #|     const count = require('node:fs').readSync(fd, buffer, 0, buffer.length, null);
  #|     return buffer.subarray(0, count);
  #|   } catch { return undefined; }
  #| }

///|
priv struct LineSource {
  fd : Int
  mut chunk : Bytes
  mut position : Int
  mut line : Int64
  mut eof : Bool
}

///|
fn LineSource::next_line(self : LineSource) -> String? raise {
  if self.eof {
    return None
  }
  self.line += 1L
  let mut fragments : @buffer.Buffer? = None
  while true {
    if self.position == self.chunk.length() {
      guard read_chunk(self.fd) is Some(next) else {
        fail("JSONL line \{self.line}: could not read input")
      }
      if next.is_empty() {
        self.eof = true
        break
      }
      self.chunk = next
      self.position = 0
    }
    let start = self.position
    while self.position < self.chunk.length() && self.chunk[self.position] != 10 {
      self.position += 1
    }
    let part = self.chunk[start:self.position]
    let buffered = match fragments {
      Some(buffer) => buffer.length()
      None => 0
    }
    if part.length() > 512 * 1024 * 1024 - buffered {
      fail("JSONL line \{self.line}: record exceeds the 512 MiB line limit")
    }
    if self.position < self.chunk.length() {
      self.position += 1
      match fragments {
        None => return Some(self.decode_line(part))
        Some(buffer) => {
          buffer.write_bytes(part)
          break
        }
      }
    }
    match fragments {
      None => fragments = Some(@buffer.from_bytes(part))
      Some(buffer) => buffer.write_bytes(part)
    }
  }
  match fragments {
    Some(buffer) => Some(self.decode_line(buffer.to_bytes()[:]))
    None => None
  }
}

///|
fn LineSource::decode_line(
  self : LineSource,
  bytes : BytesView,
) -> String raise {
  @utf8.decode(bytes) catch {
    _ => fail("JSONL line \{self.line}: invalid UTF-8")
  }
}

///|
fn with_lines(
  path : String,
  use_lines : (LineSource) -> Unit raise,
) -> Unit raise {
  guard open_input(path) is Some(fd) else {
    fail("cannot read regular JSONL file: \{path}")
  }
  let source : LineSource = {
    fd,
    chunk: b"",
    position: 0,
    line: 0L,
    eof: false,
  }
  {
    errdefer ignore(close_file(fd))
    use_lines(source)
  }
  if close_file(fd) is Some(message) {
    fail("cannot close input: \{message}")
  }
}
