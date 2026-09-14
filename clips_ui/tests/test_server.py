"""Tests for ``clips_ui.server`` and ``clips_ui.page``.

These run against a real :class:`~http.server.ThreadingHTTPServer` bound to
``127.0.0.1:0`` and talk to it over a real socket with :mod:`http.client`.
Nothing here monkeypatches the handler: the thing under test is the HTTP
surface, and the tests that matter most are about what that surface refuses.

This server ships with no authentication -- it is protected only by binding
to the box's Tailscale address -- so the refusals are the point. A traversal
upload, an unknown folder, an undecodable file and a nearly-full SD card
each have a test that asserts the clip folders came out unchanged, not just
that a status code was returned.

Two seams keep the suite off the machine's real resources: ``server.probe_runner``
stands in for ffprobe (the same ``runner`` seam :func:`clips_ui.audio.is_decodable`
documents) and ``server.free_bytes`` stands in for :func:`shutil.disk_usage`.
The ``no_decode`` and ``full_disk`` fixtures flip them.
"""

import http.client
import json
import subprocess
import threading
import time
from collections.abc import Iterator
from pathlib import Path
from typing import NamedTuple

import pytest

from clips_ui.folders import SOURCES
from clips_ui.server import build_server
from clips_ui.staging import Staging

_BOUNDARY = "----clipsuitestboundary"


class _Response(NamedTuple):
    """One HTTP response, read to the end and disconnected."""

    status: int
    body: bytes

    def json(self) -> dict:
        """The body decoded as JSON."""
        return json.loads(self.body)

    @property
    def text(self) -> str:
        """The body decoded as UTF-8."""
        return self.body.decode("utf-8")


def _multipart(files: dict[str, tuple[str, bytes]]) -> tuple[bytes, str]:
    """Build a ``multipart/form-data`` body from ``field -> (filename, bytes)``."""
    chunks: list[bytes] = []
    for field, (filename, data) in files.items():
        disposition = f'form-data; name="{field}"; filename="{filename}"'
        chunks.append(b"--" + _BOUNDARY.encode() + b"\r\n")
        chunks.append(f"Content-Disposition: {disposition}\r\n".encode())
        chunks.append(b"Content-Type: application/octet-stream\r\n\r\n")
        chunks.append(data)
        chunks.append(b"\r\n")
    chunks.append(b"--" + _BOUNDARY.encode() + b"--\r\n")
    return b"".join(chunks), f"multipart/form-data; boundary={_BOUNDARY}"


class _Client:
    """A tiny HTTP client, one connection per request (the server is HTTP/1.0)."""

    def __init__(self, address: tuple[str, int]) -> None:
        self._address = address

    def _send(
        self,
        method: str,
        path: str,
        body: bytes = b"",
        headers: dict[str, str] | None = None,
    ) -> _Response:
        conn = http.client.HTTPConnection(*self._address, timeout=10)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            raw = conn.getresponse()
            return _Response(raw.status, raw.read())
        finally:
            conn.close()

    def get(self, path: str) -> _Response:
        """GET ``path``."""
        return self._send("GET", path)

    def post(
        self, path: str, files: dict[str, tuple[str, bytes]] | None = None
    ) -> _Response:
        """POST ``path``, as multipart when ``files`` is given."""
        if files is None:
            return self._send("POST", path, b"", {"Content-Length": "0"})
        body, content_type = _multipart(files)
        headers = {"Content-Type": content_type, "Content-Length": str(len(body))}
        return self._send("POST", path, body, headers)


def _accepting_runner(cmd: list[str], **kwargs: object) -> subprocess.CompletedProcess:
    """An ffprobe that reports an audio stream for anything."""
    return subprocess.CompletedProcess(args=cmd, returncode=0, stdout="audio\n", stderr="")


def _refusing_runner(cmd: list[str], **kwargs: object) -> subprocess.CompletedProcess:
    """An ffprobe that finds no audio stream, as it would in a text file."""
    return subprocess.CompletedProcess(args=cmd, returncode=1, stdout="", stderr="boom")


@pytest.fixture
def root(tmp_path: Path) -> Path:
    """An installation working directory with one seeded clip folder.

    ``EPiano Stems`` holds three clips, so a test can stage two removals and
    still leave a clip behind, or stage three and trip the empty-pool guard.
    """
    folder = tmp_path / "EPiano Stems"
    folder.mkdir()
    (folder / "existing.mp3").write_bytes(b"existing clip bytes")
    (folder / "a.mp3").write_bytes(b"a")
    (folder / "b.mp3").write_bytes(b"b")
    return tmp_path


@pytest.fixture
def server(root: Path) -> Iterator:
    """A live server on an ephemeral loopback port, with ffprobe faked out."""
    httpd = build_server(root, "127.0.0.1", 0, runner=_accepting_runner)
    # A short poll interval keeps shutdown() from costing half a second a test.
    thread = threading.Thread(
        target=httpd.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True
    )
    thread.start()
    try:
        yield httpd
    finally:
        httpd.shutdown()
        httpd.server_close()
        thread.join(timeout=5)


@pytest.fixture
def client(server) -> _Client:
    """A client pointed at the live server."""
    return _Client(server.server_address[:2])


@pytest.fixture
def no_decode(server) -> None:
    """Make every upload fail the decode check, as an undecodable file would."""
    server.probe_runner = _refusing_runner


@pytest.fixture
def decode_by_content(server) -> None:
    """Refuse only the files whose contents say ``bad``.

    Lets one upload carry a file that would be accepted alongside one that
    would not, which is what an all-or-nothing batch has to be tested with.
    """

    def runner(cmd: list[str], **kwargs: object) -> subprocess.CompletedProcess:
        probed = Path(cmd[-1]).read_bytes()
        if b"bad" in probed:
            return _refusing_runner(cmd, **kwargs)
        return _accepting_runner(cmd, **kwargs)

    server.probe_runner = runner


@pytest.fixture
def full_disk(server) -> None:
    """Report an SD card with less free space than the floor allows."""
    server.free_bytes = lambda _path: 10 * 1024 * 1024


def _names(folder: Path) -> set[str]:
    return {entry.name for entry in folder.iterdir()}


# --- the page ------------------------------------------------------------


def test_the_page_lists_what_is_in_the_chosen_folder(client: _Client) -> None:
    response = client.get("/?source=piano")
    assert response.status == 200
    assert "existing.mp3" in response.text


def test_the_page_offers_every_source(client: _Client) -> None:
    body = client.get("/").text
    for folder_name in SOURCES.values():
        assert folder_name in body


def test_the_page_escapes_a_filename_that_looks_like_markup(
    client: _Client, root: Path
) -> None:
    # Filenames are attacker-controlled in this threat model: anyone who can
    # reach the port can upload one, and every viewer of the page is staff.
    (root / "EPiano Stems" / "<script>bad<'\"&.mp3").write_bytes(b"x")
    body = client.get("/?source=piano").text
    assert "<script>bad" not in body
    assert "&lt;script&gt;bad&lt;&#x27;&quot;&amp;.mp3" in body


def test_an_unknown_source_on_the_page_is_a_404(client: _Client) -> None:
    assert client.get("/?source=harpsichord").status == 404


# --- listing -------------------------------------------------------------


def test_an_unknown_folder_is_a_404_not_a_new_pool(client: _Client, root: Path) -> None:
    assert client.get("/list/harpsichord").status == 404
    assert not (root / "harpsichord").exists()


def test_list_reports_the_live_clips_with_their_sizes(client: _Client) -> None:
    payload = client.get("/list/piano").json()
    assert payload["folder"] == "EPiano Stems"
    sizes = {entry["name"]: entry["size"] for entry in payload["live"]}
    assert sizes["existing.mp3"] == len(b"existing clip bytes")


def test_an_unknown_route_is_a_404(client: _Client) -> None:
    assert client.get("/nonsense").status == 404


# --- upload --------------------------------------------------------------


def test_a_traversal_upload_is_refused(client: _Client, root: Path) -> None:
    before = _names(root / "EPiano Stems")
    assert client.post("/upload/piano", files={"f": ("../../evil.mp3", b"x")}).status == 400
    assert _names(root / "EPiano Stems") == before
    assert not (root / "evil.mp3").exists()
    assert not (root.parent / "evil.mp3").exists()


def test_an_upload_to_an_unknown_folder_is_a_404(client: _Client, root: Path) -> None:
    assert client.post("/upload/harpsichord", files={"f": ("a.mp3", b"x")}).status == 404
    assert not (root / "harpsichord").exists()


def test_an_undecodable_upload_leaves_the_folder_untouched(
    client: _Client, root: Path, no_decode: None
) -> None:
    before = _names(root / "EPiano Stems")
    assert client.post("/upload/piano", files={"f": ("bad.mp3", b"x")}).status == 400
    assert _names(root / "EPiano Stems") == before


def test_a_refused_upload_leaves_no_temporary_file_behind(
    client: _Client, root: Path, no_decode: None
) -> None:
    client.post("/upload/piano", files={"f": ("bad.mp3", b"x")})
    leftovers = [path for path in root.rglob("*.part")]
    assert leftovers == []


def test_an_upload_that_is_not_audio_at_all_is_refused(
    client: _Client, root: Path
) -> None:
    before = _names(root / "EPiano Stems")
    assert client.post("/upload/piano", files={"f": ("notes.txt", b"x")}).status == 400
    assert _names(root / "EPiano Stems") == before


def test_upload_is_refused_when_the_disk_is_nearly_full(
    client: _Client, root: Path, full_disk: None
) -> None:
    # An SD card that fills corrupts in ways worse than a refused upload.
    before = _names(root / "EPiano Stems")
    assert client.post("/upload/piano", files={"f": ("a.mp3", b"x")}).status == 507
    assert _names(root / "EPiano Stems") == before


def test_an_upload_with_no_file_part_is_refused(client: _Client) -> None:
    assert client.post("/upload/piano").status == 400


def test_pressing_upload_with_nothing_chosen_is_refused(
    client: _Client, root: Path
) -> None:
    # A browser with an empty file chooser still sends the field: one part
    # with an empty filename. That is not a file named "".
    response = client.post("/upload/piano", files={"files": ("", b"")})
    assert response.status == 400
    assert "no file" in response.json()["detail"]
    assert list(root.rglob("*.part")) == []


def test_an_accepted_upload_is_pending_and_not_live_until_apply(
    client: _Client, root: Path
) -> None:
    assert client.post("/upload/piano", files={"f": ("new.mp3", b"clip")}).status == 200
    assert not (root / "EPiano Stems" / "new.mp3").exists()
    assert client.get("/list/piano").json()["pending"]["adds"] == ["new.mp3"]

    assert client.post("/apply").status == 200
    assert (root / "EPiano Stems" / "new.mp3").read_bytes() == b"clip"
    assert json.loads((root / "reload.request").read_text())["sources"] == ["piano"]


def test_an_uploaded_file_survives_the_round_trip_byte_for_byte(
    client: _Client, root: Path
) -> None:
    # The multipart reader is hand-rolled, because loading a whole clip into
    # 512 MB shared with the GPU is not an option. The bytes it is most
    # likely to get wrong are the CRLF in front of a boundary (which belongs
    # to the boundary, not the file) and a line longer than one read.
    clip = b"ID3\x00\r\n--not-a-boundary\r\n" + bytes(range(256)) * 400 + b"\r\n"
    assert client.post("/upload/piano", files={"f": ("round.mp3", clip)}).status == 200
    assert client.post("/apply").status == 200
    assert (root / "EPiano Stems" / "round.mp3").read_bytes() == clip
    assert client.get("/download/piano/round.mp3").body == clip


def test_several_files_arrive_in_one_upload(client: _Client) -> None:
    response = client.post(
        "/upload/piano",
        files={"one": ("one.mp3", b"1"), "two": ("two.mp3", b"22")},
    )
    assert response.status == 200
    assert sorted(response.json()["staged"]) == ["one.mp3", "two.mp3"]


def test_one_bad_file_refuses_the_whole_upload(
    client: _Client, root: Path, decode_by_content: None
) -> None:
    # Not the same as "every file was bad": the good file must be refused
    # too, so nobody has to be told which half of their upload landed.
    response = client.post(
        "/upload/piano",
        files={"one": ("good.mp3", b"fine"), "two": ("bad.mp3", b"bad")},
    )
    assert response.status == 400
    assert client.get("/list/piano").json()["pending"]["adds"] == []
    assert list(root.rglob("*.part")) == []


# --- download ------------------------------------------------------------


def test_download_returns_the_bytes(client: _Client, root: Path) -> None:
    response = client.get("/download/piano/existing.mp3")
    assert response.status == 200
    assert response.body == (root / "EPiano Stems" / "existing.mp3").read_bytes()


def test_a_traversal_download_is_refused(client: _Client) -> None:
    assert client.get("/download/piano/..%2F..%2Fetc%2Fpasswd").status == 400


def test_downloading_what_is_not_there_is_a_404(client: _Client) -> None:
    assert client.get("/download/piano/absent.mp3").status == 404


# --- remove --------------------------------------------------------------


def test_remove_is_pending_until_apply(client: _Client, root: Path) -> None:
    assert client.post("/remove/piano/a.mp3").status == 200
    assert (root / "EPiano Stems" / "a.mp3").exists()
    assert client.get("/list/piano").json()["pending"]["removes"] == ["a.mp3"]

    assert client.post("/apply").status == 200
    assert not (root / "EPiano Stems" / "a.mp3").exists()


def test_removing_what_is_not_there_is_a_404(client: _Client) -> None:
    assert client.post("/remove/piano/absent.mp3").status == 404


def test_a_traversal_remove_is_refused(client: _Client) -> None:
    assert client.post("/remove/piano/..%2F..%2Fetc%2Fpasswd").status == 400


# --- apply ---------------------------------------------------------------


def test_apply_that_would_empty_a_pool_is_refused(client: _Client, root: Path) -> None:
    client.post("/remove/piano/a.mp3")
    client.post("/remove/piano/b.mp3")
    client.post("/remove/piano/existing.mp3")
    response = client.post("/apply")
    assert response.status == 409
    assert "no clips" in response.json()["detail"]
    assert _names(root / "EPiano Stems") == {"a.mp3", "b.mp3", "existing.mp3"}
    assert not (root / "reload.request").exists()


def test_two_applies_are_serialised_and_neither_is_lost(server, client: _Client) -> None:
    # ThreadingHTTPServer means two staff can press Apply at once. write_request
    # renames to a fixed path, so an unserialised second Apply would silently
    # overwrite the first: one operator's changes gone, the UI reporting success.
    events: list[str] = []

    class _Recording(Staging):
        def apply(self, root: Path) -> str:
            events.append("enter")
            time.sleep(0.1)
            request_id = super().apply(root)
            events.append("exit")
            return request_id

    server.staging = _Recording()
    responses: list[_Response] = []

    def press() -> None:
        responses.append(client.post("/apply"))

    pressers = [threading.Thread(target=press) for _ in range(2)]
    for presser in pressers:
        presser.start()
    for presser in pressers:
        presser.join()

    assert events == ["enter", "exit", "enter", "exit"]
    assert [response.status for response in responses] == [200, 200]
    assert len({response.json()["id"] for response in responses}) == 2


# --- status --------------------------------------------------------------


def test_status_is_not_ready_until_the_installation_answers(
    client: _Client, root: Path
) -> None:
    client.post("/remove/piano/a.mp3")
    request_id = client.post("/apply").json()["id"]
    assert client.get(f"/status/{request_id}").json() == {"ready": False}

    (root / "reload.result").write_text(
        json.dumps(
            {
                "id": request_id,
                "outcomes": [
                    {"source": "piano", "status": "applied", "clips": 2, "detail": ""}
                ],
            }
        )
    )
    payload = client.get(f"/status/{request_id}").json()
    assert payload["ready"] is True
    assert payload["outcomes"][0]["status"] == "applied"
    assert payload["outcomes"][0]["clips"] == 2


def test_a_stale_result_does_not_answer_a_new_request(
    client: _Client, root: Path
) -> None:
    (root / "reload.result").write_text(
        json.dumps(
            {
                "id": "20260101T000000Z-oldold",
                "outcomes": [
                    {"source": "piano", "status": "applied", "clips": 9, "detail": ""}
                ],
            }
        )
    )
    assert client.get("/status/20260913T185301Z-a1b2c3").json() == {"ready": False}


# --- the entry point -----------------------------------------------------


def test_the_command_line_takes_a_root_a_bind_and_a_port() -> None:
    from clips_ui.__main__ import _parse_args

    args = _parse_args(
        ["--root", "/home/pi/mami-sound", "--bind", "100.83.113.99", "--port", "8080"]
    )
    assert args.root == Path("/home/pi/mami-sound")
    assert args.bind == "100.83.113.99"
    assert args.port == 8080
