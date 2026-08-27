#!/bin/sh
# PackageBuilder.field.changed.sh - generic writer for the simple scalar controls
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.sh"
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.packagebuilder.window.sh"

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

# Which component the component-scoped controls belong to. Resolved once, before
# anything reads or writes the model, because field_key_path routes IDENTIFIER,
# INSTALL_LOCATION, AUTH and the rest through the current component.
load_current_component_index

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
# These controls edit the selected entry of the current component's PAYLOAD, so
# their key path depends on two selections rather than on the view id alone.
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

# The installer identity picker carries the identity in its option tags, but a
# Picker's value channel is the 1-based option index when its options are plain
# strings (design 5.2). Which of the two a runtime-populated picker delivers is
# not something this app has established, so the value is resolved through the
# ordered list either way before it reaches the model.
if [ "$vid" = "$IDENTITY_PICKER_ID" ]; then
    value="$(resolve_identity_value "$value")"
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

# The component list shows a title that falls back to the identifier, so either
# control can rename the row the user is looking at.
if is_component_column_field "$vid"; then
    refresh_component_list
fi

# Either version field changes what the caption beside the component's version
# should say: its own field decides whether there is anything to inherit, and
# the project's is what would be inherited.
if [ "$vid" = "$COMPONENT_VERSION_ID" ] || [ "$vid" = "$VERSION_ID" ]; then
    refresh_version_hint
fi

# Customize decides whether the two installer-choice controls on the Component
# tab do anything, and it is edited on a different tab. Without this the note
# beside them would go on claiming the installer shows no choice list until the
# next time a component is selected.
if [ "$vid" = "$CUSTOMIZE_ID" ]; then
    set_value "$COMPONENT_CHOICE_NOTE_ID" "$(choice_list_note)"
fi

# Two components may not share an identifier, nor have identifiers that differ
# only in punctuation: both collapse to one Distribution choice id AND one
# component package file name, so one would quietly replace the other.
#
# The edit is kept and the status line warns, rather than refused. A text field
# reports its value when it is committed, and a rename is usually half done at
# that moment - refusing would leave the user looking at text the document does
# not contain, which is the failure the whole write path is built to avoid. The
# build refuses it, and now it is not a surprise when it does. The CLI's
# add-component refuses outright because there is nothing half-typed there.
if [ "$vid" = "$IDENTIFIER_ID" ]; then
    conflict="$(component_identifier_conflict "$value" "$PB_COMPONENT_INDEX")"
    if [ -n "$conflict" ]; then
        set_status "The build will refuse this: $conflict"
    fi
fi

# Only now, and only for the picker. Everything above has to have held for
# execution to arrive here: loading_in_progress returned, so this is not
# push_model_to_window writing the picker as a document opens; the value differed
# from the model, so it is not the engine echoing a programmatic write back; and
# the write itself succeeded.
#
# That belt-and-braces placement is deliberate and was not the first attempt.
# Sitting up beside resolve_identity_value, this had only the loading flag
# between it and disaster - and that flag is cleared two dialog_tool spawns after
# the picker is written (push_model_to_window), so an echoed event arriving even
# slightly late would slip past it. Every other write in this handler has always
# had the value-equality exit as a second line of defense; before this feature
# existed, an escaped echo simply matched the model and exited, costing nothing.
# A preference is different: it outlives the document and every later File > New
# inherits it, so merely opening a project would have quietly retargeted the
# user's default to whatever that project named. Found in review, 2026-08-23.
#
# The cost is that re-picking the identity a document already names does not
# refresh the preference. That is a gesture with nothing to say - the value is
# what it already was - and it is a fair price for a write that cannot fire by
# accident.
if [ "$vid" = "$IDENTITY_PICKER_ID" ]; then
    remember_default_identity "$value"
fi

model_unlock

exit 0
