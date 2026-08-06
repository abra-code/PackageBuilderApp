#!/bin/sh
# PackageBuilder.field.changed.sh - generic writer for the simple scalar controls
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"

dbg_context "PackageBuilder.field.changed.sh"

vid="$OMC_ACTIONUI_TRIGGER_VIEW_ID"

# view_value interpolates this into an eval, so it is established as a plain
# number before it is used for anything.
case "$vid" in
    ''|*[!0-9]*)
        dbg "field.changed: non-numeric trigger view id [$vid]"
        exit 0
        ;;
esac

# push_model_to_window writes every control programmatically; anything arriving
# while that is in flight is the app talking to itself, not the user.
if loading_in_progress; then
    dbg "field.changed: ignored view $vid while loading"
    exit 0
fi

has_model || exit 0

value="$(view_value "$vid")"
dbg "field.changed: view=$vid value=[$value]"

# Every edit is a read-modify-write of the whole model file, so two handlers
# racing would lose one of the two edits.
if ! model_lock; then
    dbg "field.changed: could not take the model lock"
    set_status "Busy - that change was not applied, please try again"
    exit 0
fi

failed=0

# --- the payload inspector ----------------------------------------------------
# These controls edit the selected entry of COMPONENTS/0/PAYLOAD, so their key
# path depends on the selection rather than on the view id alone.
if is_payload_field "$vid"; then
    idx="$(selected_payload_index)"
    if [ -z "$idx" ]; then
        # No row is selected, so there is nothing this value belongs to. The
        # inspector is disabled in that state; a value arriving anyway is the
        # engine echoing a programmatic clear, not an edit.
        dbg "field.changed: payload view $vid with no selection"
        model_unlock
        exit 0
    fi

    if is_verify_toggle "$vid"; then
        case "$value" in
            1|true|TRUE|YES) new=1 ;;
            *) new=0 ;;
        esac
        # Each of the four is stored in a shape a plain bool write cannot reach:
        # two are projections of a list and a string, two are ordinary bools
        # that still need their VERIFY dict to exist first.
        case "$vid" in
            "$VERIFY_UNIVERSAL_ID") old="$(payload_universal_get "$idx")" ;;
            "$VERIFY_SIGNED_ID")    old="$(payload_signed_get "$idx")" ;;
            "$VERIFY_HARDENED_ID")  old="$(payload_bool_get "$idx" VERIFY/HARDENED_RUNTIME)" ;;
            *)                      old="$(payload_bool_get "$idx" VERIFY/SECURE_TIMESTAMP)" ;;
        esac
        if [ "$new" = "$old" ]; then
            model_unlock
            exit 0
        fi
        case "$vid" in
            "$VERIFY_UNIVERSAL_ID") payload_universal_set "$idx" "$new" || failed=1 ;;
            "$VERIFY_SIGNED_ID")    payload_signed_set "$idx" "$new" || failed=1 ;;
            "$VERIFY_HARDENED_ID")  payload_bool_set "$idx" VERIFY/HARDENED_RUNTIME "$new" || failed=1 ;;
            *)                      payload_bool_set "$idx" VERIFY/SECURE_TIMESTAMP "$new" || failed=1 ;;
        esac
    else
        pkey="$(payload_field_key "$vid")"
        if [ "$value" = "$(payload_get "$idx" "$pkey")" ]; then
            model_unlock
            exit 0
        fi
        case "$pkey" in
            VERIFY/*) ensure_payload_verify "$idx" || failed=1 ;;
        esac
        if [ "$failed" != "1" ]; then
            payload_set "$idx" "$pkey" "$value" || failed=1
        fi
    fi

    if [ "$failed" = "1" ]; then
        model_unlock
        dbg "field.changed: payload write for view $vid failed"
        set_status "Could not record that change"
        exit 0
    fi
    mark_dirty
    # Source, destination and mode are the table's three visible columns, so
    # editing one has to be repeated there. Setting the rows drops the
    # selection, hence the reselect.
    if is_payload_column_field "$vid"; then
        populate_payload_table
        select_payload_row "$idx"
    fi
    model_unlock
    exit 0
fi

# The two architecture toggles are one array in the model, so they are written
# together from both toggles' current states rather than through the field map.
if [ "$vid" = "$ARCH_ARM64_ID" ] || [ "$vid" = "$ARCH_X86_64_ID" ]; then
    arm="$(view_value "$ARCH_ARM64_ID")"
    intel="$(view_value "$ARCH_X86_64_ID")"
    case "$arm" in 1|true|TRUE|YES) arm=1 ;; *) arm=0 ;; esac
    case "$intel" in 1|true|TRUE|YES) intel=1 ;; *) intel=0 ;; esac
    if [ "$arm" = "$(has_architecture arm64)" ] && [ "$intel" = "$(has_architecture x86_64)" ]; then
        model_unlock
        exit 0
    fi
    if set_architectures "$arm" "$intel"; then
        mark_dirty
    else
        failed=1
    fi
    model_unlock
    if [ "$failed" = "1" ]; then
        set_status "Could not record the host architectures"
    fi
    exit 0
fi

keypath="$(field_key_path "$vid")"
if [ -z "$keypath" ]; then
    dbg "field.changed: view $vid is not in the field map"
    model_unlock
    exit 0
fi

if [ "$(field_kind "$vid")" = "bool" ]; then
    case "$value" in
        1|true|TRUE|YES) new=1 ;;
        *) new=0 ;;
    esac
    # A control that reports the value it already holds is not an edit, and
    # marking the document dirty for one would make a fresh document look
    # modified the first time a checkbox is drawn.
    if [ "$new" = "$(model_get_bool "$keypath")" ]; then
        model_unlock
        exit 0
    fi
    model_set_bool "$keypath" "$new" || failed=1
else
    if [ "$value" = "$(model_get "$keypath")" ]; then
        model_unlock
        exit 0
    fi
    model_set "$keypath" "$value" || failed=1
fi

# plister's "set" fails outright when a parent container is absent, and a write
# that did not land must not leave the document looking edited - the window
# would show text the document does not contain, and the next save would make
# that permanent and call it clean.
if [ "$failed" = "1" ]; then
    model_unlock
    dbg "field.changed: write to $keypath failed"
    set_status "Could not record that change"
    exit 0
fi

mark_dirty
model_unlock

exit 0
