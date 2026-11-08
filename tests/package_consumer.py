"""Build and use the actual local package archive from an isolated consumer."""
from pathlib import Path
import subprocess
import tempfile
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
subprocess.run(["moon", "package"], cwd=ROOT, check=True)
archive = ROOT / "_build/publish/trail-it-moondta-0.2.0.zip"

with tempfile.TemporaryDirectory(prefix="moondta-consumer-") as directory:
    root = Path(directory).resolve()
    library = root / "library"
    consumer = root / "consumer"
    library.mkdir()
    consumer.mkdir()
    with ZipFile(archive) as package:
        names = package.namelist()
        required = {"moon.mod", "moon.pkg", "reader.mbt", "writer.mbt", "pkg.generated.mbti",
                    "LICENSE", "third_party/ReadStat-LICENSE", "README.md", "examples/survey.json"}
        assert required <= set(names)
        for name in names:
            assert (library / name).resolve().is_relative_to(library)
            assert not any(part in {".git", ".venv", "_build", "node_modules", "generated", "release-local", "__pycache__"}
                           for part in Path(name).parts), name
        package.extractall(library)
    (root / "moon.work").write_text('members = ["library", "consumer"]\n', encoding="utf-8")
    (consumer / "moon.mod").write_text('name = "consumer/check"\nimport { "trail-it/moondta@0.2.0" }\n', encoding="utf-8")
    (consumer / "moon.pkg").write_text('import { "trail-it/moondta" @dta } for "test"\n', encoding="utf-8")
    (consumer / "consumer_test.mbt").write_text((ROOT / "api_test.mbt").read_text(encoding="utf-8"), encoding="utf-8")
    for target in ("js", "wasm-gc"):
        subprocess.run(["moon", "test", "--target", target, "--package", "consumer/check"], cwd=consumer, check=True)
    print(f"Actual archive checked: {len(names)} files; independent JS/Wasm GC consumer passed.")
