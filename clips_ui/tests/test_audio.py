"""Tests for ``clips_ui.audio``.

``is_decodable`` is the check that stands between a web upload and a clip
pool: an extension check answers a different question than "can ffmpeg
actually decode this". A file that fails silently here would otherwise
become a slot in the rotation that plays nothing -- the exact failure
``src/adapters/clip_loader.zig`` calls out as indistinguishable, in a live
museum room, from the installation working correctly.

Every test injects a fake ``runner`` -- the real ``subprocess.run`` /
``ffprobe`` is never invoked, so these tests pass on a machine with no
ffmpeg installed and do not depend on any real audio file.
"""

import subprocess
from pathlib import Path

from clips_ui.audio import is_decodable


def test_a_file_ffprobe_reads_is_accepted(tmp_path: Path) -> None:
    calls = []

    def fake(cmd, **kw):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, stdout="audio\n", stderr="")

    assert is_decodable(tmp_path / "a.mp3", runner=fake)
    assert "ffprobe" in calls[0][0]


def test_a_file_ffprobe_rejects_is_refused(tmp_path: Path) -> None:
    def fake(cmd, **kw):
        return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="invalid data")

    assert not is_decodable(tmp_path / "a.mp3", runner=fake)


def test_a_file_with_no_audio_stream_is_refused(tmp_path: Path) -> None:
    # A video container with only a video stream has a valid header and no
    # sound in it -- exit code 0 alone is not enough to accept it.
    def fake(cmd, **kw):
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    assert not is_decodable(tmp_path / "a.mp4", runner=fake)


def test_ffprobe_hanging_is_refused_not_waited_on(tmp_path: Path) -> None:
    def fake(cmd, **kw):
        raise subprocess.TimeoutExpired(cmd, 10)

    assert not is_decodable(tmp_path / "a.mp3", runner=fake)


def test_ffprobe_not_installed_is_refused_not_raised(tmp_path: Path) -> None:
    # OSError is what subprocess.run raises when the executable does not
    # exist at all -- this must degrade to "refuse the upload", not a
    # stack trace that would take the upload handler down with it.
    def fake(cmd, **kw):
        raise OSError("no such file or directory: ffprobe")

    assert not is_decodable(tmp_path / "a.mp3", runner=fake)


def test_a_timeout_is_passed_to_the_runner(tmp_path: Path) -> None:
    # The timeout is not optional: a malformed or enormous file can make
    # ffprobe hang, and a hung upload handler is a wedged UI.
    calls = []

    def fake(cmd, **kw):
        calls.append(kw)
        return subprocess.CompletedProcess(cmd, 0, stdout="audio\n", stderr="")

    is_decodable(tmp_path / "a.mp3", runner=fake)
    assert isinstance(calls[0]["timeout"], (int, float))
    assert calls[0]["timeout"] > 0
