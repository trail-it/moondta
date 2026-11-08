"""Independent pandas/ReadStat interoperability tests. Run after moon build --target js.

Generated fixtures are synthetic. --official additionally fetches Stata Press
examples for local verification; those third-party data files are not distributed.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import struct
import subprocess
import tempfile
import urllib.request

import numpy as np
import pandas as pd
import pyreadstat

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "_build/js/debug/build/cmd/main/main.js"


def cli(*args, ok=True):
    proc = subprocess.run(["node", str(CLI), *map(str, args)], capture_output=True, text=True, encoding="utf-8")
    if ok and proc.returncode:
        raise AssertionError(f"CLI {args}: {proc.stderr}")
    if not ok:
        assert proc.returncode != 0, args
    return proc.stdout


def export(path, directory, name):
    result = directory / f"{name}.json"
    cli("export", path, result)
    return json.loads(result.read_text(encoding="utf-8"))


def scalar(cell):
    if "int" in cell:
        return cell["int"]
    if "number_bits" in cell:
        return struct.unpack(">d", int(cell["number_bits"], 16).to_bytes(8, "big"))[0]
    if "text" in cell:
        return cell["text"]
    if "binary" in cell:
        return bytes(cell["binary"])
    return "." + (chr(96 + cell["missing"]) if cell["missing"] else "")


def compare_pandas(path, wire):
    df = pd.read_stata(path, convert_dates=False, convert_categoricals=False,
                       convert_missing=True, preserve_dtypes=False)
    assert list(df.columns) == [c["name"] for c in wire["schema"]["columns"]]
    assert len(df) == len(wire["rows"])
    for row, expected in zip(wire["rows"], df.itertuples(index=False, name=None)):
        for cell, value in zip(row, expected):
            actual = scalar(cell)
            if "missing" in cell:
                assert actual == str(value), (actual, value)
            else:
                assert actual == value, (actual, value)
                if isinstance(actual, float) and actual == 0:
                    assert math.copysign(1, actual) == math.copysign(1, value)
    with pd.io.stata.StataReader(path, convert_categoricals=False) as reader:
        assert reader.data_label == wire["schema"]["label"]
        assert reader.variable_labels() == {c["name"]: c["label"] for c in wire["schema"]["columns"]}


def synthetic(directory):
    df = pd.DataFrame({
        "字节": np.array([-127, 0, 100], dtype=np.int8),
        "small": np.array([-32767, 0, 32740], dtype=np.int16),
        "large": np.array([-2147483647, 0, 2147483620], dtype=np.int32),
        "single": np.array([-1.25, -0.0, np.nan], dtype=np.float32),
        "double_value": [-1.25e200, -0.0, np.nan],
        "name": ["中文😀", "abcdefghijkl", ""],
        "longtext": ["长文本" * 2000, "", "long"],
        "date": pd.to_datetime(["1960-01-01", "2026-11-07", None]),
    })
    first_wire = None
    for version in (118, 119):
        for order in ("<", ">"):
            stem = f"pandas-{version}-{'le' if order == '<' else 'be'}"
            source = directory / f"{stem}.dta"
            df.to_stata(source, version=version, byteorder=order, write_index=False,
                        data_label="中文数据集", variable_labels={"字节": "编码", "longtext": "长文本"},
                        value_labels={"字节": {-127: "负", 0: "零", 100: "百"}},
                        convert_strl=["longtext"], convert_dates={"date": "td"})
            wire = export(source, directory, stem)
            compare_pandas(source, wire)
            first_wire = first_wire or wire
            dest = directory / f"{stem}-moon.dta"
            cli("import", directory / f"{stem}.json", dest)
            compare_pandas(dest, wire)
            readstat_frame, meta = pyreadstat.read_dta(dest, disable_datetime_conversion=True)
            assert list(readstat_frame.columns) == list(df.columns)
            assert meta.column_names_to_labels["字节"] == "编码"
            assert meta.file_label == "中文数据集"
            assert meta.variable_value_labels["字节"][100] == "百"
            assert meta.original_variable_types["date"] == "%td"
            again = export(dest, directory, stem + "-moon")
            assert wire == again
            assert "Verified 3 rows" in cli("verify", dest, "--batch-size", 2)
            selected = directory / f"{stem}-select.dta"
            cli("select", source, selected, "--columns", "longtext,字节", "--offset", 1, "--limit", 2)
            result = pd.read_stata(selected, convert_categoricals=False)
            assert list(result.columns) == ["longtext", "字节"]
            assert result["字节"].tolist() == [0, 100]
            # CLI failures must neither overwrite existing output nor create partial files.
            before = dest.read_bytes()
            cli("import", directory / f"{stem}.json", dest, ok=False)
            assert dest.read_bytes() == before
            cli("select", source, directory / "bad.dta", "--columns", "unknown", ok=False)
            assert not (directory / "bad.dta").exists()
            print(f"PASS pandas <-> MoonDTA + ReadStat: {version} {order}")

    # Build all 27 missings with independent IEEE encodings through the exchange API.
    wire = first_wire
    wire["schema"]["columns"] = wire["schema"]["columns"][:5]
    wire["schema"]["value_labels"] = []
    wire["schema"]["columns"][0]["value_labels"] = ""
    wire["rows"] = [[{"missing": i} for _ in range(5)] for i in range(27)]
    for version in (118, 119):
        for order in ("little", "big"):
            exchange = directory / f"missing-{version}-{order}.json"
            exchange.write_text(json.dumps(wire, ensure_ascii=False), encoding="utf-8")
            dest = exchange.with_suffix(".dta")
            cli("import", exchange, dest, "--version", version, "--endian", order)
            compare_pandas(dest, wire)
            rs, meta = pyreadstat.read_dta(dest, user_missing=True)
            for name in rs.columns:
                assert math.isnan(rs[name].iloc[0])
                assert rs[name].iloc[1:].tolist() == list("abcdefghijklmnopqrstuvwxyz")
                assert meta.missing_user_values[name] == list("abcdefghijklmnopqrstuvwxyz")
    print("PASS all 27 missing values x 5 numeric types x 2 versions x 2 endians")

    # Independent ReadStat writer, including user missing values and labelled missing.
    rs_path = directory / "readstat.dta"
    pyreadstat.write_dta(pd.DataFrame({"x": [1.0, "a", "z", float("nan")]}), rs_path,
                        version=15, file_label="ReadStat 来源", column_labels={"x": "标签"},
                        missing_user_values={"x": ["a", "z"]},
                        variable_value_labels={"x": {1.0: "one", "a": "缺失甲", "z": "缺失末"}})
    rs_wire = export(rs_path, directory, "readstat")
    assert [scalar(r[0]) for r in rs_wire["rows"]] == [1.0, ".a", ".z", "."]
    assert {v["value"] for s in rs_wire["schema"]["value_labels"] for v in s["entries"]} == {1, 2147483622, 2147483647}
    out = directory / "readstat-moon.dta"
    cli("import", directory / "readstat.json", out)
    compare_pandas(out, rs_wire)
    print("PASS ReadStat writer -> MoonDTA -> pandas")


def official(directory):
    for name in ("auto", "auto2", "datexmpl2"):
        url = f"https://www.stata-press.com/data/r18/{name}.dta"
        cache = ROOT / "tests/generated"
        cache.mkdir(exist_ok=True)
        path = cache / f"{name}.dta"
        if not path.exists():
            request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 MoonDTA-interop/0.1"})
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = response.read()
            path.write_bytes(payload)
        if name == "datexmpl2":
            # The official r18 documentation still serves this example as DTA 117.
            assert b"<release>117</release>" in path.read_bytes()[:80]
            cli("verify", path, ok=False)
            print("PASS official datexmpl2: legacy DTA 117 explicitly rejected")
            continue
        wire = export(path, directory, f"official-{name}")
        compare_pandas(path, wire)
        out = directory / f"official-{name}-moon.dta"
        cli("import", directory / f"official-{name}.json", out)
        compare_pandas(out, wire)
        assert export(out, directory, f"official-{name}-moon") == wire
        cli("verify", out)
        print(f"PASS official {name}: {len(wire['rows'])} rows, {len(wire['schema']['columns'])} variables")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--official", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="moondta-interop-") as work:
        synthetic(Path(work))
        if args.official:
            official(Path(work))
    print("All independent interoperability checks passed.")
