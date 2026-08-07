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
        pgid="$(/bin/cat "$dir/run.pgid" 2>/dev/null)"
        # "kill -TERM -1" means every process this user is allowed to signal,
        # which would tear down their login session; "-0" means this script's
        # own process group. A truncated or stale pid file is enough to produce
        # either, so the value is checked before it is negated.
        case "$pid" in
            ''|*[!0-9]*) pid="" ;;
        esac
        case "$pgid" in
            ''|*[!0-9]*) pgid="" ;;
        esac
        # Everything below asks the live process table, never the files alone.
        #
        # Comparing the recorded pid against the recorded pgid proves only that
        # the pair is self-consistent - both were written by the same
        # build_begin - and says nothing about what that number names now. These
        # files outlive a crash or a force quit, which is precisely when this
        # handler does not run to clean them up, so hours later and after pid
        # wrap the number can belong to an unrelated process. Most GUI apps and
        # login shells are group leaders, so a stale pair was enough to send
        # SIGTERM to a stranger's entire process group - demonstrated in review,
        # 2026-08-06, by killing an innocent leader and its child.
        live_cmd=""
        live_pgid=""
        if [ -n "$pid" ] && [ "$pid" -gt 1 ]; then
            live_cmd="$(/bin/ps -o command= -p "$pid" 2>/dev/null)"
            live_pgid="$(/bin/ps -o pgid= -p "$pid" 2>/dev/null | /usr/bin/tr -d ' ')"
        fi
        # A build handler is this app's own script, run by path - a script in
        # this bundle's Scripts folder, not merely any command line with the
        # app's name somewhere in it, which an editor holding a build script
        # open or a git command naming the repo would satisfy. Anything else
        # wearing that pid now is a stranger and is left alone.
        case "$live_cmd" in
            *"/Scripts/PackageBuilder."*) ;;
            *) live_cmd="" ;;
        esac

        if [ -n "$live_cmd" ]; then
            # The tool the build is inside, which is not in the build script's
            # group when the build script does not lead one. Identified by
            # parentage rather than by name: a tool's command line is codesign
            # or productsign against a path that need not be ours, but its
            # parent is the build script and nothing else's child is.
            #
            # Signaled before its parent, because the parentage evidence dies
            # with the parent: the build script sits in wait and is gone within
            # a millisecond of its own SIGTERM, the tool is reparented to
            # launchd, and a ppid read after that reports 1 - ordered the other
            # way around, this kill never reaches the tool at all.
            toolpid="$(/bin/cat "$dir/tool.pid" 2>/dev/null)"
            case "$toolpid" in
                ''|*[!0-9]*) toolpid="" ;;
            esac
            if [ -n "$toolpid" ] && [ "$toolpid" -gt 1 ]; then
                tool_parent="$(/bin/ps -o ppid= -p "$toolpid" 2>/dev/null | /usr/bin/tr -d ' ')"
                if [ "$tool_parent" = "$pid" ]; then
                    /bin/kill -TERM "$toolpid" 2>/dev/null
                fi
            fi
            # The group is re-derived from the live process and must still match
            # both the recorded pgid and the pid itself. pgid == pid is what
            # proves the script leads its own group, so nothing else - the
            # application above all - is in the group about to be signaled.
            if [ -n "$live_pgid" ] && [ "$live_pgid" = "$pid" ] && [ "$pid" = "$pgid" ]; then
                /bin/kill -TERM "-$pid" 2>/dev/null
            fi
            /bin/kill -TERM "$pid" 2>/dev/null
        fi
    fi
    /bin/rm -rf "$dir"
done

exit 0
