#!/bin/sh
# lib.packagebuilder.sh - Shared functions and variables for PackageBuilder
#
# POSIX sh only (macOS /bin/sh is bash 3.2 in POSIX mode). No [[ ]], no arrays,
# no process substitution, no ${var,,}. Validate with "sh -n", never "bash -n".
#
# The infrastructure layer here (state_dir, pb_*, the omc_dialog_control
# wrappers, append_log, prefs_*, canonical_path) is a copy of the equivalents in
# Notarize.app's lib.notarize.sh. OMC has no mechanism for sharing scripts
# between applets; each block that came from there says so.

# --- OMC environment ---
support_path="$OMC_OMC_SUPPORT_PATH"
app_bundle="$OMC_APP_BUNDLE_PATH"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
parent_uuid="$OMC_PARENT_DIALOG_GUID"
cmd_guid="$OMC_CURRENT_COMMAND_GUID"
# Document window UUID: the parent when running inside a child sheet, else self.
document_uuid="${parent_uuid:-$window_uuid}"

# --- OMC support tools (lowercase vars, as in the other applets) ---
dialog_tool="$support_path/omc_dialog_control"
next_cmd="$support_path/omc_next_command"
pasteboard_tool="$support_path/pasteboard"
alert_tool="$support_path/alert"
notify_tool="$support_path/notify"
plister="$support_path/plister"

# System tools are called by absolute path inline (e.g. /bin/cat).

resources_dir="$app_bundle/Contents/Resources"
new_document_template="$resources_dir/NewDocument.json"

# --- Debug logging ------------------------------------------------------------
# Silent unless the flag file exists, so a shipped applet writes nothing. The log
# lives under TMPDIR rather than /tmp: /tmp is world-writable, so on a shared
# machine another user could pre-create the log as a symlink and have this app
# append document paths wherever this user can write.
# Turn on with: touch "$TMPDIR/packagebuilder_debug"
dbg_flag="${TMPDIR:-/tmp}/packagebuilder_debug"
dbg_log="${TMPDIR:-/tmp}/packagebuilder_debug.log"

dbg() {
    [ -f "$dbg_flag" ] || return 0
    printf '%s %s\n' "$(/bin/date '+%H:%M:%S')" "$*" >> "$dbg_log"
}

# Log the OMC context a handler was invoked with.
dbg_context() {
    local handler_name="$1"
    [ -f "$dbg_flag" ] || return 0
    dbg "=== $handler_name"
    dbg "    OMC_OBJ_PATH=[$OMC_OBJ_PATH]"
    dbg "    OMC_DLG_SAVE_AS_PATH=[$OMC_DLG_SAVE_AS_PATH]"
    dbg "    window=[$window_uuid] parent=[$parent_uuid] doc=[$document_uuid]"
    dbg "    trigger_view=[$OMC_ACTIONUI_TRIGGER_VIEW_ID]"
}

# --- View ids (match the ids in Base.lproj/PackageBuilder.json) ---------------
BUILD_BTN_ID=30
STOP_BTN_ID=31
ACTIONS_MENU_ID=32
NOTARIZE_BTN_ID=33
TABVIEW_ID=40

PAYLOAD_TABLE_ID=100
PAYLOAD_ADD_ID=101
PAYLOAD_REMOVE_ID=102
PAYLOAD_UP_ID=103
PAYLOAD_DOWN_ID=104
ARTIFACTS_DIR_ID=105
ARTIFACTS_BROWSE_ID=106

SOURCE_ID=110
SOURCE_BROWSE_ID=111
DESTINATION_ID=112
OWNER_ID=113
GROUP_ID=114
MODE_ID=115
VERIFY_UNIVERSAL_ID=116
VERIFY_SIGNED_ID=117
VERIFY_HARDENED_ID=118
VERIFY_TIMESTAMP_ID=119
VERSION_FLAG_ID=120
DESTINATION_MENU_ID=121

# The payload table's hidden index column (1-based, past the three visible ones).
PAYLOAD_INDEX_COLUMN=4

# One id per item of the destination presets menu, so the item that fired says
# which directory was chosen.
PRESET_APPLICATIONS_ID=1211
PRESET_USR_LOCAL_BIN_ID=1212
PRESET_FRAMEWORKS_ID=1213
PRESET_APP_SUPPORT_ID=1214
PRESET_LAUNCHDAEMONS_ID=1215
PRESET_LAUNCHAGENTS_ID=1216
PRESET_PREFPANES_ID=1217

NAME_ID=129
IDENTIFIER_ID=130
VERSION_ID=131
READ_VERSION_ID=132
INSTALL_LOCATION_ID=133
AUTH_ID=134
OVERWRITE_ID=135
RELOCATABLE_ID=136
PREINSTALL_ID=137
POSTINSTALL_ID=139

TITLE_ID=150
MIN_OS_ID=151
READ_MINOS_ID=152
ARCH_ARM64_ID=153
ARCH_X86_64_ID=154
CUSTOMIZE_ID=155
README_ID=156
LICENSE_ID=158
WELCOME_ID=160
CONCLUSION_ID=162
BACKGROUND_ID=164

OUTPUT_DIR_ID=170
PACKAGE_NAME_ID=172
SIGN_ID=173
IDENTITY_PICKER_ID=174

STATUS_ID=220
PROGRESS_ID=221
LOG_ID=222
REVEAL_BTN_ID=223

# --- State directory ----------------------------------------------------------
# Per-window scratch: model.json, doc_path.txt, doc_hash.txt, dirty.txt,
# run.log. Created lazily on first use. (Idiom from lib.notarize.sh.)
state_dir() {
    local dir="${TMPDIR:-/tmp}/packagebuilder-state-${document_uuid}"
    /bin/mkdir -p "$dir"
    printf '%s' "$dir"
}

model_file() {
    printf '%s/model.json' "$(state_dir)"
}

has_model() {
    [ -f "$(model_file)" ]
}

# --- Pasteboard (cross-script flags, keyed by document uuid) ------------------
# From lib.notarize.sh; the key is suffixed here rather than at each call site.
pb_get() {
    local flag_name="$1"
    "$pasteboard_tool" "${flag_name}_${document_uuid}" get 2>/dev/null
}

pb_set() {
    local flag_name="$1" flag_value="$2"
    printf '%s' "$flag_value" | "$pasteboard_tool" "${flag_name}_${document_uuid}" set
}

# --- Window control -----------------------------------------------------------
# set_value, set_property, enable_view, show_view, set_status and show_progress
# are NOT defined here. They are the presentation layer, and there are two
# implementations of it: lib.packagebuilder.window.sh draws in the window,
# lib.packagebuilder.console.sh writes to a terminal for the agent CLI. Every
# frontend sources exactly one of them after this file.
#
# They were defined here until 2026-08-07, and the CLI had to redefine all six
# after sourcing to stop them talking to a window that does not exist. Splitting
# them out is what lets the CLI and the app share the pipeline itself rather
# than the CLI carrying a second copy of it.
#
# The readers below stay here: they take their values from the environment OMC
# set up, so they answer the same way with or without a window.

# Read a view's current value out of the environment. Arguments: view id.
# The caller must have established that the id is numeric - it is interpolated
# into the eval'd text. (The value itself is expanded inside the eval's double
# quotes and is never re-evaluated.)
view_value() {
    local view_id="$1"
    eval "printf '%s' \"\$OMC_ACTIONUI_VIEW_${view_id}_VALUE\""
}

# Escape a value for a JSON string literal. Backslash first, or the backslashes
# the quote escape introduces would be escaped a second time. Used to build the
# options fragment omc_set_property parses - an identity name is user data as
# far as this app is concerned, and one containing a quote would otherwise
# produce a fragment the parser rejects and a picker that silently keeps its
# placeholder.
json_escape() {
    local text="$1"
    text="$(str_replace "$text" '\' '\\')"
    text="$(str_replace "$text" '"' '\"')"
    printf '%s' "$text"
}

# Read one column of a table's selected row out of the environment. Columns are
# 1-based here and 0 means "the whole row, tab-joined" - the opposite base to
# omc_select_row's 0-based row index. Both arguments are interpolated into the
# eval, so callers pass the numeric constants from this file and nothing else.
table_column_value() {
    local view_id="$1" column="$2"
    eval "printf '%s' \"\$OMC_ACTIONUI_TABLE_${view_id}_COLUMN_${column}_VALUE\""
}

# Print "true"/"false" for a "1"/"0" flag. ActionUI's Bool elements accept only
# the strings "true" and "false" through setElementValueFromString; anything
# else, "1" and "0" included, is logged and discarded
# (ActionUI/Common/ActionUIModel.swift, valueType == Bool.self). Reading back
# gives boolValue.description, so the two directions do not use the same words.
bool_str() {
    local flag="$1"
    if [ "$flag" = "1" ]; then printf 'true'; else printf 'false'; fi
}

# --- Log ----------------------------------------------------------------------
# clear_log, append_log and append_log_file are part of the presentation layer
# too - what "the log" is differs between a TextEditor and a terminal - so they
# live in lib.packagebuilder.window.sh and lib.packagebuilder.console.sh beside
# the view wrappers. Both write $(state_dir)/run.log, which is the part the
# pipeline reads back.

# --- Preferences (read/written with plister; from lib.notarize.sh) -----------
prefs_dir="$HOME/Library/Application Support/PackageBuilder"
prefs_file="$prefs_dir/prefs.plist"

prefs_ensure() {
    /bin/mkdir -p "$prefs_dir"
    if [ ! -f "$prefs_file" ]; then
        "$plister" set dict "$prefs_file" /
    fi
}

prefs_get() {
    local pref_name="$1"
    "$plister" get value "$prefs_file" "/$pref_name" 2>/dev/null
}

prefs_set() {
    local pref_name="$1" pref_value="$2"
    prefs_ensure
    "$plister" set string "$pref_value" "$prefs_file" "/$pref_name"
}

# --- Model access -------------------------------------------------------------
# The model is a file and the window is a projection of it (design section 9.1).

# Print a value from the model. Arguments: key path (e.g. /PROJECT/VERSION)
model_get() {
    local key_path="$1"
    "$plister" get value "$(model_file)" "$key_path" 2>/dev/null
}

# Print the plist type at a key path, or nothing when it does not exist.
model_type() {
    local key_path="$1"
    "$plister" get type "$(model_file)" "$key_path" 2>/dev/null
}

# Write a string into the model. Returns plister's status: "set" creates a
# missing leaf, but FAILS when any parent container is absent, so the status is
# the only way to know the value landed. model_normalize makes every container
# exist, and this status is the backstop for anything it missed.
# Arguments: key path, value
model_set() {
    local key_path="$1" new_value="$2"
    "$plister" set string "$new_value" "$(model_file)" "$key_path"
}

# Write a bool into the model. Same status contract as model_set.
# Arguments: key path, "1"/"0"/true/false
model_set_bool() {
    local key_path="$1" flag="$2"
    local stored
    case "$flag" in
        1|true|TRUE|YES) stored=true ;;
        *) stored=false ;;
    esac
    "$plister" set bool "$stored" "$(model_file)" "$key_path"
}

# Print "1" or "0" for a model bool. Arguments: key path
model_get_bool() {
    local key_path="$1"
    case "$(model_get "$key_path")" in
        1|true|TRUE|YES) printf '1' ;;
        *) printf '0' ;;
    esac
}

# Print "true"/"false" for a model bool, ready for a Toggle. Arguments: key path
model_get_bool_str() {
    local key_path="$1"
    bool_str "$(model_get_bool "$key_path")"
}

# Print the element count of a model array (0 when absent). Arguments: key path
model_count() {
    local key_path="$1"
    local element_count="$("$plister" get count "$(model_file)" "$key_path" 2>/dev/null)"
    case "$element_count" in
        ''|*[!0-9]*) element_count=0 ;;
    esac
    printf '%s' "$element_count"
}

# --- Model serialization ------------------------------------------------------
# Every edit is a read-modify-write of the whole model file, and control events
# arrive concurrently - tabbing quickly from one field to the next can start the
# second handler's read before the first has written. plister's write is atomic
# (NSDataWritingAtomic) so the file cannot be corrupted, but an edit can be lost,
# so the read-modify-write is serialized. mkdir is the atomic primitive.
model_lock() {
    local lock_dir="$(state_dir)/model.lock"
    local attempt=0 holder_pid
    while [ "$attempt" -lt 120 ]; do
        if /bin/mkdir "$lock_dir" 2>/dev/null; then
            # Written after the mkdir, so a waiter can briefly see the lock with
            # no pid in it. That reads as "holder unknown", which is the safe
            # answer - the branch below does nothing without a pid.
            printf '%s' "$$" > "$lock_dir/holder.pid"
            return 0
        fi
        # A lock whose holder is gone belongs to a handler that died between
        # taking it and releasing it. The test is liveness, not age: a large
        # drop legitimately holds the lock for many seconds - each item costs a
        # dozen plister calls plus a "file" and a "vtool" - and an age-based
        # break would cut the lock out from under a holder that is still
        # working, which is worse than the wedge it is trying to fix.
        #
        # An age-based break was what this used to attempt, and it never ran at
        # all: BSD find rejects a fractional -mmin ("illegal trailing
        # character") and the error went to /dev/null, so a dead holder wedged
        # every later edit in the window until it was closed. Found in review,
        # 2026-08-06.
        holder_pid="$(/bin/cat "$lock_dir/holder.pid" 2>/dev/null)"
        case "$holder_pid" in
            ''|*[!0-9]*) ;;
            *)
                if ! /bin/kill -0 "$holder_pid" 2>/dev/null; then
                    dbg "model_lock: breaking a lock left by dead pid $holder_pid"
                    /bin/rm -rf "$lock_dir" 2>/dev/null
                fi
                ;;
        esac
        /bin/sleep 0.05
        attempt=$((attempt + 1))
    done
    return 1
}

model_unlock() {
    local lock_dir="$(state_dir)/model.lock"
    /bin/rm -f "$lock_dir/holder.pid" 2>/dev/null
    /bin/rmdir "$lock_dir" 2>/dev/null
    return 0
}

# --- Model shape --------------------------------------------------------------
# Create a missing container. Arguments: parent key path, key or index, dict|array
ensure_container() {
    local parent_path="$1" key="$2" kind="$3"
    local child_path="${parent_path%/}/$key"
    if [ -z "$(model_type "$child_path")" ]; then
        "$plister" insert "$key" "$kind" "$(model_file)" "$parent_path"
    fi
    return 0
}

# Give a missing scalar its default. Arguments: key path, default value
ensure_string() {
    local key_path="$1" default_value="$2"
    if [ -z "$(model_type "$key_path")" ]; then
        model_set "$key_path" "$default_value"
    fi
    return 0
}

ensure_bool() {
    local key_path="$1" default_flag="$2"
    if [ -z "$(model_type "$key_path")" ]; then
        model_set_bool "$key_path" "$default_flag"
    fi
    return 0
}

# Bring a just-loaded model up to the shape every handler assumes.
#
# load_document accepts any file carrying a numeric FORMAT_VERSION, so a
# hand-written, truncated, or older-format project can arrive missing whole
# subtrees. That matters because plister's "set" cannot create intermediate
# containers: writing /DISTRIBUTION/RESOURCES/README into a document with no
# DISTRIBUTION fails, and without this the field would show the typed text while
# the document never received it.
#
# Only containers, defaults for absent scalars, and out-of-range enum values are
# touched - nothing a document actually says is overwritten. The document is
# still marked clean afterwards: what was added is exactly what the window would
# display anyway, and it reaches the file on the next ordinary save.
model_normalize() {
    ensure_container / PROJECT dict
    ensure_container / COMPONENTS array
    if [ -z "$(model_type /COMPONENTS/0)" ]; then
        "$plister" insert 0 dict "$(model_file)" /COMPONENTS
    fi
    ensure_container /COMPONENTS/0 PAYLOAD array
    ensure_container / DISTRIBUTION dict
    ensure_container /DISTRIBUTION RESOURCES dict
    ensure_container /DISTRIBUTION HOST_ARCHITECTURES array
    ensure_container / SIGNING dict

    ensure_string /PROJECT/NAME ""
    ensure_string /PROJECT/VERSION ""
    ensure_string /PROJECT/MIN_OS_VERSION ""
    ensure_string /PROJECT/ARTIFACTS_DIR ""
    ensure_string /PROJECT/OUTPUT_DIR ""
    ensure_string /PROJECT/PACKAGE_NAME '${NAME}_${VERSION}.pkg'
    ensure_string /COMPONENTS/0/IDENTIFIER ""
    ensure_string /COMPONENTS/0/INSTALL_LOCATION "/"
    ensure_string /COMPONENTS/0/PREINSTALL ""
    ensure_string /COMPONENTS/0/POSTINSTALL ""
    ensure_bool /COMPONENTS/0/OVERWRITE_PERMISSIONS 0
    ensure_bool /COMPONENTS/0/RELOCATABLE 0
    ensure_string /DISTRIBUTION/TITLE ""
    ensure_string /DISTRIBUTION/RESOURCES/README ""
    ensure_string /DISTRIBUTION/RESOURCES/LICENSE ""
    ensure_string /DISTRIBUTION/RESOURCES/WELCOME ""
    ensure_string /DISTRIBUTION/RESOURCES/CONCLUSION ""
    ensure_string /DISTRIBUTION/RESOURCES/BACKGROUND ""
    ensure_bool /SIGNING/ENABLED 1
    ensure_string /SIGNING/INSTALLER_IDENTITY ""

    # Enum fields feed Pickers whose value channel is the option tag. A value
    # with no matching tag leaves the Picker on its previous selection, fires no
    # action, and survives into the Distribution XML - so an out-of-range value
    # is replaced by the default here. The planned .pkgproj import produces
    # exactly this case: its AUTHENTICATION is the integer 1, not "Root".
    case "$(model_get /COMPONENTS/0/AUTH)" in
        Root|User) ;;
        1) model_set /COMPONENTS/0/AUTH Root ;;
        *) model_set /COMPONENTS/0/AUTH Root ;;
    esac
    case "$(model_get /DISTRIBUTION/CUSTOMIZE)" in
        never|allow|always) ;;
        *) model_set /DISTRIBUTION/CUSTOMIZE never ;;
    esac

    normalize_payload_entries
    return 0
}

# Give every payload entry the fields the inspector reads and the build writes.
# Same contract as the rest of model_normalize: absent keys get a default,
# present keys are left exactly as the document has them. Without this an entry
# written by hand as {"SOURCE":..,"DESTINATION":..} - which is what the README's
# own example looks like - shows an empty Owner field that cannot be typed into,
# because plister "set" fails on a key whose parent dict it has to invent.
#
# MODE defaults to 0755 rather than 0644: an entry that omitted it came from a
# document that did not care, and every artifact in this workflow so far is an
# executable or a bundle. A plain data file added through the UI gets 0644 from
# guess_mode at the moment it is added, so this default is only ever seen by
# hand-written documents.
normalize_payload_entries() {
    local entry_count="$(model_count /COMPONENTS/0/PAYLOAD)"
    local index=0
    while [ "$index" -lt "$entry_count" ]; do
        ensure_string "/COMPONENTS/0/PAYLOAD/$index/SOURCE" ""
        ensure_string "/COMPONENTS/0/PAYLOAD/$index/DESTINATION" ""
        ensure_string "/COMPONENTS/0/PAYLOAD/$index/OWNER" root
        ensure_string "/COMPONENTS/0/PAYLOAD/$index/GROUP" wheel
        ensure_string "/COMPONENTS/0/PAYLOAD/$index/MODE" 0755
        index=$((index + 1))
    done
    return 0
}

# --- Document state -----------------------------------------------------------
doc_path() {
    local f="$(state_dir)/doc_path.txt"
    [ -f "$f" ] && /bin/cat "$f"
    return 0
}

set_doc_path() {
    local path="$1"
    printf '%s' "$path" > "$(state_dir)/doc_path.txt"
}

# SHA-256 of a file, or empty when it cannot be read.
file_hash() {
    local path="$1"
    [ -f "$path" ] || return 0
    /usr/bin/shasum -a 256 "$path" 2>/dev/null | /usr/bin/awk '{print $1}'
}

store_doc_hash() {
    local path="$1"
    printf '%s' "$(file_hash "$path")" > "$(state_dir)/doc_hash.txt"
}

stored_doc_hash() {
    local f="$(state_dir)/doc_hash.txt"
    [ -f "$f" ] && /bin/cat "$f"
    return 0
}

is_dirty() {
    local f="$(state_dir)/dirty.txt"
    [ -f "$f" ] || return 1
    [ "$(/bin/cat "$f")" = "1" ]
}

mark_dirty() {
    printf '1' > "$(state_dir)/dirty.txt"
    refresh_window_title
}

mark_clean() {
    printf '0' > "$(state_dir)/dirty.txt"
    refresh_window_title
}

# Set the window title from the document path, or "Untitled" for a new one.
# setTitleWithRepresentedFilename: gives the window its proxy icon and the
# standard document title menu but says nothing about unsaved changes, so
# setDocumentEdited: carries that; an unsaved document has no file to represent
# and carries the edited state in the title text instead.
refresh_window_title() {
    local p="$(doc_path)"
    local edited=0
    is_dirty && edited=1
    if [ -n "$p" ]; then
        "$dialog_tool" "$document_uuid" omc_window omc_invoke \
            setTitleWithRepresentedFilename: "$p"
        "$dialog_tool" "$document_uuid" omc_window omc_invoke \
            setDocumentEdited: "$edited"
    elif [ "$edited" = "1" ]; then
        "$dialog_tool" "$document_uuid" omc_window "Untitled - Edited"
    else
        "$dialog_tool" "$document_uuid" omc_window "Untitled"
    fi
    return 0
}

document_name() {
    local p="$(doc_path)"
    if [ -n "$p" ]; then
        /usr/bin/basename "$p"
    else
        printf 'Untitled'
    fi
}

# --- Loading and saving -------------------------------------------------------
# Start a new empty document in this window's state directory.
new_document() {
    /bin/cp "$new_document_template" "$(model_file)" || return 1
    set_doc_path ""
    printf '' > "$(state_dir)/doc_hash.txt"
    mark_clean
    return 0
}

# Load a document from disk into the model. Arguments: path.
# Returns non-zero when the file is not a readable PackageBuilder project - a
# foreign or malformed JSON file is rejected before it can half-replace the
# model, so a failed open leaves the window showing what it showed before.
#
# The document is staged as .json before plister sees it. plister decides
# between JSON and plist by file extension alone, and ".pkgbuilderproj" is
# neither, so reading the document in place fails with no useful error.
load_document() {
    local path="$1"
    [ -f "$path" ] || return 1
    local incoming="$(state_dir)/incoming.json"
    /bin/rm -f "$incoming"
    /bin/cp "$path" "$incoming" || return 1
    local format_version="$("$plister" get value "$incoming" /FORMAT_VERSION 2>/dev/null)"
    case "$format_version" in
        ''|*[!0-9]*) /bin/rm -f "$incoming"; return 1 ;;
    esac
    /bin/mv -f "$incoming" "$(model_file)" || return 1
    model_normalize
    set_doc_path "$path"
    store_doc_hash "$path"
    mark_clean
    return 0
}

# Write the model to a path and adopt it as the document. Prints the path
# actually written and returns 0 only when the document really is on disk.
# Arguments: path
save_document() {
    local dest="$1"
    case "$dest" in
        *.pkgbuilderproj) ;;
        *) dest="${dest}.pkgbuilderproj" ;;
    esac
    # A destination that exists as something other than a plain file must be
    # refused here: "mv -f file dir" moves the file *into* the directory and
    # returns 0, which would report success while the document went somewhere
    # else entirely and the window went clean.
    if [ -e "$dest" ] && [ ! -f "$dest" ]; then
        return 1
    fi
    local dir="$(/usr/bin/dirname "$dest")"
    local base="$(/usr/bin/basename "$dest")"
    if [ ! -d "$dir" ]; then
        /bin/mkdir -p "$dir" || return 1
    fi
    # Write through a temp file in the destination directory and rename, so an
    # interrupted save cannot leave a truncated project where a working one was.
    # The pid keeps two windows saving to one destination from sharing a temp.
    local tmp="$dir/.${base}.$$.pbsaving"
    /bin/rm -f "$tmp"
    if ! /bin/cp "$(model_file)" "$tmp"; then
        /bin/rm -f "$tmp"
        return 1
    fi
    if ! /bin/mv -f "$tmp" "$dest"; then
        /bin/rm -f "$tmp"
        return 1
    fi
    # Nothing below may report success without a readable file at the
    # destination: an empty hash would also disable external-change detection
    # for the rest of the session.
    if [ ! -f "$dest" ] || [ -z "$(file_hash "$dest")" ]; then
        return 1
    fi
    set_doc_path "$dest"
    store_doc_hash "$dest"
    mark_clean
    printf '%s' "$dest"
    return 0
}

# --- Projecting the model into the window ------------------------------------
# Push every model field into its control. Guarded by the loading flag so a
# programmatic write cannot be mistaken for a user edit by field.changed.
push_model_to_window() {
    # The flag holds the time it was set, so a handler killed mid-push cannot
    # latch it on and silently swallow every later edit (see loading_in_progress).
    pb_set pb_loading "$(/bin/date '+%s')"

    set_value "$ARTIFACTS_DIR_ID" "$(model_get /PROJECT/ARTIFACTS_DIR)"
    set_value "$NAME_ID" "$(model_get /PROJECT/NAME)"
    set_value "$IDENTIFIER_ID" "$(model_get /COMPONENTS/0/IDENTIFIER)"
    set_value "$VERSION_ID" "$(model_get /PROJECT/VERSION)"
    set_value "$INSTALL_LOCATION_ID" "$(model_get /COMPONENTS/0/INSTALL_LOCATION)"
    set_value "$AUTH_ID" "$(model_get /COMPONENTS/0/AUTH)"
    set_value "$OVERWRITE_ID" "$(model_get_bool_str /COMPONENTS/0/OVERWRITE_PERMISSIONS)"
    set_value "$RELOCATABLE_ID" "$(model_get_bool_str /COMPONENTS/0/RELOCATABLE)"
    set_value "$PREINSTALL_ID" "$(model_get /COMPONENTS/0/PREINSTALL)"
    set_value "$POSTINSTALL_ID" "$(model_get /COMPONENTS/0/POSTINSTALL)"

    set_value "$TITLE_ID" "$(model_get /DISTRIBUTION/TITLE)"
    set_value "$MIN_OS_ID" "$(model_get /PROJECT/MIN_OS_VERSION)"
    set_value "$ARCH_ARM64_ID" "$(bool_str "$(has_architecture arm64)")"
    set_value "$ARCH_X86_64_ID" "$(bool_str "$(has_architecture x86_64)")"
    set_value "$CUSTOMIZE_ID" "$(model_get /DISTRIBUTION/CUSTOMIZE)"
    set_value "$README_ID" "$(model_get /DISTRIBUTION/RESOURCES/README)"
    set_value "$LICENSE_ID" "$(model_get /DISTRIBUTION/RESOURCES/LICENSE)"
    set_value "$WELCOME_ID" "$(model_get /DISTRIBUTION/RESOURCES/WELCOME)"
    set_value "$CONCLUSION_ID" "$(model_get /DISTRIBUTION/RESOURCES/CONCLUSION)"
    set_value "$BACKGROUND_ID" "$(model_get /DISTRIBUTION/RESOURCES/BACKGROUND)"

    set_value "$OUTPUT_DIR_ID" "$(model_get /PROJECT/OUTPUT_DIR)"
    set_value "$PACKAGE_NAME_ID" "$(model_get /PROJECT/PACKAGE_NAME)"
    set_value "$SIGN_ID" "$(model_get_bool_str /SIGNING/ENABLED)"

    # A freshly opened document starts on its first payload row, so the
    # inspector shows something rather than a column of disabled fields.
    if [ "$(payload_count)" -gt 0 ]; then
        repopulate_payload 0
    else
        repopulate_payload ""
    fi
    enable_view "$PAYLOAD_ADD_ID" 1
    # The Actions menu is enabled as a whole once there is a document; the items
    # belonging to later phases carry their own "disabled" in the window JSON.
    enable_view "$ACTIONS_MENU_ID" 1
    enable_view "$BUILD_BTN_ID" 1

    # The picker's options come from the keychain, so they are filled in here
    # rather than declared in the window JSON. This also selects the identity
    # the document names, which is why it runs inside the loading guard.
    refresh_identity_picker

    # Both start off: Reveal has nothing to reveal until a build succeeds, and
    # Notarize has nothing to hand over.
    show_view "$REVEAL_BTN_ID" 0
    enable_view "$NOTARIZE_BTN_ID" 0

    pb_set pb_loading ""
    return 0
}

# Succeed while a push_model_to_window is in flight. The flag carries the epoch
# second it was set; a value older than the window below is treated as debris
# from a handler that died rather than as a push still running, because latching
# it on would make every later edit vanish with no symptom.
loading_in_progress() {
    local flag="$(pb_get pb_loading)"
    case "$flag" in
        ''|*[!0-9]*) return 1 ;;
    esac
    local now="$(/bin/date '+%s')"
    [ "$((now - flag))" -lt 10 ]
}

# Print "1" when an architecture is listed in DISTRIBUTION/HOST_ARCHITECTURES.
# Arguments: architecture name
has_architecture() {
    local wanted_arch="$1"
    local arch_count="$(model_count /DISTRIBUTION/HOST_ARCHITECTURES)"
    local index=0
    while [ "$index" -lt "$arch_count" ]; do
        if [ "$(model_get "/DISTRIBUTION/HOST_ARCHITECTURES/$index")" = "$wanted_arch" ]; then
            printf '1'
            return 0
        fi
        index=$((index + 1))
    done
    printf '0'
}

# Rewrite HOST_ARCHITECTURES from the two toggles' states. The array is replaced
# wholesale rather than edited in place, so the stored order is always the
# declared one and a toggled-off architecture cannot survive as a stale element.
# Returns non-zero if any step failed, so a caller does not mark a document
# dirty for an edit that never landed.
# Arguments: arm64 flag ("1"/"0"), x86_64 flag ("1"/"0")
set_architectures() {
    local want_arm64="$1" want_x86_64="$2"
    local model="$(model_file)"
    "$plister" remove "$model" /DISTRIBUTION/HOST_ARCHITECTURES 2>/dev/null
    "$plister" set array "$model" /DISTRIBUTION/HOST_ARCHITECTURES || return 1
    if [ "$want_arm64" = "1" ]; then
        "$plister" append string arm64 "$model" /DISTRIBUTION/HOST_ARCHITECTURES || return 1
    fi
    if [ "$want_x86_64" = "1" ]; then
        "$plister" append string x86_64 "$model" /DISTRIBUTION/HOST_ARCHITECTURES || return 1
    fi
    return 0
}

# Fill the payload table from the model. Three visible columns plus a hidden
# fourth carrying the item's index into COMPONENTS/0/PAYLOAD, per design 5.2.
# getElementColumnCount counts the data columns, hidden ones included, so the
# index comes back as $OMC_ACTIONUI_TABLE_100_COLUMN_4_VALUE on selection.
# Flatten one value for one table cell.
#
# Rows are tab-joined and newline-separated, so a tab in a path would add a
# field and shift the hidden index column onto MODE - which is numeric, passes
# the digit check, fails the range check, and clears the selection. The row
# could then never be selected, and so never removed or repaired through the
# UI. A newline would split the feed into a phantom row. Both are legal in an
# APFS filename. This is display only; the model keeps the real string.
table_cell() {
    local raw_value="$1"
    printf '%s' "$raw_value" | /usr/bin/tr '\t\n' '  '
}

populate_payload_table() {
    local entry_count="$(model_count /COMPONENTS/0/PAYLOAD)"
    local index=0
    # Set once per iteration, so they carry their own "local" up here.
    local source destination mode
    {
        while [ "$index" -lt "$entry_count" ]; do
            source="$(table_cell "$(model_get "/COMPONENTS/0/PAYLOAD/$index/SOURCE")")"
            destination="$(table_cell "$(model_get "/COMPONENTS/0/PAYLOAD/$index/DESTINATION")")"
            mode="$(table_cell "$(model_get "/COMPONENTS/0/PAYLOAD/$index/MODE")")"
            printf '%s\t%s\t%s\t%s\n' "$source" "$destination" "$mode" "$index"
            index=$((index + 1))
        done
    } | "$dialog_tool" "$document_uuid" "$PAYLOAD_TABLE_ID" omc_table_set_rows_from_stdin
}

# ==============================================================================
# Payload (design sections 4.1 to 4.4 and 5.3)
# ==============================================================================

payload_count() {
    model_count /COMPONENTS/0/PAYLOAD
}

# Print the model key path of one field of one payload entry.
# Arguments: index, field (may itself contain a slash, e.g. VERIFY/SIGNED_BY)
payload_key() {
    local entry_index="$1" field="$2"
    printf '/COMPONENTS/0/PAYLOAD/%s/%s' "$entry_index" "$field"
}

payload_get() {
    local entry_index="$1" field="$2"
    model_get "$(payload_key "$entry_index" "$field")"
}

payload_set() {
    local entry_index="$1" field="$2" new_value="$3"
    model_set "$(payload_key "$entry_index" "$field")" "$new_value"
}

# --- Selection ----------------------------------------------------------------
# Which row the inspector is showing, as an index into COMPONENTS/0/PAYLOAD.
# Prints nothing when there is no selection. The stored value is re-checked
# against the current count on every read: a remove or an external reload can
# shrink the array under a selection that was valid when it was made, and every
# caller would otherwise address a payload entry that no longer exists.
selected_payload_index() {
    local entry_index="$(pb_get pb_selected_payload_index)"
    case "$entry_index" in
        ''|*[!0-9]*) return 0 ;;
    esac
    local entry_count="$(payload_count)"
    [ "$entry_index" -lt "$entry_count" ] || return 0
    printf '%s' "$entry_index"
}

set_selected_payload_index() {
    local entry_index="$1"
    pb_set pb_selected_payload_index "$entry_index"
}

# Select a row in the table. omc_select_row takes a 0-based row index, which is
# the one place in this API where the base differs from a Picker's 1-based
# option index - and the two appear a few lines apart in this file. Rows are
# written in model order, so the row index and the payload index are the same
# number; this helper is the only place that relies on that.
# Arguments: payload index
select_payload_row() {
    local entry_index="$1"
    "$dialog_tool" "$document_uuid" "$PAYLOAD_TABLE_ID" omc_select_row "$entry_index"
}

deselect_payload_row() {
    "$dialog_tool" "$document_uuid" "$PAYLOAD_TABLE_ID" omc_deselect
}

# --- Paths (design 4.2, 4.3, 4.4) ---------------------------------------------
# Absolute directory containing the document, or nothing when it is unsaved.
document_dir() {
    local p="$(doc_path)"
    [ -n "$p" ] || return 0
    /usr/bin/dirname "$p"
}

# Replace every occurrence of a literal needle in a string.
#
# Not sed. Substitution here is textual and a bad value corrupts output silently
# rather than loudly: "&" in a sed replacement means "the matched text", which is
# how makepkg.sh once produced a readme reading "replay 2__VERSION__2" and exited
# 0 (design 4.4). Parameter expansion has no such metacharacters.
# Arguments: haystack, needle, replacement
str_replace() {
    local haystack="$1" needle="$2" replacement="$3"
    local result=""
    # Set only in the matching branch of the loop below.
    local head
    [ -n "$needle" ] || { printf '%s' "$haystack"; return 0; }
    while [ -n "$haystack" ]; do
        case "$haystack" in
            *"$needle"*)
                head="${haystack%%"$needle"*}"
                result="$result$head$replacement"
                haystack="${haystack#*"$needle"}"
                ;;
            *)
                result="$result$haystack"
                haystack=""
                ;;
        esac
    done
    printf '%s' "$result"
}

# Expand every token except ${ARTIFACTS_DIR}. Kept separate because resolving
# ARTIFACTS_DIR itself runs through an expansion, and a single function would
# recurse forever on a document whose ARTIFACTS_DIR contains the token.
expand_basic_tokens() {
    local text="$1"
    case "$text" in
        *'${'*) ;;
        *) printf '%s' "$text"; return 0 ;;
    esac
    text="$(str_replace "$text" '${NAME}' "$(model_get /PROJECT/NAME)")"
    text="$(str_replace "$text" '${VERSION}' "$(model_get /PROJECT/VERSION)")"
    # ${DATE} is fixed once per build; outside a build it is today.
    text="$(str_replace "$text" '${DATE}' "${PB_BUILD_DATE:-$(/bin/date '+%Y-%m-%d')}")"
    text="$(str_replace "$text" '${PROJECT_DIR}' "$(document_dir)")"
    printf '%s' "$text"
}

# Make a path absolute: absolute stays, ~ expands, anything else is relative to
# the directory containing the document (design 4.2). A relative path in an
# unsaved document has no base to resolve against and is returned unchanged, so
# callers see a path that does not exist rather than one resolved against the
# working directory OMC happened to hand the handler.
absolutize() {
    local path="$1" base_dir="$2"
    case "$path" in
        '') return 0 ;;
        /*) printf '%s' "$path" ;;
        '~') printf '%s' "$HOME" ;;
        '~/'*) printf '%s%s' "$HOME" "${path#\~}" ;;
        *)
            if [ -n "$base_dir" ]; then
                printf '%s/%s' "$base_dir" "$path"
            else
                printf '%s' "$path"
            fi
            ;;
    esac
}

# Absolute PROJECT.ARTIFACTS_DIR, or nothing when it is unset. Optional by
# design (4.3): a document may use absolute or document-relative sources and
# never set it.
artifacts_dir_abs() {
    local raw="$(model_get /PROJECT/ARTIFACTS_DIR)"
    [ -n "$raw" ] || return 0
    local expanded="$(expand_basic_tokens "$raw")"
    [ -n "$expanded" ] || return 0
    absolutize "$expanded" "$(document_dir)"
}

# Succeed when a stored value uses ${ARTIFACTS_DIR} and there is no artifacts
# folder to resolve it against.
#
# This is the case design 4.3 calls a precondition failure rather than a silent
# empty string, and the reason is worth keeping in view: a source stored as
# ${ARTIFACTS_DIR}/usr/local/bin/replay collapses to /usr/local/bin/replay,
# which very likely *exists* - it is the previously installed copy. Reading a
# version from it would report the version of the last release and call it the
# new one, which is precisely the stale-artifact mistake the whole verify stage
# exists to catch. Found in review, 2026-08-06.
uses_unset_artifacts_dir() {
    local raw="$1"
    case "$raw" in
        *'${ARTIFACTS_DIR}'*) ;;
        *) return 1 ;;
    esac
    [ -z "$(artifacts_dir_abs)" ]
}

# Expand all five placeholders of design 4.4. Purely textual: callers that must
# not accept an empty ${ARTIFACTS_DIR} ask uses_unset_artifacts_dir first, so
# this stays usable for the name and destination fields, where the token is not
# expected in the first place.
expand_tokens() {
    local raw_text="$1"
    local text="$(expand_basic_tokens "$raw_text")"
    case "$text" in
        *'${ARTIFACTS_DIR}'*)
            text="$(str_replace "$text" '${ARTIFACTS_DIR}' "$(artifacts_dir_abs)")"
            ;;
    esac
    printf '%s' "$text"
}

# Turn a stored path into the absolute path it names on this machine. Prints
# nothing and returns non-zero when the value names an artifacts folder that is
# not set, so a caller cannot mistake the collapsed path for a real one.
resolve_stored_path() {
    local stored="$1"
    [ -n "$stored" ] || return 1
    if uses_unset_artifacts_dir "$stored"; then
        return 1
    fi
    local expanded="$(expand_tokens "$stored")"
    [ -n "$expanded" ] || return 1
    absolutize "$expanded" "$(document_dir)"
}

# Succeed when child is at or below parent. Both are compared literally: the
# case patterns interpolate parent, so a parent containing a glob character
# would otherwise match more than itself.
path_is_under() {
    local child="$1" parent="$2"
    [ -n "$parent" ] || return 1
    # The root is the parent of every absolute path, and it has to be handled
    # before the trailing slash is stripped - "/" would otherwise become the
    # empty string, which is the parent of nothing. The default install
    # location is "/", so this is the common case rather than the exotic one.
    if [ "$parent" = "/" ]; then
        case "$child" in
            /*) return 0 ;;
        esac
        return 1
    fi
    parent="${parent%/}"
    case "$child" in
        "$parent") return 0 ;;
        "$parent"/*) return 0 ;;
    esac
    return 1
}

# Canonicalize a path, or print it unchanged when it cannot be resolved (it
# does not exist yet, or a component is unreadable).
canonical_or_self() {
    local path="$1"
    [ -n "$path" ] || return 0
    local canonical="$(canonical_path "$path")"
    if [ -n "$canonical" ]; then printf '%s' "$canonical"; else printf '%s' "$path"; fi
}

# Print a path relative to a directory when it is at or below it, and return
# non-zero when it is not.
#
# Both sides are canonicalized first, and that is load-bearing rather than
# tidiness: an artifact path has been through canonical_path while the document
# path is whatever the open panel handed over, and on macOS that is exactly the
# difference between /var/folders/... and /private/var/folders/... - one
# directory under two names, which a literal prefix test calls unrelated. The
# symptom would be a source stored as an absolute path in a project that sits
# right next to it, so the project would stop being portable with no message.
relative_to() {
    local path="$1" base_dir="$2"
    local canonical_path_value="$(canonical_or_self "$path")"
    local canonical_base="$(canonical_or_self "$base_dir")"
    [ -n "$canonical_path_value" ] || return 1
    [ -n "$canonical_base" ] || return 1
    path_is_under "$canonical_path_value" "$canonical_base" || return 1
    local relative="${canonical_path_value#"${canonical_base%/}"}"
    relative="${relative#/}"
    [ -n "$relative" ] || return 1
    printf '%s' "$relative"
    return 0
}

# Turn an absolute path into the form a non-payload field should store: relative
# to the document's folder when it is below it, else absolute.
#
# ${ARTIFACTS_DIR} is deliberately not consulted. That folder holds build
# products; a readme, a license or an install script is part of the project and
# lives with it, so writing one as ${ARTIFACTS_DIR}-relative would tie a file
# that never moves to the one field that changes every release.
store_document_relative_path() {
    local absolute_path="$1"
    local relative
    [ -n "$absolute_path" ] || return 0
    relative="$(relative_to "$absolute_path" "$(document_dir)")" && {
        printf '%s' "$relative"
        return 0
    }
    printf '%s' "$absolute_path"
}

# Record a browsed path into the document field a control edits, and echo it
# back into that control. Shared by every Browse button on the Package,
# Distribution and Output tabs, all of which do exactly this.
# Arguments: text field view id, chosen path
store_browsed_path() {
    local view_id="$1" chosen="$2"
    [ -n "$chosen" ] || return 0
    has_model || return 0

    local key_path="$(field_key_path "$view_id")"
    if [ -z "$key_path" ]; then
        dbg "store_browsed_path: view $view_id is not in the field map"
        return 0
    fi

    if ! model_lock; then
        set_status "Busy - that path was not recorded, please try again"
        return 0
    fi

    local stored="$(store_document_relative_path "$(canonical_or_self "$chosen")")"
    if [ "$stored" = "$(model_get "$key_path")" ]; then
        model_unlock
        return 0
    fi
    if ! model_set "$key_path" "$stored"; then
        model_unlock
        set_status "Could not record that path"
        return 0
    fi

    mark_dirty
    # The echo back into the control is a programmatic write like any other.
    local previous_flag="$(pb_get pb_loading)"
    pb_set pb_loading "$(/bin/date '+%s')"
    set_value "$view_id" "$stored"
    pb_set pb_loading "$previous_flag"
    model_unlock
    return 0
}

# Turn an absolute path into the form the document should store: relative to
# ${ARTIFACTS_DIR} when it is below it, else relative to the document's folder
# when it is below that, else absolute (design 4.2, 4.3).
store_path() {
    local absolute_path="$1"
    # Declared apart from its assignments on purpose: "local" is itself a
    # command, so "local relative=$(...)" would make the "&&" below test local's
    # status, which is always 0, and every path would come out absolute.
    local relative
    [ -n "$absolute_path" ] || return 0
    relative="$(relative_to "$absolute_path" "$(artifacts_dir_abs)")" && {
        printf '${ARTIFACTS_DIR}/%s' "$relative"
        return 0
    }
    relative="$(relative_to "$absolute_path" "$(document_dir)")" && {
        printf '%s' "$relative"
        return 0
    }
    printf '%s' "$absolute_path"
}

# --- Looking at an artifact ---------------------------------------------------
# Print the path of a bundle's Info.plist, or nothing when the argument is not a
# bundle.
#
# Two layouts, and the second is the one that bites. An .app, .prefPane,
# .qlgenerator, .mdimporter or .saver keeps its Info.plist under Contents. A
# .framework is a *versioned* bundle and keeps it under Versions/<v>/Resources
# with no Contents directory at all - so a Contents-only test reports that a
# framework is not a bundle, which costs it mode 0755, all four verify toggles,
# and its version read, while the destination guess still works from the
# extension and makes the result look deliberate. Design 5.3 lists
# Foo.framework explicitly. Found in review, 2026-08-06.
bundle_info_plist() {
    local bundle_path="$1"
    # Set by the "for" below.
    local candidate
    [ -d "$bundle_path" ] || return 0
    if [ -f "$bundle_path/Contents/Info.plist" ]; then
        printf '%s/Contents/Info.plist' "$bundle_path"
        return 0
    fi
    # Current first, so a framework with several versions answers for the one
    # it actually publishes.
    for candidate in "$bundle_path"/Versions/Current/Resources/Info.plist \
                     "$bundle_path"/Versions/*/Resources/Info.plist \
                     "$bundle_path"/Resources/Info.plist; do
        if [ -f "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 0
}

is_bundle() {
    local bundle_path="$1"
    [ -n "$(bundle_info_plist "$bundle_path")" ]
}

# Print a bundle's main executable path, or nothing when the argument is not a
# bundle or names an executable that is not there.
bundle_executable() {
    local bundle_path="$1"
    # Set by the "for" below.
    local candidate
    local info_plist="$(bundle_info_plist "$bundle_path")"
    [ -n "$info_plist" ] || return 0
    local executable_name="$("$plister" get value "$info_plist" /CFBundleExecutable 2>/dev/null)"
    if [ -z "$executable_name" ]; then
        executable_name="$(/usr/bin/basename "$bundle_path")"
        executable_name="${executable_name%.*}"
    fi
    # Contents/MacOS for an ordinary bundle; for a framework the executable sits
    # in the version directory beside Resources rather than under a MacOS
    # folder, which is the directory two levels up from the Info.plist.
    local version_dir="$(/usr/bin/dirname "$(/usr/bin/dirname "$info_plist")")"
    for candidate in "$bundle_path/Contents/MacOS/$executable_name" \
                     "$version_dir/$executable_name" \
                     "$bundle_path/$executable_name"; do
        if [ -f "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 0
}

# Succeed when the path is a Mach-O file. "file -b" is used rather than a magic
# number read because it reports fat binaries and thin ones alike.
is_macho() {
    local path="$1"
    # Declared apart from its assignment: the "|| return 1" has to test "file",
    # and "local description=$(...)" would test local instead.
    local description
    [ -f "$path" ] || return 1
    description="$(/usr/bin/file -b "$path" 2>/dev/null)" || return 1
    case "$description" in
        *Mach-O*) return 0 ;;
    esac
    return 1
}

# Print the executable this payload entry's checks apply to: the file itself for
# a bare binary, the main executable for a bundle, nothing for anything else.
# This is what decides whether the verify toggles start on (design 5.3) and what
# a version read runs.
artifact_executable() {
    local artifact_path="$1"
    # Set only on the bundle branch.
    local executable
    if is_bundle "$artifact_path"; then
        executable="$(bundle_executable "$artifact_path")"
        if [ -n "$executable" ] && is_macho "$executable"; then
            printf '%s' "$executable"
        fi
        return 0
    fi
    if is_macho "$artifact_path"; then
        printf '%s' "$artifact_path"
    fi
    return 0
}

# Where a dropped or browsed artifact installs, by its kind (design 5.3).
# Arguments: absolute source path, fallback destination directory
guess_destination() {
    local artifact_path="$1" fallback_dir="$2"
    local base_name="$(/usr/bin/basename "$artifact_path")"
    case "$base_name" in
        *.app)         printf '/Applications/%s' "$base_name"; return 0 ;;
        *.framework)   printf '/Library/Frameworks/%s' "$base_name"; return 0 ;;
        *.prefPane)    printf '/Library/PreferencePanes/%s' "$base_name"; return 0 ;;
        *.qlgenerator) printf '/Library/QuickLook/%s' "$base_name"; return 0 ;;
        *.mdimporter)  printf '/Library/Spotlight/%s' "$base_name"; return 0 ;;
        *.saver)       printf '/Library/Screen Savers/%s' "$base_name"; return 0 ;;
    esac
    if [ -f "$artifact_path" ] && [ -x "$artifact_path" ]; then
        case "$base_name" in
            *.*) ;;
            *) printf '/usr/local/bin/%s' "$base_name"; return 0 ;;
        esac
    fi
    if [ -n "$fallback_dir" ]; then
        printf '%s/%s' "${fallback_dir%/}" "$base_name"
        return 0
    fi
    # No guess. The entry is added with an empty destination and the build's
    # preconditions refuse to run until it is filled in, rather than inventing
    # one silently (design 5.3).
    return 0
}

guess_mode() {
    local artifact_path="$1"
    if is_bundle "$artifact_path" || { [ -f "$artifact_path" ] && [ -x "$artifact_path" ]; }; then
        printf '0755'
    else
        printf '0644'
    fi
}

# Directory of the last payload entry's destination, for the "anything else"
# row of the destination table. Prints nothing when there is no entry yet or
# the last one has no destination.
last_destination_dir() {
    local entry_count="$(payload_count)"
    [ "$entry_count" -gt 0 ] || return 0
    local destination="$(model_get "/COMPONENTS/0/PAYLOAD/$((entry_count - 1))/DESTINATION")"
    [ -n "$destination" ] || return 0
    case "$destination" in
        /*) ;;
        *) return 0 ;;
    esac
    /usr/bin/dirname "$destination"
}

# --- Reading a version out of an artifact (design 4.5) ------------------------
# Print the first version-looking token in a string, or nothing.
first_version_token() {
    local text="$1"
    printf '%s' "$text" \
        | /usr/bin/grep -oE '[0-9]+(\.[0-9]+)+([0-9A-Za-z.+_-]*)?' 2>/dev/null \
        | /usr/bin/head -n 1
}

# Print the version an artifact reports about itself, or nothing.
# Arguments: absolute artifact path, version flag ("" = do not run it)
#
# A bundle answers from its Info.plist. A bare executable only answers when the
# entry carries a version flag, because the alternative is running an arbitrary
# binary the user has not asked us to run.
artifact_version() {
    local artifact_path="$1" version_flag="$2"
    local info_plist="$(bundle_info_plist "$artifact_path")"
    if [ -n "$info_plist" ]; then
        "$plister" get value "$info_plist" /CFBundleShortVersionString 2>/dev/null
        return 0
    fi
    [ -n "$version_flag" ] || return 0
    [ -f "$artifact_path" ] && [ -x "$artifact_path" ] || return 0
    # Every capture of a possibly-failing command ends in "|| true": a tool that
    # exits non-zero must produce an empty version that the caller reports, not
    # a status that ends the handler (design 7). stdin is closed as well, so a
    # tool that reads it when given an unknown flag cannot leave the handler
    # waiting forever on a user who has no terminal to type into.
    local first_line="$("$artifact_path" "$version_flag" </dev/null 2>/dev/null | /usr/bin/head -n 1 || true)"
    first_version_token "$first_line"
}

# Print the minimum macOS version an artifact declares, or nothing.
artifact_minos() {
    local artifact_path="$1"
    local info_plist="$(bundle_info_plist "$artifact_path")"
    if [ -n "$info_plist" ]; then
        "$plister" get value "$info_plist" /LSMinimumSystemVersion 2>/dev/null
        return 0
    fi
    local executable="$(artifact_executable "$artifact_path")"
    [ -n "$executable" ] || return 0
    local minos="$(/usr/bin/xcrun vtool -show-build "$executable" 2>/dev/null | /usr/bin/awk '/minos/ {print $2; exit}' || true)"
    printf '%s' "$minos"
}

# --- Editing the payload array ------------------------------------------------
# Create the VERIFY dict of an entry when it has none. plister "set" cannot
# create an intermediate container (design 12.3), so every write below VERIFY
# has to be preceded by this.
ensure_payload_verify() {
    local entry_index="$1"
    if [ -z "$(model_type "$(payload_key "$entry_index" VERIFY)")" ]; then
        "$plister" insert VERIFY dict "$(model_file)" "/COMPONENTS/0/PAYLOAD/$entry_index" || return 1
    fi
    return 0
}

# Print an entry's architecture list, one name per line.
payload_archs_get() {
    local entry_index="$1"
    local arch_count="$(model_count "$(payload_key "$entry_index" VERIFY/ARCHITECTURES)")"
    local index=0
    while [ "$index" -lt "$arch_count" ]; do
        printf '%s\n' "$(payload_get "$entry_index" "VERIFY/ARCHITECTURES/$index")"
        index=$((index + 1))
    done
    return 0
}

# Replace an entry's architecture list with a newline-separated one. The array
# is rewritten wholesale rather than edited, so a removed name cannot survive as
# a stale element.
payload_archs_set() {
    local entry_index="$1" arch_list="$2"
    # Set by the "for" below.
    local arch
    local model="$(model_file)"
    local key="$(payload_key "$entry_index" VERIFY/ARCHITECTURES)"
    ensure_payload_verify "$entry_index" || return 1
    "$plister" remove "$model" "$key" 2>/dev/null
    "$plister" set array "$model" "$key" || return 1
    [ -n "$arch_list" ] || return 0
    # Split on newlines through the positional parameters rather than a pipe:
    # a "printf | while read" loop runs in a subshell, so a failed append would
    # report success. Architecture names are bare tokens, so word splitting is
    # safe here in a way it would not be for a path. The function's own
    # arguments were captured into locals above, so "set --" is free to reuse
    # the positional parameters.
    local saved_ifs="$IFS"
    IFS='
'
    set -- $arch_list
    IFS="$saved_ifs"
    for arch in "$@"; do
        [ -n "$arch" ] || continue
        "$plister" append string "$arch" "$model" "$key" || return 1
    done
    return 0
}

# Print "1" when an entry asks for both architectures.
#
# This is a projection, not the whole truth: the checkbox can say "both" or
# "none" and the document can say anything. Everything that has to preserve an
# entry's real list - reordering, most obviously - goes through
# payload_archs_get/set instead.
payload_universal_get() {
    local entry_index="$1"
    # Set by the "for" below.
    local arch
    local has_x86=0 has_arm=0
    local saved_ifs="$IFS"
    IFS='
'
    set -- $(payload_archs_get "$entry_index")
    IFS="$saved_ifs"
    for arch in "$@"; do
        case "$arch" in
            x86_64) has_x86=1 ;;
            arm64) has_arm=1 ;;
        esac
    done
    if [ "$has_x86" = "1" ] && [ "$has_arm" = "1" ]; then printf '1'; else printf '0'; fi
}

# Arguments: index, "1"/"0"
payload_universal_set() {
    local entry_index="$1" universal="$2"
    if [ "$universal" = "1" ]; then
        payload_archs_set "$entry_index" 'x86_64
arm64'
    else
        payload_archs_set "$entry_index" ""
    fi
}

# The Developer ID checkbox and VERIFY.SIGNED_BY are the same setting seen two
# ways. The document stores the authority the signature must carry, which may be
# a full identity a project pinned by hand; the checkbox can only say whether
# there is one. So the checkbox reads as on whenever the field is non-empty, and
# turning it on fills in the certificate class rather than a specific team - the
# broadest assertion that still means "signed with a Developer ID".
DEFAULT_SIGNED_BY="Developer ID Application"

payload_signed_get() {
    local entry_index="$1"
    if [ -n "$(payload_get "$entry_index" VERIFY/SIGNED_BY)" ]; then printf '1'; else printf '0'; fi
}

payload_signed_set() {
    local entry_index="$1" signed="$2"
    ensure_payload_verify "$entry_index" || return 1
    if [ "$signed" = "1" ]; then
        # Turning it back on must not discard a pinned identity that is still
        # there, so an existing value wins over the default.
        if [ -z "$(payload_get "$entry_index" VERIFY/SIGNED_BY)" ]; then
            payload_set "$entry_index" VERIFY/SIGNED_BY "$DEFAULT_SIGNED_BY" || return 1
        fi
    else
        payload_set "$entry_index" VERIFY/SIGNED_BY "" || return 1
    fi
    return 0
}

payload_bool_get() {
    local entry_index="$1" field="$2"
    case "$(payload_get "$entry_index" "$field")" in
        1|true|TRUE|YES) printf '1' ;;
        *) printf '0' ;;
    esac
}

payload_bool_set() {
    local entry_index="$1" field="$2" flag="$3"
    ensure_payload_verify "$entry_index" || return 1
    model_set_bool "$(payload_key "$entry_index" "$field")" "$flag"
}

# Append a payload entry for an artifact and print its index.
#
# plister cannot append a container - "append dict" and "add dict" both fail
# with "invalid number of arguments" while "insert <n> dict" works (design
# 12.1) - so growth is a count-then-insert.
#
# Arguments: absolute source path
payload_append_from_path() {
    local artifact_path="$1"
    # Set on both branches of the test below.
    local verify_flag

    local destination="$(guess_destination "$artifact_path" "$(last_destination_dir)")"
    local mode="$(guess_mode "$artifact_path")"
    local executable="$(artifact_executable "$artifact_path")"
    # The checks of design 7 step 1 only have something to say about a Mach-O,
    # so they start on for one and off for a plain file (design 5.3).
    if [ -n "$executable" ]; then verify_flag=1; else verify_flag=0; fi

    local entry_index="$(payload_count)"
    "$plister" insert "$entry_index" dict "$(model_file)" /COMPONENTS/0/PAYLOAD || return 1

    # The dict exists from here on, so anything that fails below leaves a
    # half-built entry the window never learns about - the model and the window
    # would disagree, and the phantom would ride into the next save. Every exit
    # past this point removes it first.
    if payload_set "$entry_index" SOURCE "$(store_path "$artifact_path")" &&
       payload_set "$entry_index" DESTINATION "$destination" &&
       payload_set "$entry_index" OWNER root &&
       payload_set "$entry_index" GROUP wheel &&
       payload_set "$entry_index" MODE "$mode" &&
       ensure_payload_verify "$entry_index" &&
       payload_set "$entry_index" VERIFY/VERSION_FLAG "" &&
       payload_universal_set "$entry_index" "$verify_flag" &&
       payload_signed_set "$entry_index" "$verify_flag" &&
       payload_bool_set "$entry_index" VERIFY/HARDENED_RUNTIME "$verify_flag" &&
       payload_bool_set "$entry_index" VERIFY/SECURE_TIMESTAMP "$verify_flag"; then
        printf '%s' "$entry_index"
        return 0
    fi

    dbg "payload_append_from_path: rolling back entry $entry_index"
    payload_remove_at "$entry_index"
    return 1
}

payload_remove_at() {
    local entry_index="$1"
    "$plister" remove "$(model_file)" "/COMPONENTS/0/PAYLOAD/$entry_index"
}

# Move an entry one place toward the front or the back of the list.
#
# plister has no move, and the array elements are dicts, so the swap is done by
# writing the whole array out and reading it back with two neighbors exchanged
# would need a second file. Instead the two entries' scalar fields are exchanged
# in place, which is equivalent for the flat shape a payload entry has and needs
# no temporary document. Arguments: index a, index b
payload_swap() {
    local first_index="$1" second_index="$2"
    # "field" is set by the loops below; the two values are set inside them.
    local field first_value second_value

    for field in SOURCE DESTINATION OWNER GROUP MODE; do
        first_value="$(payload_get "$first_index" "$field")"
        second_value="$(payload_get "$second_index" "$field")"
        payload_set "$first_index" "$field" "$second_value" || return 1
        payload_set "$second_index" "$field" "$first_value" || return 1
    done

    ensure_payload_verify "$first_index" || return 1
    ensure_payload_verify "$second_index" || return 1

    for field in VERIFY/SIGNED_BY VERIFY/VERSION_FLAG; do
        first_value="$(payload_get "$first_index" "$field")"
        second_value="$(payload_get "$second_index" "$field")"
        payload_set "$first_index" "$field" "$second_value" || return 1
        payload_set "$second_index" "$field" "$first_value" || return 1
    done

    for field in VERIFY/HARDENED_RUNTIME VERIFY/SECURE_TIMESTAMP; do
        first_value="$(payload_bool_get "$first_index" "$field")"
        second_value="$(payload_bool_get "$second_index" "$field")"
        payload_bool_set "$first_index" "$field" "$second_value" || return 1
        payload_bool_set "$second_index" "$field" "$first_value" || return 1
    done

    # The architecture list is exchanged as a list, not through the universal
    # checkbox's view of it. That checkbox can only say "both" or "none", so
    # swapping through it would read a hand-written ["arm64"] - a perfectly
    # ordinary Apple-Silicon-only tool, and a shape the schema allows and
    # normalize preserves - as "not both", and write back an empty array. One
    # click on the up arrow would delete the entry's only architecture check,
    # moving the row back would not bring it back, and saving would ship the
    # loss. Found in review, 2026-08-06.
    first_value="$(payload_archs_get "$first_index")"
    second_value="$(payload_archs_get "$second_index")"
    payload_archs_set "$first_index" "$second_value" || return 1
    payload_archs_set "$second_index" "$first_value" || return 1
    return 0
}

# --- The inspector ------------------------------------------------------------
# Enable or disable every control that edits the selected payload entry.
set_inspector_enabled() {
    local enabled="$1"
    # Set by the "for" below.
    local view_id
    for view_id in $SOURCE_ID $SOURCE_BROWSE_ID $DESTINATION_ID $DESTINATION_MENU_ID \
                   $OWNER_ID $GROUP_ID $MODE_ID $VERIFY_UNIVERSAL_ID $VERIFY_SIGNED_ID \
                   $VERIFY_HARDENED_ID $VERIFY_TIMESTAMP_ID $VERSION_FLAG_ID; do
        enable_view "$view_id" "$enabled"
    done
    return 0
}

# Blank the inspector and disable it.
#
# Guarded by the loading flag for the same reason push_payload_item_to_window
# is. These ten writes are echoed back as field.changed events, and relying on
# "no row is selected" to discard them means relying on the echoes arriving
# before the user's next click. If a row is selected in between, the echo for
# the source field arrives with a live selection and an empty value, which is a
# blanked SOURCE and a document marked edited. Found in review, 2026-08-06.
clear_payload_inspector() {
    local previous_flag="$(pb_get pb_loading)"
    pb_set pb_loading "$(/bin/date '+%s')"
    set_value "$SOURCE_ID" ""
    set_value "$DESTINATION_ID" ""
    set_value "$OWNER_ID" ""
    set_value "$GROUP_ID" ""
    set_value "$MODE_ID" ""
    set_value "$VERIFY_UNIVERSAL_ID" false
    set_value "$VERIFY_SIGNED_ID" false
    set_value "$VERIFY_HARDENED_ID" false
    set_value "$VERIFY_TIMESTAMP_ID" false
    set_value "$VERSION_FLAG_ID" ""
    set_inspector_enabled 0
    pb_set pb_loading "$previous_flag"
    return 0
}

# Show one payload entry in the inspector. Wrapped in the loading flag so the
# programmatic writes are not mistaken for user edits by field.changed - the
# same guard push_model_to_window uses, and needed here too because selecting a
# row writes eleven controls.
push_payload_item_to_window() {
    local entry_index="$1"
    # The previous flag is restored rather than cleared: this runs both on its
    # own, from a row selection, and inside push_model_to_window's own guarded
    # stretch, where clearing it would expose the rest of that push to
    # field.changed as if the user had typed it.
    local previous_flag="$(pb_get pb_loading)"
    pb_set pb_loading "$(/bin/date '+%s')"
    set_inspector_enabled 1
    set_value "$SOURCE_ID" "$(payload_get "$entry_index" SOURCE)"
    set_value "$DESTINATION_ID" "$(payload_get "$entry_index" DESTINATION)"
    set_value "$OWNER_ID" "$(payload_get "$entry_index" OWNER)"
    set_value "$GROUP_ID" "$(payload_get "$entry_index" GROUP)"
    set_value "$MODE_ID" "$(payload_get "$entry_index" MODE)"
    set_value "$VERIFY_UNIVERSAL_ID" "$(bool_str "$(payload_universal_get "$entry_index")")"
    set_value "$VERIFY_SIGNED_ID" "$(bool_str "$(payload_signed_get "$entry_index")")"
    set_value "$VERIFY_HARDENED_ID" "$(bool_str "$(payload_bool_get "$entry_index" VERIFY/HARDENED_RUNTIME)")"
    set_value "$VERIFY_TIMESTAMP_ID" "$(bool_str "$(payload_bool_get "$entry_index" VERIFY/SECURE_TIMESTAMP)")"
    set_value "$VERSION_FLAG_ID" "$(payload_get "$entry_index" VERIFY/VERSION_FLAG)"
    pb_set pb_loading "$previous_flag"
    return 0
}

# Enable the list buttons that make sense for the current selection.
refresh_payload_buttons() {
    local entry_index="$(selected_payload_index)"
    local entry_count="$(payload_count)"
    if [ -z "$entry_index" ]; then
        enable_view "$PAYLOAD_REMOVE_ID" 0
        enable_view "$PAYLOAD_UP_ID" 0
        enable_view "$PAYLOAD_DOWN_ID" 0
        return 0
    fi
    enable_view "$PAYLOAD_REMOVE_ID" 1
    if [ "$entry_index" -gt 0 ]; then
        enable_view "$PAYLOAD_UP_ID" 1
    else
        enable_view "$PAYLOAD_UP_ID" 0
    fi
    if [ "$entry_index" -lt "$((entry_count - 1))" ]; then
        enable_view "$PAYLOAD_DOWN_ID" 1
    else
        enable_view "$PAYLOAD_DOWN_ID" 0
    fi
    return 0
}

# Adopt a selection: record it, show it, and set the list buttons. An empty
# index clears the selection instead. Arguments: index or ""
show_payload_selection() {
    local entry_index="$1"
    if [ -z "$entry_index" ]; then
        set_selected_payload_index ""
        clear_payload_inspector
        refresh_payload_buttons
        return 0
    fi
    set_selected_payload_index "$entry_index"
    push_payload_item_to_window "$entry_index"
    refresh_payload_buttons
    return 0
}

# Rebuild the table and put the selection back on a chosen row. Every edit that
# changes the shape of the list goes through here, because setting a table's
# rows replaces them and does not move the selection (design 5.2).
# Arguments: index to select, or "" for none
repopulate_payload() {
    local wanted_index="$1"
    local entry_count="$(payload_count)"
    populate_payload_table
    if [ -n "$wanted_index" ] && [ "$wanted_index" -ge 0 ] && [ "$wanted_index" -lt "$entry_count" ]; then
        select_payload_row "$wanted_index"
        show_payload_selection "$wanted_index"
    else
        deselect_payload_row
        show_payload_selection ""
    fi
    return 0
}

# Fill NAME, VERSION and MIN_OS_VERSION from a just-added artifact, but only
# where the document has nothing yet - typing a version the artifacts do not
# carry is the easy mistake here, and overwriting one the user chose would be a
# worse one (design 4.5). Prints nothing; returns 0 always.
# Arguments: absolute artifact path
fill_project_fields_from_artifact() {
    local artifact_path="$1"
    # Set only inside the three tests below.
    local candidate
    if [ -z "$(model_get /PROJECT/NAME)" ]; then
        candidate="$(/usr/bin/basename "$artifact_path")"
        candidate="${candidate%.*}"
        case "$candidate" in
            '') ;;
            *) model_set /PROJECT/NAME "$candidate" ;;
        esac
    fi
    if [ -z "$(model_get /PROJECT/VERSION)" ]; then
        candidate="$(artifact_version "$artifact_path" "")"
        [ -n "$candidate" ] && model_set /PROJECT/VERSION "$candidate"
    fi
    if [ -z "$(model_get /PROJECT/MIN_OS_VERSION)" ]; then
        candidate="$(artifact_minos "$artifact_path")"
        [ -n "$candidate" ] && model_set /PROJECT/MIN_OS_VERSION "$candidate"
    fi
    return 0
}

# --- Drop payload -------------------------------------------------------------
# Print one dropped path per line, from the JSON context an onDropActionID
# handler receives.
#
# ActionUI builds the context as {"items":[String],"location":{...}} and
# serializes it with NSJSONSerialization, so the paths carry JSON escaping and
# may contain anything a filename may contain. It is parsed with plister rather
# than with grep for that reason - and plister goes by file extension, so the
# context is staged as .json first (design 12.2).
#
# DropHelper resolves each item to a plain filesystem path (URL(string:)?.path),
# but an older engine handed over a "file://" URL, so both are accepted.
dropped_paths() {
    local trigger_context="$1"
    # Set once per iteration of the loop below.
    local item
    [ -n "$trigger_context" ] || return 0
    local staging_file="$(state_dir)/drop.json"
    /bin/rm -f "$staging_file"
    printf '%s' "$trigger_context" > "$staging_file" || return 0
    local item_count="$("$plister" get count "$staging_file" /items 2>/dev/null)"
    case "$item_count" in
        ''|*[!0-9]*) /bin/rm -f "$staging_file"; return 0 ;;
    esac
    local index=0
    while [ "$index" -lt "$item_count" ]; do
        item="$("$plister" get value "$staging_file" "/items/$index" 2>/dev/null)"
        case "$item" in
            file://*) item="$(url_to_path "$item")" ;;
        esac
        [ -n "$item" ] && printf '%s\n' "$item"
        index=$((index + 1))
    done
    /bin/rm -f "$staging_file"
    return 0
}

# Decode a file:// URL into a path. Percent-escapes are the only encoding a
# file URL applies, and printf %b turns the \xNN form into the byte itself.
# Backslashes are doubled first: a path may legitimately contain one, and %b
# would otherwise read it as the start of an escape of its own.
url_to_path() {
    local url="$1"
    local path="${url#file://}"
    # "file:///path" leaves an empty authority and "file://localhost/path"
    # leaves the word - and localhost is precisely the form the older CF code
    # this branch exists for used to emit, so without this the compatibility
    # path misses its own main case. Found in review, 2026-08-06.
    case "$path" in
        localhost/*) path="${path#localhost}" ;;
    esac
    path="${path%/}"
    printf '%b' "$(printf '%s' "$path" | /usr/bin/sed 's/\\/\\\\/g; s/%/\\x/g')"
}

# --- Installer identity picker -----------------------------------------------
# Print the Developer ID Installer identities in the keychain, one per line.
#
# Copied from list_signing_identities in lib.notarize.sh, restricted to its pkg
# branch. The policy matters: an installer certificate is not valid for the
# codesigning policy and does not appear under "-p codesigning" at all, so it
# has to be looked up under "-p basic".
list_installer_identities() {
    /usr/bin/security find-identity -v -p basic 2>/dev/null \
        | /usr/bin/grep "Developer ID Installer" \
        | /usr/bin/sed 's/.*"\(.*\)".*/\1/'
}

NO_IDENTITY_LABEL="(no Developer ID Installer certificate found)"
CHOOSE_IDENTITY_LABEL="(choose an identity)"

# Fill the installer identity picker from the keychain and select the one the
# document names.
#
# The ordered list is also written to identities.txt. The options carry explicit
# tags, so the picker should deliver the identity name directly the way the Auth
# and Customize pickers already do - but a Picker's value channel is the 1-based
# option index when options are plain strings (design 5.2), and which of the two
# a runtime-populated picker uses is not something this app has established.
# Keeping the map costs one file and lets the reader below accept either.
refresh_identity_picker() {
    local map_file="$(state_dir)/identities.txt"
    local stored="$(model_get /SIGNING/INSTALLER_IDENTITY)"
    # Set once per iteration below.
    local identity

    list_installer_identities > "$map_file"

    local options="" selected="" found=0
    while IFS= read -r identity; do
        [ -n "$identity" ] || continue
        if [ -n "$options" ]; then options="$options,"; fi
        options="$options{\"title\":\"$(json_escape "$identity")\",\"tag\":\"$(json_escape "$identity")\"}"
        if [ "$identity" = "$stored" ]; then
            selected="$identity"
            found=1
        fi
    done < "$map_file"

    if [ -z "$options" ]; then
        set_property "$IDENTITY_PICKER_ID" options \
            "[{\"title\":\"$(json_escape "$NO_IDENTITY_LABEL")\",\"tag\":\"\"}]"
        enable_view "$IDENTITY_PICKER_ID" 0
        return 0
    fi

    # An explicit empty first row, so a document that names no identity shows
    # one rather than appearing to have chosen the first certificate.
    #
    # Without it the picker sits on its first option while the model holds "",
    # which is every fresh document, and the build then refuses with "no
    # installer identity is chosen" while the window plainly shows one. The
    # picker's own value channel is what makes this unavoidable: a value with no
    # matching tag leaves it on its previous selection and fires no action
    # (design 5.2), so there is no way to say "nothing" except to offer it.
    options="{\"title\":\"$(json_escape "$CHOOSE_IDENTITY_LABEL")\",\"tag\":\"\"},$options"

    set_property "$IDENTITY_PICKER_ID" options "[$options]"
    enable_view "$IDENTITY_PICKER_ID" 1

    # A document naming an identity this machine does not have keeps its stored
    # value - the project is not wrong just because it was opened elsewhere -
    # and the build's preconditions are what refuse it.
    if [ "$found" = "1" ]; then
        local previous_flag="$(pb_get pb_loading)"
        pb_set pb_loading "$(/bin/date '+%s')"
        set_value "$IDENTITY_PICKER_ID" "$selected"
        pb_set pb_loading "$previous_flag"
    fi
    return 0
}

# Turn whatever the identity picker delivered into an identity name: the name
# itself when the picker used its tags, or the nth line of the map when it
# delivered a 1-based index.
resolve_identity_value() {
    local delivered="$1"
    [ -n "$delivered" ] || return 0
    case "$delivered" in
        ''|*[!0-9]*) printf '%s' "$delivered"; return 0 ;;
    esac
    # The picker carries a "(choose an identity)" row ahead of the certificates,
    # so a 1-based option index is one further along than the matching line of
    # identities.txt, which lists only real identities. Index 1 is that row and
    # means "none chosen".
    if [ "$delivered" -le 1 ]; then
        return 0
    fi
    local line="$(/usr/bin/sed -n "$((delivered - 1))p" "$(state_dir)/identities.txt" 2>/dev/null)"
    if [ -n "$line" ]; then printf '%s' "$line"; else printf '%s' "$delivered"; fi
}

# --- Field map (design section 9.2) ------------------------------------------
# The single place where the window's view ids and the document schema meet.
# Print the model key path a scalar control writes to. Arguments: view id
field_key_path() {
    local view_id="$1"
    case "$view_id" in
        "$ARTIFACTS_DIR_ID")     printf '/PROJECT/ARTIFACTS_DIR' ;;
        "$NAME_ID")              printf '/PROJECT/NAME' ;;
        "$IDENTIFIER_ID")        printf '/COMPONENTS/0/IDENTIFIER' ;;
        "$VERSION_ID")           printf '/PROJECT/VERSION' ;;
        "$INSTALL_LOCATION_ID")  printf '/COMPONENTS/0/INSTALL_LOCATION' ;;
        "$AUTH_ID")              printf '/COMPONENTS/0/AUTH' ;;
        "$OVERWRITE_ID")         printf '/COMPONENTS/0/OVERWRITE_PERMISSIONS' ;;
        "$RELOCATABLE_ID")       printf '/COMPONENTS/0/RELOCATABLE' ;;
        "$PREINSTALL_ID")        printf '/COMPONENTS/0/PREINSTALL' ;;
        "$POSTINSTALL_ID")       printf '/COMPONENTS/0/POSTINSTALL' ;;
        "$TITLE_ID")             printf '/DISTRIBUTION/TITLE' ;;
        "$MIN_OS_ID")            printf '/PROJECT/MIN_OS_VERSION' ;;
        "$CUSTOMIZE_ID")         printf '/DISTRIBUTION/CUSTOMIZE' ;;
        "$README_ID")            printf '/DISTRIBUTION/RESOURCES/README' ;;
        "$LICENSE_ID")           printf '/DISTRIBUTION/RESOURCES/LICENSE' ;;
        "$WELCOME_ID")           printf '/DISTRIBUTION/RESOURCES/WELCOME' ;;
        "$CONCLUSION_ID")        printf '/DISTRIBUTION/RESOURCES/CONCLUSION' ;;
        "$BACKGROUND_ID")        printf '/DISTRIBUTION/RESOURCES/BACKGROUND' ;;
        "$OUTPUT_DIR_ID")        printf '/PROJECT/OUTPUT_DIR' ;;
        "$PACKAGE_NAME_ID")      printf '/PROJECT/PACKAGE_NAME' ;;
        "$SIGN_ID")              printf '/SIGNING/ENABLED' ;;
        "$IDENTITY_PICKER_ID")   printf '/SIGNING/INSTALLER_IDENTITY' ;;
        *) printf '' ;;
    esac
}

# Print "bool" or "string" for a scalar control. Arguments: view id
field_kind() {
    local view_id="$1"
    case "$view_id" in
        "$OVERWRITE_ID"|"$RELOCATABLE_ID"|"$SIGN_ID") printf 'bool' ;;
        *) printf 'string' ;;
    esac
}

# Succeed when a view id belongs to the payload inspector, whose key path
# depends on which row is selected rather than on the view id alone.
is_payload_field() {
    local view_id="$1"
    case "$view_id" in
        "$SOURCE_ID"|"$DESTINATION_ID"|"$OWNER_ID"|"$GROUP_ID"|"$MODE_ID"|\
        "$VERIFY_UNIVERSAL_ID"|"$VERIFY_SIGNED_ID"|"$VERIFY_HARDENED_ID"|\
        "$VERIFY_TIMESTAMP_ID"|"$VERSION_FLAG_ID") return 0 ;;
    esac
    return 1
}

# Succeed when a view id is one of the four verify toggles, which are stored in
# shapes a plain bool write cannot reach.
is_verify_toggle() {
    local view_id="$1"
    case "$view_id" in
        "$VERIFY_UNIVERSAL_ID"|"$VERIFY_SIGNED_ID"|"$VERIFY_HARDENED_ID"|"$VERIFY_TIMESTAMP_ID")
            return 0 ;;
    esac
    return 1
}

# Succeed when a view id edits one of the table's three visible columns, so an
# edit to it has to be repeated in the table.
is_payload_column_field() {
    local view_id="$1"
    case "$view_id" in
        "$SOURCE_ID"|"$DESTINATION_ID"|"$MODE_ID") return 0 ;;
    esac
    return 1
}

# The same idea one level down: the field of the *selected payload entry* a
# control writes to, relative to the entry. Kept apart from field_key_path
# because these controls have no fixed key path - theirs depends on which row
# is selected, which is state rather than layout.
# Prints nothing for a view that does not edit a payload entry.
payload_field_key() {
    local view_id="$1"
    case "$view_id" in
        "$SOURCE_ID")       printf 'SOURCE' ;;
        "$DESTINATION_ID")  printf 'DESTINATION' ;;
        "$OWNER_ID")        printf 'OWNER' ;;
        "$GROUP_ID")        printf 'GROUP' ;;
        "$MODE_ID")         printf 'MODE' ;;
        "$VERSION_FLAG_ID") printf 'VERIFY/VERSION_FLAG' ;;
        *) printf '' ;;
    esac
}

# Print the destination a preset menu item fills in, without the artifact's own
# basename, which the handler appends (design 5.3).
destination_preset() {
    local view_id="$1"
    case "$view_id" in
        "$PRESET_APPLICATIONS_ID")   printf '/Applications' ;;
        "$PRESET_USR_LOCAL_BIN_ID")  printf '/usr/local/bin' ;;
        "$PRESET_FRAMEWORKS_ID")     printf '/Library/Frameworks' ;;
        "$PRESET_APP_SUPPORT_ID")    printf '/Library/Application Support/${NAME}' ;;
        "$PRESET_LAUNCHDAEMONS_ID")  printf '/Library/LaunchDaemons' ;;
        "$PRESET_LAUNCHAGENTS_ID")   printf '/Library/LaunchAgents' ;;
        "$PRESET_PREFPANES_ID")      printf '/Library/PreferencePanes' ;;
        *) printf '' ;;
    esac
}

# --- Paths --------------------------------------------------------------------
# Canonicalize a file or directory path, resolving symlinks all the way down.
# Prints nothing and returns 1 on failure. Arguments: path
#
# Copied from lib.notarize.sh, whose review pass earned the symlink handling: a
# file's final component cannot be resolved by "cd -P", so it is resolved by
# hand; and "cd -P" rather than plain cd keeps a relative link's ".." from being
# collapsed lexically against the wrong directory.
canonical_path() {
    local path="$1"
    # "dir" is declared apart from its assignments because they are guarded by
    # "|| return 1": written as "local dir=$(...)" the guard would test local's
    # own status, which is always 0, and a failed cd would go unnoticed.
    # "link" is set inside the loop below.
    local dir link
    if [ -d "$path" ]; then
        dir="$(cd -P "$path" 2>/dev/null && /bin/pwd -P)" || return 1
        [ -n "$dir" ] || return 1
        printf '%s' "$dir"
        return 0
    fi

    local target="$path"
    local hops=0
    while [ -L "$target" ] && [ "$hops" -lt 40 ]; do
        link="$(/usr/bin/readlink "$target")"
        [ -n "$link" ] || break
        case "$link" in
            /*) target="$link" ;;
            *) target="$(/usr/bin/dirname "$target")/$link" ;;
        esac
        hops=$((hops + 1))
    done
    # Still a symlink means a loop, or a chain longer than the loop allows.
    [ -L "$target" ] && return 1

    dir="$(/usr/bin/dirname "$target")"
    local base="$(/usr/bin/basename "$target")"
    dir="$(cd -P "$dir" 2>/dev/null && /bin/pwd -P)" || return 1
    [ -n "$dir" ] || return 1
    printf '%s/%s' "$dir" "$base"
}

# --- Cleanup ------------------------------------------------------------------
# Remove this window's scratch directory and clear its pasteboard flags. Called
# on every close path, dirty or clean - but never on a path where a save failed
# or was canceled, because the model file is the only copy of the user's work.
cleanup_state() {
    local dir="${TMPDIR:-/tmp}/packagebuilder-state-${document_uuid}"
    # rm -rf runs only on a path that is one of ours (design section 8.4). In a
    # case pattern "?" and "*" both match "/", so the uuid is checked separately
    # for a path separator or a parent reference rather than trusted to the glob.
    case "$document_uuid" in
        ''|*/*|*..*)
            dbg "cleanup_state: refusing suspicious uuid [$document_uuid]"
            return 1
            ;;
    esac
    case "$dir" in
        */packagebuilder-state-?*) /bin/rm -rf "$dir" ;;
        *) return 1 ;;
    esac
    pb_set pb_loading ""
    pb_set pb_close_after_save ""
    pb_set pb_busy ""
    return 0
}
