"""Shared strLs, mixed labels, batch boundaries, binary payload and CLI display checks."""
import json
from pathlib import Path
import struct
import tempfile
import numpy as np
import pandas as pd
from interop import cli, export, compare_pandas, ROOT


def binary_objects(raw):
    order = '<' if b'<byteorder>LSF</byteorder>' in raw[:100] else '>'
    offsets = struct.unpack_from(order + '14Q', raw, raw.index(b'<map>') + 5)
    pos, end = offsets[10] + len(b'<strls>'), offsets[11] - len(b'</strls>')
    objects = []
    while pos < end:
        assert raw[pos:pos+3] == b'GSO'
        v, o, kind, size = struct.unpack_from(order + 'IQBI', raw, pos + 3)
        objects.append((pos, v, o, kind, raw[pos+20:pos+20+size]))
        pos += 20 + size
    assert pos == end
    return objects


with tempfile.TemporaryDirectory(prefix='moondta-compat-') as directory:
    root = Path(directory)
    n = 1025
    values = ['', '共享中文😀', '汉' * 2500, 'another']
    df = pd.DataFrame({
        'id': np.arange(n, dtype=np.int32),
        'kind': (np.arange(n) % 3).astype(np.int8),
        'score': np.where(np.arange(n) % 7 == 0, np.nan, np.arange(n) / 8),
        'left_text': [values[i % 4] for i in range(n)],
        'right_text': [values[(i + 1) % 4] for i in range(n)],
    })
    for version in (118, 119):
        for order in ('<', '>'):
            stem = f"shared-{version}-{'le' if order == '<' else 'be'}"
            path = root / f'{stem}.dta'
            df.to_stata(path, version=version, byteorder=order, write_index=False,
                        convert_strl=['left_text', 'right_text'],
                        value_labels={'kind': {0: '零', 1: '一'}},  # 2 deliberately has no label
                        variable_labels={'score': '分数', 'left_text': '共享内容'},
                        data_label='跨批次验证')
            objects = binary_objects(path.read_bytes())
            assert len(objects) == 3, 'pandas fixture must really share cross-column GSO references'
            wire = export(path, root, stem)
            compare_pandas(path, wire)
            assert f'Verified {n} rows' in cli('verify', path, '--batch-size', 256)
            for offset in (0, 255, 256, 1024):
                count = min(258, n - offset)
                dest = root / f'{stem}-{offset}.json'
                cli('export', path, dest, '--columns', 'right_text,kind,score', '--offset', offset, '--limit', count)
                subset = json.loads(dest.read_text(encoding='utf-8'))
                expected = wire['rows'][offset:offset+count]
                assert subset['rows'] == [[row[4], row[1], row[2]] for row in expected]
            rewritten = root / f'{stem}-written.dta'
            cli('import', root / f'{stem}.json', rewritten)
            compare_pandas(rewritten, wire)
            rewritten_raw = rewritten.read_bytes()
            assert len(binary_objects(rewritten_raw)) == 3, 'writer must retain shared text storage'
            # Same metadata and values as pandas: sharing must also retain its compact size.
            assert len(rewritten_raw) == path.stat().st_size
            print(f'PASS deduplicated text: {len(rewritten_raw):,} bytes, 3 objects', flush=True)
            print(f'PASS shared strL / mixed labels / 1,025 rows / batch boundaries: {version} {order}', flush=True)

            # Independent binary fixture: change pandas' GSO payload into a binary object.
            tiny = root / f'{stem}-binary.dta'
            pd.DataFrame({'a': ['abc', 'abc'], 'b': ['abc', '']}).to_stata(
                tiny, version=version, byteorder=order, write_index=False, convert_strl=['a', 'b'])
            raw = bytearray(tiny.read_bytes())
            [(at, _, _, kind, payload)] = binary_objects(raw)
            assert kind == 130 and payload == b'abc\0'
            raw[at + 15] = 129
            raw[at + 20:at + 24] = b'\0\xff\x80\x7f'
            tiny.write_bytes(raw)
            binary_wire = export(tiny, root, stem + '-binary')
            binary = {'binary': [0, 255, 128, 127]}
            assert binary_wire['rows'] == [[binary, binary], [binary, {'text': ''}]]
            rewritten_binary = root / f'{stem}-binary-written.dta'
            cli('import', root / f'{stem}-binary.json', rewritten_binary)
            written_objects = binary_objects(rewritten_binary.read_bytes())
            assert len(written_objects) == 1
            assert rewritten_binary.stat().st_size == tiny.stat().st_size
            assert all(kind == 129 and payload == b'\0\xff\x80\x7f' for _, _, _, kind, payload in written_objects)

    survey = root / 'survey.dta'
    cli('import', ROOT / 'examples/survey.json', survey)
    view = cli('preview', survey, '--columns', '回答,score,备注', '--width', 12)
    assert '.a ("拒绝回答")' in view and '| 1.5 |' in view and '| -0 |' in view
    assert 'number_bits' not in view and '中文' in view
    assert '拒绝回答' not in cli('preview', survey, '--labels', 'off', '--columns', '回答')
    dictionary = cli('describe', survey)
    assert '合成问卷示例' in dictionary and '是否满意' in dictionary and '| .a | "拒绝回答" |' in dictionary
    cli('preview', survey, '--width', 0, ok=False)
    cli('preview', survey, '--offset', 4, ok=False)
    cli('preview', survey, '--labels', 'invalid', ok=False)
    print('PASS independent binary GSO checks and readable CLI commands', flush=True)
