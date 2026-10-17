#!/usr/bin/env python3
"""Write the B01 test-matrix summary the oracle report gates SP06 on.

Each stage's boolean records whether that matrix command completed green
in build/b01/outputs/<stage>.log. Usage:

    b01_matrix_summary.py <output-dir>
"""

import json
import re
import sys
from pathlib import Path


def main() -> int:
    out = Path(sys.argv[1])
    matrix_dir = out / "matrix"
    matrix_dir.mkdir(parents=True, exist_ok=True)

    def suite_green(log: Path, marker: str = "All tests passed!") -> bool:
        if not log.exists():
            return False
        text = log.read_text()
        return marker in text and "Some tests failed" not in text

    analyze_text = (out / "analyze.log").read_text() if (out / "analyze.log").exists() else ""
    corpus_text = (out / "corpus-check.log").read_text() if (out / "corpus-check.log").exists() else ""
    publish_text = (out / "publish-dry-run.log").read_text() if (out / "publish-dry-run.log").exists() else ""

    summary = {
        "generatedAt": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),
        "format": "format exit=0" in (out / "format.log").read_text()
        if (out / "format.log").exists()
        else False,
        "analyze": "No issues found!" in analyze_text,
        "vm": suite_green(out / "vm-suite.log"),
        "chrome": suite_green(out / "chrome-suite.log"),
        "fuzz": suite_green(out / "fuzz-suite.log"),
        "corpus": "manifest check OK" in corpus_text,
        "publish": "Package has 0 warnings" in publish_text
        and "publish exit=0" in publish_text,
    }
    (matrix_dir / "test-matrix.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0 if all(v for k, v in summary.items() if k != "generatedAt") else 1


if __name__ == "__main__":
    sys.exit(main())
