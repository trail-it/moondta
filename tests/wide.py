"""DTA 119 high variable-index strL interoperability (65,537 columns)."""
from pathlib import Path
import tempfile
import json
import pandas as pd
from interop import cli


with tempfile.TemporaryDirectory(prefix="moondta-wide-") as work:
    root = Path(work)
    count = 65537
    df = pd.DataFrame({f"v{i}": ([i % 100] if i < count - 1 else ["宽表长文本"]) for i in range(count)})
    for order in ("<", ">"):
        name = "little" if order == "<" else "big"
        source = root / f"wide-{name}.dta"
        df.to_stata(source, version=119, byteorder=order, write_index=False, convert_strl=[f"v{count-1}"])
        info = json.loads(cli("inspect", source))
        assert len(info["schema"]["columns"]) == count
        assert info["rows"] == 1
        out = root / f"selected-{name}.json"
        cli("export", source, out, "--columns", "v65536,v0")
        wire = json.loads(out.read_text(encoding="utf-8"))
        assert wire["rows"] == [[{"text": "宽表长文本"}, {"int": 0}]]
        written = root / f"moon-{name}.dta"
        cli("convert", source, written)
        check = pd.read_stata(written, columns=["v65536", "v0"], convert_categoricals=False)
        assert check["v65536"].iloc[0] == "宽表长文本"
        assert check["v0"].iloc[0] == 0
        cli("convert", source, root / "invalid118.dta", "--version", 118, ok=False)
        assert not (root / "invalid118.dta").exists()
        print(f"PASS DTA 119 {name}: {count} columns, high strL index, 118 downgrade rejected", flush=True)
