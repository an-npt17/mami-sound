"""Tests for ``clips_ui.staging``.

Staff do not want every upload or delete to hit the clip folders one at a
time -- they want to queue three adds and two removes, glance at what is
pending, then press Apply once. :class:`Staging` is that queue: nothing it
does touches a clip folder until :meth:`Staging.apply` runs, and ``apply``
writes exactly one ``reload.request`` naming only the sources that actually
changed.

The rule under heaviest test here is the one the task brief calls out by
name: :meth:`Staging.would_empty` is checked for *every* touched source
before ``apply`` moves or deletes a single file. A pool left with no clips
means a plant plays silence -- the one failure nobody in the room can tell
apart from the installation working correctly -- so the check must run, in
full, before any mutation, not fail fast on the first source and leave
later sources half-applied.
"""

import json
from pathlib import Path

import pytest

from clips_ui.folders import UnsafeName
from clips_ui.staging import Pending, Staging, WouldEmptyPool


@pytest.fixture
def upload(tmp_path: Path) -> Path:
    """A file sitting wherever the web layer saved it, before Apply moves it.

    Lives outside any clip folder -- ``uploads/`` beside them, never inside
    ``EPiano Stems`` -- so it is obvious in a failing test whether a path
    came from the upload side or the destination side.
    """
    uploads = tmp_path / "uploads"
    uploads.mkdir()
    path = uploads / "incoming.mp3"
    path.write_bytes(b"fake audio bytes")
    return path


def _seed(root: Path, folder_name: str, filenames: list[str]) -> Path:
    """Create ``folder_name`` under ``root`` with empty files named ``filenames``."""
    folder = root / folder_name
    folder.mkdir(parents=True, exist_ok=True)
    for name in filenames:
        (folder / name).write_bytes(b"clip")
    return folder


def test_staged_changes_do_not_touch_the_folder_until_apply(tmp_path: Path) -> None:
    _seed(tmp_path, "EPiano Stems", ["old.mp3"])
    s = Staging()
    s.stage_remove("piano", "old.mp3")
    assert (tmp_path / "EPiano Stems" / "old.mp3").exists()


def test_apply_deletes_and_moves_then_writes_one_request(tmp_path: Path, upload: Path) -> None:
    _seed(tmp_path, "EPiano Stems", ["old.mp3"])
    s = Staging()
    s.stage_add("piano", upload, "new.mp3")
    s.stage_remove("piano", "old.mp3")
    request_id = s.apply(tmp_path)
    assert (tmp_path / "EPiano Stems" / "new.mp3").exists()
    assert not (tmp_path / "EPiano Stems" / "old.mp3").exists()
    payload = json.loads((tmp_path / "reload.request").read_text())
    assert payload["sources"] == ["piano"]
    assert payload["id"] == request_id


def test_removing_every_clip_is_caught_before_anything_is_deleted() -> None:
    s = Staging()
    s.stage_remove("piano", "a.mp3")
    s.stage_remove("piano", "b.mp3")
    assert s.would_empty("piano", ["a.mp3", "b.mp3"])


def test_an_add_offsets_a_remove(upload: Path) -> None:
    s = Staging()
    s.stage_remove("piano", "a.mp3")
    s.stage_add("piano", upload, "new.mp3")
    assert not s.would_empty("piano", ["a.mp3"])


def test_apply_names_only_the_sources_that_changed(tmp_path: Path, upload: Path) -> None:
    _seed(tmp_path, "Insect", [])
    s = Staging()
    s.stage_add("insect", upload, "x.wav")
    request_id = s.apply(tmp_path)
    payload = json.loads((tmp_path / "reload.request").read_text())
    assert payload["sources"] == ["insect"]
    assert payload["id"] == request_id


def test_would_empty_is_false_when_other_live_clips_remain() -> None:
    s = Staging()
    s.stage_remove("piano", "a.mp3")
    assert not s.would_empty("piano", ["a.mp3", "b.mp3"])


def test_apply_raises_before_touching_any_file_across_any_touched_source(
    tmp_path: Path, upload: Path
) -> None:
    # "piano" would end up empty; "insect" is a perfectly fine, unrelated
    # change. The empty-pool check on "piano" must stop apply before it
    # mutates *either* source -- not just before it mutates "piano".
    _seed(tmp_path, "EPiano Stems", ["only.mp3"])
    _seed(tmp_path, "Insect", ["a.wav"])
    s = Staging()
    s.stage_remove("piano", "only.mp3")
    s.stage_add("insect", upload, "new.wav")

    with pytest.raises(WouldEmptyPool):
        s.apply(tmp_path)

    assert (tmp_path / "EPiano Stems" / "only.mp3").exists()
    assert not (tmp_path / "Insect" / "new.wav").exists()
    assert upload.exists()  # never moved
    assert not (tmp_path / "reload.request").exists()


def test_would_empty_pool_names_the_folder(tmp_path: Path) -> None:
    _seed(tmp_path, "EPiano Stems", ["only.mp3"])
    s = Staging()
    s.stage_remove("piano", "only.mp3")
    with pytest.raises(WouldEmptyPool, match="EPiano Stems"):
        s.apply(tmp_path)


def test_pending_for_reports_staged_adds_and_removes(upload: Path) -> None:
    s = Staging()
    s.stage_add("piano", upload, "new.mp3")
    s.stage_remove("piano", "old.mp3")
    pending = s.pending_for("piano")
    assert pending == Pending(
        adds={"piano": [Path("new.mp3")]}, removes={"piano": ["old.mp3"]}
    )


def test_pending_for_an_untouched_source_is_empty() -> None:
    s = Staging()
    s.stage_add("piano", Path("/tmp/whatever.mp3"), "new.mp3")
    pending = s.pending_for("insect")
    assert pending == Pending(adds={"insect": []}, removes={"insect": []})


def test_apply_clears_staged_state_so_a_second_apply_has_nothing_to_do(
    tmp_path: Path, upload: Path
) -> None:
    _seed(tmp_path, "Insect", [])
    s = Staging()
    s.stage_add("insect", upload, "x.wav")
    s.apply(tmp_path)
    assert s.pending_for("insect") == Pending(adds={"insect": []}, removes={"insect": []})

    second_id = s.apply(tmp_path)
    payload = json.loads((tmp_path / "reload.request").read_text())
    assert payload["sources"] == []
    assert payload["id"] == second_id


def test_an_interrupted_apply_cannot_leave_a_touched_source_empty(
    tmp_path: Path, upload: Path
) -> None:
    # The reviewer's scenario: "piano" is live with [a.mp3, b.mp3]; staff
    # stage removing both plus one offsetting add. would_empty correctly
    # says the net result is non-empty, so the precheck passes. Then
    # b.mp3 vanishes out-of-band (a concurrent process, a manual cleanup)
    # before apply's own unlink() reaches it -- simulated here by deleting
    # it right before calling apply. That unlink must still fail loudly
    # (this is not testing missing_ok=True), but because adds run before
    # removes within a source, new.mp3 is already in place by the time the
    # failing unlink is reached: the folder ends up with an extra file,
    # never with none.
    _seed(tmp_path, "EPiano Stems", ["a.mp3", "b.mp3"])
    s = Staging()
    s.stage_remove("piano", "a.mp3")
    s.stage_remove("piano", "b.mp3")
    s.stage_add("piano", upload, "new.mp3")

    (tmp_path / "EPiano Stems" / "b.mp3").unlink()  # the out-of-band race

    with pytest.raises(FileNotFoundError):
        s.apply(tmp_path)

    remaining = list((tmp_path / "EPiano Stems").iterdir())
    assert remaining, "an interrupted apply must never leave a touched source empty"
    assert (tmp_path / "EPiano Stems" / "new.mp3").exists()
    assert not (tmp_path / "reload.request").exists()


def test_an_unsafe_staged_filename_is_caught_before_any_file_moves(
    tmp_path: Path, upload: Path
) -> None:
    _seed(tmp_path, "EPiano Stems", ["old.mp3"])
    s = Staging()
    s.stage_add("piano", upload, "new.mp3")
    s.stage_remove("piano", "../evil.mp3")

    with pytest.raises(UnsafeName):
        s.apply(tmp_path)

    assert not (tmp_path / "EPiano Stems" / "new.mp3").exists()
    assert upload.exists()  # the staged add was never moved
    assert (tmp_path / "EPiano Stems" / "old.mp3").exists()  # nothing was removed
    assert not (tmp_path / "reload.request").exists()


def test_double_staging_the_same_removal_does_not_duplicate_it(tmp_path: Path) -> None:
    _seed(tmp_path, "Insect", ["a.wav", "b.wav"])
    s = Staging()
    s.stage_remove("insect", "a.wav")
    s.stage_remove("insect", "a.wav")

    assert s.pending_for("insect").removes["insect"] == ["a.wav"]

    s.apply(tmp_path)  # a second unlink() of a.wav would raise otherwise
    assert not (tmp_path / "Insect" / "a.wav").exists()
    assert (tmp_path / "Insect" / "b.wav").exists()
