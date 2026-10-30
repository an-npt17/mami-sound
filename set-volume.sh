#!/bin/sh
# Put every playback control on the sound card at full volume and unmuted.
#
# ALSA only saves mixer levels on a clean shutdown or an explicit
# `alsactl store`, and an installation box is usually switched off at the wall,
# so whatever alsamixer was set to is lost on the next boot. The service runs
# this before every start instead of trusting the restored state. The level
# the room hears is then set by the clips' own gains, not by the mixer.
#
# Usage: set-volume.sh [CARD]   (default 0, the card plughw:0,0 plays on)

card="${1:-0}"

amixer -c "$card" scontrols |
    sed -n "s/^Simple mixer control '\(.*\)',[0-9]*$/\1/p" |
    while IFS= read -r control; do
        # Only controls with a playback volume: capture gains and plain
        # switches are left alone.
        if amixer -c "$card" sget "$control" | grep -q 'pvolume'; then
            amixer -q -c "$card" sset "$control" 100% unmute || true
            echo "set-volume: card $card '$control' at 100%"
        fi
    done
