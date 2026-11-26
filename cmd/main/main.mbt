///|
extern "js" fn args() -> FixedArray[String] =
  #| () => process.argv.slice(2)

///|
extern "js" fn read_file(path : String) -> Bytes? =
  #| (path) => { try { const fs = require('node:fs'); const s = fs.statSync(path); if (!s.isFile() || s.size > 536870912) return undefined; return fs.readFileSync(path); } catch { return undefined; } }

///|
extern "js" fn write_file(path : String, data : Bytes) -> String? =
  #| (path, data) => { const fs=require('node:fs'); let fd, created=false;
  #| try { fd=fs.openSync(path,'wx'); created=true; fs.writeFileSync(fd,data); fs.closeSync(fd); return undefined; }
  #| catch(e) { if(fd!==undefined) {try{fs.closeSync(fd)}catch{}} if(created){try{fs.unlinkSync(path)}catch{}} return e.message; } }

///|
extern "js" fn report_error(message : String) -> Unit =
  #| (message) => { process.stderr.write(message + '\n'); process.exitCode = 1; }

///|
extern "js" fn create_output(path : String) -> Int? =
  #| (path) => { try { return require('node:fs').openSync(path, 'wx'); } catch { return undefined; } }

///|
extern "js" fn write_line(fd : Int, line : String) -> String? =
  #| (fd, line) => { try { require('node:fs').writeFileSync(fd, line, 'utf8'); return undefined; } catch (e) { return e.message; } }

///|
extern "js" fn close_output(fd : Int) -> String? =
  #| (fd) => { try { require('node:fs').closeSync(fd); return undefined; } catch (e) { return e.message; } }

///|
extern "js" fn discard_output(fd : Int, path : String) -> Unit =
  #| (fd, path) => { const fs = require('node:fs'); try { fs.closeSync(fd); } catch {} try { fs.unlinkSync(path); } catch {} }

///|
fn load(path : String) -> Bytes raise {
  guard read_file(path) is Some(bytes) else {
    fail("cannot read regular file (CLI input limit: 512 MiB): \{path}")
  }
  bytes
}

///|
fn save(path : String, bytes : Bytes) -> Unit raise {
  if write_file(path, bytes) is Some(message) {
    fail("cannot create \{path}: \{message}")
  }
}

///|
fn number(s : String) -> Int raise {
  if s.is_empty() {
    fail("expected nonnegative integer")
  }
  let mut n : Int64 = 0
  for ch in s.iter() {
    if ch < '0' || ch > '9' {
      fail("expected nonnegative integer: \{s}")
    }
    n = n * 10L + (ch.to_int() - 48).to_int64()
    if n > 2147483647L {
      fail("integer too large")
    }
  }
  n.to_int()
}

///|
fn help() -> Unit {
  println(
    (
      #|MoonDTA — Stata DTA 118/119
      #|  inspect INPUT.dta
      #|  describe INPUT.dta
      #|  preview INPUT.dta [--columns a,b] [--offset N] [--limit N] [--width N] [--labels on|off]
      #|  verify INPUT.dta [--batch-size N]
      #|  export INPUT.dta OUTPUT.json [--columns a,b] [--offset N] [--limit N]
      #|  export-jsonl INPUT.dta OUTPUT.jsonl [--columns a,b] [--offset N] [--limit N] [--batch-size N]
      #|  import INPUT.json OUTPUT.dta [--version 118|119] [--endian little|big]
      #|  convert INPUT.dta OUTPUT.dta [--version 118|119] [--endian little|big]
      #|  select INPUT.dta OUTPUT.dta --columns a,b [--offset N] [--limit N]
      #|Output paths must not already exist. inspect validates metadata; verify scans every cell.
    ),
  )
}

///|
fn run() -> Unit raise {
  let argv = args()
  if argv.length() == 0 ||
    (argv.length() == 1 && (argv[0] == "--help" || argv[0] == "help")) {
    help()
    return
  }
  let command = argv[0]
  let header = if command == "inspect" ||
    command == "verify" ||
    command == "preview" ||
    command == "describe" {
    2
  } else {
    3
  }
  if argv.length() < header {
    fail("missing arguments; run --help")
  }
  let options : Map[String, String] = Map([])
  let mut i = header
  while i < argv.length() {
    if i + 1 >= argv.length() {
      fail("missing option value")
    }
    let key = argv[i]
    let allowed = match command {
      "verify" => key == "--batch-size"
      "export" | "select" =>
        key == "--columns" || key == "--offset" || key == "--limit"
      "export-jsonl" =>
        key == "--columns" ||
        key == "--offset" ||
        key == "--limit" ||
        key == "--batch-size"
      "preview" =>
        key == "--columns" ||
        key == "--offset" ||
        key == "--limit" ||
        key == "--width" ||
        key == "--labels"
      "import" | "convert" => key == "--version" || key == "--endian"
      _ => false
    }
    if !allowed || options.contains(key) {
      fail("unknown or duplicate option: \{key}")
    }
    options[key] = argv[i + 1]
    i += 2
  }
  if command == "import" {
    let json = @json.parse(@utf8.decode(load(argv[1])[:]))
    let data = @dta.from_exchange(json)
    save(argv[2], @dta.encode(change_format(data, options)))
    return
  }
  if command != "inspect" &&
    command != "verify" &&
    command != "export" &&
    command != "export-jsonl" &&
    command != "select" &&
    command != "preview" &&
    command != "describe" &&
    command != "convert" {
    fail("unknown command: \{command}")
  }
  let reader = @dta.open(load(argv[1]))
  if command == "inspect" {
    println(reader.inspect_json().stringify(indent=2))
    return
  }
  if command == "describe" {
    println(reader.describe())
    return
  }
  if command == "verify" {
    let batch = number(options.get("--batch-size").unwrap_or("256"))
    if batch < 1 {
      fail("batch size must be positive")
    }
    reader.verify(batch_size=batch)
    println(
      "Verified \{reader.row_count()} rows, \{reader.column_count()} variables",
    )
    return
  }
  if command == "convert" {
    save(argv[2], @dta.encode(change_format(reader.read(), options)))
    return
  }
  let columns = match options.get("--columns") {
    Some(list) =>
      reader.column_indices(
        list.split(",").map(name => name.to_owned()).collect(),
      )
    None => {
      if command == "select" {
        fail("select requires --columns")
      }
      Array::makei(reader.column_count(), i => i)
    }
  }
  let offset = number(options.get("--offset").unwrap_or("0"))
  let limit = match options.get("--limit") {
    Some(s) => number(s)
    None => if command == "preview" { 10 } else { reader.row_count() - offset }
  }
  if command == "export-jsonl" {
    let batch = number(options.get("--batch-size").unwrap_or("256"))
    guard create_output(argv[2]) is Some(fd) else {
      fail("cannot create output: \{argv[2]}")
    }
    errdefer discard_output(fd, argv[2])
    reader.export_jsonl(
      line => {
        if write_line(fd, line) is Some(message) {
          fail("cannot write output: \{message}")
        }
      },
      offset~,
      limit~,
      columns~,
      batch_size=batch,
    )
    if close_output(fd) is Some(message) {
      fail("cannot close output: \{message}")
    }
    return
  }
  if command == "preview" {
    let width = number(options.get("--width").unwrap_or("60"))
    let labels = match options.get("--labels").unwrap_or("on") {
      "on" => true
      "off" => false
      _ => fail("labels must be on or off")
    }
    println(reader.preview(offset~, limit~, columns~, max_chars=width, labels~))
    return
  }
  let data = reader.select(columns, offset~, limit~)
  let bytes = if command == "export" {
    @utf8.encode(data.to_exchange().stringify(indent=2) + "\n")
  } else {
    @dta.encode(data)
  }
  save(argv[2], bytes)
}

///|
fn change_format(
  data : @dta.Dataset,
  options : Map[String, String],
) -> @dta.Dataset raise {
  let s = data.schema
  let version = match options.get("--version") {
    Some(v) => number(v)
    None => s.version
  }
  let endian = match options.get("--endian") {
    Some("little") => @dta.Little
    Some("big") => @dta.Big
    None => s.endian
    _ => fail("endian must be little or big")
  }
  { schema: { ..s, version, endian, }, rows: data.rows, }
}

///|
fn main {
  run() catch {
    @dta.Invalid(offset~, message~) =>
      report_error("MoonDTA: byte \{offset}: \{message}")
    e => report_error("MoonDTA: \{e}")
  }
}
