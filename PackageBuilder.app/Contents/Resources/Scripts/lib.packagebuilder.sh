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

# Log the OMC context a handler was invoked with. Arguments: handler name
dbg_context() {
    [ -f "$dbg_flag" ] || return 0
    dbg "=== $1"
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
ARTIFACTS_DIR_ID=105

NAME_ID=129
IDENTIFIER_ID=130
VERSION_ID=131
INSTALL_LOCATION_ID=133
AUTH_ID=134
OVERWRITE_ID=135
RELOCATABLE_ID=136
PREINSTALL_ID=137
POSTINSTALL_ID=139

TITLE_ID=150
MIN_OS_ID=151
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
    "$pasteboard_tool" "${1}_${document_uuid}" get 2>/dev/null
}

pb_set() {
    printf '%s' "$2" | "$pasteboard_tool" "${1}_${document_uuid}" set
}

# --- Window control (thin wrappers over omc_dialog_control) ------------------
# All target document_uuid so a child sheet updates the parent document window.
set_value() {
    "$dialog_tool" "$document_uuid" "$1" "$2"
}

set_property() {
    "$dialog_tool" "$document_uuid" "$1" omc_set_property "$2" "$3"
}

enable_view() {
    if [ "$2" = "1" ]; then
        "$dialog_tool" "$document_uuid" "$1" omc_enable
    else
        "$dialog_tool" "$document_uuid" "$1" omc_disable
    fi
}

show_view() {
    if [ "$2" = "1" ]; then
        "$dialog_tool" "$document_uuid" "$1" omc_show
    else
        "$dialog_tool" "$document_uuid" "$1" omc_hide
    fi
}

set_status() {
    set_value "$STATUS_ID" "$1"
}

show_progress() {
    show_view "$PROGRESS_ID" "$1"
}

# Read a view's current value out of the environment. Arguments: view id.
# The caller must have established that the id is numeric - it is interpolated
# into the eval'd text. (The value itself is expanded inside the eval's double
# quotes and is never re-evaluated.)
view_value() {
    eval "printf '%s' \"\$OMC_ACTIONUI_VIEW_${1}_VALUE\""
}

# Print "true"/"false" for a "1"/"0" flag. ActionUI's Bool elements accept only
# the strings "true" and "false" through setElementValueFromString; anything
# else, "1" and "0" included, is logged and discarded
# (ActionUI/Common/ActionUIModel.swift, valueType == Bool.self). Reading back
# gives boolValue.description, so the two directions do not use the same words.
bool_str() {
    if [ "$1" = "1" ]; then printf 'true'; else printf 'false'; fi
}

# --- Log view -----------------------------------------------------------------
# From lib.notarize.sh: append to the file, then mirror the whole file into the
# view, because the TextEditor has no incremental append.
clear_log() {
    : > "$(state_dir)/run.log"
    set_value "$LOG_ID" ""
}

append_log() {
    local f="$(state_dir)/run.log"
    printf '%s\n' "$1" >> "$f"
    set_value "$LOG_ID" "$(/bin/cat "$f")"
}

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
    "$plister" get value "$prefs_file" "/$1" 2>/dev/null
}

prefs_set() {
    prefs_ensure
    "$plister" set string "$2" "$prefs_file" "/$1"
}

# --- Model access -------------------------------------------------------------
# The model is a file and the window is a projection of it (design section 9.1).

# Print a value from the model. Arguments: key path (e.g. /PROJECT/VERSION)
model_get() {
    "$plister" get value "$(model_file)" "$1" 2>/dev/null
}

# Print the plist type at a key path, or nothing when it does not exist.
model_type() {
    "$plister" get type "$(model_file)" "$1" 2>/dev/null
}

# Write a string into the model. Returns plister's status: "set" creates a
# missing leaf, but FAILS when any parent container is absent, so the status is
# the only way to know the value landed. model_normalize makes every container
# exist, and this status is the backstop for anything it missed.
# Arguments: key path, value
model_set() {
    "$plister" set string "$2" "$(model_file)" "$1"
}

# Write a bool into the model. Same status contract as model_set.
# Arguments: key path, "1"/"0"/true/false
model_set_bool() {
    local v
    case "$2" in
        1|true|TRUE|YES) v=true ;;
        *) v=false ;;
    esac
    "$plister" set bool "$v" "$(model_file)" "$1"
}

# Print "1" or "0" for a model bool. Arguments: key path
model_get_bool() {
    case "$(model_get "$1")" in
        1|true|TRUE|YES) printf '1' ;;
        *) printf '0' ;;
    esac
}

# Print "true"/"false" for a model bool, ready for a Toggle. Arguments: key path
model_get_bool_str() {
    bool_str "$(model_get_bool "$1")"
}

# Print the element count of a model array (0 when absent). Arguments: key path
model_count() {
    local n
    n="$("$plister" get count "$(model_file)" "$1" 2>/dev/null)"
    case "$n" in
        ''|*[!0-9]*) n=0 ;;
    esac
    printf '%s' "$n"
}

# --- Model serialization ------------------------------------------------------
# Every edit is a read-modify-write of the whole model file, and control events
# arrive concurrently - tabbing quickly from one field to the next can start the
# second handler's read before the first has written. plister's write is atomic
# (NSDataWritingAtomic) so the file cannot be corrupted, but an edit can be lost,
# so the read-modify-write is serialized. mkdir is the atomic primitive.
model_lock() {
    local d="$(state_dir)/model.lock"
    local i=0
    while [ "$i" -lt 120 ]; do
        if /bin/mkdir "$d" 2>/dev/null; then
            return 0
        fi
        # A lock older than about ten seconds belongs to a handler that died.
        if [ -n "$(/usr/bin/find "$d" -maxdepth 0 -mmin +0.16 2>/dev/null)" ]; then
            /bin/rmdir "$d" 2>/dev/null
        fi
        /bin/sleep 0.05
        i=$((i + 1))
    done
    return 1
}

model_unlock() {
    /bin/rmdir "$(state_dir)/model.lock" 2>/dev/null
    return 0
}

# --- Model shape --------------------------------------------------------------
# Create a missing container. Arguments: parent key path, key or index, dict|array
ensure_container() {
    local parent="$1"
    local key="$2"
    local kind="$3"
    local child="${parent%/}/$key"
    if [ -z "$(model_type "$child")" ]; then
        "$plister" insert "$key" "$kind" "$(model_file)" "$parent"
    fi
    return 0
}

# Give a missing scalar its default. Arguments: key path, default value
ensure_string() {
    if [ -z "$(model_type "$1")" ]; then
        model_set "$1" "$2"
    fi
    return 0
}

ensure_bool() {
    if [ -z "$(model_type "$1")" ]; then
        model_set_bool "$1" "$2"
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
    return 0
}

# --- Document state -----------------------------------------------------------
doc_path() {
    local f="$(state_dir)/doc_path.txt"
    [ -f "$f" ] && /bin/cat "$f"
    return 0
}

set_doc_path() {
    printf '%s' "$1" > "$(state_dir)/doc_path.txt"
}

# SHA-256 of a file, or empty when it cannot be read.
file_hash() {
    [ -f "$1" ] || return 0
    /usr/bin/shasum -a 256 "$1" 2>/dev/null | /usr/bin/awk '{print $1}'
}

store_doc_hash() {
    printf '%s' "$(file_hash "$1")" > "$(state_dir)/doc_hash.txt"
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
    local incoming fv
    [ -f "$1" ] || return 1
    incoming="$(state_dir)/incoming.json"
    /bin/rm -f "$incoming"
    /bin/cp "$1" "$incoming" || return 1
    fv="$("$plister" get value "$incoming" /FORMAT_VERSION 2>/dev/null)"
    case "$fv" in
        ''|*[!0-9]*) /bin/rm -f "$incoming"; return 1 ;;
    esac
    /bin/mv -f "$incoming" "$(model_file)" || return 1
    model_normalize
    set_doc_path "$1"
    store_doc_hash "$1"
    mark_clean
    return 0
}

# Write the model to a path and adopt it as the document. Prints the path
# actually written and returns 0 only when the document really is on disk.
# Arguments: path
save_document() {
    local dest="$1"
    local dir base tmp
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
    dir="$(/usr/bin/dirname "$dest")"
    base="$(/usr/bin/basename "$dest")"
    if [ ! -d "$dir" ]; then
        /bin/mkdir -p "$dir" || return 1
    fi
    # Write through a temp file in the destination directory and rename, so an
    # interrupted save cannot leave a truncated project where a working one was.
    # The pid keeps two windows saving to one destination from sharing a temp.
    tmp="$dir/.${base}.$$.pbsaving"
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

    populate_payload_table

    pb_set pb_loading ""
    return 0
}

# Succeed while a push_model_to_window is in flight. The flag carries the epoch
# second it was set; a value older than the window below is treated as debris
# from a handler that died rather than as a push still running, because latching
# it on would make every later edit vanish with no symptom.
loading_in_progress() {
    local flag now
    flag="$(pb_get pb_loading)"
    case "$flag" in
        ''|*[!0-9]*) return 1 ;;
    esac
    now="$(/bin/date '+%s')"
    [ "$((now - flag))" -lt 10 ]
}

# Print "1" when an architecture is listed in DISTRIBUTION/HOST_ARCHITECTURES.
# Arguments: architecture name
has_architecture() {
    local n i
    n="$(model_count /DISTRIBUTION/HOST_ARCHITECTURES)"
    i=0
    while [ "$i" -lt "$n" ]; do
        if [ "$(model_get "/DISTRIBUTION/HOST_ARCHITECTURES/$i")" = "$1" ]; then
            printf '1'
            return 0
        fi
        i=$((i + 1))
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
    local f="$(model_file)"
    "$plister" remove "$f" /DISTRIBUTION/HOST_ARCHITECTURES 2>/dev/null
    "$plister" set array "$f" /DISTRIBUTION/HOST_ARCHITECTURES || return 1
    if [ "$1" = "1" ]; then
        "$plister" append string arm64 "$f" /DISTRIBUTION/HOST_ARCHITECTURES || return 1
    fi
    if [ "$2" = "1" ]; then
        "$plister" append string x86_64 "$f" /DISTRIBUTION/HOST_ARCHITECTURES || return 1
    fi
    return 0
}

# Fill the payload table from the model. Three visible columns plus a hidden
# fourth carrying the item's index into COMPONENTS/0/PAYLOAD, per design 5.2.
populate_payload_table() {
    local n i src dst mode
    n="$(model_count /COMPONENTS/0/PAYLOAD)"
    i=0
    {
        while [ "$i" -lt "$n" ]; do
            src="$(model_get "/COMPONENTS/0/PAYLOAD/$i/SOURCE")"
            dst="$(model_get "/COMPONENTS/0/PAYLOAD/$i/DESTINATION")"
            mode="$(model_get "/COMPONENTS/0/PAYLOAD/$i/MODE")"
            printf '%s\t%s\t%s\t%s\n' "$src" "$dst" "$mode" "$i"
            i=$((i + 1))
        done
    } | "$dialog_tool" "$document_uuid" "$PAYLOAD_TABLE_ID" omc_table_set_rows_from_stdin
}

# --- Field map (design section 9.2) ------------------------------------------
# The single place where the window's view ids and the document schema meet.
# Print the model key path a scalar control writes to. Arguments: view id
field_key_path() {
    case "$1" in
        105) printf '/PROJECT/ARTIFACTS_DIR' ;;
        129) printf '/PROJECT/NAME' ;;
        130) printf '/COMPONENTS/0/IDENTIFIER' ;;
        131) printf '/PROJECT/VERSION' ;;
        133) printf '/COMPONENTS/0/INSTALL_LOCATION' ;;
        134) printf '/COMPONENTS/0/AUTH' ;;
        135) printf '/COMPONENTS/0/OVERWRITE_PERMISSIONS' ;;
        136) printf '/COMPONENTS/0/RELOCATABLE' ;;
        137) printf '/COMPONENTS/0/PREINSTALL' ;;
        139) printf '/COMPONENTS/0/POSTINSTALL' ;;
        150) printf '/DISTRIBUTION/TITLE' ;;
        151) printf '/PROJECT/MIN_OS_VERSION' ;;
        155) printf '/DISTRIBUTION/CUSTOMIZE' ;;
        156) printf '/DISTRIBUTION/RESOURCES/README' ;;
        158) printf '/DISTRIBUTION/RESOURCES/LICENSE' ;;
        160) printf '/DISTRIBUTION/RESOURCES/WELCOME' ;;
        162) printf '/DISTRIBUTION/RESOURCES/CONCLUSION' ;;
        164) printf '/DISTRIBUTION/RESOURCES/BACKGROUND' ;;
        170) printf '/PROJECT/OUTPUT_DIR' ;;
        172) printf '/PROJECT/PACKAGE_NAME' ;;
        173) printf '/SIGNING/ENABLED' ;;
        *) printf '' ;;
    esac
}

# Print "bool" or "string" for a scalar control. Arguments: view id
field_kind() {
    case "$1" in
        135|136|173) printf 'bool' ;;
        *) printf 'string' ;;
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
    # "dir" is declared apart from its assignments because they are guarded by
    # "|| return 1": written as "local dir=$(...)" the guard would test local's
    # own status, which is always 0, and a failed cd would go unnoticed.
    local dir link target hops base
    if [ -d "$1" ]; then
        dir="$(cd -P "$1" 2>/dev/null && /bin/pwd -P)" || return 1
        [ -n "$dir" ] || return 1
        printf '%s' "$dir"
        return 0
    fi

    target="$1"
    hops=0
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
    base="$(/usr/bin/basename "$target")"
    dir="$(cd -P "$dir" 2>/dev/null && /bin/pwd -P)" || return 1
    [ -n "$dir" ] || return 1
    printf '%s/%s' "$dir" "$base"
}

# --- Cleanup ------------------------------------------------------------------
# Remove this window's scratch directory and clear its pasteboard flags. Called
# on every close path, dirty or clean - but never on a path where a save failed
# or was cancelled, because the model file is the only copy of the user's work.
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
