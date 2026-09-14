"""Guards against ``sources.json`` drifting from the Zig source of truth.

``sources.json`` should be produced by ``zig build dump-sources``, which
reads the seven name/folder pairs straight out of
``clip_loader.directoriesFor``. The zig toolchain could not be run on the
machine this file was written on, so ``sources.json`` was hand-written to
match ``directoriesFor`` instead (see the note in ``folders.py`` and in
``tools/dump_sources.zig``).

Without ever running the generator, this test is the only thing standing
between that hand-written file and drift: it parses
``directoriesFor``'s Zig source directly and compares the pairs it finds
against ``sources.json``. If a folder is ever renamed in the Zig source and
``sources.json`` is not regenerated to match, this test -- not a human
proofreading a diff -- is what catches it.
"""

import json
import re
from pathlib import Path

from clips_ui.folders import SOURCES

# clips_ui/tests/test_sources_drift.py -> clips_ui/ -> repo root
_REPO_ROOT = Path(__file__).resolve().parents[2]
_CLIP_LOADER = _REPO_ROOT / "src" / "adapters" / "clip_loader.zig"
_SOURCES_JSON = Path(__file__).resolve().parents[1] / "src" / "clips_ui" / "sources.json"

# Matches lines like `.piano => &.{"EPiano Stems"},` inside `directoriesFor`.
# Deliberately does not match `.drone => unreachable,` -- drone has no
# folder, and is asserted absent below.
_PAIR_RE = re.compile(r'\.(\w+)\s*=>\s*&\.\{"([^"]+)"\},')


def _pairs_from_directories_for() -> dict[str, str]:
    text = _CLIP_LOADER.read_text(encoding="utf-8")
    start = text.index("pub fn directoriesFor")
    end = text.index("\n}", start)
    body = text[start:end]
    return dict(_PAIR_RE.findall(body))


def test_sources_json_matches_directories_for() -> None:
    pairs = _pairs_from_directories_for()

    assert len(pairs) == 7, (
        f"expected 7 source/folder pairs in directoriesFor, found {len(pairs)}: {pairs}. "
        "run zig build dump-sources"
    )
    assert "drone" not in pairs, "drone has no folder and must stay out of sources.json"

    on_disk = json.loads(_SOURCES_JSON.read_text(encoding="utf-8"))

    assert pairs == on_disk, (
        "sources.json has drifted from clip_loader.directoriesFor "
        f"(loader has {pairs}, sources.json has {on_disk}) -- run zig build dump-sources"
    )
    assert pairs == SOURCES, (
        "SOURCES loaded from sources.json does not match clip_loader.directoriesFor "
        "-- run zig build dump-sources"
    )
