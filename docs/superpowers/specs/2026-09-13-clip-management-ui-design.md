# Clip management UI

A web page on the Pi for adding and removing the recordings a plant plays,
without a rebuild, a restart, or a trip to the rig with a USB stick.

## The problem

Every clip pool is a folder beside the binary, named in
`src/adapters/clip_loader.zig:70`. Changing what a plant plays means getting a
file onto `/home/pi/mami-sound/<folder>/` and restarting the service. That is an
SSH session and a silence, and it is done by whoever has the laptop rather than
by whoever knows which recording is wrong.

## What this is not

Files only, in the seven folders that already exist -- `drone` is generated and has no folder at all (`src/adapters/clip_loader.zig:74`). The source list stays a Zig
enum: adding a pool is still a variant in `src/core/source.zig` and a line in the
loader. Per-plant settings stay on the command line. Those were scoped out
deliberately and each is its own piece of work.

## The constraint that shapes everything

Four things are built at startup and then read from three threads with no lock:

| Thing | Built at | Read by |
|---|---|---|
| `pools[plant]`, owning the path strings | `src/main.zig:151` | stream worker |
| `stream.paths`, borrowing the above | `src/main.zig:184` | stream worker |
| `stream.heads`, the decoded openings | `src/main.zig:191` | audio thread, worker |
| `selector`, whose clip count is baked in | `src/main.zig:215` | audio thread |

`src/adapters/clip_stream.zig:31` states the invariant outright: the heads are
"read-only from then on, which is what lets both the audio thread and the worker
hold it without a lock."

So rescanning a folder in place means either a mutex in the render path or a
use-after-free on a thread that is decoding. This design does neither. It builds
the replacement beside the running one and swaps whole voices. Each streamer
stays write-once; what changes is which streamer a plant points at.

## Shape

Two units, both `User=pi`, both with `WorkingDirectory=/home/pi/mami-sound`, so
the web process writes the clip folders directly with no privilege step.

```
mami-clips.service   Python stdlib http.server, LAN-bound
        |
        |  reload.request   (staff pressed Apply)
        v
mami-sound.service   the installation, unchanged in the audio path
        |
        |  reload.result    (applied, or refused and why)
        v
mami-clips.service   shows the outcome on the page
```

Files rather than a signal. The Apply button needs an answer -- "applied" or
"refused: Insect would have no clips left" -- and a signal carries no reply.
A file protocol also survives a restart of either side: a request left by a web
process that died is picked up when the installation next looks, and a result
written while the browser tab was closed is still there when it reopens.

### Where the two files live, and what they name

Both sit in `/home/pi/mami-sound/`, the working directory both units share:
`reload.request` written by the web process, `reload.result` written by the
installation. Each is written to a temporary name in the same directory and
renamed into place, so a reader never sees half a file.

A request names **source folders**, not plants. The web process knows which
folders it changed; it does not know which plant is playing what, because that
is a command-line decision made when the service started. The installation does
the mapping: for each named source it reloads whichever of its two plants is
currently playing that source. A source no plant is playing is not an error --
the files were still written, and the next start will pick them up. The result
says so rather than reporting success for a swap that did not happen.

### Why Python stdlib rather than Flask

The board is a Zero 2 W: four slow cores and 512 MB shared with the GPU, already
holding decoded clip heads. Flask with Werkzeug costs about 40 MB resident;
`http.server` costs about 13 MB and, more to the point, needs nothing installed.
A museum box with no pip and no network to reach an index is the normal case,
not the awkward one.

Throughput is not the question. Upload is bound by the Zero 2 W's wifi, which
tops out well below what any Python server can write to an SD card.

## The swap

Three steps, and only the second is on the audio thread's schedule.

**1. Stage, off-thread.** A helper thread runs `clip_loader.loadPool` and
`primeHeads` for the changed plant into a staging slot. The existing audio
sources spec measures a pool at 0.7 s on a development machine and the Pi at
five to ten times slower, so this is seconds of work. It never runs on the
render loop.

**2. Swap, between steps.** When the staging slot is ready *and* that plant is
untouched and not sounding, the run loop assigns the new voice over the old one.
A struct assignment, on the one thread that renders, between two `step()` calls.
No lock, because there is no concurrent reader: the audio thread is the thread
doing it.

Waiting for silence is not politeness. A swap mid-clip would cut a recording off
in the room, and the room cannot tell that from a fault.

**3. Retire, off-thread.** The old streamer goes to the helper thread for
disposal. It is never deinitialised inline: `deinit` joins the ffmpeg worker, and
a join on the render loop is a dropout.

### The seam

`Engine` holds `voices: [2]voice_mod.Voice` by value
(`src/application/engine.zig:19`), so `main.zig` cannot reach into a running
engine to swap one. The run loop gains a port -- `src/ports/voice_reload.zig` --
that it asks between steps whether a new voice is waiting for a plant.

A port rather than a callback because that is how `probe_capture` and
`clip_stream` already plug in, and because it keeps `core` and the engine
ignorant of files, folders, and helper threads. A test supplies a fake that
hands over a voice on a chosen step; nothing in the test needs a disk.

`null` is the whole of the production default. A run given no reload port
behaves exactly as it does now, which is what every existing test relies on.

## What the page does

One page. A folder picker across the seven clip sources, a list of what is in the
chosen folder with a size and a delete box beside each, a file chooser that
takes several files at once, and an Apply button.

Changes stage rather than apply. Staff upload three recordings and delete two,
see the pending list, then press Apply once. One swap, at a moment they chose.
The list distinguishes what is live from what is pending, because a page that
shows a file the installation is not yet playing has to say so.

Download is a link per file. Staff take a copy before replacing it, which is the
undo this design otherwise does not have.

## Guards

**An empty pool is refused, not fatal.** `NoAudioFiles` today exits the process
(`src/main.zig:158`), and that is right at startup: a plant with no clips is
silence nobody in the room can tell from the piece working. On a live reload it
must not exit. The old pool stands, the request is refused, and the page says
which folder and why.

**Uploads are decoded before they are accepted.** `library.isAudio` checks an
extension, which is not the same question as whether ffmpeg can read it. An
undecodable file that reaches a pool becomes a slot in the rotation that plays
nothing -- the exact failure the loader's own comment says must not happen. The
web process runs ffprobe on the upload and rejects what will not decode, with
the folder untouched.

**Writes are confined to the seven folders.** Names are matched against
`clip_loader.directoriesFor`, and an upload filename is reduced to its basename
before it is joined to anything. A folder the enum does not name is a 404, not a
new pool.

**Disk is checked before a write.** An SD card that fills corrupts in ways worse
than a refused upload.

**Access is LAN-bound and unauthenticated.** Scoped that way deliberately.
Anyone who can reach the museum wifi can delete every clip in every pool. This
is acceptable only while that network is private; if it ever gains guest access,
a shared password is the smallest fix and belongs here before that happens.

## Failure

| What happens | What the room gets |
|---|---|
| Web process dies | Audio unaffected. No page until systemd restarts it. |
| Installation dies | systemd restarts it as now; it reads the folders fresh. |
| ffprobe rejects an upload | Folder untouched, page names the file. |
| Reload would empty a pool | Old pool keeps playing, page names the folder. |
| `primeHeads` fails while staging | Old voice keeps playing, page says so. Matches `src/main.zig:196`, where failed heads are already survivable. |
| Apply arrives while a plant is held | Swap waits for silence. Page says pending. |
| Disk full | Upload refused before any write. |

Nothing in that table ends in silence, which is the only outcome that matters.

## Testing

Without a Pi, and without audio:

- Request and result protocol, both directions, including a truncated file.
- The refuse-on-empty rule, as a pure decision over a folder listing.
- Path confinement: traversal, absolute paths, an unknown folder, a bare `..`.
- The staging state machine: idle, staged, waiting for silence, applied, refused.
- Upload acceptance, with ffprobe stubbed both ways.

With a fake clip stream:

- A swap happens only while the plant is silent.
- The old streamer is retired off the render loop.
- A plant not named in the request is left alone.
- A run with no reload port behaves as it does today.

`src/clip_stream_integration_test.zig` and the `FakeClips` in
`src/application/engine.zig` are the models to follow; neither needs a device.

## Deployment

A second unit file beside `mami-sound.service`, `Restart=on-failure` for the same
reason. `After=network.target`. No change to `mami-sound.service` itself beyond
what the reload port needs at startup.
