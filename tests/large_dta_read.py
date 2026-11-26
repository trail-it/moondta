"""Measure seekable verify/export on the same deterministic survey as large_jsonl.py.

Use --rows 1100000 to generate the 2.71 GiB DTA, or supply an existing pair
with --dta and --expected. TMPDIR selects the disk for both output and indexes.
"""
import argparse
from collections import deque
from itertools import zip_longest
import json
from pathlib import Path
import subprocess
import tempfile

from large_jsonl import ROOT, write_input


def compare_lines(expected, exported):
    tail = deque(maxlen=3)
    count = 0
    with expected.open('rb') as original, exported.open('rb') as actual:
        header = json.loads(next(original))
        assert json.loads(next(actual)) == header, 'schema or row count changed'
        for a, b in zip_longest(original, actual):
            count += 1
            assert a is not None and b is not None and b.endswith(b'\n'), count
            assert a == b or json.loads(a) == json.loads(b), count
            tail.append(a)
    assert count == header['rows']
    return header, [json.loads(line) for line in tail]


def run(cli, heap, directory, dta, expected):
    exported = directory / 'all.jsonl'
    metrics = {}
    for command, args in [('verify', []), ('export-jsonl', [exported])]:
        report = directory / f'{command}.json'
        subprocess.run(['node', f'--max-old-space-size={heap}', ROOT / 'tests/measure.cjs',
                        cli, report, command, dta, *args], check=True)
        metrics[command] = json.loads(report.read_text(encoding='utf-8'))
    header, tail = compare_lines(expected, exported)
    projected = directory / 'tail.jsonl'
    schema = header['schema']
    names = [schema['columns'][-1]['name'], schema['columns'][0]['name']]
    subprocess.run(['node', f'--max-old-space-size={heap}', cli, 'export-jsonl', dta, projected,
                    '--columns', ','.join(names), '--offset', str(header['rows'] - len(tail)),
                    '--limit', str(len(tail)), '--batch-size', '1'], check=True)
    with projected.open(encoding='utf-8') as lines:
        projection = json.loads(next(lines))
        expected_schema = dict(schema, columns=[schema['columns'][-1], schema['columns'][0]], sort_order=[2])
        assert projection == dict(header, schema=expected_schema, rows=len(tail))
        assert [json.loads(line) for line in lines] == [[row[-1], row[0]] for row in tail]
    metrics.update(verified_rows=header['rows'], dta_bytes=dta.stat().st_size,
                   jsonl_bytes=exported.stat().st_size, old_space_mib=heap)
    print(json.dumps(metrics), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, default=ROOT / '_build/js/debug/build/cmd/main/main.js')
    parser.add_argument('--rows', type=int, default=10000)
    parser.add_argument('--heap-mib', type=int, default=64)
    parser.add_argument('--dta', type=Path)
    parser.add_argument('--expected', type=Path)
    args = parser.parse_args()
    if bool(args.dta) != bool(args.expected) or args.heap_mib < 1 or not 1 <= args.rows <= 2147483620:
        parser.error('supply both existing files or a positive, representable number of survey rows')
    cli = args.cli.resolve()
    with tempfile.TemporaryDirectory(prefix='moondta-dta-benchmark-') as temp:
        directory = Path(temp)
        dta, expected = args.dta, args.expected
        if dta is None:
            dta, expected = directory / 'survey.dta', directory / 'survey.jsonl'
            write_input(expected, args.rows)
            subprocess.run(['node', f'--max-old-space-size={args.heap_mib}', cli,
                            'import-jsonl', expected, dta], check=True)
        run(cli, args.heap_mib, directory, dta, expected)


if __name__ == '__main__':
    main()
