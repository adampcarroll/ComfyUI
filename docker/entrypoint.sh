#!/bin/sh
set -e

# Docker auto-creates any missing directories needed for a bind mount as
# root, before this container's own process ever starts - even though the
# image itself is built with /app owned by comfyuser. Any bind mount nested
# under /app/ComfyUI/user/ (e.g. .../user/default/workflows/PROJECT, used by
# every project and the testing sandbox) triggers this, leaving
# /app/ComfyUI/user itself - and everything else ComfyUI needs to write
# there: comfy.settings.json, the sqlite asset database, ComfyUI-Manager's
# own __manager directory - owned by root and unwritable by comfyuser.
#
# Fix it fresh at every container start, as root, then drop to comfyuser for
# the actual application process. This is the standard pattern for a
# non-root image that also needs bind mounts (the same thing official images
# like postgres do) - the brief root moment here only ever runs a chown, it
# never touches the application itself.
#
# Tolerate failures here: some projects/the sandbox also mount a read-only
# folder nested under /app/ComfyUI/user/ (e.g. a live, read-only view of a
# shared templates collection) - chown can't touch that, and must not abort
# the whole script over it (this script has `set -e`, so a plain failing
# chown would silently prevent ComfyUI from ever starting at all).
chown -R comfyuser:comfyuser /app/ComfyUI/user 2>/dev/null || true

exec gosu comfyuser python3.11 main.py --listen 0.0.0.0 $CLI_ARGS
