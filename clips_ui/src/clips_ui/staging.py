"""Pending clip changes, and what Apply does with them.

Staff do not want every upload or delete to hit the clip folders one at a
time -- they want to add three clips and remove two, see the pending list,
then press Apply once. :class:`Staging` is the object that holds those
pending changes: nothing it does touches a clip folder until
:meth:`Staging.apply` runs, and ``apply`` produces a single
``reload.request`` (via :mod:`clips_ui.protocol`) naming only the sources
that actually changed.

The rule that matters most: a source whose applied changes would leave it
with no clips at all must never reach the filesystem. A plant whose pool is
empty plays silence, and silence is the one failure nobody in the room can
tell apart from the installation working correctly. :meth:`Staging.apply`
therefore checks :meth:`Staging.would_empty` -- and that every staged
filename is a safe target -- for every touched source *before* moving or
deleting a single file, and raises :class:`WouldEmptyPool` naming the
folder if any of them would empty. This check is the page's own guard --
the first line of defence. The installation refusing a reload that would
empty a pool is the second line, not a substitute for this one.

That precheck is not the whole story: a filesystem operation can still fail
partway through the mutation phase, after every check has passed (a file
disappearing out from under ``apply``, for instance). ``apply`` cannot make
that phase fully atomic without more machinery than a museum installation's
reload protocol needs, so instead it orders the mutation so that a partial
failure is never a *fatal* one: every staged add is moved into place before
any staged removal runs, for each touched source. Because ``would_empty``
already verified the net result -- adds included -- is non-empty, a source
can end up with more clips than intended if a later removal fails, but it
can never end up with none.
"""

import logging
import shutil
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

from clips_ui.folders import folder_for, is_audio, safe_target
from clips_ui.protocol import new_request_id, write_request

logger = logging.getLogger(__name__)

__all__ = ["Pending", "Staging", "WouldEmptyPool"]


class WouldEmptyPool(Exception):
    """Raised by :meth:`Staging.apply` when a source would end up with no clips.

    Carries the folder's on-disk name (e.g. ``"EPiano Stems"``), not the
    internal source key (e.g. ``"piano"``), since the folder name is what
    staff will actually go and look at.
    """


@dataclass
class Pending:
    """What is staged for one source, awaiting Apply.

    ``adds`` maps that source to the filenames it will gain once applied
    (the name it will be saved under, not the temporary upload path it
    currently lives at); ``removes`` maps it to the filenames it will lose.
    Both dicts carry exactly the one key passed to
    :meth:`Staging.pending_for`, with an empty list when nothing of that
    kind is staged -- so a page can always do ``pending.adds[source]``
    without a membership check.
    """

    adds: dict[str, list[Path]]
    removes: dict[str, list[str]]


class Staging:
    """A queue of clip changes that have not yet reached any clip folder.

    Staging never touches the filesystem itself except inside
    :meth:`apply`. :meth:`stage_add` and :meth:`stage_remove` only record
    intent; :meth:`would_empty` reasons about a caller-supplied listing of
    what is currently live, so it never needs to read a directory either.
    """

    def __init__(self) -> None:
        self._adds: dict[str, list[tuple[Path, str]]] = {}
        self._removes: dict[str, list[str]] = {}

    def stage_add(self, source: str, tmp_path: Path, filename: str) -> None:
        """Queue moving ``tmp_path`` into ``source``'s folder as ``filename``.

        Args:
            source: A source name, e.g. ``"piano"``. Not validated here --
                an unknown source surfaces as :class:`~clips_ui.folders.UnknownSource`
                from :meth:`apply`, which is the first point staging needs a
                real folder to check against.
            tmp_path: Where the uploaded file currently sits (outside every
                clip folder). Left untouched until :meth:`apply` runs.
            filename: The name it will be saved under. Checked for safety
                by :func:`~clips_ui.folders.safe_target` at apply time, not
                here.
        """
        self._adds.setdefault(source, []).append((tmp_path, filename))

    def stage_remove(self, source: str, filename: str) -> None:
        """Queue deleting ``filename`` from ``source``'s folder.

        Staging the same ``(source, filename)`` pair twice queues it once --
        two ``unlink`` calls for the same path at apply time would mean the
        second one raises against a file the first one already deleted,
        which is exactly the partial-failure hazard :meth:`apply` otherwise
        guards against.

        Args:
            source: As :meth:`stage_add`.
            filename: The clip to remove. The file is untouched until
                :meth:`apply` runs -- this call does not even check that it
                exists.
        """
        bucket = self._removes.setdefault(source, [])
        if filename not in bucket:
            bucket.append(filename)

    def pending_for(self, source: str) -> Pending:
        """What is staged for ``source``, for display before Apply.

        Args:
            source: A source name.

        Returns:
            A :class:`Pending` with exactly the ``source`` key in both
            dicts -- an empty list on either side if nothing of that kind
            is staged for it.
        """
        adds = [Path(filename) for _tmp_path, filename in self._adds.get(source, [])]
        removes = list(self._removes.get(source, []))
        return Pending(adds={source: adds}, removes={source: removes})

    def would_empty(self, source: str, live_names: Iterable[str]) -> bool:
        """Whether applying what is staged would leave ``source`` with no clips.

        Reasons about the *net* result, not the removals in isolation: a
        staged add for ``source`` can offset a staged removal, so removing
        the only live clip and adding a new one in the same batch is fine.

        Args:
            source: A source name.
            live_names: The filenames currently in ``source``'s folder, as
                the caller has observed them (this method never reads a
                directory itself).

        Returns:
            True if ``(live_names - staged removes) | staged add filenames``
            is empty for ``source``.
        """
        removed = set(self._removes.get(source, []))
        added = {filename for _tmp_path, filename in self._adds.get(source, [])}
        remaining = (set(live_names) - removed) | added
        return not remaining

    def _live_names(self, root: Path, source: str) -> list[str]:
        """The audio filenames currently in ``source``'s folder under ``root``."""
        folder = folder_for(root, source)
        if not folder.is_dir():
            return []
        return [
            entry.name
            for entry in folder.iterdir()
            if entry.is_file() and is_audio(entry.name)
        ]

    def _touched_sources(self) -> list[str]:
        """Every source with a staged add or removal, in a stable order."""
        return sorted(set(self._adds) | set(self._removes))

    def apply(self, root: Path) -> str:
        """Apply every staged change as one batch, and request one reload.

        Every touched source is checked before anything is mutated: every
        staged filename (add or remove) must resolve through
        :func:`~clips_ui.folders.safe_target`, and :meth:`would_empty` --
        run against that source's actual current contents on disk -- must
        be false. If any touched source fails either check, this raises
        (:class:`~clips_ui.folders.UnsafeName`,
        :class:`~clips_ui.folders.UnknownSource`, or
        :class:`WouldEmptyPool`) before a single file has moved or been
        deleted, and every clip folder is left exactly as it was.

        Once every touched source has cleared both checks, mutation begins.
        Within each source, every staged add is moved into place before any
        staged removal runs -- see the module docstring for why. This
        method is therefore not fully atomic: if a filesystem operation
        fails partway through the mutation phase (after the precheck has
        already passed), a touched source can be left with extra clips and
        no ``reload.request`` written at all, and the exception propagates
        to the caller with staged state left as it was. What it guarantees
        even then is that no touched source is left with none.

        Args:
            root: The installation's working directory (see
                :mod:`clips_ui.protocol`).

        Returns:
            The id of the ``reload.request`` this call wrote.

        Raises:
            WouldEmptyPool: if applying the staged changes would leave any
                touched source's folder with no clips.
            UnknownSource: if a staged source is not a real source.
            UnsafeName: if a staged filename could not be trusted, from
                :func:`~clips_ui.folders.safe_target`.
        """
        touched = self._touched_sources()

        for source in touched:
            for filename in self._removes.get(source, []):
                safe_target(root, source, filename)
            for _tmp_path, filename in self._adds.get(source, []):
                safe_target(root, source, filename)

            live_names = self._live_names(root, source)
            if self.would_empty(source, live_names):
                folder = folder_for(root, source)
                logger.warning(
                    "apply refused: %s would be left with no clips", folder.name
                )
                raise WouldEmptyPool(folder.name)

        for source in touched:
            for tmp_path, filename in self._adds.get(source, []):
                target = safe_target(root, source, filename)
                shutil.move(str(tmp_path), str(target))
            for filename in self._removes.get(source, []):
                target = safe_target(root, source, filename)
                target.unlink()

        request_id = new_request_id()
        write_request(root, request_id, touched)
        logger.info("applied pending changes for sources=%s id=%s", touched, request_id)
        self._adds = {}
        self._removes = {}
        return request_id
