#!/bin/sh
# Tests/70-export-import.test.sh - importing a Packages.app project.
#
# PARTIAL. This file will hold Private/harness.sh sections 121 to 133; what is
# here so far is the import block that the plister content-fallback change made
# urgent - sections 126b and 133b, plus one case the proof of concept does not
# have. The export sections and the rest of the import sections are still only
# in the proof of concept.
#
# Why these first, out of order: `import_pkgproj` used to read a COPY of the
# user's .pkgproj staged under a .plist name, and its cleanup removed that copy
# by name. It reads the user's own file now, so the same line would have deleted
# their project on every successful import. That is the kind of defect a suite
# has to own, and until this file existed the tracked suite could not see the
# import path at all.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.packagebuilder.sh"

# A project shaped like the ones Packages.app writes: the system-tree scaffold
# with its hidden (-1) nodes, TYPE = 3 payload leaves, integer permissions, and
# project-relative source paths. plutil builds the plist from JSON so the
# fixture stays readable here.
project_dir="$OMCTEST_WORK/pkgimport"
/bin/mkdir -p "$project_dir/archives"
/bin/cp /bin/echo "$project_dir/archives/alpha"
/bin/cp /bin/echo "$project_dir/archives/beta"

/bin/cat > "$project_dir/fixture.json" <<'PKGPROJ'
{"PACKAGES":[{"PACKAGE_SETTINGS":{"NAME":"imported","VERSION":"3.1",
  "IDENTIFIER":"com.example.pkg.imported","OVERWRITE_PERMISSIONS":false,
  "RELOCATABLE":false,"AUTHENTICATION":1},
 "PACKAGE_FILES":{"DEFAULT_INSTALL_LOCATION":"/",
  "HIERARCHY":{"TYPE":1,"PATH":"/","PATH_TYPE":0,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[
   {"TYPE":-1,"PATH":"usr","PATH_TYPE":0,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[
    {"TYPE":-1,"PATH":"local","PATH_TYPE":0,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[
     {"TYPE":-1,"PATH":"bin","PATH_TYPE":0,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[
      {"TYPE":3,"PATH":"archives/alpha","PATH_TYPE":1,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[]},
      {"TYPE":3,"PATH":"archives/beta","PATH_TYPE":1,"UID":0,"GID":0,"PERMISSIONS":493,"CHILDREN":[]}]}]}]}]}}}],
 "PROJECT":{"PROJECT_SETTINGS":{"BUILD_PATH":{"PATH":"build","PATH_TYPE":1}}}}
PKGPROJ
/usr/bin/plutil -convert xml1 -o "$project_dir/Fixture.pkgproj" "$project_dir/fixture.json" >/dev/null 2>&1

open_new_document() { # <document-name>
    reset_state
    omc_object ""
    omc_run PackageBuilder.main.init
    omc_dialog_answer save_as "$OMCTEST_WORK/$1"
    omc_run PackageBuilder.save.as
}

import_project() { # <pkgproj-path>
    omc_dialog_answer choose_file "$1"
    omc_run PackageBuilder.import.pkgproj
}

section "126. the XML project maps across"
# Enough of the mapping to prove the import really ran. Without it the survival
# checks below would pass just as happily on an import that did nothing, which
# is the failure they exist to distinguish from a deletion.
open_new_document Imported.pkgbuilderproj
fixture_hash="$(hash_of "$project_dir/Fixture.pkgproj")"
import_project "$project_dir/Fixture.pkgproj"
check "name"                     "imported"                  "$(model /PROJECT/NAME)"
check "version"                  "3.1"                       "$(model /PROJECT/VERSION)"
check "identifier"               "com.example.pkg.imported"  "$(model /COMPONENTS/0/IDENTIFIER)"
check "auth 1 becomes Root"      "Root"                      "$(model /COMPONENTS/0/AUTH)"
check "two entries, not the scaffold" "2"                    "$(count /COMPONENTS/0/PAYLOAD)"
check "destination accumulated"  "/usr/local/bin/alpha"      "$(payload_field 0 DESTINATION)"
check "source tokenized"         '${ARTIFACTS_DIR}/alpha'    "$(payload_field 0 SOURCE)"

section "126b. the project is read where it lies, and survives it"
# import_file names the USER'S file now. The cleanup at the end of import_pkgproj
# used to remove import_file by name, which against the source deletes the
# project on every successful import - silently, because the import reports
# success. These two checks are the ones that catch that.
check_exists "the source project survives" "$project_dir/Fixture.pkgproj"
check "and its bytes are unchanged" "$fixture_hash"          "$(hash_of "$project_dir/Fixture.pkgproj")"

section "133b. a binary .pkgproj imports the same as an XML one"
# Binary is the other form Packages.app writes. The staged copy got this for
# free from its .plist name; reading in place makes it plister's content
# fallback that has to recognize it.
/bin/cp "$project_dir/Fixture.pkgproj" "$project_dir/Binary.pkgproj"
/usr/bin/plutil -convert binary1 "$project_dir/Binary.pkgproj" >/dev/null 2>&1
check "the fixture really is binary" "1"                     "$(/usr/bin/file -b "$project_dir/Binary.pkgproj" | /usr/bin/grep -c 'inary')"
open_new_document ImportedBinary.pkgbuilderproj
import_project "$project_dir/Binary.pkgproj"
check "a binary project imports" "imported"                  "$(model /PROJECT/NAME)"
check "with the same payload"    "2"                         "$(count /COMPONENTS/0/PAYLOAD)"
check "and the same tokenization" '${ARTIFACTS_DIR}/alpha'   "$(payload_field 0 SOURCE)"
check_exists "and it survives as well" "$project_dir/Binary.pkgproj"

section "133c. a project that cannot be read is named as unreadable"
# Driven through the CLI on purpose. The window handler has its own readability
# check and would refuse this before import_pkgproj ever ran; the CLI's gate is
# only "is it a file", so this is the path that reaches the guard under test.
# Before that guard existed the answer was "this does not look like a
# Packages.app project", which is plausible and names the wrong problem.
/bin/cp "$project_dir/Fixture.pkgproj" "$project_dir/Locked.pkgproj"
/bin/chmod 000 "$project_dir/Locked.pkgproj"
pbcli import-pkgproj "$project_dir/Locked.pkgproj" "$OMCTEST_WORK/Locked.pkgbuilderproj" --force \
    > "$OMCTEST_WORK/locked.txt" 2>&1
check "it refused"               "1"                         "$([ -s "$OMCTEST_WORK/locked.txt" ] && echo 1 || echo 0)"
check "and said it cannot read it" "1"                       "$(/usr/bin/grep -c 'cannot be read' "$OMCTEST_WORK/locked.txt" | /usr/bin/tr -d ' ')"
check "not that it is the wrong format" "0"                  "$(/usr/bin/grep -c 'does not look like' "$OMCTEST_WORK/locked.txt" | /usr/bin/tr -d ' ')"
/bin/chmod 644 "$project_dir/Locked.pkgproj"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids"        ""                          "$(ui_unknown_writes)"

omctest_end
