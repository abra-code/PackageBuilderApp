#!/bin/sh
# lib.packagebuilder.import.sh - import a Packages.app .pkgproj
#
# Design section 10. A .pkgproj is a plist, XML or binary, which plister reads
# in place now that it falls back to content for an extension it does not
# recognize (design 12.2). The interesting part is the payload hierarchy walk:
# Packages stores a scaffold of the whole system tree in every project, and the
# real payload references sit at TYPE = 3 leaf
# nodes inside it. Everything else - the presentation model beyond the readme,
# the excluded-file patterns, the requirement list, the template tree itself -
# is dropped, and the log says so, so nothing disappears quietly.
#
# Sourced after lib.packagebuilder.sh, which provides plister, the model
# accessors, store_path and the payload editing helpers.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".

# The .pkgproj every import_ function below reads. Set by import_pkgproj, and
# read-only: it is the user's file, not a copy of it.
import_file=""
import_project_dir=""

# One collected payload record per line in $(state_dir)/import.entries:
# source, destination, mode, owner, group - separated by the unit separator,
# which cannot appear in a plist string that survived Packages.app's own UI.
import_record_separator="$(printf '\037')"

# Read one value out of the staged plist, empty when the key is not there.
# Arguments: plister path
import_get() {
    local key_path="$1"
    "$plister" get value "$import_file" "$key_path" 2>/dev/null
}

import_count() {
    local key_path="$1"
    local element_count="$("$plister" get count "$import_file" "$key_path" 2>/dev/null)"
    case "$element_count" in
        ''|*[!0-9]*) printf '0' ;;
        *) printf '%s' "$element_count" ;;
    esac
}

# Resolve a .pkgproj path reference against the project file's folder.
# Arguments: raw path, PATH_TYPE (0 = absolute, 1 = relative to the project)
#
# PATH_TYPE 2 is "relative to a reference folder", a Packages feature this
# document model does not carry; it is resolved like 1 and the walk logs the
# guess, rather than dropping a payload entry over a base directory nobody has
# used in years.
import_resolve() {
    local raw_path="$1" path_type="$2"
    case "$path_type" in
        0) printf '%s' "$raw_path" ;;
        *) printf '%s/%s' "$import_project_dir" "$raw_path" ;;
    esac
}

# Walk one hierarchy node, appending TYPE = 3 records to the entries file.
# Arguments: plister path of the node, accumulated destination directory
#
# TYPE 1 and -1 are the system-tree scaffold - the same directory template
# Packages writes into every project, differing only in whether its outline
# shows them. They contribute their name to the destination of what sits under
# them, and nothing else; their UID/GID/PERMISSIONS describe /usr and /Library
# and are exactly what a package must not touch (design 8.1).
import_walk_node() {
    local node_path="$1" dest_prefix="$2"
    local node_type="$(import_get "$node_path/TYPE")"
    local raw_path="$(import_get "$node_path/PATH")"
    # Set on the branches that need them.
    local child_index child_count source_abs mode_octal owner group permissions path_type

    if [ "$node_type" = "3" ]; then
        # The records file is line-oriented, so a PATH carrying a line break
        # would shift every field of the record after it and fabricate a
        # second, half-empty entry - silent model corruption out of a data
        # file. Refused rather than repaired: a payload path with a newline in
        # it is not something to guess the intent of. Found in review,
        # 2026-08-07.
        # A real newline to compare against: command substitution strips
        # trailing newlines, so "$(printf '\n')" is empty and the pattern
        # would match every path. The sentinel survives and is then removed.
        local newline="$(printf '\nx')"
        newline="${newline%x}"
        case "$raw_path" in
            *"$newline"*)
                append_log "! A payload path contains a line break, which cannot be imported: $(printf '%s' "$raw_path" | /usr/bin/head -n 1) ..."
                return 1
                ;;
        esac
        path_type="$(import_get "$node_path/PATH_TYPE")"
        if [ "$path_type" != "0" ] && [ "$path_type" != "1" ]; then
            append_log "  note: \"$(/usr/bin/basename "$raw_path")\" uses a reference-folder path; imported as relative to the project file"
        fi
        # Packages can describe nodes inside a payload reference - a file
        # inside a bundle, say. The document model has no way to express that,
        # so the reference comes in whole and what is under it is named as a
        # drop rather than left to be noticed later.
        if [ "$(import_count "$node_path/CHILDREN")" != "0" ]; then
            append_log "  note: \"$(/usr/bin/basename "$raw_path")\" has entries described inside it; it is imported whole"
        fi
        source_abs="$(import_resolve "$raw_path" "$path_type")"
        # raw_path was checked above, but the RECORD stores source_abs, which for
        # a project-relative node is "$import_project_dir/$raw_path" - so a
        # .pkgproj sitting in a folder whose own name carries a line break slips
        # through with entirely ordinary content and shifts every field after it.
        case "$source_abs" in
            *"$newline"*)
                append_log "! A payload source path contains a line break, which cannot be imported: $(printf '%s' "$source_abs" | /usr/bin/head -n 1) ..."
                return 1
                ;;
        esac
        permissions="$(import_get "$node_path/PERMISSIONS")"
        case "$permissions" in
            ''|*[!0-9]*) mode_octal="0755" ;;
            *) mode_octal="$(printf '%04o' "$permissions")" ;;
        esac
        # Absent is not the same as 0, and both mean root:wheel here - the
        # default a dropped artifact gets. Anything else stays numeric, which
        # the staging stage already warns about, since --ownership recommended
        # does not apply it.
        owner="$(import_get "$node_path/UID")"
        group="$(import_get "$node_path/GID")"
        case "$owner" in ''|0) owner="root" ;; esac
        case "$group" in ''|0) group="wheel" ;; esac
        # basename disposes of any ".." in the directory part of a leaf's path,
        # which is a source path and may legitimately hold one. What it does not
        # dispose of is a path that IS "..", whose basename is "..".
        local leaf_name="$(/usr/bin/basename "$raw_path")"
        if path_has_dotdot "$leaf_name"; then
            append_log "  ! Item path \"$raw_path\" contains \"..\" and was refused"
            return 1
        fi
        printf '%s%s%s%s%s%s%s%s%s\n' \
            "$source_abs" "$import_record_separator" \
            "${dest_prefix%/}/$leaf_name" "$import_record_separator" \
            "$mode_octal" "$import_record_separator" \
            "$owner" "$import_record_separator" "$group" \
            >> "$(state_dir)/import.entries"
        return 0
    fi

    # A scaffold directory. Its PATH becomes part of the DESTINATION of
    # everything beneath it, and the records file is line-oriented, so a line
    # break here fabricates extra half-empty entries out of a data file exactly
    # as one in a leaf path does - the leaf branch above refuses it, and this
    # branch had no check at all.
    local scaffold_newline="$(printf '\nx')"
    scaffold_newline="${scaffold_newline%x}"
    case "$raw_path" in
        *"$scaffold_newline"*)
            append_log "! A payload directory name contains a line break, which cannot be imported: $(printf '%s' "$raw_path" | /usr/bin/head -n 1) ..."
            return 1
            ;;
    esac

    # The root's PATH is "/", which contributes nothing.
    local next_prefix="$dest_prefix"
    case "$raw_path" in
        ''|/) ;;
        # A .pkgproj is somebody else's file, and this is where its strings
        # first become destinations we would later write to. A ".." here walks
        # the whole subtree out of the install location; the build refuses it,
        # but a document that cannot be built is not worth writing, and naming
        # it at the boundary beats naming it three commands later.
        *) if path_has_dotdot "$raw_path"; then
               append_log "  ! Node path \"$raw_path\" contains \"..\" and was refused"
               return 1
           fi
           next_prefix="${dest_prefix%/}/$raw_path" ;;
    esac
    child_count="$(import_count "$node_path/CHILDREN")"
    child_index=0
    while [ "$child_index" -lt "$child_count" ]; do
        import_walk_node "$node_path/CHILDREN/$child_index" "$next_prefix" || return 1
        child_index=$((child_index + 1))
    done
    return 0
}

# Print the longest common directory prefix of every collected source, or
# nothing when there is none worth factoring out (design section 10: a prefix
# of "/" or a bare volume root is left alone).
import_common_prefix() {
    local entries_file="$(state_dir)/import.entries"
    [ -s "$entries_file" ] || return 0
    # Set by the read loop below.
    local source_path rest
    local prefix="" previous
    while IFS="$import_record_separator" read -r source_path rest; do
        # A SOURCE path may legitimately carry ".." - it names a file on the
        # machine doing the import, not a place anything is written to - but
        # path_is_under now refuses such a child outright, which would make the
        # loop below shrink the prefix to nothing and cost every OTHER entry its
        # ${ARTIFACTS_DIR} tokenization. This is portability inference, not a
        # write gate, so the honest answer is to leave this one entry out of the
        # prefix rather than to give up on all of them.
        if path_has_dotdot "$source_path"; then
            continue
        fi
        if [ -z "$prefix" ]; then
            prefix="$(/usr/bin/dirname "$source_path")"
            continue
        fi
        while ! path_is_under "$source_path" "$prefix"; do
            previous="$prefix"
            prefix="$(/usr/bin/dirname "$prefix")"
            # Progress, not "$prefix" = "/", is what ends this. dirname "." is
            # "." and dirname "a" is ".", so a relative path - which a
            # PATH_TYPE 0 node may perfectly well hold - spun here forever,
            # and the handler holds the model lock across the whole import, so
            # a live spinner wedged the window on "Busy" for good: the lock's
            # recovery reclaims a dead holder, never a running one. Found in
            # review, 2026-08-07.
            [ "$prefix" != "$previous" ] || break
        done
    done < "$entries_file"
    case "$prefix" in
        ''|/|.|..) return 0 ;;
        # A relative prefix is not a folder anyone can point --artifacts-dir
        # at; the sources keep whatever the project said and the document is
        # honest about not having factored anything.
        [!/]*) return 0 ;;
        /Volumes/*)
            case "${prefix#/Volumes/}" in
                */*) ;;
                *) return 0 ;;
            esac
            ;;
    esac
    printf '%s' "$prefix"
}

# Replace the payload with the collected entries. The artifacts folder is set
# first, so store_path tokenizes every source below it as
# ${ARTIFACTS_DIR}/... on the way in.
import_apply_payload() {
    local entries_file="$(state_dir)/import.entries"
    # Set by the loops below.
    local source_path destination mode_octal owner group entry_index verify_flag

    # The guard comes before the removal, not after it. A scaffold-only
    # project - one that describes the system tree and references nothing -
    # would otherwise empty the payload and report success, which is the one
    # outcome an import should never produce silently. Found in review,
    # 2026-08-07.
    if [ ! -s "$entries_file" ]; then
        append_log "  no payload references in the project; the payload was left as it was"
        return 0
    fi

    while [ "$(payload_count)" -gt 0 ]; do
        payload_remove_at 0 || return 1
    done
    while IFS="$import_record_separator" read -r source_path destination mode_octal owner group; do
        entry_index="$(payload_count)"
        # The current component, not a literal 0. Every other accessor on these
        # lines defaults to it, and the two disagreeing is what would split one
        # import across two components.
        "$plister" insert "$entry_index" dict "$(model_file)" "/COMPONENTS/$PB_COMPONENT_INDEX/PAYLOAD" || return 1
        # The same verify defaults a dropped artifact gets (design 5.3): a
        # Mach-O starts out asserting universal, signed, hardened and
        # timestamped; a plain file or a source that is not on this disk
        # asserts nothing.
        if [ -n "$(artifact_executable "$source_path")" ]; then verify_flag=1; else verify_flag=0; fi
        if ! { payload_set "$entry_index" SOURCE "$(store_path "$source_path")" &&
               payload_set "$entry_index" DESTINATION "$destination" &&
               payload_set "$entry_index" OWNER "$owner" &&
               payload_set "$entry_index" GROUP "$group" &&
               payload_set "$entry_index" MODE "$mode_octal" &&
               ensure_payload_verify "$entry_index" &&
               payload_set "$entry_index" VERIFY/VERSION_FLAG "" &&
               payload_universal_set "$entry_index" "$verify_flag" &&
               payload_signed_set "$entry_index" "$verify_flag" &&
               payload_bool_set "$entry_index" VERIFY/HARDENED_RUNTIME "$verify_flag" &&
               payload_bool_set "$entry_index" VERIFY/SECURE_TIMESTAMP "$verify_flag"; }; then
            payload_remove_at "$entry_index"
            return 1
        fi
        append_log "  $(/usr/bin/basename "$source_path") -> $destination ($mode_octal)"
    done < "$entries_file"
    return 0
}

# Import a .pkgproj into the current document's model. The window is not
# touched here - the handler pushes the model once the import has succeeded.
# Arguments: absolute path of the .pkgproj
import_pkgproj() {
    local pkgproj_path="$1"
    # A .pkgproj describes one component, and it lands in the first one. Pinned
    # here, in the shell variable the accessors below default to, rather than
    # left to whatever the window last selected - and rather than through
    # set_current_component_index, which persists and would move the window's
    # own state on an import that refuses and changes nothing.
    PB_COMPONENT_INDEX=0
    import_project_dir="$(/usr/bin/dirname "$pkgproj_path")"
    # Read where it lies. This used to stage a copy under a .plist name, because
    # plister picked the format from the extension alone and .pkgproj is not an
    # extension it knows; it now falls back to the file's own content for any
    # unknown extension, and a .pkgproj is a plist however it is named (design
    # 12.2). Both the XML and the binary form read this way.
    #
    # import_file now names the USER'S project, so nothing in this file may
    # write to it or delete it. The cleanup at the end of this function removes
    # only what the import created - it used to name import_file as well, back
    # when that was a copy.
    import_file="$pkgproj_path"

    /bin/rm -f "$(state_dir)/import.entries"
    # The copy used to be what refused an unreadable or absent file, and cp said
    # why on stderr. plister would refuse it too, but a project it cannot read is
    # indistinguishable from one with nothing in it, so the user would be told
    # "this does not look like a Packages.app project" - plausible, and the wrong
    # problem. Refuse it here and name it, or the message is worse than the one
    # the copy used to produce.
    if [ ! -r "$import_file" ]; then
        append_log "! $(/usr/bin/basename "$pkgproj_path") cannot be read"
        return 1
    fi

    local settings="/PACKAGES/0/PACKAGE_SETTINGS"
    local name="$(import_get "$settings/NAME")"
    local version="$(import_get "$settings/VERSION")"
    local identifier="$(import_get "$settings/IDENTIFIER")"
    if [ -z "$name" ] && [ -z "$identifier" ]; then
        append_log "! This does not look like a Packages.app project: no package settings in it"
        return 1
    fi

    append_log "Imported from $(/usr/bin/basename "$pkgproj_path"):"

    # Everything is read before anything is written. The walk is the part that
    # can fail on a malformed project, and a failure after the settings had
    # already landed left a half-imported model behind a window still showing
    # the old values, with the document not even marked dirty. Reading first
    # makes the refusal paths mean what the log says they mean. Found in
    # review, 2026-08-07.
    local overwrite_flag="$(import_get "$settings/OVERWRITE_PERMISSIONS")"
    local relocatable_flag="$(import_get "$settings/RELOCATABLE")"
    local authentication="$(import_get "$settings/AUTHENTICATION")"
    local install_location="$(import_get "/PACKAGES/0/PACKAGE_FILES/DEFAULT_INSTALL_LOCATION")"

    # The payload walk, into a records file: the entries land in the model only
    # after the whole tree has been read, so a walk that trips over a malformed
    # node cannot leave half a payload behind.
    if ! import_walk_node "/PACKAGES/0/PACKAGE_FILES/HIERARCHY" ""; then
        append_log "! The payload hierarchy could not be read; nothing was imported"
        return 1
    fi

    [ -z "$name" ] || model_set /PROJECT/NAME "$name"
    [ -z "$version" ] || model_set /PROJECT/VERSION "$version"
    [ -z "$identifier" ] || model_set "/COMPONENTS/$PB_COMPONENT_INDEX/IDENTIFIER" "$identifier"
    # A .pkgproj describes one component at one version, which lands in
    # PROJECT/VERSION above. Any per-component override this document was
    # carrying describes the project that was just replaced, so it goes with it.
    model_set "/COMPONENTS/$PB_COMPONENT_INDEX/VERSION" ""

    # Booleans only when the key is present, so a sparse project does not
    # silently flip a safety default (design 8.1: overwrite-permissions).
    [ -z "$overwrite_flag" ] || model_set_bool "/COMPONENTS/$PB_COMPONENT_INDEX/OVERWRITE_PERMISSIONS" "$overwrite_flag"
    [ -z "$relocatable_flag" ] || model_set_bool "/COMPONENTS/$PB_COMPONENT_INDEX/RELOCATABLE" "$relocatable_flag"

    # Packages stores 1 for "requires administrator password".
    case "$authentication" in
        1) model_set "/COMPONENTS/$PB_COMPONENT_INDEX/AUTH" "Root" ;;
        '') ;;
        *) model_set "/COMPONENTS/$PB_COMPONENT_INDEX/AUTH" "User" ;;
    esac

    [ -z "$install_location" ] || model_set "/COMPONENTS/$PB_COMPONENT_INDEX/INSTALL_LOCATION" "$install_location"

    # The artifacts folder first, then the entries: store_path tokenizes every
    # source under it as ${ARTIFACTS_DIR}/... on the way in, which is what
    # makes the imported document portable to the machine where the artifacts
    # actually get built.
    local common_prefix="$(import_common_prefix)"
    if [ -n "$common_prefix" ]; then
        model_set /PROJECT/ARTIFACTS_DIR "$(store_path "$common_prefix")"
        append_log "  artifacts folder: $common_prefix"
    fi

    if ! import_apply_payload; then
        append_log "! A payload entry could not be written; save nothing and reopen the document"
        return 1
    fi

    local build_path="$(import_get "/PROJECT/PROJECT_SETTINGS/BUILD_PATH/PATH")"
    if [ -n "$build_path" ]; then
        model_set /PROJECT/OUTPUT_DIR "$(store_path "$(import_resolve "$build_path" "$(import_get "/PROJECT/PROJECT_SETTINGS/BUILD_PATH/PATH_TYPE")")")"
    fi

    local readme_path="$(import_get "/PROJECT/PROJECT_PRESENTATION/README/LOCALIZATIONS/0/VALUE/PATH")"
    if [ -n "$readme_path" ]; then
        model_set /DISTRIBUTION/RESOURCES/README "$(store_path "$(import_resolve "$readme_path" "$(import_get "/PROJECT/PROJECT_PRESENTATION/README/LOCALIZATIONS/0/VALUE/PATH_TYPE")")")"
        append_log "  readme: $(/usr/bin/basename "$readme_path")"
    fi

    # Said out loud rather than dropped quietly (design section 10). Only what
    # the project actually carries is reported, so the list is what was lost,
    # not a recitation of the format.
    append_log ""
    append_log "Not imported:"
    append_log "  the filesystem template tree Packages stores in every project"
    [ "$(import_count "/PROJECT/PROJECT_PRESENTATION/INSTALLATION_STEPS")" = "0" ] || \
        append_log "  the presentation model (titles, installation steps) beyond the readme"
    [ "$(import_count "/PROJECT/PROJECT_REQUIREMENTS/LIST")" = "0" ] || \
        append_log "  the requirement list"
    [ "$(import_count "/PROJECT/PROJECT_SETTINGS/EXCLUDED_FILES")" = "0" ] || \
        append_log "  the excluded-file patterns"

    # Only what the import created. import_file is the user's own .pkgproj.
    /bin/rm -f "$(state_dir)/import.entries"
    return 0
}
