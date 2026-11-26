"""Check JSONL round trips and compare the resulting DTA files with pandas."""
import json
import struct
import subprocess
import tempfile
from pathlib import Path

import pandas as pd
from interop import cli, export, compare_pandas, ROOT, CLI


def read_jsonl(path):
    with path.open(encoding='utf-8') as stream:
        header = json.loads(next(stream))
        rows = [json.loads(line) for line in stream]
    assert header['moondta_jsonl'] == 1
    assert header['rows'] == len(rows)
    return {'moondta_exchange': 1, 'schema': header['schema'], 'rows': rows}


with tempfile.TemporaryDirectory(prefix='moondta-jsonl-') as directory:
    root = Path(directory)
    for version in (118, 119):
        for endian in ('<', '>'):
            stem = f'{version}-{ord(endian)}'
            source = root / f'{stem}.dta'
            pd.DataFrame({'id': range(515), 'text': [['中\n文😀', 'quote"\\', ''][i % 3] for i in range(515)]}).to_stata(
                source, version=version, byteorder=endian, write_index=False, convert_strl=['text'])
            wire = export(source, root, stem)
            for batch in (1, 256, 1024):
                target = root / f'{stem}-{batch}.jsonl'
                cli('export-jsonl', source, target, '--batch-size', batch)
                assert read_jsonl(target) == wire
                compare_pandas(source, read_jsonl(target))
            subset_json = root / f'{stem}-subset.json'
            subset_jsonl = root / f'{stem}-subset.jsonl'
            args = ('--columns', 'text,id', '--offset', 255, '--limit', 258)
            cli('export', source, subset_json, *args)
            cli('export-jsonl', source, subset_jsonl, *args, '--batch-size', 256)
            assert read_jsonl(subset_jsonl) == json.loads(subset_json.read_text(encoding='utf-8'))
            # Import CRLF records with an unterminated final line, preserving projection order.
            subset_jsonl.write_bytes(b'\r\n'.join(subset_jsonl.read_bytes().splitlines()))
            restored = root / f'{stem}-restored.dta'
            cli('import-jsonl', subset_jsonl, restored)
            projected = read_jsonl(subset_jsonl)
            assert export(restored, root, f'{stem}-roundtrip') == projected
            compare_pandas(restored, projected)
            empty = root / f'{stem}-empty.jsonl'
            cli('export-jsonl', source, empty, '--offset', 515)
            assert read_jsonl(empty)['rows'] == []
            empty_dta = root / f'{stem}-empty.dta'
            cli('import-jsonl', empty, empty_dta)
            assert export(empty_dta, root, f'{stem}-empty') == read_jsonl(empty)
            for flag, value in (('--batch-size', 0), ('--offset', 516), ('--columns', 'id,id')):
                rejected = root / 'invalid.jsonl'
                cli('export-jsonl', source, rejected, flag, value, ok=False)
                assert not rejected.exists()
            existing = root / 'existing.jsonl'
            existing.write_bytes(b'keep me')
            cli('export-jsonl', source, existing, ok=False)
            assert existing.read_bytes() == b'keep me'
            existing.unlink()
            # Fail after the first row has been emitted, not during metadata parsing.
            raw = bytearray(source.read_bytes())
            offsets = struct.unpack_from(endian + '14Q', raw, raw.index(b'<map>') + 5)
            row_start = offsets[9] + len(b'<data>')
            raw[row_start + 12:row_start + 16] = b'\x80\x00\x00\x00' if endian == '>' else b'\x00\x00\x00\x80'
            broken = root / f'{stem}-broken.dta'
            broken.write_bytes(raw)
            partial = root / f'{stem}-partial.jsonl'
            cli('export-jsonl', broken, partial, '--batch-size', 1, ok=False)
            assert not partial.exists()
            print(f'PASS JSONL {version} {endian}: external values, batches, projection, empty range, cleanup', flush=True)

    survey = root / 'survey.dta'
    cli('import', ROOT / 'examples/survey.json', survey)
    typed = export(survey, root, 'survey')
    lines = root / 'survey.jsonl'
    cli('export-jsonl', survey, lines, '--batch-size', 1)
    assert read_jsonl(lines) == typed
    binary_wire = dict(typed)
    binary_wire['rows'] = [row[:] for row in typed['rows']]
    binary_wire['rows'][0][-1] = {'binary': [0, 255, 128, 10]}
    binary_json = root / 'binary.json'
    binary_json.write_text(json.dumps(binary_wire, ensure_ascii=False), encoding='utf-8')
    binary_dta = root / 'binary.dta'
    cli('import', binary_json, binary_dta)
    binary_lines = root / 'binary.jsonl'
    cli('export-jsonl', binary_dta, binary_lines, '--batch-size', 1)
    assert read_jsonl(binary_lines) == binary_wire
    restored = root / 'typed-restored.dta'
    cli('import-jsonl', binary_lines, restored, '--version', '119', '--endian', 'big')
    restored_wire = export(restored, root, 'typed-restored')
    assert restored_wire['schema'] == dict(binary_wire['schema'], version=119, endian='Big')
    assert restored_wire['rows'] == binary_wire['rows']
    preserved = restored.read_bytes()
    cli('import-jsonl', binary_lines, restored, ok=False)
    assert restored.read_bytes() == preserved
    records = binary_lines.read_bytes().splitlines()
    for index, (bad, line_number) in enumerate([
            (records[:-1], len(records)), (records + [b'[]'], len(records) + 1),
            ([records[0], b'[]', *records[2:]], 2), ([records[0], b'\xff'], 2),
            ([b''], 1)]):
        source = root / f'invalid-{index}.jsonl'
        target = root / f'invalid-{index}.dta'
        source.write_bytes(b'\n'.join(bad) + b'\n')
        result = subprocess.run(['node', str(CLI), 'import-jsonl', str(source), str(target)],
                                capture_output=True, text=True, encoding='utf-8')
        assert result.returncode != 0 and f'JSONL line {line_number}:' in result.stderr, result
        assert not target.exists()
    # Inject a destination write error after output has begun to exercise cleanup.
    preload = root / 'write-failure.cjs'
    preload.write_text("""const fs = require('node:fs');
const original = fs.writeFileSync;
let writes = 0;
fs.writeFileSync = function(fd, ...args) {
  if (typeof fd === 'number' && ++writes === 3) throw new Error('injected write failure');
  return original.call(this, fd, ...args);
};
""", encoding='utf-8')
    failed_output = root / 'write-failure.jsonl'
    failure = subprocess.run(['node', '--require', str(preload), str(CLI), 'export-jsonl',
                              str(survey), str(failed_output), '--batch-size', '1'],
                             capture_output=True, text=True, encoding='utf-8')
    assert failure.returncode != 0 and 'injected write failure' in failure.stderr
    assert not failed_output.exists()
    print('PASS JSONL typed missing values, negative zero, labels and binary bytes', flush=True)
