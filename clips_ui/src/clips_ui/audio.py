"""Whether an uploaded file can actually be decoded, before it reaches a pool.

An extension check answers a different question than "can ffmpeg decode
this". The installation streams clips by spawning ffmpeg (see
``src/adapters/clip_loader.zig``); a file that ffmpeg cannot decode becomes
a slot in the rotation that plays nothing, and silence is the one failure
nobody in the room can tell apart from the piece working correctly. This
module is the check that stands between an upload and that outcome.

:func:`is_decodable` never raises: every failure mode -- a non-zero exit, a
hang, ffprobe not being installed at all -- degrades to "refuse the
upload", not a stack trace that would take the upload handler down with it.
"""

import logging
import subprocess
from pathlib import Path
from typing import Protocol

logger = logging.getLogger(__name__)

__all__ = ["is_decodable"]

#: Seconds ffprobe is given before it is treated as hung. A malformed or
#: enormous file can make ffprobe hang; a hung upload handler is a wedged
#: UI, so this is never optional and never left to the caller.
_PROBE_TIMEOUT_SECONDS = 30


class _Runner(Protocol):
    def __call__(
        self, cmd: list[str], **kwargs: object
    ) -> subprocess.CompletedProcess: ...


def is_decodable(path: Path, *, runner: _Runner = subprocess.run) -> bool:
    """Whether ``path`` has an audio stream ffprobe can actually read.

    Runs ``ffprobe`` restricted to the first audio stream (``-select_streams
    a:0``) and asks only for its codec type, so a valid container with no
    audio in it -- e.g. an ``.mp4`` with only a video stream -- reports
    success (exit code 0) but no audio, and is refused. Exit code alone is
    therefore never sufficient; the check also confirms ``"audio"`` was
    reported in stdout.

    Args:
        path: The file to check. Not required to exist as far as this
            function's signature goes; a missing or unreadable path is
            simply another way for ``runner`` to fail to report audio.
        runner: What to call instead of ``subprocess.run`` -- the seam
            every test injects a fake through. The real ffprobe/ffmpeg is
            never spawned by this module's own test suite.

    Returns:
        True if ``runner`` exits 0 and reports an audio stream. False for
        every other outcome, including a non-zero exit, a timeout, and
        ffprobe not being installed at all (``OSError``) -- this function
        never raises.
    """
    try:
        done = runner(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "a:0",
                "-show_entries",
                "stream=codec_type",
                "-of",
                "csv=p=0",
                str(path),
            ],
            capture_output=True,
            text=True,
            timeout=_PROBE_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        logger.warning("ffprobe timed out checking %s", path)
        return False
    except OSError:
        logger.warning("ffprobe could not be run checking %s", path, exc_info=True)
        return False
    return done.returncode == 0 and "audio" in done.stdout
