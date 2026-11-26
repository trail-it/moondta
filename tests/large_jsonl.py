"""Stream a deterministic survey under a capped V8 heap and check the DTA sequentially.

Use --rows 1100000 to cross both a 512 MiB JSONL input and a 2 GiB DTA output.
TMPDIR controls the disk used for the temporary input, output and strL scratch.
"""
import argparse
import json
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TEXT = '城市公共交通出行调查。' * 17
WIDTH = 4 + 2045 + 8
FIXED = b'OK' + bytes(2043)


def write_input(path, count):
    schema = json.loads((ROOT / 'examples/survey.json').read_text(encoding='utf-8'))['schema']
    fixed = dict(schema['columns'][0], name='pad', storage=['Str', 2045], format='%9s')
    schema.update(version=119, endian='Big', columns=[schema['columns'][0], fixed, schema['columns'][-1]],
                  value_labels=[])
    with path.open('w', encoding='utf-8', newline='\n') as source:
        print(json.dumps(dict(moondta_jsonl=1, schema=schema, rows=count), ensure_ascii=False), file=source)
        for i in range(1, count + 1):
            row = [{'int': i}, {'text': 'OK'}, {'text': f'{i}: {TEXT}'}]
            print(json.dumps(row, separators=(',', ':'), ensure_ascii=False), file=source)


def verify_output(path, count):
    # Independently check all rows, all references and all GSO payloads with fixed-size reads.
    with path.open('rb', buffering=1 << 20) as data, path.open('rb', buffering=1 << 20) as objects:
        prefix = data.read(512)
        offsets = struct.unpack_from('>14Q', prefix, prefix.index(b'<map>') + 5)
        assert offsets[13] == path.stat().st_size
        assert struct.unpack_from('>Q', prefix, prefix.index(b'<N>') + 3)[0] == count
        data.seek(offsets[9])
        assert data.read(6) == b'<data>'
        assert data.tell() + WIDTH * count + len(b'</data>') == offsets[10]
        objects.seek(offsets[10])
        assert objects.read(7) == b'<strls>'
        for i in range(1, count + 1):
            ref = b'\x00\x00\x03' + i.to_bytes(5, 'big')
            assert data.read(WIDTH) == i.to_bytes(4, 'big') + FIXED + ref, i
            payload = f'{i}: {TEXT}'.encode('utf-8') + b'\0'
            assert objects.read(20) == b'GSO' + struct.pack('>IQBI', 3, i, 130, len(payload)), i
            assert objects.read(len(payload)) == payload, i
        assert data.read(7) == b'</data>'
        assert objects.read(8) == b'</strls>' and objects.tell() == offsets[11]
        tail = b'<value_labels></value_labels></stata_dta>'
        assert objects.read(len(tail) + 1) == tail


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, default=ROOT / '_build/js/debug/build/cmd/main/main.js')
    parser.add_argument('--rows', type=int, default=10000)
    parser.add_argument('--heap-mib', type=int, default=64)
    args = parser.parse_args()
    if not 1 <= args.rows <= 2147483620 or args.heap_mib < 1:
        parser.error('choose a positive heap size and a row count representable by a Stata long ID')
    with tempfile.TemporaryDirectory(prefix='moondta-large-jsonl-') as directory:
        root = Path(directory)
        source, target, report = (root / name for name in ('large.jsonl', 'large.dta', 'metrics.json'))
        write_input(source, args.rows)
        subprocess.run(['node', f'--max-old-space-size={args.heap_mib}', str(ROOT / 'tests/measure.cjs'),
                        str(args.cli.resolve()), str(report), 'import-jsonl', str(source), str(target)], check=True)
        verify_output(target, args.rows)
        assert not list(root.glob('.moondta-*'))
        result = json.loads(report.read_text(encoding='utf-8'))
        result.update(verified_rows=args.rows, input_bytes=source.stat().st_size,
                      output_bytes=target.stat().st_size, old_space_mib=args.heap_mib)
        print(json.dumps(result))


if __name__ == '__main__':
    main()
