"""Exercise disk-backed references, bounded reads, and late failure cleanup through the CLI."""
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile

from interop import CLI, ROOT, cli


HOOK = """const fs = require('node:fs');
const path = require('node:path');
const mode = process.env.MOONDTA_READ_TEST;
const [open, close, read, write, readFile, writeFile] =
  [fs.openSync, fs.closeSync, fs.readSync, fs.writeSync, fs.readFileSync, fs.writeFileSync];
const files = new Map();
let outputStarted = false, shortRead = false, shortWrite = false, injected = false;
fs.openSync = function(name, ...args) {
  const fd = open.call(this, name, ...args);
  if (name === process.argv[3]) files.set(fd, 'input');
  if (name === process.argv[4]) files.set(fd, 'output');
  if (typeof name === 'string' && path.basename(name) === 'strls.tmp') files.set(fd, 'index');
  return fd;
};
fs.closeSync = function(fd) { files.delete(fd); return close.call(this, fd); };
fs.readFileSync = function(name, ...args) {
  if (name === process.argv[3] || files.get(name) === 'input') throw Error('whole-file read');
  return readFile.call(this, name, ...args);
};
fs.writeFileSync = function(fd, ...args) {
  if (files.get(fd) === 'output') outputStarted = true;
  return writeFile.call(this, fd, ...args);
};
fs.readSync = function(fd, buf, offset, length, pos) {
  const file = files.get(fd);
  if (file === 'input' || file === 'index') {
    if (length > 65536) throw Error('unbounded read');
    if ((mode === 'input' && file === 'input' && outputStarted) ||
        (mode === 'index-read' && file === 'index')) {
      injected = true;
      throw Error('injected read failure');
    }
    if (mode === 'short' && length > 997) { length = 997; shortRead = true; }
  }
  return read.call(this, fd, buf, offset, length, pos);
};
fs.writeSync = function(fd, buf, offset, length, pos) {
  if (files.get(fd) !== 'index') return write.apply(this, arguments);
  if (mode === 'index-write') { injected = true; throw Error('injected index write failure'); }
  if (mode === 'short' && length > 499) { length = 499; shortWrite = true; }
  return write.call(this, fd, buf, offset, length, pos);
};
process.on('exit', () => {
  const exercised = mode === 'short' ? shortRead && shortWrite : injected;
  if (files.size || !exercised) process.exitCode = 92;
});
"""


def expect_error(path, command, *args, contains):
    run = subprocess.run(['node', CLI, command, path, *args], capture_output=True,
                         encoding='utf-8', check=False)
    assert run.returncode == 1 and contains in run.stderr, (command, run.stderr)


def main():
    with tempfile.TemporaryDirectory(prefix='moondta-reader-test-') as directory:
        root = Path(directory)
        sample = json.loads((ROOT / 'examples/survey.json').read_text(encoding='utf-8'))
        schema = dict(sample['schema'], columns=[sample['schema']['columns'][i] for i in (0, -1)])
        rows = [[{'int': i}, {'text': f'answer {i}'}] for i in range(1, 2301)]
        rows[4][1]['text'] = 'x' * 65535 + '\U0001f600' + 'y' * (2 * 65536) + '\u00e9'
        exchange, source = root / 'survey.json', root / 'survey.dta'
        exchange.write_text(json.dumps(dict(sample, schema=schema, rows=rows)), encoding='utf-8')
        cli('import', exchange, source)
        original = source.read_bytes()
        offsets = struct.unpack_from('<14Q', original, original.index(b'<map>') + 5)
        data, first = offsets[9] + len(b'<data>'), offsets[10] + len(b'<strls>')
        starts, pos = [], first
        while original[pos:pos + 3] == b'GSO':
            starts.append(pos)
            pos += 20 + struct.unpack_from('<I', original, pos + 16)[0]
        assert len(starts) == len(rows) and original[pos:pos + 8] == b'</strls>'
        records = [original[a:b] for a, b in zip(starts, starts[1:] + [pos])]
        unordered = root / 'unordered.dta'
        unordered.write_bytes(original[:first] + b''.join(reversed(records)) + original[pos:])
        cli('verify', unordered)
        exported = root / 'unordered.jsonl'
        cli('export-jsonl', unordered, exported)
        with exported.open(encoding='utf-8') as lines:
            assert json.loads(next(lines)) == dict(moondta_jsonl=1, rows=len(rows), schema=schema)
            assert [json.loads(line) for line in lines] == rows

        broken = root / 'broken.dta'
        partial = root / 'partial.jsonl'
        # The duplicate key lives in a previously flushed disk index block.
        duplicate = bytearray(original)
        duplicate[starts[-1] + 3:starts[-1] + 15] = duplicate[first + 3:first + 15]
        broken.write_bytes(duplicate)
        expect_error(broken, 'verify', contains='duplicate strL key')
        # The 6-byte observation field in 118 must never alias row 1 at 2**32 + 1.
        last = data + (len(rows) - 1) * 12
        invalid = bytearray(original)
        invalid[last + 6:last + 12] = (2**32 + 1).to_bytes(6, 'little')
        broken.write_bytes(invalid)
        expect_error(broken, 'export-jsonl', partial, contains=f'byte {last + 4}: unresolved strL reference')
        assert not partial.exists()
        # verify also decodes the text of an otherwise unreferenced object.
        invalid[last + 4:last + 12] = bytes(8)
        invalid[starts[-1] + 22] = 0
        broken.write_bytes(invalid)
        expect_error(broken, 'verify', contains=f'byte {starts[-1] + 22}: strL text contains embedded NUL')
        cli('export-jsonl', broken, root / 'id-only.jsonl', '--columns', 'id')
        invalid = bytearray(original)
        invalid[starts[4] + 20 + 65536] = 255
        broken.write_bytes(invalid)
        expect_error(broken, 'verify', contains='invalid UTF-8')
        invalid = bytearray(original)
        struct.pack_into('<i', invalid, last, -2147483648)
        broken.write_bytes(invalid)
        expect_error(broken, 'verify', contains=f'byte {last}: integer uses reserved minimum')
        expect_error(broken, 'export-jsonl', partial, contains=f'byte {last}:')
        assert not partial.exists()
        partial.write_bytes(b'existing output')
        expect_error(broken, 'export-jsonl', partial, contains='cannot create output')
        assert partial.read_bytes() == b'existing output'

        hook = root / 'io.cjs'
        hook.write_text(HOOK, encoding='utf-8')
        for mode in ('short', 'input', 'index-read', 'index-write'):
            destination = root / f'{mode}.jsonl'
            env = dict(os.environ, TMPDIR=directory, TMP=directory, TEMP=directory, MOONDTA_READ_TEST=mode)
            result = subprocess.run(['node', '--require', hook, CLI, 'export-jsonl', unordered, destination],
                                    env=env, capture_output=True, encoding='utf-8')
            if mode == 'short':
                assert result.returncode == 0, result.stderr
                assert destination.read_bytes() == exported.read_bytes()
            else:
                assert result.returncode == 1 and not destination.exists(), result.stderr
            assert not list(root.glob('moondta-read-*')), mode
        print('PASS seekable verify/export: unordered and duplicate objects, bounded UTF-8, '
              '64-bit references, short I/O, exact offsets and failure cleanup', flush=True)


if __name__ == '__main__':
    main()
