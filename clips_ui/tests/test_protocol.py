"""Tests for ``clips_ui.protocol``.

Two processes talk through two files in the installation's working
directory: the web UI writes ``reload.request``, the Zig installation reads
it, swaps a plant's clip pool, and writes ``reload.result`` back. These
tests pin the wire format on the Python side of that conversation --
requests are renamed into place atomically, and results are matched by
request id so a stale answer from an earlier request never reads as this
request's answer.
"""

import json
import re
from datetime import UTC, datetime

import clips_ui.protocol as protocol
from clips_ui.protocol import Outcome, Result, new_request_id, read_result, write_request


def test_a_request_is_renamed_into_place(tmp_path):
    write_request(tmp_path, "id-1", ["piano"])
    assert json.loads((tmp_path / "reload.request").read_text()) == {
        "id": "id-1",
        "sources": ["piano"],
    }
    assert not list(tmp_path.glob("*.tmp"))  # no temp file left behind


def test_a_result_for_another_request_is_not_mine(tmp_path):
    (tmp_path / "reload.result").write_text('{"id": "older", "outcomes": []}')
    assert read_result(tmp_path, "id-1") is None


def test_a_matching_result_is_returned(tmp_path):
    (tmp_path / "reload.result").write_text(
        json.dumps(
            {
                "id": "id-1",
                "outcomes": [
                    {"source": "piano", "status": "applied", "clips": 9, "detail": ""}
                ],
            }
        )
    )
    result = read_result(tmp_path, "id-1")
    assert result.outcomes[0].status == "applied"
    assert result.outcomes[0].clips == 9


def test_a_half_written_result_reads_as_not_ready(tmp_path):
    # Should never happen -- the installation renames into place -- but a
    # crash mid-write must not raise into the page.
    (tmp_path / "reload.result").write_text('{"id": "id-1", "outc')
    assert read_result(tmp_path, "id-1") is None


def test_no_result_file_yet_reads_as_not_ready(tmp_path):
    assert read_result(tmp_path, "id-1") is None


def test_new_request_id_has_a_timestamp_prefix_and_a_random_suffix():
    id_ = new_request_id()
    assert re.fullmatch(r"\d{8}T\d{6}Z-[0-9a-f]{6}", id_)


def test_new_request_id_does_not_collide_within_the_same_second():
    ids = {new_request_id() for _ in range(50)}
    assert len(ids) == 50


def test_new_request_id_sorts_chronologically(monkeypatch):
    class _FixedClock:
        def __init__(self, moments):
            self._moments = iter(moments)

        def now(self, tz):
            return next(self._moments)

    earlier = datetime(2026, 9, 13, 18, 53, 1, tzinfo=UTC)
    later = datetime(2026, 9, 13, 18, 53, 2, tzinfo=UTC)
    monkeypatch.setattr(protocol, "datetime", _FixedClock([earlier, later]))

    first = new_request_id()
    second = new_request_id()
    assert first < second


def test_write_request_uses_no_leftover_tmp_file_on_repeated_writes(tmp_path):
    write_request(tmp_path, "id-1", ["piano"])
    write_request(tmp_path, "id-2", ["piano", "insect"])
    assert not list(tmp_path.glob("*.tmp"))
    assert json.loads((tmp_path / "reload.request").read_text())["id"] == "id-2"


def test_a_result_with_an_unknown_status_is_unreadable(tmp_path):
    (tmp_path / "reload.result").write_text(
        json.dumps(
            {
                "id": "id-1",
                "outcomes": [
                    {"source": "piano", "status": "bogus", "clips": 1, "detail": ""}
                ],
            }
        )
    )
    assert read_result(tmp_path, "id-1") is None


def test_a_result_with_a_missing_outcome_field_is_unreadable(tmp_path):
    (tmp_path / "reload.result").write_text(
        json.dumps(
            {
                "id": "id-1",
                "outcomes": [{"source": "piano", "status": "applied", "clips": 1}],
            }
        )
    )
    assert read_result(tmp_path, "id-1") is None


def test_a_result_missing_the_outcomes_key_is_unreadable(tmp_path):
    (tmp_path / "reload.result").write_text(json.dumps({"id": "id-1"}))
    assert read_result(tmp_path, "id-1") is None


def test_a_result_that_is_not_a_json_object_is_unreadable(tmp_path):
    (tmp_path / "reload.result").write_text(json.dumps(["id-1", []]))
    assert read_result(tmp_path, "id-1") is None


def test_result_and_outcome_are_plain_dataclasses():
    outcome = Outcome(source="piano", status="applied", clips=9, detail="")
    result = Result(id="id-1", outcomes=[outcome])
    assert result.outcomes[0] is outcome
