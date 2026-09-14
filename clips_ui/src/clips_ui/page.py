"""The one page staff see, rendered as a single self-contained HTML string.

One page, no framework, no assets: a folder picker across the seven clip
sources, a table of what is live in the chosen folder with a size, a
download link and a remove button, a multi-file chooser, the pending list,
and an Apply button.

Every value that comes off the filesystem is escaped on the way in.
Filenames are attacker-controlled in this design's threat model -- the
server this page is served from has no authentication, so anyone who can
reach the port can choose what a filename says -- and a filename reaches
this module three times over: as link text, inside an ``href``, and inside
a ``data-`` attribute the page's own script reads back. Link text goes
through :func:`html.escape`; anything landing in a URL goes through
:func:`urllib.parse.quote` first and *then* :func:`html.escape`, because
percent-encoding alone does not make ``"`` safe inside an attribute and
escaping alone does not make ``?`` or ``#`` safe inside a path.

The script is deliberately small and never builds markup from a string: it
sets ``textContent``, so an outcome's ``detail`` coming back from the
installation cannot become markup either.
"""

import html
import json
import logging
from collections.abc import Sequence
from urllib.parse import quote

from clips_ui.folders import SOURCES
from clips_ui.staging import Pending

logger = logging.getLogger(__name__)

__all__ = ["render"]

_STYLE = """
  body { font: 16px/1.5 system-ui, sans-serif; margin: 2rem auto; max-width: 46rem;
         padding: 0 1rem; color: #1a1a1a; background: #fbfbf9; }
  h1 { font-size: 1.3rem; } h2 { font-size: 1.05rem; margin-top: 2rem; }
  nav a { display: inline-block; padding: .2rem .5rem; margin: 0 .3rem .3rem 0;
          border: 1px solid #ccc; border-radius: .3rem; text-decoration: none;
          color: #1a1a1a; }
  nav a.current { background: #1a1a1a; color: #fbfbf9; border-color: #1a1a1a; }
  table { border-collapse: collapse; width: 100%; }
  td, th { text-align: left; padding: .3rem .5rem; border-bottom: 1px solid #e4e4e0; }
  td.size { text-align: right; color: #555; white-space: nowrap; }
  ul { padding-left: 1.2rem; } li.add { color: #16610e; } li.remove { color: #8a1c10; }
  button { font: inherit; padding: .2rem .6rem; }
  #apply { padding: .4rem 1.2rem; margin-top: .5rem; }
  #status { min-height: 1.5rem; font-weight: 600; }
  .quiet { color: #666; }
"""

_SCRIPT = """
  const say = (message) => { document.getElementById("status").textContent = message; };
  async function detail(response) {
    try { return (await response.json()).detail; }
    catch (error) { return "refused (" + response.status + ")"; }
  }
  async function send(url, body) {
    const response = await fetch(url, { method: "POST", body: body });
    if (response.ok) { location.reload(); return; }
    say(await detail(response));
  }
  document.querySelectorAll("button[data-remove]").forEach((button) => {
    button.addEventListener("click", () => send(button.dataset.remove));
  });
  document.getElementById("chooser").addEventListener("submit", (event) => {
    event.preventDefault();
    say("uploading\\u2026");
    send("/upload/" + encodeURIComponent(SOURCE), new FormData(event.target));
  });
  async function poll(id, tries) {
    const response = await fetch("/status/" + encodeURIComponent(id));
    const result = await response.json();
    if (!result.ready) {
      if (tries > 0) { setTimeout(() => poll(id, tries - 1), 1000); }
      else { say("applied on disk, but the installation has not answered yet"); }
      return;
    }
    say(result.outcomes.map((o) => o.source + ": " + o.status +
        (o.detail ? " (" + o.detail + ")" : "")).join("; ") || "applied");
    setTimeout(() => location.reload(), 3000);
  }
  document.getElementById("apply").addEventListener("click", async () => {
    say("applying\\u2026");
    const response = await fetch("/apply", { method: "POST" });
    if (!response.ok) { say(await detail(response)); return; }
    poll((await response.json()).id, 30);
  });
"""


def _human_size(size: int) -> str:
    """``size`` in bytes, rounded for a human reading a table."""
    if size < 1024:
        return f"{size} B"
    if size < 1024 * 1024:
        return f"{size / 1024:.0f} KB"
    return f"{size / (1024 * 1024):.1f} MB"


def _link(source: str, name: str) -> str:
    """A download link for ``name``, escaped for both the href and the text."""
    href = html.escape(f"/download/{quote(source)}/{quote(name)}", quote=True)
    return f'<a href="{href}">{html.escape(name)}</a>'


def _live_rows(source: str, live: Sequence[tuple[str, int]]) -> str:
    """The table body listing what is currently in the folder."""
    if not live:
        return '<tr><td colspan="3" class="quiet">nothing in this folder</td></tr>'
    rows = []
    for name, size in live:
        target = html.escape(f"/remove/{quote(source)}/{quote(name)}", quote=True)
        rows.append(
            f"<tr><td>{_link(source, name)}</td>"
            f'<td class="size">{html.escape(_human_size(size))}</td>'
            f'<td><button data-remove="{target}">remove</button></td></tr>'
        )
    return "".join(rows)


def _pending_items(pending: Pending, source: str) -> str:
    """The pending list: what Apply would add, and what it would remove."""
    adds = [path.name for path in pending.adds.get(source, [])]
    removes = list(pending.removes.get(source, []))
    if not adds and not removes:
        return (
            '<p class="quiet">nothing staged.'
            " The folder is as the installation sees it.</p>"
        )
    items = [f'<li class="add">add {html.escape(name)}</li>' for name in adds]
    items += [f'<li class="remove">remove {html.escape(name)}</li>' for name in removes]
    return f"<ul>{''.join(items)}</ul>"


def _picker(source: str) -> str:
    """Links to every one of the seven clip folders, current one marked."""
    links = []
    for name, folder_name in SOURCES.items():
        current = ' class="current"' if name == source else ""
        href = html.escape(f"/?source={quote(name)}", quote=True)
        links.append(f'<a href="{href}"{current}>{html.escape(folder_name)}</a>')
    return "".join(links)


def render(source: str, live: Sequence[tuple[str, int]], pending: Pending) -> str:
    """The whole page for one source, as a single HTML string.

    Args:
        source: The source being shown, e.g. ``"piano"``. Must be a key of
            :data:`~clips_ui.folders.SOURCES`; the caller validates that
            with :func:`~clips_ui.folders.folder_for` before rendering, so
            an unknown source is a 404 rather than an empty page.
        live: ``(filename, size in bytes)`` for each clip currently in the
            folder, in the order they should be listed.
        pending: What is staged for ``source``, from
            :meth:`~clips_ui.staging.Staging.pending_for`.

    Returns:
        A complete HTML document. No external stylesheet, script, or font:
        the museum box serves this from a Pi with no internet.
    """
    folder_name = html.escape(SOURCES[source])
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>mami-sound clips</title>
<style>{_STYLE}</style>
</head>
<body>
<h1>mami-sound clips</h1>
<nav>{_picker(source)}</nav>
<h2>{folder_name}</h2>
<table><thead><tr><th>clip</th><th class="size">size</th><th></th></tr></thead>
<tbody>{_live_rows(source, live)}</tbody></table>
<h2>add clips</h2>
<form id="chooser"><input type="file" name="files" multiple>
<button type="submit">upload</button></form>
<h2>pending</h2>
{_pending_items(pending, source)}
<button id="apply">Apply</button>
<p id="status"></p>
<script>
  const SOURCE = {json.dumps(source)};
{_SCRIPT}
</script>
</body>
</html>
"""
