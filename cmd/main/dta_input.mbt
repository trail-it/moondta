///|
extern "js" fn input_length(fd : Int) -> Int64 =
  #| fd => {
  #|   try {
  #|     const size = require('node:fs').fstatSync(fd, {bigint: true}).size;
  #|     if (size <= BigInt(Number.MAX_SAFE_INTEGER)) return size;
  #|   } catch {}
  #|   return -1n;
  #| }

///|
extern "js" fn index_directory() -> String? =
  #| () => {
  #|   try {
  #|     const prefix = require('node:path').join(require('node:os').tmpdir(), 'moondta-read-');
  #|     return require('node:fs').mkdtempSync(prefix);
  #|   } catch { return undefined; }
  #| }

///|
priv struct ReadScratch {
  mut dir : String?
  mut fd : Int?
}

///|
fn ReadScratch::handle(self : ReadScratch) -> Int raise {
  if self.fd is Some(fd) {
    return fd
  }
  guard index_directory() is Some(dir) else {
    fail("cannot create temporary strL index directory")
  }
  self.dir = Some(dir)
  guard create_work_file(dir + "/strls.tmp") is Some(fd) else {
    fail("cannot create strL index")
  }
  self.fd = Some(fd)
  fd
}

///|
fn ReadScratch::close(self : ReadScratch) -> String? {
  let error = self.fd.bind(close_file)
  let removed = self.dir.bind(remove_staging)
  self.fd = None
  self.dir = None
  match error {
    Some(_) => error
    None => removed
  }
}

///|
fn disk_read(fd : Int, pos : Int64, size : Int) -> Bytes raise {
  guard read_at(fd, pos, size) is Some(bytes) else {
    fail("cannot read file at byte \{pos}")
  }
  bytes
}

///|
fn with_disk_reader(
  path : String,
  use_reader : (@dta.StreamReader) -> Unit raise,
) -> Unit raise {
  guard open_input(path) is Some(fd) else {
    fail("cannot read regular DTA file: \{path}")
  }
  let index : ReadScratch = { dir: None, fd: None, }
  {
    errdefer ignore(close_file(fd))
    {
      errdefer ignore(index.close())
      let length = input_length(fd)
      if length < 0L {
        fail("cannot obtain an addressable DTA file size: \{path}")
      }
      let scratch : @dta.ScratchFile = {
        read_at: (pos, n) => disk_read(index.handle(), pos, n),
        write_at: (pos, bytes) => {
          if write_at(index.handle(), pos, bytes) is Some(message) {
            fail("cannot write temporary strL index: \{message}")
          }
        },
      }
      use_reader(
        @dta.open_stream(length, (pos, n) => disk_read(fd, pos, n), scratch~),
      )
    }
    if index.close() is Some(message) {
      fail("cannot remove temporary strL index: \{message}")
    }
  }
  if close_file(fd) is Some(message) {
    fail("cannot close input: \{message}")
  }
}

///|
fn export_disk_jsonl(
  input : String,
  output : String,
  options : Map[String, String],
  batch : Int,
) -> Unit raise {
  let offset = number(options.get("--offset").unwrap_or("0"))
  let limit = options.get("--limit").map(number)
  let names = column_names(options)
  guard create_output(output) is Some(fd) else {
    fail("cannot create output: \{output}")
  }
  errdefer discard_output(fd, output)
  with_disk_reader(input, reader => {
    let columns = names.map(names => reader.column_indices(names))
    reader.export_jsonl(
      line => {
        if write_line(fd, line) is Some(message) {
          fail("cannot write output: \{message}")
        }
      },
      offset~,
      limit?,
      columns?,
      batch_size=batch,
    )
  })
  if close_file(fd) is Some(message) {
    fail("cannot close output: \{message}")
  }
}
