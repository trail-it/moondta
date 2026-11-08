"""Reproducible synthetic workloads; measurements are observations, not CI thresholds."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--cli', type=Path, default=ROOT / '_build/js/debug/build/cmd/main/main.js')
parser.add_argument('--sizes', type=int, nargs='+', default=[8, 32])
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--label', default='current')
args = parser.parse_args()
fixtures = ROOT / 'tests/generated/benchmark'
fixtures.mkdir(parents=True, exist_ok=True)
workloads = []
for size in args.sizes:
    path = fixtures / f'long-{size}mib.dta'
    if not path.exists():
        n = size * 1024 // 8
        # Every string is unique: this measures payloads, not a deduplicated dictionary.
        df = pd.DataFrame({'id': np.arange(n, dtype=np.int32),
                           'memo': [f'{i:010d}:' + '汉字' * 1363 for i in range(n)]})
        df.to_stata(path, version=118, write_index=False, convert_strl=['memo'])
    workloads.append(path)
numeric = fixtures / 'numeric-200000.dta'
if not numeric.exists():
    df = pd.DataFrame({f'n{i}': np.arange(200000, dtype=np.float64) + i / 8 for i in range(8)})
    df.to_stata(numeric, version=118, write_index=False)
workloads.append(numeric)
results = []
with tempfile.TemporaryDirectory(prefix='moondta-bench-') as directory:
    temp = Path(directory)
    for source in workloads:
        for command in ('inspect', 'select', 'verify', 'convert'):
            out = temp / f'{source.stem}-{command}.dta'
            argv = [command, str(source)]
            if command == 'select':
                argv += [str(out), '--columns', 'n0' if source == numeric else 'id', '--limit', '10']
            elif command == 'verify':
                argv += ['--batch-size', '256']
            elif command == 'convert':
                argv += [str(out)]
            report = temp / 'metrics.json'
            proc = subprocess.run(['node', str(ROOT / 'tests/measure.cjs'), str(args.cli), str(report), *argv],
                                  capture_output=True, timeout=180)
            if proc.returncode:
                raise RuntimeError(proc.stderr.decode('utf-8', errors='replace'))
            result = json.loads(report.read_text())
            result.update(workload=source.stem, file_mib=source.stat().st_size / 1048576, command=command)
            results.append(result)
            print(f"{source.stem:20} {command:8} {result['seconds']:.3f}s {result['peak_rss_mib']:.1f} MiB", flush=True)
            if out.exists():
                out.unlink()
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps({'label': args.label, 'results': results}, indent=2) + '\n', encoding='utf-8')
