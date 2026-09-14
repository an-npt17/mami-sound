"""Tests for ``clips_ui.folders``.

``SOURCES`` is loaded from ``sources.json``, a file generated from
``clip_loader.directoriesFor`` (see ``tools/dump_sources.zig``). These tests
pin the values that file must hold for the rest of the clip UI to work, and
pin the traversal defenses in ``safe_target`` -- the boundary that stops a
web upload writing outside the clip folders.
"""

from pathlib import Path

import pytest

from clips_ui.folders import SOURCES, UnknownSource, UnsafeName, folder_for, is_audio, safe_target


def test_every_source_maps_to_a_folder() -> None:
    assert len(SOURCES) == 7
    assert "drone" not in SOURCES  # generated, has no folder at all
    assert SOURCES["piano"] == "EPiano Stems"


def test_an_unknown_source_is_refused() -> None:
    with pytest.raises(UnknownSource):
        folder_for(Path("/srv"), "harpsichord")


@pytest.mark.parametrize(
    "evil",
    [
        "../../etc/passwd",
        "..",
        "/etc/passwd",
        "a/../../b",
        "",
        ".",
        "x\x00y",
    ],
)
def test_traversal_is_refused(evil: str) -> None:
    with pytest.raises(UnsafeName):
        safe_target(Path("/srv"), "piano", evil)


@pytest.mark.parametrize(
    "evil",
    [
        "evil\ntrack.mp3",  # embedded newline -- header/log-line injection one layer up
        "evil\ttrack.mp3",  # embedded tab
        "evil\x7ftrack.mp3",  # DEL
        "\x1b",  # bare escape
    ],
)
def test_control_characters_are_refused(evil: str) -> None:
    with pytest.raises(UnsafeName):
        safe_target(Path("/srv"), "piano", evil)


def test_a_plain_name_lands_in_its_folder() -> None:
    assert safe_target(Path("/srv"), "piano", "new.mp3") == Path("/srv/EPiano Stems/new.mp3")


def test_leading_dot_is_not_audio() -> None:
    # Hidden files and the ._name resource forks a macOS machine leaves on a
    # USB stick are not audio however they are named.
    assert not is_audio("._track.mp3")
    assert is_audio("track.MP3")
