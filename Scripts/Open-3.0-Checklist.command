#!/bin/zsh
cd "${0:A:h:h}" || exit 1
exec python3 Scripts/serve-3.0-checklist.py
