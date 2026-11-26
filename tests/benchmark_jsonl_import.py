"""Compare two built CLIs on the same generated survey and verify identical DTA output."""
import argparse
import filecmp
import json
from pathlib import Path
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def write_survey(path, count):
    schema = json.loads((ROOT / 'examples/survey.json').read_text(encoding='utf-8'))['schema']
    schema['columns'] = [schema['columns'][0], schema['columns'][-1]]
    schema['value_labels'] = []
    observations = [
        '公交站更近了，雨天换乘也很方便。',
        '希望增加夜间班次，方便上晚班的人回家。',
        '站牌的字体太小，换乘时看不清楚。',
        '步行过街时间比较短，希望能多给几秒钟。',
    ]
    with path.open('w', encoding='utf-8', newline='\n') as stream:
        stream.write(json.dumps(dict(moondta_jsonl=1, rows=count, schema=schema), ensure_ascii=False) + '\n')
        for i in range(count):
            memo = f'站点 {i % 512}\n' + ''.join(observations[(i + j) % 4] for j in range(8))
            row = [{'int': i + 1}, {'text': memo}]
            stream.write(json.dumps(row, ensure_ascii=False, separators=(',', ':')) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--rows', type=int, default=100000)
    parser.add_argument('--repeats', type=int, default=3)
    args = parser.parse_args()
    if args.rows < 1 or args.repeats < 1:
        parser.error('rows and repeats must be positive')
    results = {'baseline': [], 'candidate': []}
    with tempfile.TemporaryDirectory(prefix='moondta-import-bench-') as tmp:
        root = Path(tmp)
        source = root / 'survey.jsonl'
        write_survey(source, args.rows)
        for run in range(args.repeats):
            order = ('baseline', 'candidate') if run % 2 == 0 else ('candidate', 'baseline')
            for name in order:
                report = root / 'metrics.json'
                subprocess.run(['node', str(ROOT / 'tests/measure.cjs'), str(getattr(args, name).resolve()),
                                str(report), 'import-jsonl', str(source), str(root / f'{name}.dta')], check=True)
                results[name].append(json.loads(report.read_text(encoding='utf-8')))
            left, right = (root / 'baseline.dta', root / 'candidate.dta')
            assert filecmp.cmp(left, right, shallow=False), 'DTA outputs differ'
            left.unlink()
            right.unlink()
        print(json.dumps({'rows': args.rows, 'input_bytes': source.stat().st_size, 'runs': results,
                          'median_peak_rss_mib': {k: statistics.median(x['peak_rss_mib'] for x in runs)
                                                  for k, runs in results.items()}}, indent=2))


if __name__ == '__main__':
    main()
