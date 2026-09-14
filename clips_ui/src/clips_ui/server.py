"""The HTTP surface: seven routes over the clip folders, and nothing else.

This module composes what the rest of the package already does --
:mod:`clips_ui.folders` decides what may be written where,
:mod:`clips_ui.audio` decides what may be accepted at all,
:mod:`clips_ui.staging` holds the pending changes, :mod:`clips_ui.protocol`
talks to the installation, :mod:`clips_ui.page` renders. Nothing here
re-decides any of that.

**There is no authentication.** The service is protected only by binding to
the box's Tailscale address, so anyone who reaches the port can delete
every clip in every pool. Three rules follow, and none of them is optional:

1. Every path segment naming a source goes through
   :func:`~clips_ui.folders.folder_for`, which raises
   :class:`~clips_ui.folders.UnknownSource` for anything that is not one of
   the seven. An unknown folder is a 404, never an implicitly created pool.
2. Every client-supplied filename goes through
   :func:`~clips_ui.folders.safe_target`. No handler here joins a
   client-supplied string to a path itself.
3. An upload is streamed to a :class:`~tempfile.NamedTemporaryFile` in
   ``<root>/.uploads`` -- the same filesystem as the clip folders, so Apply
   moves it with a rename rather than a copy -- and is checked for space,
   for extension and for decodability *there*. A refused upload never
   touches a clip folder, and leaves no temporary file behind either.

**Apply is serialised.** :class:`~http.server.ThreadingHTTPServer` means two
staff can press Apply at once, and
:func:`~clips_ui.protocol.write_request` renames onto a fixed path -- so two
concurrent Applies would leave the second silently overwriting the first,
one operator's changes gone with the page reporting success. The whole
operation (the empty-pool checks, the file moves and the request write, all
of which live inside :meth:`~clips_ui.staging.Staging.apply`) runs under
:attr:`ClipsServer.staging_lock`.

Multipart bodies are read a line at a time rather than loaded whole: a Zero
2 W has 512 MB shared with the GPU, and a clip is not small. Part *headers*
are parsed with :class:`email.parser.BytesParser`, which knows RFC 2231 and
quoting; part *bodies* go straight to disk.
"""

import json
import logging
import shutil
import subprocess
import tempfile
import threading
from collections.abc import Callable
from dataclasses import asdict
from email.message import Message
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import BinaryIO
from urllib.parse import parse_qs, quote, unquote, urlsplit

from clips_ui.audio import is_decodable
from clips_ui.folders import (
    SOURCES,
    UnknownSource,
    UnsafeName,
    folder_for,
    is_audio,
    safe_target,
)
from clips_ui.page import render
from clips_ui.protocol import read_result
from clips_ui.staging import Staging, WouldEmptyPool

logger = logging.getLogger(__name__)

__all__ = ["FREE_SPACE_FLOOR_BYTES", "ClipsServer", "build_server"]

#: An upload is refused outright below this much free space. The clips live
#: on an SD card, and a card that fills corrupts in ways far worse than a
#: refused upload -- including taking the installation down with it.
FREE_SPACE_FLOOR_BYTES = 200 * 1024 * 1024

#: Where uploads land before Apply moves them. Beside the clip folders, so
#: the move is a rename; dot-prefixed, so nothing that scans for clips
#: (:func:`~clips_ui.folders.is_audio` included) will ever look inside it.
#: A file here is owned by :class:`~clips_ui.staging.Staging` until Apply
#: moves it, so uploads staged but never applied outlive a restart of this
#: service and have to be cleared by hand.
UPLOAD_DIR_NAME = ".uploads"

#: Largest chunk read from a request body in one go, and the cap on one
#: part's headers. A binary line can be longer than this; it simply arrives
#: in several chunks.
_LINE_LIMIT = 64 * 1024
_MAX_PART_HEADER_BYTES = 16 * 1024

#: The folder shown when ``/`` is asked for without a ``?source=``.
_DEFAULT_SOURCE = next(iter(SOURCES))


class _Refused(Exception):
    """An HTTP status and a sentence for the page to show, raised by a route."""

    def __init__(self, status: int, detail: str) -> None:
        super().__init__(detail)
        self.status = status
        self.detail = detail


class _Body:
    """The request body, readable only as far as ``Content-Length`` allows.

    ``self.rfile`` is the whole connection; reading past the declared body
    length would block waiting for a request that will never come. This
    wrapper hands out at most ``length`` bytes and then reports EOF.
    """

    def __init__(self, stream: BinaryIO, length: int) -> None:
        self._stream = stream
        self._remaining = max(0, length)

    def readline(self, limit: int = _LINE_LIMIT) -> bytes:
        """The next line, at most ``limit`` bytes; ``b""`` at the end of the body."""
        if self._remaining <= 0:
            return b""
        line = self._stream.readline(min(limit, self._remaining))
        self._remaining -= len(line)
        return line

    def discard(self) -> None:
        """Read and throw away whatever is left, so the response is not truncated."""
        while self._remaining > 0:
            chunk = self._stream.read(min(_LINE_LIMIT, self._remaining))
            if not chunk:
                self._remaining = 0
                return
            self._remaining -= len(chunk)


def _boundary_of(content_type: str) -> bytes:
    """The multipart boundary declared in ``content_type``.

    Raises:
        _Refused: 400 if this is not a ``multipart/form-data`` body, or
            declares no boundary.
    """
    parsed = Message()
    parsed["Content-Type"] = content_type or "application/octet-stream"
    if parsed.get_content_type() != "multipart/form-data":
        raise _Refused(400, "an upload must be multipart/form-data")
    boundary = parsed.get_param("boundary")
    if not isinstance(boundary, str) or not boundary:
        raise _Refused(400, "that upload declared no multipart boundary")
    return boundary.encode("latin-1")


def _part_headers(body: _Body) -> Message:
    """Read one part's headers, up to and including the blank line."""
    raw = b""
    while True:
        line = body.readline()
        if not line:
            raise _Refused(400, "that upload ended in the middle of a part")
        if line in (b"\r\n", b"\n"):
            break
        raw += line
        if len(raw) > _MAX_PART_HEADER_BYTES:
            raise _Refused(400, "that upload's part headers are unreasonably long")
    return BytesParser().parsebytes(raw + b"\r\n")


def _copy_part(
    body: _Body,
    delimiter: bytes,
    closing: bytes,
    filename: str | None,
    dest_dir: Path,
    parts: list[tuple[str, Path]],
) -> bool:
    """Stream one part's body to a temp file, stopping at the next boundary.

    A part with no ``filename`` is a plain form field: its body is read and
    discarded, because it still has to be consumed to reach the next part.

    The CRLF in front of a boundary line belongs to the boundary, not to the
    file, so each line is held back until the next one proves it was not the
    last -- otherwise every uploaded clip would gain two stray bytes.

    Args:
        body: The request body, positioned just after the part's headers.
        delimiter: ``--boundary``.
        closing: ``--boundary--``.
        filename: The name the part gave itself, or ``None`` for a non-file
            field. Not validated here; :func:`~clips_ui.folders.safe_target`
            does that once the bytes are safely outside every clip folder.
        dest_dir: Where the temp file is created.
        parts: Appended to with ``(filename, temp path)`` as soon as the
            file exists, so a caller can clean up even if this raises.

    Returns:
        True if this part ended at the closing delimiter (no more parts).
    """
    handle = None
    if filename is not None:
        handle = tempfile.NamedTemporaryFile(
            dir=dest_dir, prefix="upload-", suffix=".part", delete=False
        )
        parts.append((filename, Path(handle.name)))
    try:
        held = b""
        at_line_start = True
        while True:
            line = body.readline()
            if not line:
                raise _Refused(400, "that upload ended in the middle of a file")
            if at_line_start and line.rstrip(b"\r\n") in (delimiter, closing):
                if held.endswith(b"\r\n"):
                    held = held[:-2]
                elif held.endswith(b"\n"):
                    held = held[:-1]
                if handle is not None:
                    handle.write(held)
                return line.rstrip(b"\r\n") == closing
            if handle is not None:
                handle.write(held)
            held = line
            at_line_start = line.endswith(b"\n")
    finally:
        if handle is not None:
            handle.close()


def _read_file_parts(
    body: _Body, boundary: bytes, dest_dir: Path
) -> list[tuple[str, Path]]:
    """Every file part of a multipart body, streamed into ``dest_dir``.

    Returns:
        ``(filename as the part named itself, temp path)`` per file part, in
        the order they arrived. Empty if the body carried no file part.

    Raises:
        _Refused: 400 for a malformed or truncated body. Any temp file
            already written is removed first: a refused upload leaves
            nothing behind.
    """
    delimiter = b"--" + boundary
    closing = delimiter + b"--"
    parts: list[tuple[str, Path]] = []
    try:
        line = body.readline()
        while line and line.rstrip(b"\r\n") != delimiter:
            if line.rstrip(b"\r\n") == closing:
                return parts
            line = body.readline()
        if not line:
            raise _Refused(400, "that upload carried no multipart boundary")
        while True:
            # A browser whose file chooser is empty still sends the field,
            # as a part with an empty filename. That is "no file chosen",
            # not a file named "": it is consumed and discarded like any
            # other non-file field.
            filename = _part_headers(body).get_filename() or None
            if _copy_part(body, delimiter, closing, filename, dest_dir, parts):
                return parts
    except BaseException:
        for _filename, path in parts:
            path.unlink(missing_ok=True)
        raise


def _free_bytes(path: Path) -> int:
    """Free space, in bytes, on the filesystem holding ``path``."""
    return shutil.disk_usage(path).free


class _Handler(BaseHTTPRequestHandler):
    """One request. Every route is a method; every refusal is a :class:`_Refused`."""

    server_version = "mami-clips/1.0"
    #: HTTP/1.0: one request per connection, so an early refusal can never
    #: desynchronise a reused connection.
    protocol_version = "HTTP/1.0"
    #: The request body, once a route has asked for it.
    _body: _Body | None = None
    #: Whether a response has already gone out, so a failure part-way
    #: through one (a cancelled download, say) cannot append a second.
    _responded = False

    # do_GET/do_POST are the names BaseHTTPRequestHandler dispatches to.
    def do_GET(self) -> None:
        """Serve the page, a listing, a download, or a status poll."""
        self._dispatch(self._route_get)

    def do_POST(self) -> None:
        """Stage an upload or a removal, or apply what is staged."""
        self._dispatch(self._route_post)

    # --- plumbing --------------------------------------------------------

    def _dispatch(self, route: Callable[[list[str], dict[str, list[str]]], None]) -> None:
        """Run ``route``, turning every expected failure into a JSON refusal."""
        split = urlsplit(self.path)
        # Split on "/" first and unquote each segment afterwards, so a
        # percent-encoded separator cannot invent a path segment.
        segments = [unquote(part) for part in split.path.split("/") if part]
        try:
            route(segments, parse_qs(split.query))
        except UnknownSource:
            self._refuse(404, "no such clip folder")
        except UnsafeName:
            self._refuse(400, "that filename is not allowed")
        except _Refused as refusal:
            self._refuse(refusal.status, refusal.detail)
        except Exception:
            logger.exception("%s %s failed", self.command, self.path)
            self._refuse(500, "something went wrong on the box")

    def _refuse(self, status: int, detail: str) -> None:
        """Log a refusal and answer with it, unless an answer already went out."""
        logger.warning("%s %s refused: %d %s", self.command, self.path, status, detail)
        if self._responded:
            logger.error(
                "%s %s: too late to refuse, a response was already sent",
                self.command,
                self.path,
            )
            return
        self._send_json(status, {"detail": detail})

    def _send(self, status: int, content_type: str, payload: bytes) -> None:
        """Send one complete response."""
        self._drain()
        self._responded = True
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _send_json(self, status: int, payload: dict) -> None:
        """Send ``payload`` as JSON."""
        self._send(status, "application/json", json.dumps(payload).encode("utf-8"))

    def _drain(self) -> None:
        """Consume any unread request body before answering.

        A refusal that answers before reading the body -- a full disk, an
        unknown folder -- would otherwise close the socket with bytes still
        in flight, and the client can lose the response to the reset.
        """
        if self._body is not None:
            self._body.discard()

    def _body_reader(self) -> _Body:
        """The request body, read at most once.

        Raises:
            _Refused: 400 if there is no usable ``Content-Length``.
        """
        raw = self.headers.get("Content-Length")
        try:
            length = int(raw)
        except (TypeError, ValueError):
            raise _Refused(400, "an upload needs a Content-Length") from None
        self._body = _Body(self.rfile, length)
        return self._body

    def log_message(self, format: str, *args: object) -> None:
        """Route the handler's own chatter through the module logger."""
        logger.info("%s %s", self.address_string(), format % args)

    # --- routes ----------------------------------------------------------

    def _route_get(self, segments: list[str], query: dict[str, list[str]]) -> None:
        """Match a GET to a route, or 404."""
        if not segments:
            self._page(query.get("source", [_DEFAULT_SOURCE])[0])
        elif segments[:1] == ["list"] and len(segments) == 2:
            self._list(segments[1])
        elif segments[:1] == ["download"] and len(segments) == 3:
            self._download(segments[1], segments[2])
        elif segments[:1] == ["status"] and len(segments) == 2:
            self._status(segments[1])
        else:
            raise _Refused(404, "no such page")

    def _route_post(self, segments: list[str], _query: dict[str, list[str]]) -> None:
        """Match a POST to a route, or 404."""
        if segments[:1] == ["upload"] and len(segments) == 2:
            self._upload(segments[1])
        elif segments[:1] == ["remove"] and len(segments) == 3:
            self._remove(segments[1], segments[2])
        elif segments == ["apply"]:
            self._apply()
        else:
            raise _Refused(404, "no such page")

    def _live(self, source: str) -> list[tuple[str, int]]:
        """``(name, size)`` for every clip currently in ``source``'s folder."""
        folder = folder_for(self.server.root, source)
        if not folder.is_dir():
            return []
        return sorted(
            (entry.name, entry.stat().st_size)
            for entry in folder.iterdir()
            if entry.is_file() and is_audio(entry.name)
        )

    def _page(self, source: str) -> None:
        """GET ``/`` -- the whole page for one source."""
        live = self._live(source)
        pending = self.server.staging.pending_for(source)
        self._send(200, "text/html; charset=utf-8", render(source, live, pending).encode())

    def _list(self, source: str) -> None:
        """GET ``/list/<source>`` -- what is live and what is staged, as JSON."""
        live = self._live(source)
        pending = self.server.staging.pending_for(source)
        self._send_json(
            200,
            {
                "source": source,
                "folder": SOURCES[source],
                "live": [{"name": name, "size": size} for name, size in live],
                "pending": {
                    "adds": [path.name for path in pending.adds[source]],
                    "removes": list(pending.removes[source]),
                },
            },
        )

    def _download(self, source: str, name: str) -> None:
        """GET ``/download/<source>/<name>`` -- the bytes, as an attachment.

        This is the undo this design otherwise does not have: staff take a
        copy of a clip before replacing it.
        """
        target = safe_target(self.server.root, source, name)
        if not target.is_file():
            raise _Refused(404, "no such clip")
        self._drain()
        self._responded = True
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(target.stat().st_size))
        # RFC 5987 form: the name is percent-encoded, so no filename can
        # break out of the header, whatever it contains.
        self.send_header(
            "Content-Disposition", f"attachment; filename*=UTF-8''{quote(target.name)}"
        )
        self.end_headers()
        with target.open("rb") as handle:
            shutil.copyfileobj(handle, self.wfile)

    def _upload(self, source: str) -> None:
        """POST ``/upload/<source>`` -- stage one or more files, or refuse them all.

        Nothing reaches the clip folder here: accepted files sit in
        ``.uploads`` until Apply moves them. If any file in the request is
        refused, none of them is staged and every temp file is removed --
        an upload is all or nothing, so a half-accepted batch never has to
        be explained to whoever pressed the button.
        """
        # Called for its refusal, not its result: an unknown source is a 404
        # before a single byte of the body is read, let alone written.
        folder_for(self.server.root, source)
        free = self.server.free_bytes(self.server.root)
        if free < FREE_SPACE_FLOOR_BYTES:
            raise _Refused(507, f"only {free // (1024 * 1024)} MB free; upload refused")

        boundary = _boundary_of(self.headers.get("Content-Type", ""))
        dest_dir = self.server.root / UPLOAD_DIR_NAME
        dest_dir.mkdir(exist_ok=True)
        parts = _read_file_parts(self._body_reader(), boundary, dest_dir)
        if not parts:
            raise _Refused(400, "that upload carried no file")

        try:
            accepted: list[tuple[Path, str]] = []
            for filename, tmp_path in parts:
                target = safe_target(self.server.root, source, filename)
                if not is_audio(target.name):
                    raise _Refused(400, f"{target.name} is not an audio file")
                if not is_decodable(tmp_path, runner=self.server.probe_runner):
                    raise _Refused(
                        400, f"{target.name} is not something ffmpeg can decode"
                    )
                accepted.append((tmp_path, target.name))
        except BaseException:
            for _filename, tmp_path in parts:
                tmp_path.unlink(missing_ok=True)
            raise

        with self.server.staging_lock:
            for tmp_path, name in accepted:
                self.server.staging.stage_add(source, tmp_path, name)
        logger.info("staged %d upload(s) for %s", len(accepted), source)
        self._send_json(200, {"staged": [name for _tmp_path, name in accepted]})

    def _remove(self, source: str, name: str) -> None:
        """POST ``/remove/<source>/<name>`` -- stage a removal, deleting nothing yet."""
        target = safe_target(self.server.root, source, name)
        if not target.is_file():
            raise _Refused(404, "no such clip")
        with self.server.staging_lock:
            self.server.staging.stage_remove(source, target.name)
        self._send_json(200, {"staged": target.name})

    def _apply(self) -> None:
        """POST ``/apply`` -- move everything staged, and ask for one reload.

        Held under :attr:`ClipsServer.staging_lock` for its whole duration
        (see the module docstring): the empty-pool checks, the file moves
        and the ``reload.request`` write are one indivisible operation.
        """
        with self.server.staging_lock:
            try:
                request_id = self.server.staging.apply(self.server.root)
            except WouldEmptyPool as refusal:
                raise _Refused(409, f"{refusal} would be left with no clips") from refusal
        self._send_json(200, {"id": request_id})

    def _status(self, request_id: str) -> None:
        """GET ``/status/<id>`` -- the installation's answer, once it has one."""
        result = read_result(self.server.root, request_id)
        if result is None:
            self._send_json(200, {"ready": False})
            return
        self._send_json(
            200,
            {
                "ready": True,
                "id": result.id,
                "outcomes": [asdict(outcome) for outcome in result.outcomes],
            },
        )


class ClipsServer(ThreadingHTTPServer):
    """A threading HTTP server that carries the state its handlers share.

    Attributes:
        root: The installation's working directory, the folders' parent.
        staging: The pending changes, shared across every request.
        staging_lock: Guards every mutation of ``staging`` -- and, crucially,
            the whole of Apply (see the module docstring).
        probe_runner: What :func:`~clips_ui.audio.is_decodable` runs instead
            of ``subprocess.run``; the seam tests inject a fake ffprobe at.
        free_bytes: What is called instead of :func:`shutil.disk_usage` to
            find the free space at a path; the seam tests fake a full disk at.
    """

    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        address: tuple[str, int],
        handler: type[BaseHTTPRequestHandler],
        *,
        root: Path,
        runner: Callable[..., subprocess.CompletedProcess],
        free_bytes: Callable[[Path], int],
    ) -> None:
        super().__init__(address, handler)
        self.root = root
        self.staging = Staging()
        self.staging_lock = threading.Lock()
        self.probe_runner = runner
        self.free_bytes = free_bytes


def build_server(
    root: Path,
    bind: str,
    port: int,
    *,
    runner: Callable[..., subprocess.CompletedProcess] = subprocess.run,
    free_bytes: Callable[[Path], int] = _free_bytes,
) -> ThreadingHTTPServer:
    """A server ready to be told to :meth:`~socketserver.BaseServer.serve_forever`.

    Args:
        root: The installation's working directory -- the directory the
            seven clip folders, ``reload.request`` and ``reload.result``
            all live in.
        bind: The address to listen on. In production this is the box's own
            Tailscale address and nothing wider: the service has no
            authentication, and that bind is what stands in for it.
        port: The port to listen on. ``0`` picks a free one, which is what
            the tests use.
        runner: Passed to :func:`~clips_ui.audio.is_decodable` for every
            upload. Defaults to really running ffprobe.
        free_bytes: How free space is measured before an upload. Defaults to
            :func:`shutil.disk_usage`.

    Returns:
        A bound, unstarted :class:`ClipsServer`.
    """
    return ClipsServer(
        (bind, port), _Handler, root=root, runner=runner, free_bytes=free_bytes
    )
