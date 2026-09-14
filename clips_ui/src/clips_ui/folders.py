"""Which clip folders exist, and what may be written into them.

This module is the security boundary for the clip web UI: every filename a
web upload will ever write to disk passes through :func:`safe_target` first.
Nothing here talks HTTP; it only knows folder names and validates paths.

The folder names themselves are not owned by this module. They are owned by
``clip_loader.directoriesFor`` in the Zig side of this project (see
``src/adapters/clip_loader.zig``), because that is where a mistake would
actually break playback. ``sources.json`` -- loaded into :data:`SOURCES`
below -- is meant to be generated from that function by running
``zig build dump-sources`` (see ``tools/dump_sources.zig``), never
hand-edited.

NOTE: at the time this file was written, the zig toolchain could not be run
on this machine, so ``sources.json`` was hand-written to match
``clip_loader.directoriesFor`` instead of generated. It must be regenerated
with ``zig build dump-sources`` whenever a folder name changes; a drift test
(``tests/test_sources_drift.py``) parses ``directoriesFor`` directly and
fails if this file falls out of sync.
"""

import json
import logging
from pathlib import Path

logger = logging.getLogger(__name__)

__all__ = [
    "SOURCES",
    "AUDIO_EXTENSIONS",
    "UnknownSource",
    "UnsafeName",
    "folder_for",
    "safe_target",
    "is_audio",
]

_SOURCES_PATH = Path(__file__).parent / "sources.json"


def _load_sources() -> dict[str, str]:
    """Load the source-name to folder-name mapping from ``sources.json``.

    Raises:
        FileNotFoundError: if ``sources.json`` is missing.
        json.JSONDecodeError: if it is not valid JSON.
    """
    with _SOURCES_PATH.open(encoding="utf-8") as handle:
        return json.load(handle)


#: Source name (as named in the Zig ``Source`` enum, e.g. ``"piano"``) to the
#: folder name it is read from (e.g. ``"EPiano Stems"``). Deliberately has no
#: entry for ``"drone"``: the drone is generated audio with no folder behind
#: it at all.
SOURCES: dict[str, str] = _load_sources()

#: Mirrors ``src/adapters/library.zig``'s ``audio_extensions``, matched
#: case-insensitively. Anything else in a folder -- a text note, a cover
#: image, a stray project file -- is not audio.
AUDIO_EXTENSIONS: frozenset[str] = frozenset(
    {".mp3", ".wav", ".ogg", ".opus", ".flac", ".m4a", ".aac", ".aif", ".aiff", ".wma"}
)


class UnknownSource(Exception):
    """Raised when a source name is not one of :data:`SOURCES`."""


class UnsafeName(Exception):
    """Raised when a filename could not be trusted to stay inside its folder."""


def _is_control_character(char: str) -> bool:
    """Whether ``char`` is a C0 or C1 control character.

    Covers ``\x00``-``\x1f`` (NUL, newline, tab, escape, ...) and
    ``\x7f``-``\x9f`` (DEL and the C1 set). These are never legitimate in a
    filename an upload names itself, and are a live risk one layer up from
    this module -- e.g. header injection in an HTTP response, or breaking a
    naive log line or directory listing -- even though they cannot by
    themselves defeat the containment check below.
    """
    code_point = ord(char)
    return code_point < 0x20 or 0x7F <= code_point <= 0x9F


def folder_for(root: Path, source: str) -> Path:
    """The folder a source's clips live in, under ``root``.

    Args:
        root: The directory the clip folders live beside (the installation's
            working directory in production; a temp directory in tests).
        source: A source name, e.g. ``"piano"``.

    Returns:
        The path to that source's folder. The folder is not required to
        exist on disk; this function only computes the path.

    Raises:
        UnknownSource: if ``source`` is not a key of :data:`SOURCES` -- this
            covers both typos and ``"drone"``, which has no folder.
    """
    try:
        folder_name = SOURCES[source]
    except KeyError:
        raise UnknownSource(source) from None
    return root / folder_name


def safe_target(root: Path, source: str, filename: str) -> Path:
    """Where ``filename`` may be written for ``source``, or refuse it.

    This is the security boundary that stops a web upload writing outside
    the clip folders. It is deliberately belt and braces: a name is rejected
    by inspection first (any of the checks below), and only then is the
    result resolved and re-checked for containment in the target folder.

    What this function guarantees: the returned path is contained in
    ``source``'s folder (no traversal out of it, however the input is
    spelled), and the filename carries no C0 or C1 control character (no
    embedded newline, tab, or other byte a naive HTTP header, log line, or
    directory listing would not expect).

    What this function does NOT guarantee: it is not HTML-escaping, not
    shell-quoting, and not a substitute for correct escaping at whatever
    layer renders or shells out with the name later. Shell metacharacters
    ($, backticks, parentheses, spaces, quotes) are deliberately accepted --
    they occur in real audio filenames (this project's own folders are
    named things like ``Trad Vn Jam`` and ``EPiano Stems``) -- so a caller
    that passes a filename to a shell or an HTML template must quote or
    escape it there; banning characters here would not help that caller and
    would reject legitimate names.

    Args:
        root: As for :func:`folder_for`.
        source: As for :func:`folder_for`.
        filename: The filename an upload asked to be saved as. Only the
            basename is meaningful; any directory component is itself
            grounds for refusal (see below), never silently followed.

    Returns:
        The path ``filename`` may safely be written to, inside ``source``'s
        folder.

    Raises:
        UnknownSource: as :func:`folder_for`.
        UnsafeName: if ``filename`` is empty, ``.``, ``..``, contains a NUL
            byte or any other C0/C1 control character (``\x00``-``\x1f``,
            ``\x7f``-``\x9f`` -- covers newlines, tabs, and escape), contains
            a path separator (so it cannot name a directory component),
            starts with ``.`` (hidden files and macOS resource forks are
            never a legitimate upload name), or -- after all of that --
            still does not resolve inside the target folder.
    """
    folder = folder_for(root, source)

    if any(_is_control_character(c) for c in filename):
        raise UnsafeName(filename)

    name = Path(filename).name

    if name in ("", ".", ".."):
        raise UnsafeName(filename)
    if name != filename:
        # The basename differs from the input: the input carried a directory
        # component (a path separator), which is refused outright rather
        # than silently reduced.
        raise UnsafeName(filename)
    if name.startswith("."):
        raise UnsafeName(filename)

    target = (folder / name).resolve()
    resolved_folder = folder.resolve()
    if resolved_folder != target and resolved_folder not in target.parents:
        raise UnsafeName(filename)

    return folder / name


def is_audio(name: str) -> bool:
    """Whether a directory entry name is a clip, mirroring ``library.isAudio``.

    A name starting with ``.`` is never audio -- this covers both hidden
    files and the ``._name`` resource forks a macOS machine leaves on a USB
    stick, whatever extension they carry.

    Args:
        name: A bare filename (not a path).

    Returns:
        True if the name ends with one of :data:`AUDIO_EXTENSIONS`,
        case-insensitively, and does not start with ``.``.
    """
    if not name or name.startswith("."):
        return False
    lowered = name.lower()
    return any(lowered.endswith(ext) for ext in AUDIO_EXTENSIONS)
