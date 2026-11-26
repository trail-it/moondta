"""Build and use the actual local package archive from an isolated consumer."""
from pathlib import Path
import re
import subprocess
import tempfile
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
subprocess.run(["moon", "package"], cwd=ROOT, check=True)
version = re.search(r'^version\s*=\s*"([^"]+)"', (ROOT / "moon.mod").read_text(encoding="utf-8"), re.M)[1]
archive = ROOT / f"_build/publish/trail-it-moondta-{version}.zip"

with tempfile.TemporaryDirectory(prefix="moondta-consumer-") as directory:
    root = Path(directory).resolve()
    library = root / "library"
    consumer = root / "consumer"
    library.mkdir()
    consumer.mkdir()
    with ZipFile(archive) as package:
        names = package.namelist()
        required = {"moon.mod", "moon.pkg", "reader.mbt", "writer.mbt", "pkg.generated.mbti",
                    "stream_writer.mbt", "strl_spool.mbt", "cmd/main/jsonl_output.mbt",
                    "stream_reader.mbt", "read_index.mbt", "file_layout.mbt", "cmd/main/dta_input.mbt",
                    "LICENSE", "third_party/ReadStat-LICENSE", "README.md", "examples/survey.json"}
        assert required <= set(names)
        for name in names:
            assert (library / name).resolve().is_relative_to(library)
            assert not any(part in {".git", ".venv", "_build", "node_modules", "generated", "release-local", "__pycache__"}
                           for part in Path(name).parts), name
        package.extractall(library)
    # Build the packaged CLI before adding the consumer workspace.
    subprocess.run(["moon", "build", "--target", "js"], cwd=library, check=True)
    cli = ["node", str(library / "_build/js/debug/build/cmd/main/main.js")]
    sample = root / "survey.dta"
    lines = root / "survey.jsonl"
    restored = root / "restored.dta"
    subprocess.run([*cli, "import", library / "examples/survey.json", sample], check=True)
    subprocess.run([*cli, "verify", sample], check=True)
    subprocess.run([*cli, "export-jsonl", sample, lines], check=True)
    subprocess.run([*cli, "import-jsonl", lines, restored], check=True)
    assert restored.read_bytes() == sample.read_bytes()
    (root / "moon.work").write_text('members = ["library", "consumer"]\n', encoding="utf-8")
    (consumer / "moon.mod").write_text(f'name = "consumer/check"\nimport {{ "trail-it/moondta@{version}" }}\n', encoding="utf-8")
    (consumer / "moon.pkg").write_text('import { "trail-it/moondta" @dta } for "test"\n', encoding="utf-8")
    (consumer / "consumer_test.mbt").write_text((ROOT / "api_test.mbt").read_text(encoding="utf-8"), encoding="utf-8")
    for target in ("js", "wasm-gc"):
        subprocess.run(["moon", "test", "--target", target, "--package", "consumer/check"], cwd=consumer, check=True)
    print(f"Actual archive checked: {len(names)} files; packaged CLI round trip and independent JS/Wasm GC consumer passed.")
