///|
extern "js" fn staging_directory(target : String) -> String? =
  #| target => {
  #|   const fs = require('node:fs'), path = require('node:path');
  #|   try {
  #|     if (fs.lstatSync(target, {throwIfNoEntry: false})) return undefined;
  #|     return fs.mkdtempSync(path.join(path.dirname(target), '.moondta-'));
  #|   } catch { return undefined; }
  #| }

///|
extern "js" fn remove_staging(dir : String) -> String? =
  #| dir => {
  #|   const fs = require('node:fs'), path = require('node:path');
  #|   try {
  #|     for (const name of ['output.dta', 'strls.tmp']) fs.rmSync(path.join(dir, name), {force: true});
  #|     fs.rmdirSync(dir);
  #|   } catch (e) { return e.message; }
  #| }

///|
extern "js" fn install_output(staged : String, target : String) -> String? =
  #| (staged, target) => {
  #|   const fs = require('node:fs');
  #|   try { fs.linkSync(staged, target); }
  #|   catch (e) {
  #|     // Filesystems without hard links can still copy exclusively.
  #|     if (!['ENOTSUP', 'EOPNOTSUPP', 'ENOSYS', 'EPERM', 'EXDEV'].includes(e.code)) return e.message;
  #|     try { fs.copyFileSync(staged, target, fs.constants.COPYFILE_EXCL); }
  #|     catch (err) { return err.message; }
  #|   }
  #| }

///|
extern "js" fn create_work_file(path : String) -> Int? =
  #| path => { try { return require('node:fs').openSync(path, 'wx+'); } catch { return undefined; } }

///|
extern "js" fn write_at(fd : Int, position : Int64, bytes : Bytes) -> String? =
  #| (fd, position, bytes) => {
  #|   const fs = require('node:fs');
  #|   const pos = Number(position);
  #|   if (!Number.isSafeInteger(pos + bytes.length)) return 'file position exceeds the Node.js safe integer range';
  #|   try {
  #|     let i = 0;
  #|     while (i < bytes.length) {
  #|       const n = fs.writeSync(fd, bytes, i, bytes.length - i, pos + i);
  #|       if (n === 0) return 'zero-length file write';
  #|       i += n;
  #|     }
  #|   } catch (e) { return e.message; }
  #| }

///|
extern "js" fn read_at(fd : Int, position : Int64, length : Int) -> Bytes? =
  #| (fd, position, length) => {
  #|   const fs = require('node:fs');
  #|   const pos = Number(position);
  #|   if (!Number.isSafeInteger(pos + length)) return undefined;
  #|   try {
  #|     const bytes = Buffer.allocUnsafe(length);
  #|     let i = 0;
  #|     while (i < length) {
  #|       const n = fs.readSync(fd, bytes, i, length - i, pos + i);
  #|       if (n === 0) return undefined;
  #|       i += n;
  #|     }
  #|     return bytes;
  #|   } catch { return undefined; }
  #| }

///|
fn file_write(fd : Int, pos : Int64, bytes : Bytes) -> Unit raise {
  if write_at(fd, pos, bytes) is Some(message) {
    fail("cannot write DTA import: \{message}")
  }
}

///|
fn with_work_file(path : String, action : (Int) -> Unit raise) -> Unit raise {
  guard create_work_file(path) is Some(fd) else {
    fail("cannot create DTA import work file")
  }
  {
    errdefer ignore(close_file(fd))
    action(fd)
  }
  if close_file(fd) is Some(message) {
    fail("cannot close DTA import work file: \{message}")
  }
}

///|
fn import_jsonl(
  input : String,
  target : String,
  version? : Int,
  endian? : @dta.Endian,
) -> Unit raise {
  guard staging_directory(target) is Some(dir) else {
    fail("cannot create output: \{target}")
  }
  let staged = dir + "/output.dta"
  {
    errdefer ignore(remove_staging(dir))
    with_lines(input, source => {
      with_work_file(staged, output => {
        with_work_file(dir + "/strls.tmp", spool => {
          let scratch : @dta.ScratchFile = {
            read_at: (pos, n) => {
              guard read_at(spool, pos, n) is Some(bytes) else {
                fail("cannot read strL scratch file")
              }
              bytes
            },
            write_at: (pos, bytes) => file_write(spool, pos, bytes),
          }
          @dta.write_jsonl(
            () => source.next_line(),
            (pos, bytes) => file_write(output, pos, bytes),
            scratch~,
            version?,
            endian?,
          )
        })
      })
    })
    if install_output(staged, target) is Some(message) {
      fail("cannot create \{target}: \{message}")
    }
  }
  if remove_staging(dir) is Some(message) {
    fail("DTA saved, could not remove temporary files: \{message}")
  }
}
