#!/bin/sh
# DRAP Music Builder for Linux (Steam Proton). Run it from a terminal with the
# game closed:   sh "DRAP Music Builder.sh"
# It must sit in the Dead Rising Deluxe Remaster folder, next to DRDR.exe.
cd "$(dirname "$0")" || exit 1
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 was not found. Install it with your package manager (for example: sudo apt install python3), then run this again."
    exit 1
fi
exec python3 -I ./drap_music_builder.py "$@"
