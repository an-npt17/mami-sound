"""clips_ui: a small web UI backend for managing mami-sound clip folders.

Runtime is Python standard library only -- this ships to a Raspberry Pi
Zero 2 W with no pip.
"""

from clips_ui.audio import is_decodable
from clips_ui.folders import (
    AUDIO_EXTENSIONS,
    SOURCES,
    UnknownSource,
    UnsafeName,
    folder_for,
    is_audio,
    safe_target,
)
from clips_ui.page import render
from clips_ui.protocol import Outcome, Result, new_request_id, read_result, write_request
from clips_ui.server import ClipsServer, build_server
from clips_ui.staging import Pending, Staging, WouldEmptyPool

__all__ = [
    "SOURCES",
    "AUDIO_EXTENSIONS",
    "UnknownSource",
    "UnsafeName",
    "folder_for",
    "safe_target",
    "is_audio",
    "is_decodable",
    "Outcome",
    "Result",
    "new_request_id",
    "write_request",
    "read_result",
    "Pending",
    "Staging",
    "WouldEmptyPool",
    "render",
    "ClipsServer",
    "build_server",
]
