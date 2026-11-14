#!/bin/sh
# Removes DRAP custom music (only the files the builder made). Your songs stay.
# Run it from a terminal with the game closed:   sh "DRAP Music Uninstall.sh"
cd "$(dirname "$0")" || exit 1
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 was not found. Install it with your package manager (for example: sudo apt install python3), then run this again."
    exit 1
fi
exec python3 -I ./drap_music_builder.py --uninstall "$@"
