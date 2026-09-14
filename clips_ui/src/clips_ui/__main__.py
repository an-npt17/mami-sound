"""``python3 -m clips_ui --root <dir> --bind <address> --port <port>``.

The entry point ``mami-clips.service`` starts. It does nothing but read
three arguments, build the server, and serve until systemd stops it.

``--bind`` defaults to loopback deliberately. This service has no
authentication, so the unit file passes the box's own Tailscale address
explicitly; a missing or mistyped ``MAMI_CLIPS_BIND`` must leave the page
unreachable rather than exposed to the museum wifi.
"""

import argparse
import logging
import sys
from pathlib import Path

from clips_ui.server import build_server

logger = logging.getLogger(__name__)

__all__ = ["main"]


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse the command line into ``root``, ``bind`` and ``port``."""
    parser = argparse.ArgumentParser(
        prog="clips_ui",
        description="Web UI for adding and removing mami-sound clips.",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path.cwd(),
        help="the installation's working directory, where the clip folders live",
    )
    parser.add_argument(
        "--bind",
        default="127.0.0.1",
        help="the address to listen on; the box's Tailscale address in production",
    )
    parser.add_argument("--port", type=int, default=8080, help="the port to listen on")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """Serve until interrupted.

    Returns:
        A process exit status: ``0`` once serving has stopped cleanly.
    """
    args = _parse_args(argv)
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s"
    )
    server = build_server(args.root, args.bind, args.port)
    logger.info("serving %s on http://%s:%d/", args.root, args.bind, args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("stopping")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
