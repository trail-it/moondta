"""Exercise incremental DTA writes, short I/O, and failure cleanup through the CLI."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

from interop import CLI, ROOT, cli


HOOKS = """const fs = require('node:fs');
const path = require('node:path');
const mode = process.env.MOONDTA_TEST_IO;
const [open, read, write, close, link] = [fs.openSync, fs.readSync, fs.writeSync, fs.closeSync, fs.linkSync];
let input, output, scratch, eof = false, early = false, touched = false;
const active = new Set();
fs.openSync = function (name, ...args) {
  const fd = open.call(this, name, ...args);
  if (name === process.argv[3]) input = fd;
  if (typeof name === 'string' && path.basename(path.dirname(name)).startsWith('.moondta-')) {
    if (path.basename(name) === 'output.dta') output = fd;
    if (path.basename(name) === 'strls.tmp') scratch = fd;
  }
  if (fd === input || fd === output || fd === scratch) active.add(fd);
  return fd;
};
fs.readSync = function (fd, buf, offset, length, pos) {
  if (fd === scratch && length === 20 && mode === 'replay') {
    touched = true;
    throw new Error('injected scratch read error');
  }
  const n = read.call(this, fd, buf, offset, mode === 'short' && fd === scratch ? Math.min(length, 257) : length, pos);
  if (fd === input && n === 0) eof = true;
  return n;
};
fs.writeSync = function (fd, buf, offset, length, pos) {
  if (fd !== output && fd !== scratch) return write.apply(this, arguments);
  if (fd === output && pos > 0 && length >= 65536 && !eof) early = true;
  if ((mode === 'data' && fd === output && pos > 0 && !eof) ||
      (mode === 'patch' && fd === output && eof && length === 112) ||
      (mode === 'scratch' && fd === scratch)) {
    touched = true;
    throw new Error('injected write error');
  }
  return write.call(this, fd, buf, offset, mode === 'short' ? Math.min(length, 283) : length, pos);
};
fs.closeSync = function (fd) {
  active.delete(fd);
  return close.call(this, fd);
};
fs.linkSync = function (from, to) {
  if (mode === 'race') {
    touched = true;
    fs.writeFileSync(to, 'another importer won', {flag: 'wx'});
  }
  if (mode === 'fallback') {
    const e = new Error('no hard links');
    e.code = 'ENOTSUP';
    throw e;
  }
  return link.call(this, from, to);
};
process.on('exit', () => {
  const success = mode === 'short' || mode === 'fallback';
  if (active.size || (success ? !early : !touched)) process.exitCode = 96;
});
"""

with tempfile.TemporaryDirectory(prefix='moondta-staging-') as directory:
    root = Path(directory)
    hook = root / 'io.cjs'
    hook.write_text(HOOKS, encoding='utf-8')
    schema = json.loads((ROOT / 'examples/survey.json').read_text(encoding='utf-8'))['schema']
    schema['columns'] = [schema['columns'][0], schema['columns'][-1]]
    schema['value_labels'] = []
    text = '长记录' * 8000
    rows = [[{'int': i}, {'text': f'站点 {i % 1536}'}] for i in range(13000)]
    rows[0][1] = rows[-1][1] = {'text': text}
    rows[-2][1] = {'text': text[:-1] + '末'}
    typed = root / 'oracle.json'
    typed.write_text(json.dumps(dict(moondta_exchange=1, schema=schema, rows=rows),
                                ensure_ascii=False), encoding='utf-8')
    oracle = root / 'oracle.dta'
    cli('import', typed, oracle, '--version', 119, '--endian', 'big')
    source = root / 'input.jsonl'
    with source.open('w', encoding='utf-8') as f:
        print(json.dumps(dict(moondta_jsonl=1, schema=schema, rows=len(rows)), ensure_ascii=False), file=f)
        for row in rows:
            print(json.dumps(row, ensure_ascii=False), file=f)
    for mode in ('short', 'fallback', 'data', 'scratch', 'replay', 'patch', 'race'):
        output = root / f'{mode}.dta'
        proc = subprocess.run(['node', '--require', str(hook), str(CLI), 'import-jsonl', str(source),
                               str(output), '--version', '119', '--endian', 'big'],
                              env=dict(os.environ, MOONDTA_TEST_IO=mode),
                              capture_output=True, text=True, encoding='utf-8')
        if mode in ('short', 'fallback'):
            assert proc.returncode == 0, proc
            assert output.read_bytes() == oracle.read_bytes(), mode
        else:
            assert proc.returncode == 1, proc
            if mode == 'race':
                assert output.read_text() == 'another importer won'
            else:
                assert not output.exists(), mode
        assert not list(root.glob('.moondta-*')), mode
    # A value can be valid exchange JSON yet fail its declared DTA storage.
    with source.open('r+', encoding='utf-8') as f:
        lines = f.readlines()
        lines[-1] = '[{"int":2147483647},{"text":""}]\n'
        f.seek(0)
        f.writelines(lines)
        f.truncate()
    result = subprocess.run(['node', str(CLI), 'import-jsonl', str(source), str(root / 'bad.dta')],
                            capture_output=True, text=True)
    assert result.returncode == 1 and 'JSONL line 13001: column 1' in result.stderr, result
    assert not (root / 'bad.dta').exists() and not list(root.glob('.moondta-*'))
    print('PASS streamed data before EOF, short reads/writes, disk failures, exclusive install, cleanup and line errors')
