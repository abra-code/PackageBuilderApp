#!/bin/sh
# lib.packagebuilder.importpkg.sh - import a built .pkg into the document
#
# The reverse of the build pipeline, as far as a package can be reversed. A .pkg
# carries everything the document says about how it was assembled - identifier,
# install location, the two safety flags, the whole payload with its modes and
# owners, the Distribution options, the installer identity - and exactly one
# thing it does not: where the artifacts came from. So the import reconstructs
# the document and leaves PAYLOAD/SOURCE as ${ARTIFACTS_DIR} placeholders for the
# user to point at a real build folder, which is the same one-field move a
# version bump already is.
#
# What is deliberately NOT done: nothing is extracted to a permanent location.
# The payload IS unpacked, into the state directory, but only so the verify block
# can be filled from the real binaries; the expansion is removed before this
# returns. Resource files and install scripts are named in the log rather than
# written out, for the same reason - an import that scatters files next to the
# user's document is doing more than it was asked.
#
# Sourced after lib.packagebuilder.sh (model accessors, store_path, payload
# helpers) and lib.packagebuilder.build.sh (pkgutil_tool, xml_element_attribute,
# xml_element_text, xml_unescape, indent_file, append_log_file).
#
# POSIX sh only. Validate with "sh -n", never "bash -n".

# The user's package, and the scratch expansion of it. importpkg_file is
# read-only throughout: like the .pkgproj importer, nothing here may write to or
# delete the file it was pointed at.
importpkg_file=""
importpkg_expand_dir=""
# Set to 1 when only "--expand" worked, so the payload is a cpio archive rather
# than a tree and the verify block cannot be filled from real binaries.
importpkg_payload_opaque=0

# One collected payload record per line in the component's entries file:
# relative path, destination, mode, owner, group - separated by the unit
# separator, which no path produced by pkgbuild can contain.
importpkg_record_separator="$(printf '\037')"

# A TAB or a NEWLINE in a payload path breaks that format, and lsbom offers no
# escaping for either. Detection is therefore in two places, because one does not
# cover the other: importpkg_collect_payload cross-checks PackageInfo's
# numberOfFiles against the BOM line count, which is what catches a newline, and
# the awk pass gates every line on field count and on the mode/uid/gid columns
# being numeric, which is what catches a tab. Either one refuses the payload
# outright rather than importing part of it - see the comment on the cross-check
# for what reading it anyway produced.

# --- reading the package ------------------------------------------------------

# Expand the package into the state directory. Prefers --expand-full, which
# unpacks Payload into a real tree so the verify block can be filled from the
# binaries that shipped; falls back to --expand, which always works where
# --expand-full does and leaves Payload as an opaque archive.
#
# A package pkgutil cannot open at all is the old bundle-format .mpkg - anything
# built before flat packages. That is a refusal with a name, not a crash: the
# expansion failure is the only symptom, and "could not be expanded" on its own
# reads like a corrupt file.
importpkg_expand() {
    local package_path="$1"
    local log_file="$(state_dir)/importpkg-$$.log"
    importpkg_expand_dir="$(state_dir)/importpkg-$$"
    # The pid is in both names because the Actions menu is never disabled while
    # an import runs and commands are async - the same collision the folder scan
    # and the inspector each had, fixed the same way.
    /bin/rm -rf "$importpkg_expand_dir"

    importpkg_payload_opaque=0
    if "$pkgutil_tool" --expand-full "$package_path" "$importpkg_expand_dir" > "$log_file" 2>&1; then
        /bin/rm -f "$log_file"
        return 0
    fi

    # --expand-full unpacks the payload and can fail on a package whose payload
    # holds something ditto refuses, where --expand - which only opens the xar
    # and leaves Payload alone - still gives us the BOM and PackageInfo. That is
    # the whole document except the verify block, so it is worth having.
    /bin/rm -rf "$importpkg_expand_dir"
    if "$pkgutil_tool" --expand "$package_path" "$importpkg_expand_dir" > "$log_file" 2>&1; then
        /bin/rm -f "$log_file"
        importpkg_payload_opaque=1
        return 0
    fi

    append_log "! $(/usr/bin/basename "$package_path") could not be expanded:"
    indent_file "$log_file" "  "
    append_log_file "$log_file"
    append_log "  A package built before flat packages (an old .mpkg bundle) cannot be read."
    /bin/rm -f "$log_file"
    /bin/rm -rf "$importpkg_expand_dir"
    importpkg_expand_dir=""
    return 1
}

# Which component's collected payload the three files below belong to.
#
# A package holds several components and each has its own payload, its own notes
# and its own reason for being refused. They are collected in one pass before
# anything is written, so all of them exist at once and cannot share a file name.
# Empty for the first, so the names a person sees while debugging a
# single-component import are the names they always were.
importpkg_slot=""

importpkg_entries_file() { printf '%s/importpkg.entries%s' "$(state_dir)" "$importpkg_slot"; }
importpkg_notes_file()   { printf '%s/importpkg.notes%s' "$(state_dir)" "$importpkg_slot"; }
importpkg_refusal_file() { printf '%s/importpkg.refusal%s' "$(state_dir)" "$importpkg_slot"; }

# Remove everything the import created. Called from every exit of import_pkg,
# success or failure: a half-written entries file surviving a refusal is
# harmless, because the next run truncates it, but relying on that is below the
# standard the rest of this file keeps.
importpkg_cleanup() {
    [ -z "$importpkg_expand_dir" ] || /bin/rm -rf "$importpkg_expand_dir"
    # Globbed: there is one set of these per component, and the slot suffix
    # that named them is whatever the last run reached rather than something
    # this function can recompute.
    /bin/rm -f "$(state_dir)"/importpkg.entries* \
               "$(state_dir)"/importpkg.notes* \
               "$(state_dir)"/importpkg.refusal* \
               "$(state_dir)"/importpkg.readable* \
               "$(state_dir)/importpkg.components" \
               "$(state_dir)/importpkg.components.refs" \
               "$(state_dir)/importpkg.bundles" \
               "$(state_dir)/importpkg.bom" \
               "$(state_dir)/importpkg.bom.notes" \
               "$(state_dir)/importpkg.sources" \
               "$(state_dir)/importpkg-$$.dropped" \
               "$(state_dir)/importpkg-$$.log" \
               "$(state_dir)/importpkg-$$.toc" \
               "$(state_dir)/importpkg-$$.b64" \
               "$(state_dir)/importpkg-$$.der"
    importpkg_expand_dir=""
    return 0
}

# Write one component directory path per line into $(state_dir)/importpkg.components.
#
# Order matters, because the first one is the one that gets imported. A glob
# gives alphabetical order, which for python.org's installer would pick
# "Python_Applications.pkg" over the framework everything else depends on. The
# Distribution's own pkg-ref order is the order the package was authored in, so
# that is used when there is a Distribution, with the glob appended for anything
# the references missed and used alone for a component package.
importpkg_collect_components() {
    local out="$(state_dir)/importpkg.components"
    local distribution="$importpkg_expand_dir/Distribution"
    # Set by the loops below.
    local name dir
    : > "$out"

    if [ -f "$distribution" ]; then
        # The payload of each pkg-ref is "#<file>.pkg". Anchored on "#" and on
        # the "<" that starts the closing tag so a resource file named
        # something.pkg in an attribute cannot be picked up.
        /usr/bin/grep -o '#[^<"]*\.pkg<' "$distribution" 2>/dev/null \
            | /usr/bin/sed -e 's/^#//' -e 's/<$//' > "$out.refs"
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            name="$(xml_unescape "$name")"
            [ -d "$importpkg_expand_dir/$name" ] || continue
            /usr/bin/grep -q -x -F -- "$importpkg_expand_dir/$name" "$out" 2>/dev/null && continue
            printf '%s\n' "$importpkg_expand_dir/$name" >> "$out"
        done < "$out.refs"
        /bin/rm -f "$out.refs"
    fi

    for dir in "$importpkg_expand_dir"/*.pkg; do
        [ -d "$dir" ] || continue
        /usr/bin/grep -q -x -F -- "$dir" "$out" 2>/dev/null && continue
        printf '%s\n' "$dir" >> "$out"
    done

    # A component package built on its own IS the component: PackageInfo sits at
    # the top of the expansion and there are no *.pkg directories under it.
    if [ ! -s "$out" ] && [ -f "$importpkg_expand_dir/PackageInfo" ]; then
        printf '%s\n' "$importpkg_expand_dir" >> "$out"
    fi

    [ -s "$out" ] || return 1
    return 0
}

# Print the bundle roots PackageInfo records for a component, one per line,
# relative to the install location and carrying the leading "./" the BOM uses.
#
# This is what collapses a payload back to artifacts. A BOM lists every file in
# an .app - 52 of them for IDLE.app, tens of thousands for a real application -
# and the document wants one entry naming the bundle. pkgbuild writes exactly
# the list needed to undo that: <bundle path="./Python 3.14/IDLE.app" .../>.
#
# The "path=" filter is load-bearing. <bundle-version>, <upgrade-bundle> and
# <strict-identifier> each hold <bundle id="..."/> elements with no path, and
# those are the same bundles counted again, not more of them.
importpkg_bundle_roots() {
    local package_info="$1"
    [ -f "$package_info" ] || return 0
    /usr/bin/tr '\n' ' ' < "$package_info" 2>/dev/null \
        | /usr/bin/grep -o '<bundle[[:space:]][^>]*>' \
        | /usr/bin/grep -o 'path="[^"]*"' \
        | /usr/bin/sed -e 's/^path="//' -e 's/"$//' \
        | while IFS= read -r raw_path; do
              [ -n "$raw_path" ] || continue
              xml_unescape "$raw_path"
              printf '\n'
          done
}

# How many payload entries an import will write before it gives up on the
# payload. A component whose install location is a directory full of loose files
# - Python's documentation tree is seventy thousand of them - is not a list of
# artifacts, and a payload table holding all of them is not a document anyone can
# work with. The rest of the import still lands; only the payload is refused, and
# the log says why.
PB_IMPORT_MAX_PAYLOAD=500

# Print "1" when a component's payload is itself the inside of one bundle.
#
# The framework case, and it is common: a component whose install location is
# /Library/Frameworks/Python.framework has a BOM rooted inside the framework, so
# every path in it is a file within a bundle rather than an artifact. Read
# literally that produces three and a half thousand payload entries describing
# one thing. What the document should say instead is the one thing: install
# Python.framework into /Library/Frameworks.
importpkg_payload_is_bundle() {
    local bom="$1"
    [ -f "$bom" ] || { printf '0'; return 0; }
    if /usr/bin/lsbom -s "$bom" 2>/dev/null \
        | /usr/bin/grep -q -E '^\./(Contents/Info\.plist|Versions/[^/]+/Resources/Info\.plist)$'; then
        printf '1'
    else
        printf '0'
    fi
}

# Collect one component's BOM into the records file.
# Arguments: component directory, install location, whole-bundle destination
#
# The BOM is the authority on structure, mode and ownership even when the
# payload was unpacked, because unpacking is allowed to lose things the BOM
# records exactly.
importpkg_collect_payload() {
    local component_dir="$1" install_location="$2" whole_bundle="$3"
    local bom="$component_dir/Bom"
    local package_info="$component_dir/PackageInfo"
    local entries_file="$(importpkg_entries_file)"
    local bundles_file="$(state_dir)/importpkg.bundles"
    local bom_file="$(state_dir)/importpkg.bom"

    # No Bom is not a failure. A component can install nothing and carry only
    # install scripts - python.org ships two of them, Python_Install_Pip.pkg and
    # Python_Shell_Profile_Updater.pkg, each a PackageInfo and a Scripts
    # directory with no Bom and no numberOfFiles at all. Treating that as fatal
    # refused the whole import of any package whose first component happened to
    # be one, which is a legitimate package and a legitimate thing to import.
    if [ ! -f "$bom" ]; then
        printf '%s\n' "  this component installs no files - it carries only install scripts." \
            > "$(importpkg_refusal_file)"
        return 2
    fi

    # One entry for the whole thing. 0755 rather than the BOM's mode for "." on
    # purpose: that is what guess_mode gives a bundle, and it is the mode the
    # same artifact would get if it were dropped on the payload table.
    if [ -n "$whole_bundle" ]; then
        printf '%s%s%s%s%s%s%s%s%s\n' \
            "$(/usr/bin/basename "$whole_bundle")" "$importpkg_record_separator" \
            "$whole_bundle" "$importpkg_record_separator" \
            "0755" "$importpkg_record_separator" \
            "root" "$importpkg_record_separator" "wheel" \
            >> "$entries_file"
        return 0
    fi

    importpkg_bundle_roots "$package_info" > "$bundles_file"
    # f m u g l: path, octal mode with its type bits, numeric uid, numeric gid,
    # symlink target. One pass gives everything a payload entry needs.
    if ! /usr/bin/lsbom -p fmugl "$bom" > "$bom_file" 2>/dev/null; then
        append_log "! that component's Bom could not be read"
        /bin/rm -f "$bundles_file" "$bom_file"
        return 1
    fi

    # A path holding a TAB or a NEWLINE breaks the format this whole function
    # rests on, and neither can be escaped: lsbom writes both raw. A tab adds a
    # field; a newline splits one entry across two lines, and the tail of that
    # split is itself a well-formed five-field record. Reading it produced three
    # entries out of two files, one of them destined for "/line.txt" - a payload
    # item installing at the filesystem root, written into the model with no
    # warning at all. The same class of silent corruption out of a data file the
    # .pkgproj importer refuses per node; it cannot be refused per node here,
    # because by the time this sees a line the break is already a line boundary.
    #
    # PackageInfo counts the BOM for us. numberOfFiles is exactly the number of
    # BOM entries - verified against replay, and against Python components of 52,
    # 1156 and 4158 - so a disagreement means a path split a line. The awk pass
    # gates each line on shape as well, which is what catches the tab, since a
    # tab does not change the line count.
    local declared_files="$(/usr/bin/grep -o 'numberOfFiles="[0-9]*"' "$package_info" 2>/dev/null \
        | /usr/bin/head -n 1 | /usr/bin/tr -dc '0-9')"
    local actual_lines="$(/usr/bin/grep -c . "$bom_file" | /usr/bin/tr -d ' ')"
    case "$actual_lines" in ''|*[!0-9]*) actual_lines=0 ;; esac
    if [ -n "$declared_files" ] && [ "$declared_files" != "$actual_lines" ]; then
        # Written, not logged. The collect phase runs before import_pkg has
        # printed the "Payload:" heading, so logging here put the reason above
        # the component header where it read as part of the preamble - the same
        # detachment the skipped-symlink notes had.
        {
            printf '%s\n' "  PackageInfo counts $declared_files items and the BOM yields $actual_lines lines,"
            printf '%s\n' "  which means a payload path contains a line break. lsbom writes one raw, so"
            printf '%s\n' "  the entry splits across two lines and the tail of it reads as a whole"
            printf '%s\n' "  record - the payload cannot be read without inventing entries."
        } > "$(importpkg_refusal_file)"
        /bin/rm -f "$bundles_file" "$bom_file"
        return 2
    fi

    # awk rather than a shell loop: a framework payload is four thousand BOM
    # lines and a real application is far more, and this runs while the user
    # waits.
    #
    # Two phases, and they cannot be collapsed into one. A BOM lists a directory
    # BEFORE the files under it, so "does this directory hold anything" is not
    # answerable at the moment the directory is read - every one of them would
    # look empty and be emitted as a payload entry of its own. The whole BOM is
    # therefore read and indexed first, and every decision is made in END.
    #
    # The two-file idiom is keyed on FILENAME, not on the usual NR==FNR, because
    # an empty bundles file - a component holding no bundle at all, which is the
    # common case - makes NR==FNR true for the first BOM line and would file a
    # payload entry away as a bundle root.
    /usr/bin/awk -F'\t' \
        -v bundles_file="$bundles_file" \
        -v notes_file="$bom_file.notes" \
        -v install_location="$install_location" \
        -v separator="$importpkg_record_separator" '
        FILENAME == bundles_file {
            if (length($0) > 0) bundle[$0] = 1
            next
        }
        {
            # The shape gate. A tab inside a path adds a field and shifts the
            # numeric columns along, so "ta<TAB>b.txt" arrived as mode ".txt" and
            # owner "100644". Anything that is not exactly five fields with three
            # numeric columns is not a BOM line this can read, and reading it
            # anyway invents a payload entry.
            # The "^\./" term is what closes a crafted package. The field-count
            # test alone rejects a stray fragment, but a filename that itself
            # looks like a BOM record - "decoy<TAB>100644<TAB>0<TAB>0<TAB>pad"
            # followed by a newline - splits into lines that are ALL well
            # formed, and one file then yields two payload rows, the second
            # landing at the filesystem root. lsbom roots every real path at
            # "./", and a fabricated tail cannot. Found in review.
            # "." is the payload root and is the one path lsbom writes without
            # the "./" prefix; it is skipped later but must not be counted as
            # malformed, or every package refuses its own payload.
            if (($1 != "." && $1 !~ /^\.\//) || NF != 5 || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/) {
                malformed++
                next
            }
            count++
            path[count] = $1; mode[count] = $2; uid[count] = $3; gid[count] = $4

            # PackageInfo lists only the bundles pkgbuild considered for
            # relocation, which means the TOP-level ones. A framework nested
            # inside another payload - Tcl.framework inside Python.framework -
            # is not in that list, and read literally it explodes into three
            # thousand entries. So the BOM is also asked directly, using the
            # same two layouts bundle_info_plist knows: Contents/Info.plist for
            # an .app, Versions/<v>/Resources/Info.plist for a framework.
            #
            # A derived root of "." is rejected: that is the payload root
            # itself, the case importpkg_payload_is_bundle handles by collapsing
            # the component to a single entry. Accepting it here would mark
            # every path in the BOM as "inside a bundle" and import nothing.
            if ($1 ~ /\/Contents\/Info\.plist$/) {
                derived = $1; sub(/\/Contents\/Info\.plist$/, "", derived)
                if (derived != "." && derived != "") bundle[derived] = 1
            } else if ($1 ~ /\/Versions\/[^\/]+\/Resources\/Info\.plist$/) {
                derived = $1; sub(/\/Versions\/[^\/]+\/Resources\/Info\.plist$/, "", derived)
                if (derived != "." && derived != "") bundle[derived] = 1
            }
        }
        END {
            # Phase A: decide which entries survive filtering, and mark parents
            # from THOSE only.
            #
            # Marking during the read - which is what this did first - counts a
            # child that is itself dropped. A directory holding nothing but
            # symlinks, which /usr/local/lib really is on some systems, was then
            # dropped as scaffold while every one of its children was dropped as
            # a link, and the directory vanished from the payload with only the
            # symlink note to hint at it.
            for (i = 1; i <= count; i++) {
                p = path[i]
                if (p == "." || p == "") continue
                base = p
                sub(/^.*\//, "", base)
                # AppleDouble companions carry the resource fork of a file that
                # is already in the payload under its own name. They are an
                # artifact of how the tree was copied, never something a user
                # chose to install.
                if (base ~ /^\._/) { appledouble++; kept[i] = 0; continue }
                # The document model has no symlink of its own: an entry names a
                # source that gets copied. A link in the payload came from a link
                # in the source tree, which the payload folder scan skips for the
                # same reason, so it is counted and named rather than turned into
                # an entry that would copy the target instead.
                if (mode[i] ~ /^12/) { links++; kept[i] = 0; continue }
                kept[i] = 1
                if (match(p, /\/[^\/]*$/)) haschild[substr(p, 1, RSTART - 1)] = 1
            }

            # Phase B: emit.
            for (i = 1; i <= count; i++) {
                p = path[i]
                m = mode[i]
                if (p == "." || p == "" || !kept[i]) continue

                # Both flags are computed over the WHOLE set before either is
                # acted on. Breaking early made the outcome depend on the awk hash
                # order: a nested bundle is both a root of its own and inside
                # its parent, and whichever the loop happened to see first
                # decided whether it was emitted as an entry or skipped. Inside
                # always wins, so the outer bundle is the artifact and what is
                # nested in it rides along.
                is_root = 0
                is_inside = 0
                for (b in bundle) {
                    if (p == b) is_root = 1
                    else if (index(p, b "/") == 1) is_inside = 1
                }
                if (is_inside) continue

                # A directory holding anything that survived Phase A is scaffold
                # - pkgbuild recreates it from the entries beneath it. One
                # holding nothing was put there on purpose and is the only kind
                # worth an entry of its own.
                if (!is_root && m ~ /^4/ && haschild[p]) continue

                # Permission bits are the last four octal digits whether the
                # type prefix is three digits (100755, a file) or one (40755, a
                # directory), which also keeps a setuid bit: 104755 -> 4755.
                perm = (length(m) >= 4) ? substr(m, length(m) - 3) : m

                relative = p
                sub(/^\.\//, "", relative)
                if (relative == "") continue
                destination = install_location "/" relative
                gsub(/\/\/+/, "/", destination)
                # Absent and zero both mean the default a dropped artifact gets.
                # Anything else stays numeric, which staging already warns about
                # since --ownership recommended does not apply it.
                owner = (uid[i] == "" || uid[i] == "0") ? "root" : uid[i]
                group = (gid[i] == "" || gid[i] == "0") ? "wheel" : gid[i]
                print relative separator destination separator perm separator owner separator group
            }
            if (links > 0)       printf("links %d\n", links)            > notes_file
            if (appledouble > 0) printf("appledouble %d\n", appledouble) > notes_file
            if (malformed > 0)   printf("malformed %d\n", malformed)     > notes_file
        }
    ' "$bundles_file" "$bom_file" >> "$entries_file"

    # A line the shape gate rejected means a path held a tab, which the
    # numberOfFiles cross-check above cannot see because a tab does not change
    # the line count. Refused for the same reason: whatever this went on to
    # import would be missing entries and would not say which.
    if /usr/bin/grep -q '^malformed ' "$bom_file.notes" 2>/dev/null; then
        {
            printf '%s\n' "  $(/usr/bin/sed -n 's/^malformed //p' "$bom_file.notes") line(s) of the BOM do not parse as entries, which means a payload"
            printf '%s\n' "  path contains a tab. A tab shifts the mode, owner and group columns along,"
            printf '%s\n' "  so the payload cannot be read without dropping items silently."
        } > "$(importpkg_refusal_file)"
        /bin/rm -f "$bundles_file" "$bom_file" "$bom_file.notes"
        return 2
    fi

    # The notes survive this function on purpose. They belong under the
    # "Payload:" heading, which import_pkg has not written yet, and printing
    # them here put them above it where they read as part of the preamble.
    /bin/mv -f "$bom_file.notes" "$(importpkg_notes_file)" 2>/dev/null
    /bin/rm -f "$bundles_file" "$bom_file"
    return 0
}

# Log what the collect phase dropped. Said out loud rather than dropped quietly:
# a payload that lost four symlinks to this import is a payload the next build
# will not reproduce, and the only place that can be noticed is here.
importpkg_log_notes() {
    local notes_file="$(importpkg_notes_file)"
    # Set by the loop below.
    local note_kind note_count
    [ -f "$notes_file" ] || return 0
    while read -r note_kind note_count; do
        case "$note_kind" in
            links)       append_log "  note: $note_count symlink(s) skipped - the sources must recreate them" ;;
            appledouble) append_log "  note: $note_count AppleDouble (._*) companion(s) skipped" ;;
        esac
    done < "$notes_file"
    /bin/rm -f "$notes_file"
    return 0
}

# --- the installer identity ---------------------------------------------------

# Print the Common Name of the certificate a package was signed with, or nothing
# when it carries no signature.
#
# Read out of the xar table of contents rather than from pkgutil --check-signature,
# which reports "invalid signature" and prints no chain at all for a package whose
# certificate cannot be validated on this machine - an expired identity, or one
# issued to somebody else. The identity that signed it is a fact about the file
# and is recoverable either way; whether this Mac trusts it is a different
# question and not the one being asked.
#
# The first X509Certificate in the TOC is the leaf. The chain follows it, and
# "Developer ID Certification Authority" is not an identity anyone signs with.
importpkg_installer_identity() {
    local package_path="$1"
    local toc="$(state_dir)/importpkg-$$.toc"
    local encoded="$(state_dir)/importpkg-$$.b64"
    local decoded="$(state_dir)/importpkg-$$.der"
    local identity=""

    if ! /usr/bin/xar -f "$package_path" --dump-toc="$toc" 2>/dev/null; then
        /bin/rm -f "$toc"
        return 0
    fi
    /usr/bin/awk '
        /<X509Certificate>/ { grabbing = 1 }
        grabbing            { print }
        /<\/X509Certificate>/ { if (grabbing) exit }
    ' "$toc" 2>/dev/null \
        | /usr/bin/sed -e 's|.*<X509Certificate>||' -e 's|</X509Certificate>.*||' \
        | /usr/bin/tr -d ' \011\012\015' > "$encoded"
    /bin/rm -f "$toc"

    if [ ! -s "$encoded" ]; then
        /bin/rm -f "$encoded"
        return 0
    fi
    if /usr/bin/base64 -D -i "$encoded" -o "$decoded" 2>/dev/null; then
        identity="$(/usr/bin/openssl x509 -inform DER -in "$decoded" -noout -subject 2>/dev/null \
            | /usr/bin/sed -e 's|.*/CN=||' -e 's|/.*||')"
    fi
    /bin/rm -f "$encoded" "$decoded"
    printf '%s' "$identity"
}

# --- writing the payload ------------------------------------------------------

# Replace the payload with the collected entries.
#
# SOURCE is a placeholder, because a package does not carry one. The basename is
# what a build folder actually holds - "replay", not "usr/local/bin/replay" - so
# that is what is written, and the path under the install location is the
# fallback when two entries would otherwise claim the same source.
importpkg_apply_payload() {
    local payload_root="$1" whole_bundle_name="$2"
    local entries_file="$(importpkg_entries_file)"
    local used_file="$(state_dir)/importpkg.sources"
    # Set by the loop below.
    local relative destination mode_octal owner group overflow
    local entry_index source_name extracted executable arch_list duplicates

    # The clear happens FIRST, and unconditionally, because an empty collection
    # is still an answer about this package: it installs nothing. Returning
    # early here - which is what the .pkgproj importer does, correctly, since a
    # scaffold-only project says nothing about the payload either way - left the
    # previous project's entries in a document whose identifier, install
    # location and signing had all become the imported package's. That is the
    # same chimera the >500 and unreadable routes were fixed to avoid, reached
    # by a third door: an empty root, or a payload that is only symlinks and
    # AppleDouble companions. Found in review.
    while [ "$(payload_count)" -gt 0 ]; do
        payload_remove_at 0 || return 1
    done

    if [ ! -s "$entries_file" ]; then
        append_log "  this component installs no files."
        return 0
    fi

    : > "$used_file"
    duplicates=0
    while IFS="$importpkg_record_separator" read -r relative destination mode_octal owner group overflow; do
        # A record that does not split into exactly five fields means the BOM
        # held a path with a line break in it, which shifts every field after it
        # and would fabricate half-empty entries out of a data file. Refused per
        # entry rather than per import: the rest of the payload is sound.
        if [ -z "$group" ] || [ -n "$overflow" ]; then
            append_log "  ! a payload entry could not be read and was skipped"
            continue
        fi

        source_name="$(/usr/bin/basename "$relative")"
        if /usr/bin/grep -q -x -F -- "$source_name" "$used_file" 2>/dev/null; then
            source_name="$relative"
            duplicates=$((duplicates + 1))
        fi
        printf '%s\n' "$source_name" >> "$used_file"

        entry_index="$(payload_count)"
        "$plister" insert "$entry_index" dict "$(model_file)" "/COMPONENTS/$PB_COMPONENT_INDEX/PAYLOAD" || return 1

        # The verify block describes what the NEXT build must produce, not what
        # this package happens to contain, so the three assertions a dropped
        # artifact starts with are what a Mach-O gets here too (design 5.3).
        # ARCHITECTURES is the exception and is read for real: asserting
        # x86_64 + arm64 about an arm64-only package would fail every build
        # until someone worked out why.
        executable=""
        arch_list=""
        if [ "$importpkg_payload_opaque" = "0" ] && [ -n "$payload_root" ]; then
            # For a whole-bundle component the payload directory IS the bundle's
            # contents, so the artifact is $payload_root itself. Joining the
            # basename on gave "Payload/Foo.framework", which never exists - so
            # the one artifact class most likely to be a signed, hardened,
            # universal binary was the only one that asserted nothing.
            if [ -n "$whole_bundle_name" ] && [ "$relative" = "$whole_bundle_name" ]; then
                extracted="$payload_root"
            else
                extracted="$payload_root/$relative"
            fi
            executable="$(artifact_executable "$extracted")"
            if [ -n "$executable" ]; then
                arch_list="$(/usr/bin/lipo -archs "$executable" 2>/dev/null | /usr/bin/tr ' ' '\n' | /usr/bin/grep -v '^$')"
            fi
        fi

        if ! { payload_set "$entry_index" SOURCE "\${ARTIFACTS_DIR}/$source_name" &&
               payload_set "$entry_index" DESTINATION "$destination" &&
               payload_set "$entry_index" OWNER "$owner" &&
               payload_set "$entry_index" GROUP "$group" &&
               payload_set "$entry_index" MODE "$mode_octal" &&
               ensure_payload_verify "$entry_index" &&
               payload_set "$entry_index" VERIFY/VERSION_FLAG ""; }; then
            payload_remove_at "$entry_index"
            return 1
        fi

        # One chain with one rollback, matching payload_append_from_path and
        # import_apply_payload. Returning straight out of here left the
        # half-built entry in the payload, which is the phantom the block above
        # is careful to remove.
        if [ -n "$executable" ]; then
            if ! { payload_archs_set "$entry_index" "$arch_list" &&
                   payload_signed_set "$entry_index" 1 &&
                   payload_bool_set "$entry_index" VERIFY/HARDENED_RUNTIME 1 &&
                   payload_bool_set "$entry_index" VERIFY/SECURE_TIMESTAMP 1; }; then
                payload_remove_at "$entry_index"
                return 1
            fi
        else
            if ! { payload_universal_set "$entry_index" 0 &&
                   payload_signed_set "$entry_index" 0 &&
                   payload_bool_set "$entry_index" VERIFY/HARDENED_RUNTIME 0 &&
                   payload_bool_set "$entry_index" VERIFY/SECURE_TIMESTAMP 0; }; then
                payload_remove_at "$entry_index"
                return 1
            fi
        fi

        append_log "  $destination ($mode_octal $owner:$group)"
    done < "$entries_file"

    if [ "$duplicates" -gt 0 ]; then
        append_log "  note: $duplicates entries share a file name, so their sources kept the full path"
    fi
    /bin/rm -f "$used_file"
    return 0
}

# --- reading one component out of several -------------------------------------

# The file-name suffix that keeps component <n>'s collected payload apart from
# the others. Empty for the first, so a single-component import writes and reads
# the same three file names it always did.
importpkg_slot_for() {
    local component_index="$1"
    [ "$component_index" = "0" ] || printf '.%s' "$component_index"
    return 0
}

# The install location, when this component installs INTO a bundle rather than
# into a directory - a framework, an app. Prints nothing otherwise.
importpkg_whole_bundle() {
    local component_dir="$1" install_location="$2"
    [ "$install_location" != "/" ] || return 0
    [ "$(importpkg_payload_is_bundle "$component_dir/Bom")" = "1" ] || return 0
    printf '%s' "$install_location"
    return 0
}

# The auth attribute of the terminal pkg-ref naming this identifier.
#
# Read for one identifier rather than for the first pkg-ref in the file. A
# multi-component Distribution carries one per component, and taking the first
# would give every component the first one's auth - which is exactly the kind of
# wrong-but-plausible import that is never noticed until an installer asks for a
# password it should not need, or fails to ask for one it should.
#
# The whole document is accumulated into one string first, because the elements
# are not reliably one per line: productbuild pretty-prints, this app's own
# generator writes one per line, and a hand-written Distribution may put the lot
# on a single line.
# Arguments: Distribution path, identifier
importpkg_pkgref_auth() {
    local distribution="$1" identifier="$2"
    [ -n "$identifier" ] || return 0
    [ -f "$distribution" ] || return 0
    /usr/bin/awk -v want="$identifier" '
        { all = all $0 " " }
        END {
            pos = 1
            while ((found = index(substr(all, pos), "<pkg-ref ")) > 0) {
                start = pos + found - 1 + 9
                rest = substr(all, start)
                close_at = index(rest, ">")
                tag = (close_at > 0) ? substr(rest, 1, close_at - 1) : rest
                if (index(tag, "id=\"" want "\"") > 0 && match(tag, /auth="[^"]*"/)) {
                    print substr(tag, RSTART + 6, RLENGTH - 7)
                    exit
                }
                pos = start
            }
        }
    ' "$distribution" 2>/dev/null
    return 0
}

# The title of the choice that holds this identifier's pkg-ref, which is what a
# multi-component installer shows in its list. Prints nothing when the
# Distribution has no choice for it.
# Arguments: Distribution path, identifier
importpkg_choice_title() {
    local distribution="$1" identifier="$2"
    [ -n "$identifier" ] || return 0
    [ -f "$distribution" ] || return 0
    /usr/bin/awk -v want="$identifier" '
        { all = all $0 " " }
        END {
            pos = 1
            while ((found = index(substr(all, pos), "<choice ")) > 0) {
                start = pos + found - 1 + 8
                rest = substr(all, start)
                end_at = index(rest, "</choice>")
                block = (end_at > 0) ? substr(rest, 1, end_at - 1) : rest
                if (index(block, "<pkg-ref id=\"" want "\"") > 0 &&
                    match(block, /title="[^"]*"/)) {
                    print substr(block, RSTART + 7, RLENGTH - 8)
                    exit
                }
                pos = start
            }
        }
    ' "$distribution" 2>/dev/null
    return 0
}

# Whether the choice holding this identifier starts selected. Prints 1 unless
# the Distribution says start_selected="false", because that is what
# productbuild does with a choice that says nothing.
# Arguments: Distribution path, identifier
importpkg_choice_selected() {
    local distribution="$1" identifier="$2"
    if [ -z "$identifier" ] || [ ! -f "$distribution" ]; then
        printf '1'
        return 0
    fi
    /usr/bin/awk -v want="$identifier" '
        { all = all $0 " " }
        END {
            pos = 1
            while ((found = index(substr(all, pos), "<choice ")) > 0) {
                start = pos + found - 1 + 8
                rest = substr(all, start)
                end_at = index(rest, "</choice>")
                block = (end_at > 0) ? substr(rest, 1, end_at - 1) : rest
                if (index(block, "<pkg-ref id=\"" want "\"") > 0) {
                    # Only the opening tag: an attribute after the first ">"
                    # belongs to a pkg-ref, not to the choice.
                    gt = index(block, ">")
                    open_tag = (gt > 0) ? substr(block, 1, gt - 1) : block
                    if (index(open_tag, "start_selected=\"false\"") > 0) print "0"
                    else print "1"
                    exit
                }
                pos = start
            }
            print "1"
        }
    ' "$distribution" 2>/dev/null
    return 0
}

# Give the document exactly as many components as the package has.
#
# Shrinking matters as much as growing. Importing a two-component package into a
# document that held five must not leave three of the old ones behind: they
# would describe a project this package knows nothing about, and the build would
# happily produce them.
importpkg_resize_components() {
    local wanted="$1"
    local have="$(model_count /COMPONENTS)"
    case "$have" in
        ''|*[!0-9]*) have=0 ;;
    esac
    while [ "$have" -lt "$wanted" ]; do
        "$plister" insert "$have" dict "$(model_file)" /COMPONENTS || return 1
        have=$((have + 1))
    done
    # Removed from the end, so the index of every element still to be removed
    # stays what it was. Removing from the front renumbers the rest under the
    # loop, which leaves it deleting elements it has already passed.
    while [ "$have" -gt "$wanted" ]; do
        "$plister" remove "$(model_file)" "/COMPONENTS/$((have - 1))" || return 1
        have=$((have - 1))
    done
    # Fills in every key the new components do not have yet, including their
    # empty PAYLOAD arrays, before the write pass starts putting values in them.
    model_normalize
    return 0
}

# How many payload entries the document holds across all its components. Used
# only to decide whether the "sources did not come across" note has anything to
# be about.
importpkg_total_payload_entries() {
    local total=0 component_index=0
    local component_total="$(component_count)"
    while [ "$component_index" -lt "$component_total" ]; do
        total=$((total + $(payload_count "$component_index")))
        component_index=$((component_index + 1))
    done
    printf '%s' "$total"
}

# --- the import ---------------------------------------------------------------

# Read a built package into the current document's model. The window is not
# touched here - the handler pushes the model once the import has succeeded.
# Arguments: absolute path of the .pkg
import_pkg() {
    local package_path="$1"
    # Set below, all read before anything is written.
    local components_file component_dir component_count package_info distribution
    local identifier version install_location overwrite relocatable auth
    local title min_os architectures customize require_scripts
    local identity project_name package_base payload_root
    local scripts_note resource_note component_index
    local whole_bundle payload_total payload_readable component_own_version
    local scripts_seen refused_any first_package_info

    # The write loop below assigns this per component, so nothing that runs
    # after it depends on the value coming in. The read pass does run first,
    # though, and a line added there that touched the model would otherwise
    # address whichever component the window happened to have selected. Pinned
    # here rather than through set_current_component_index: that one persists
    # and discards the payload selection, which would move the window's state
    # on an import that refuses and changes nothing.
    PB_COMPONENT_INDEX=0

    importpkg_file="$package_path"
    importpkg_slot=""
    /bin/rm -f "$(state_dir)"/importpkg.entries* "$(state_dir)"/importpkg.refusal* \
               "$(state_dir)"/importpkg.notes* "$(state_dir)"/importpkg.readable*

    if [ ! -r "$importpkg_file" ]; then
        append_log "! $(/usr/bin/basename "$package_path") cannot be read"
        return 1
    fi

    package_base="$(/usr/bin/basename "$package_path")"
    append_log "Imported from $package_base:"
    append_log ""

    importpkg_expand "$package_path" || return 1

    if ! importpkg_collect_components; then
        append_log "! nothing in $package_base looks like an installer component"
        importpkg_cleanup
        return 1
    fi
    components_file="$(state_dir)/importpkg.components"
    component_count="$(/usr/bin/grep -c . "$components_file" | /usr/bin/tr -d ' ')"
    case "$component_count" in
        ''|*[!0-9]*) component_count=0 ;;
    esac
    distribution="$importpkg_expand_dir/Distribution"
    first_package_info="$(/usr/bin/head -n 1 "$components_file")/PackageInfo"

    if [ ! -f "$first_package_info" ]; then
        append_log "! that package's first component has no PackageInfo"
        importpkg_cleanup
        return 1
    fi

    # =========================================================================
    # Read pass. Nothing below this point writes to the model until the write
    # pass begins, so a refusal partway through cannot leave a half-imported
    # document behind a window still showing the old values. The .pkgproj
    # importer learned this in review; this one inherits it rather than
    # rediscovering it - and with several components there is more to lose,
    # because a failure on the fourth would otherwise strand three.
    # =========================================================================
    component_index=0
    while [ "$component_index" -lt "$component_count" ]; do
        importpkg_slot="$(importpkg_slot_for "$component_index")"
        component_dir="$(/usr/bin/sed -n "$((component_index + 1))p" "$components_file")"
        package_info="$component_dir/PackageInfo"
        if [ ! -f "$package_info" ]; then
            append_log "! component $((component_index + 1)) of that package has no PackageInfo"
            importpkg_cleanup
            return 1
        fi

        install_location="$(xml_element_attribute "$package_info" pkg-info install-location)"
        [ -n "$install_location" ] || install_location="/"
        whole_bundle="$(importpkg_whole_bundle "$component_dir" "$install_location")"
        [ -z "$whole_bundle" ] || install_location="$(/usr/bin/dirname "$whole_bundle")"

        # 2 is "the payload could not be read but the rest of the component is
        # sound", which the >500 branch reaches by a different route and the
        # write pass handles the same way: the component still gets everything
        # else. Anything else is fatal for the whole import.
        importpkg_collect_payload "$component_dir" "$install_location" "$whole_bundle"
        payload_readable=$?
        if [ "$payload_readable" != "0" ] && [ "$payload_readable" != "2" ]; then
            importpkg_cleanup
            return 1
        fi
        printf '%s' "$payload_readable" > "$(state_dir)/importpkg.readable$importpkg_slot"

        component_index=$((component_index + 1))
    done

    # --- the package as a whole, read once -----------------------------------
    version="$(xml_element_attribute "$first_package_info" pkg-info version)"

    # auth, the title and the options live on the Distribution, never in
    # PackageInfo, which always says auth="root" (design section 4). A component
    # package has no Distribution and therefore no recorded auth, so the
    # default stands.
    title=""
    min_os=""
    architectures=""
    customize=""
    require_scripts=""
    if [ -f "$distribution" ]; then
        title="$(xml_element_text "$distribution" title)"
        min_os="$(xml_element_attribute "$distribution" os-version min)"
        architectures="$(xml_element_attribute "$distribution" options hostArchitectures)"
        customize="$(xml_element_attribute "$distribution" options customize)"
        require_scripts="$(xml_element_attribute "$distribution" options require-scripts)"
    fi

    identity="$(importpkg_installer_identity "$package_path")"

    # PROJECT.NAME becomes part of a filename and design 4.4 restricts it to
    # [A-Za-z0-9._-]. An installer title is free text - "Python 3.14" - so it is
    # folded into the allowed set rather than refused, and the package's own file
    # name is the fallback when there is no title at all.
    project_name="$title"
    [ -n "$project_name" ] || project_name="${package_base%.pkg}"
    # Byte-oriented, deliberately: tr has no notion of UTF-8, so "Cafe Suite"
    # with an accented e yields two underscores for that one character. The
    # result still satisfies 4.4 and is still recognizable, and the alternative
    # is a transliteration table this app has no reason to carry.
    project_name="$(printf '%s' "$project_name" | /usr/bin/tr -c 'A-Za-z0-9._-' '_')"

    # =========================================================================
    # Write pass.
    # =========================================================================

    # The components array is resized to what the package holds before any of
    # them is written. Shrinking matters as much as growing: importing a
    # two-component package into a document that held five must not leave three
    # of the old ones behind, describing a project this package knows nothing
    # about.
    importpkg_resize_components "$component_count" || {
        append_log "! the document's component list could not be resized; save nothing and reopen the document"
        importpkg_cleanup
        return 1
    }

    scripts_seen=0
    refused_any=0
    component_index=0
    while [ "$component_index" -lt "$component_count" ]; do
        importpkg_slot="$(importpkg_slot_for "$component_index")"
        PB_COMPONENT_INDEX="$component_index"
        component_dir="$(/usr/bin/sed -n "$((component_index + 1))p" "$components_file")"
        package_info="$component_dir/PackageInfo"

        identifier="$(xml_element_attribute "$package_info" pkg-info identifier)"
        install_location="$(xml_element_attribute "$package_info" pkg-info install-location)"
        overwrite="$(xml_element_attribute "$package_info" pkg-info overwrite-permissions)"
        [ -n "$install_location" ] || install_location="/"

        # A component installing INTO a bundle describes one artifact, not the
        # hundreds of files inside it. The install location becomes the bundle's
        # parent and the single payload entry carries the bundle itself, which is
        # exactly the document a user would have written by dropping that bundle
        # on the payload table.
        whole_bundle="$(importpkg_whole_bundle "$component_dir" "$install_location")"
        [ -z "$whole_bundle" ] || install_location="$(/usr/bin/dirname "$whole_bundle")"

        # Relocatability is a list, not an attribute. pkgbuild expresses it by
        # naming the bundles Installer will hunt for, and design 8.2 forces that
        # list empty; PackageInfo's own relocatable="..." attribute is written by
        # pkgbuild whatever was asked for, exactly as auth is. So the honest
        # reading is whether the relocate list has anything in it.
        if /usr/bin/grep -q '<relocate/>' "$package_info" 2>/dev/null; then
            relocatable=0
        elif /usr/bin/sed -n '/<relocate>/,/<\/relocate>/p' "$package_info" 2>/dev/null | /usr/bin/grep -q 'id="'; then
            relocatable=1
        else
            relocatable=0
        fi

        # This component's own pkg-ref, not the first one in the file. With
        # several components the Distribution carries several, and reading the
        # first would give every component the first one's auth.
        auth=""
        [ ! -f "$distribution" ] || auth="$(importpkg_pkgref_auth "$distribution" "$identifier")"

        payload_readable="$(/bin/cat "$(state_dir)/importpkg.readable$importpkg_slot" 2>/dev/null)"
        case "$payload_readable" in
            0|2) ;;
            *) payload_readable=0 ;;
        esac
        payload_total="$(/usr/bin/grep -c . "$(importpkg_entries_file)" 2>/dev/null | /usr/bin/tr -d ' ')"
        case "$payload_total" in
            ''|*[!0-9]*) payload_total=0 ;;
        esac
        payload_root=""
        [ "$importpkg_payload_opaque" = "0" ] && payload_root="$component_dir/Payload"

        # A component package IS the expansion directory, whose name carries
        # this handler's pid - "Component importpkg-21028:" told the user
        # nothing and looked like a bug. Its own file name is the only name it
        # has.
        if [ "$component_dir" = "$importpkg_expand_dir" ]; then
            append_log "Component $package_base:"
        else
            append_log "Component $(/usr/bin/basename "$component_dir"):"
        fi

        [ -z "$identifier" ] || component_set IDENTIFIER "$identifier"
        component_set INSTALL_LOCATION "$install_location"
        # A package records a version per component, and this change made a
        # document able to say so. Written only when it differs from the one
        # that became the project's, so an ordinary single-version package
        # imports as it always did - and CLEARED otherwise, because an override
        # left over from whatever this document held before would outlive the
        # import and re-stamp the component on the next build.
        component_own_version="$(xml_element_attribute "$package_info" pkg-info version)"
        if [ -n "$component_own_version" ] && [ "$component_own_version" != "$version" ]; then
            component_set VERSION "$component_own_version"
        else
            component_set VERSION ""
        fi

        # The two safety-relevant flags. overwrite-permissions is written only
        # when the package actually states it, so a package missing the
        # attribute cannot silently turn design 8.1's protection off.
        case "$overwrite" in
            true|TRUE|1)   component_set_bool OVERWRITE_PERMISSIONS 1 ;;
            false|FALSE|0) component_set_bool OVERWRITE_PERMISSIONS 0 ;;
        esac
        component_set_bool RELOCATABLE "$relocatable"

        case "$auth" in
            Root|root|Admin|admin) component_set AUTH "Root" ;;
            '') ;;
            *) component_set AUTH "User" ;;
        esac

        # The choice title, which a multi-component installer shows in its list
        # and a single-component one borrows from the distribution title. Taken
        # only when the Distribution actually names one for this component, so a
        # package that says nothing leaves component_title's own fallback to
        # answer rather than freezing a guess into the document.
        if [ -f "$distribution" ] && [ "$component_count" -gt 1 ]; then
            component_set TITLE "$(importpkg_choice_title "$distribution" "$identifier")"
            component_set_bool SELECTED "$(importpkg_choice_selected "$distribution" "$identifier")"
        fi

        append_log ""
        if [ "$payload_readable" = "2" ] || [ "$payload_total" -gt "$PB_IMPORT_MAX_PAYLOAD" ]; then
            refused_any=1
            # Everything else about this component has already landed and is
            # worth keeping - identifier, install location, auth. Only the
            # payload is refused, and refusing it is the honest answer: a
            # component holding this many separate items was built from a source
            # folder, not from a list of artifacts, and this document model has
            # no way to say "that folder".
            append_log "Payload: not imported"
            if [ "$payload_readable" = "2" ] && [ -f "$(importpkg_refusal_file)" ]; then
                append_log_file "$(importpkg_refusal_file)"
            fi
            if [ "$payload_readable" != "2" ]; then
                append_log "  $payload_total items after collapsing bundles, over the limit of $PB_IMPORT_MAX_PAYLOAD."
                append_log "  A payload that size is a file tree, not a list of artifacts."
            fi
            # The old payload has to go with it. Everything else about this
            # component now describes the imported one, and leaving the previous
            # project's entries in place produced a component that would build
            # THAT payload under THIS identifier - the mirror of the .pkgproj
            # importer's "one outcome an import should never produce silently".
            while [ "$(payload_count)" -gt 0 ]; do
                payload_remove_at 0 || break
            done
            # Reporting what is actually there, not what the loop meant to do.
            # The break above is what stops a failing payload_remove_at
            # spinning, and it leaves entries behind - saying "now empty" over
            # them would be the one kind of log line that costs a user their
            # trust in the rest.
            if [ "$(payload_count)" -gt 0 ]; then
                append_log "  ! the payload could not be cleared and still holds $(payload_count) entry/entries"
                append_log "    from before this import. Do not save; reopen the document."
            else
                append_log "  The payload is now empty; everything else in the package was imported."
                append_log "  Add the payload by hand or with the folder scan."
            fi
        else
            append_log "Payload:"
            importpkg_log_notes
            if ! importpkg_apply_payload "$payload_root" "$(if [ -n "$whole_bundle" ]; then /usr/bin/basename "$whole_bundle"; fi)"; then
                append_log "! A payload entry could not be written; save nothing and reopen the document"
                # Restored on the way out like every other exit from this loop.
                # The caller stops before pushing the model on a failure, so
                # nothing reads it today - but a function that moves a global
                # should put it back whatever happens, or the next thing to read
                # it inherits an index from a component that failed.
                PB_COMPONENT_INDEX=0
                importpkg_slot=""
                importpkg_cleanup
                return 1
            fi
        fi

        /usr/bin/grep -q '<scripts>' "$package_info" 2>/dev/null && scripts_seen=$((scripts_seen + 1))

        component_index=$((component_index + 1))
        [ "$component_index" -lt "$component_count" ] && append_log ""
    done
    PB_COMPONENT_INDEX=0
    importpkg_slot=""

    # --- the project and the distribution ------------------------------------
    [ -z "$project_name" ] || model_set /PROJECT/NAME "$project_name"

    # A version pkgbuild was never given is written as "0", which passes design
    # 4.4's pattern and would then be built and shipped. Taken as read, and
    # named in the log so it is not discovered later.
    [ -z "$version" ] || model_set /PROJECT/VERSION "$version"
    [ -z "$min_os" ] || model_set /PROJECT/MIN_OS_VERSION "$min_os"

    [ -z "$title" ] || model_set /DISTRIBUTION/TITLE "$title"
    case "$customize" in
        never|allow|always) model_set /DISTRIBUTION/CUSTOMIZE "$customize" ;;
    esac
    case "$require_scripts" in
        true|TRUE|1)   model_set_bool /DISTRIBUTION/REQUIRE_SCRIPTS 1 ;;
        false|FALSE|0) model_set_bool /DISTRIBUTION/REQUIRE_SCRIPTS 0 ;;
    esac
    # productbuild refuses an empty hostArchitectures, so a package that names
    # none is telling us nothing rather than telling us "neither"; the document
    # default stands in that case.
    if [ -n "$architectures" ]; then
        local want_arm64=0 want_x86_64=0
        case "$architectures" in *arm64*)  want_arm64=1 ;; esac
        case "$architectures" in *x86_64*) want_x86_64=1 ;; esac
        # Neither name recognized means an architecture this app has no toggle
        # for, and rewriting the array from two zeroes would leave it empty -
        # which productbuild refuses outright. The default stands instead.
        if [ "$want_arm64" = "1" ] || [ "$want_x86_64" = "1" ]; then
            set_architectures "$want_arm64" "$want_x86_64"
        fi
    fi

    # The output folder is where this package was found, which is where the next
    # one should go. The artifacts folder is the one thing a package cannot tell
    # us and is deliberately left empty: design 4.3 makes ${ARTIFACTS_DIR} a hard
    # precondition failure when it is unset, so the build refuses with a clear
    # message rather than resolving the sources to previously installed copies.
    model_set /PROJECT/OUTPUT_DIR "$(store_path "$(/usr/bin/dirname "$package_path")")"
    if [ -n "$project_name" ] && [ -n "$version" ] && [ "$package_base" = "${project_name}_${version}.pkg" ]; then
        model_set /PROJECT/PACKAGE_NAME '${NAME}_${VERSION}.pkg'
    else
        model_set /PROJECT/PACKAGE_NAME "$package_base"
    fi

    if [ -n "$identity" ]; then
        model_set_bool /SIGNING/ENABLED 1
        model_set /SIGNING/INSTALLER_IDENTITY "$identity"
    else
        # Faithful to what was read. An unsigned package is a real thing to
        # import - design 8.3 keeps one out of the output folder but the
        # intermediate exists - and turning signing on with no identity would
        # produce a document that fails its preconditions for a reason the user
        # did not choose.
        model_set_bool /SIGNING/ENABLED 0
    fi

    # --- what did not come across ---------------------------------------------
    resource_note=""
    if [ -f "$distribution" ]; then
        resource_note="$(/usr/bin/grep -o '<\(readme\|license\|welcome\|conclusion\|background\) file="[^"]*"' "$distribution" 2>/dev/null \
            | /usr/bin/sed -e 's/^<//' -e 's/ file="/: /' -e 's/"$//' | /usr/bin/tr '\n' ' ')"
    fi

    # Collected first, printed only if anything landed in it: the header alone
    # over an empty block reads like something failed to print.
    local dropped_file="$(state_dir)/importpkg-$$.dropped"
    : > "$dropped_file"
    # The sources line only when there are sources to be missing. With every
    # payload refused above there are none, and telling the user to set an
    # artifacts folder for placeholders that were never written sends them
    # looking for a field that would change nothing.
    if [ "$(importpkg_total_payload_entries)" -gt 0 ]; then
        printf '%s\n' "  the payload sources - a package does not carry them. Every SOURCE is a" >> "$dropped_file"
        printf '%s\n' "  \${ARTIFACTS_DIR} placeholder; set the artifacts folder before building." >> "$dropped_file"
    fi
    if [ "$scripts_seen" -gt 0 ]; then
        if [ "$scripts_seen" = "1" ]; then
            printf '%s\n' "  a component's install scripts, which are in the package but were not extracted" >> "$dropped_file"
        else
            printf '%s\n' "  the install scripts of $scripts_seen components, which are in the package but were not extracted" >> "$dropped_file"
        fi
    fi
    [ -z "$resource_note" ] || \
        printf '%s\n' "  the presentation resources - $resource_note" >> "$dropped_file"
    [ "$importpkg_payload_opaque" = "0" ] || \
        printf '%s\n' "  the verify assertions - the payload could not be unpacked to read them" >> "$dropped_file"

    if [ -s "$dropped_file" ]; then
        append_log ""
        append_log "Not imported:"
        append_log_file "$dropped_file"
    fi
    /bin/rm -f "$dropped_file"

    if [ "$component_count" -gt 1 ]; then
        append_log ""
        append_log "$component_count components were imported."
    fi

    # Not a drop, so not in that block: the package really does declare this and
    # the document really did take it.
    case "$version" in
        0) append_log ""
           append_log "note: the package declares version \"0\", which is what pkgbuild writes when it is not given one" ;;
    esac

    importpkg_cleanup
    return 0
}
