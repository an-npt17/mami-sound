"""The request/result conversation with the Zig installation.

Two processes talk through two files that live beside each other in the
installation's working directory (``/home/pi/mami-sound/`` in production; a
temp directory in tests):

``reload.request`` -- written by this module, deleted by the Zig side once
read. Names the sources whose clip pools should be reloaded::

    {"id": "20260913T185301Z-a1b2c3", "sources": ["piano", "insect"]}

``reload.result`` -- written by the Zig side, read by this module. Reports
what happened to each requested source::

    {"id": "20260913T185301Z-a1b2c3",
     "outcomes": [{"source": "piano", "status": "applied", "clips": 9,
                   "detail": ""}]}

Both files are written to a temp name in the same directory and renamed
into place with ``os.replace``, which is atomic on the same filesystem --
so a reader never sees a half-written file. Matching by ``id`` is what lets
:func:`read_result` tell "the installation has not answered yet" apart from
"here is a stale answer to a previous request": both look like a
``reload.result`` file sitting on disk, and only the id tells them apart.
"""

import json
import logging
import os
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

logger = logging.getLogger(__name__)

__all__ = [
    "Outcome",
    "Result",
    "new_request_id",
    "write_request",
    "read_result",
]

_REQUEST_FILENAME = "reload.request"
_RESULT_FILENAME = "reload.result"

#: The only values the Zig side ever writes for an outcome's ``status``.
#: ``not_playing`` is not an error: the source is real but no plant is
#: currently playing it, so the files were written and the next start
#: picks them up.
_VALID_STATUSES = frozenset({"applied", "refused", "not_playing", "failed"})


@dataclass
class Outcome:
    """What happened to one requested source."""

    source: str
    status: str
    clips: int
    detail: str


@dataclass
class Result:
    """The installation's answer to one ``reload.request``."""

    id: str
    outcomes: list[Outcome]


def new_request_id() -> str:
    """A request id that sorts chronologically and will not collide.

    Returns:
        A UTC timestamp (second resolution, ``YYYYMMDDTHHMMSSZ``) followed
        by a short random suffix, e.g. ``"20260913T185301Z-a1b2c3"``. The
        timestamp prefix makes ids sort chronologically; the random suffix
        (from :func:`secrets.token_hex`) keeps two staff pressing Apply in
        the same second from colliding.
    """
    timestamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    suffix = secrets.token_hex(3)
    return f"{timestamp}-{suffix}"


def _atomic_write(path: Path, text: str) -> None:
    """Write ``text`` to ``path`` via a same-directory temp file and rename.

    ``os.replace`` is atomic on the same filesystem, so a reader of
    ``path`` never observes a half-written file. The temp file is cleaned
    up if the write itself fails, so a crash never leaves a stray ``.tmp``
    behind.
    """
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    try:
        tmp_path.write_text(text, encoding="utf-8")
        os.replace(tmp_path, path)
    except BaseException:
        tmp_path.unlink(missing_ok=True)
        raise


def write_request(root: Path, request_id: str, sources: list[str]) -> None:
    """Write ``reload.request``, renamed into place atomically.

    Args:
        root: The installation's working directory (see module docstring).
        request_id: The id this request should be matched by; normally
            from :func:`new_request_id`.
        sources: Source names (e.g. ``["piano", "insect"]``) whose clip
            pools should be reloaded.
    """
    payload = json.dumps({"id": request_id, "sources": sources})
    _atomic_write(root / _REQUEST_FILENAME, payload)


def _parse_outcome(raw: object) -> Outcome:
    """Parse one ``outcomes`` entry, raising on anything malformed.

    Raises:
        (any exception): if ``raw`` is not a mapping with exactly the
            expected keys and a recognised ``status`` -- callers treat any
            exception here as "this result is unreadable".
    """
    if not isinstance(raw, dict):
        raise ValueError("outcome is not an object")
    source = raw["source"]
    status = raw["status"]
    clips = raw["clips"]
    detail = raw["detail"]
    if not isinstance(source, str) or not isinstance(detail, str):
        raise ValueError("outcome has a field of the wrong type")
    if not isinstance(clips, int) or isinstance(clips, bool):
        raise ValueError("outcome has a field of the wrong type")
    if status not in _VALID_STATUSES:
        raise ValueError(f"unrecognised status: {status!r}")
    return Outcome(source=source, status=status, clips=clips, detail=detail)


def _parse_result(raw: object) -> Result:
    """Parse a decoded ``reload.result`` payload, raising on anything malformed."""
    if not isinstance(raw, dict):
        raise ValueError("result is not an object")
    request_id = raw["id"]
    outcomes_raw = raw["outcomes"]
    if not isinstance(request_id, str) or not isinstance(outcomes_raw, list):
        raise ValueError("result has a field of the wrong type")
    outcomes = [_parse_outcome(entry) for entry in outcomes_raw]
    return Result(id=request_id, outcomes=outcomes)


def read_result(root: Path, request_id: str) -> Result | None:
    """Read ``reload.result`` if it answers ``request_id``, else ``None``.

    ``None`` covers every way "no answer yet" can look on disk: the file
    does not exist, it is present but does not parse as JSON, it parses
    but is missing an expected key or carries an unrecognised ``status``,
    or it parses fine but answers a different (older) request id. This
    function never raises into the page -- a crash mid-write on the Zig
    side, however unlikely given the rename-into-place discipline, must
    not take the UI down.

    Args:
        root: As for :func:`write_request`.
        request_id: The id of the request this call is waiting on.

    Returns:
        The parsed :class:`Result` if ``reload.result`` exists, parses,
        and answers ``request_id``; ``None`` otherwise.
    """
    path = root / _RESULT_FILENAME
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
        result = _parse_result(raw)
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
        logger.debug("reload.result not ready or unreadable", exc_info=True)
        return None
    if result.id != request_id:
        return None
    return result
