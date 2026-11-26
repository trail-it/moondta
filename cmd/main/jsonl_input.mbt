///|
extern "js" fn open_input(path : String, limit : Int) -> Int? =
  #| (path, limit) => {
  #|   const fs = require('node:fs');
  #|   let fd;
  #|   try {
  #|     fd = fs.openSync(path, fs.constants.O_RDONLY | (fs.constants.O_NONBLOCK || 0));
  #|     const stat = fs.fstatSync(fd);
  #|     if (stat.isFile() && stat.size <= limit) return fd;
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
  limit : Int
  mut chunk : Bytes
  mut position : Int
  mut consumed : Int
  mut line : Int
  mut eof : Bool
}

///|
fn LineSource::next_line(self : LineSource) -> String? raise {
  if self.eof {
    return None
  }
  self.line += 1
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
      if next.length() > self.limit - self.consumed {
        fail("JSONL input exceeds the CLI limit of 512 MiB")
      }
      self.consumed += next.length()
      self.chunk = next
      self.position = 0
    }
    let start = self.position
    while self.position < self.chunk.length() && self.chunk[self.position] != 10 {
      self.position += 1
    }
    let part = self.chunk[start:self.position]
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
fn load_jsonl(path : String) -> @dta.Dataset raise {
  let limit = 512 * 1024 * 1024
  guard open_input(path, limit) is Some(fd) else {
    fail("cannot read regular file (CLI input limit: 512 MiB): \{path}")
  }
  let source : LineSource = {
    fd,
    limit,
    chunk: b"",
    position: 0,
    consumed: 0,
    line: 0,
    eof: false,
  }
  let data = {
    errdefer ignore(close_file(fd))
    @dta.from_jsonl(() => source.next_line())
  }
  if close_file(fd) is Some(message) {
    fail("cannot close input: \{message}")
  }
  data
}
