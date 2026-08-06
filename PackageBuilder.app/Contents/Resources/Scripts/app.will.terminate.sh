#!/bin/sh
# app.will.terminate.sh - sweep leftover per-window scratch directories
#
# Declared in COMMAND_LIST like any other command: OMCAppLifetimeEvents looks the
# id up through the loaded command list and does not fall back to finding a
# script on disk, so an undeclared handler never runs at all.
#
# Every window cleans up after itself on close; this is the backstop for a crash
# or a force quit, and the place where a running build's process group will be
# killed once there is one.

tmp="${TMPDIR:-/tmp}"

for dir in "$tmp"/packagebuilder-state-*; do
    [ -d "$dir" ] || continue
    pidfile="$dir/run.pid"
    if [ -f "$pidfile" ]; then
        pid="$(/bin/cat "$pidfile" 2>/dev/null)"
        # "kill -TERM -1" means every process this user is allowed to signal,
        # which would tear down their login session; "-0" means this script's
        # own process group. A truncated or stale pid file is enough to produce
        # either, so the value is checked before it is negated.
        case "$pid" in
            ''|*[!0-9]*) pid="" ;;
        esac
        if [ -n "$pid" ] && [ "$pid" -gt 1 ]; then
            /bin/kill -TERM "-$pid" 2>/dev/null
            /bin/kill -TERM "$pid" 2>/dev/null
        fi
    fi
    /bin/rm -rf "$dir"
done

exit 0
