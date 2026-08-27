#!/bin/sh
# Tests/35-component-list.test.sh - the component list in the sidebar.
#
# The window edits one component at a time and the list says which. Everything
# below is about that seam: the list following the model, the Component tab and
# the payload table following the list, and edits landing on the component the
# list has selected rather than on the first one - which is what they all did
# before there was a list.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.packagebuilder.sh"

artifacts="$(make_artifacts)"

new_project() { # <document name>
    reset_state
    omc_object ""
    omc_run PackageBuilder.main.init
    omc_dialog_answer save_as "$OMCTEST_WORK/$1"
    omc_run PackageBuilder.save.as
    omc_dialog_answer choose_folder "$artifacts"
    omc_run PackageBuilder.choose.artifacts
}

section "157. a new document shows its one component in the sidebar"
new_project Components.pkgbld
check "one row in the list"        "1"   "$(ui_row_count $COMPONENT_TABLE_ID)"
check "and it is selected"         "0"   "$(ui_selection $COMPONENT_TABLE_ID)"
check "the current component"      "0"   "$(current_component)"
# A component with nothing filled in yet still has to be nameable in a list.
check "a placeholder title"        "Component 1" "$(component_row_cell 0 1)"
check "and no payload"             "0"   "$(component_row_cell 0 2)"
check "add is enabled"             "1"   "$(ui_enabled $COMPONENT_ADD_ID)"
# A project needs a component, so the only one cannot be removed or moved.
check "remove is not"              "0"   "$(ui_enabled $COMPONENT_REMOVE_ID)"
check "nor up"                     "0"   "$(ui_enabled $COMPONENT_UP_ID)"
check "nor down"                   "0"   "$(ui_enabled $COMPONENT_DOWN_ID)"

section "158. [+] adds a component with an identifier of its own"
pl set string "com.example.pkg.widget" "$(model_file)" /COMPONENTS/0/IDENTIFIER
omc_run PackageBuilder.component.add
check "two components"             "2"   "$(component_total)"
# Not empty: a second component with no identifier collides with the first one
# that has none, and nothing would say so until a build refused the document.
check "generated identifier"       "com.example.pkg.component2" "$(component_field IDENTIFIER 1)"
check "normalized install location" "/"  "$(component_field INSTALL_LOCATION 1)"
check "selected by default"        "true" "$(component_field SELECTED 1)"
check "an empty payload"           "0"   "$(payload_total 1)"
check "the new one is current"     "1"   "$(current_component)"
check "two rows in the list"       "2"   "$(ui_row_count $COMPONENT_TABLE_ID)"
check "the new row is selected"    "1"   "$(ui_selection $COMPONENT_TABLE_ID)"
check "remove is enabled now"      "1"   "$(ui_enabled $COMPONENT_REMOVE_ID)"
check "up too"                     "1"   "$(ui_enabled $COMPONENT_UP_ID)"
check "down is not, at the end"    "0"   "$(ui_enabled $COMPONENT_DOWN_ID)"
check "the document is dirty"      "1"   "$(dirty)"

section "159. a generated identifier steps over one that is taken"
pl set string "com.example.pkg.component3" "$(model_file)" /COMPONENTS/1/IDENTIFIER
omc_run PackageBuilder.component.add
check "three components"           "3"   "$(component_total)"
# The third component would be "component3", which the second one now carries.
check "stepped past the clash"     "com.example.pkg.component4" "$(component_field IDENTIFIER 2)"

section "160. the Component tab shows the component the list selects"
pl set string "Widget"                 "$(model_file)" /COMPONENTS/0/TITLE
pl set string "Helper"                 "$(model_file)" /COMPONENTS/2/TITLE
pl set string "com.example.pkg.helper" "$(model_file)" /COMPONENTS/2/IDENTIFIER
pl set string "/usr/local"             "$(model_file)" /COMPONENTS/2/INSTALL_LOCATION
pl set string "User"                   "$(model_file)" /COMPONENTS/2/AUTH
select_component_row 0
check "title of the first"         "Widget" "$(ui_value $COMPONENT_TITLE_ID)"
check "identifier of the first"    "com.example.pkg.widget" "$(ui_value $IDENTIFIER_ID)"
check "install location"           "/"   "$(ui_value $INSTALL_LOCATION_ID)"
check "authentication"             "Root" "$(ui_value $AUTH_ID)"
select_component_row 2
check "title of the third"         "Helper" "$(ui_value $COMPONENT_TITLE_ID)"
check "identifier of the third"    "com.example.pkg.helper" "$(ui_value $IDENTIFIER_ID)"
check "its install location"       "/usr/local" "$(ui_value $INSTALL_LOCATION_ID)"
check "its authentication"         "User" "$(ui_value $AUTH_ID)"
check "and it is current"          "2"   "$(current_component)"

section "161. an edit lands on the selected component, not the first"
omc_fire PackageBuilder.field.changed $INSTALL_LOCATION_ID "/opt"
check "the third changed"          "/opt" "$(component_field INSTALL_LOCATION 2)"
check "the first did not"          "/"   "$(component_field INSTALL_LOCATION 0)"
omc_fire PackageBuilder.field.changed $COMPONENT_SELECTED_ID "false"
check "SELECTED written"           "false" "$(component_field SELECTED 2)"
check "and only there"             "true" "$(component_field SELECTED 0)"
omc_fire PackageBuilder.field.changed $COMPONENT_DESCRIPTION_ID "the helper tool"
check "DESCRIPTION written"        "the helper tool" "$(component_field DESCRIPTION 2)"
check "and only there"             ""    "$(component_field DESCRIPTION 0)"
# The Project tab is the other half of the same rule: those fields belong to the
# document, and the component the list has selected must not change where they
# land. This is why Name and Version left the tab the identifier is on.
omc_fire PackageBuilder.field.changed $NAME_ID "MyApp"
check "the project name is global" "MyApp" "$(model /PROJECT/NAME)"

section "162. the payload table follows the component"
select_component_row 0
omc_drop "$artifacts/Widget.app"
omc_run PackageBuilder.payload.drop
check "one entry in the first"     "1"   "$(payload_total 0)"
check "none in the third"          "0"   "$(payload_total 2)"
check "the table shows one row"    "1"   "$(ui_row_count $PAYLOAD_TABLE_ID)"
check "the list counts it"         "1"   "$(component_row_cell 0 2)"
select_component_row 2
check "the table is empty now"     "0"   "$(ui_row_count $PAYLOAD_TABLE_ID)"
check "and nothing is selected"    ""    "$(selected_index)"
omc_drop "$artifacts/mytool"
omc_run PackageBuilder.payload.drop
check "it landed in the third"     "1"   "$(payload_total 2)"
check "the first still has one"    "1"   "$(payload_total 0)"
check "the list counts that too"   "1"   "$(component_row_cell 2 2)"

section "163. the payload selection does not follow across components"
select_component_row 0
omc_drop "$artifacts/mytool" "$artifacts/readme.txt"
omc_run PackageBuilder.payload.drop
select_payload_row 2
check "row 2 is selected"          "2"   "$(selected_index)"
select_component_row 2
# The third component has one entry, so row 2 would be out of range and cleared
# anyway. Row 0 would not be: it is a perfectly valid row of a component the
# user has never looked at, and adopting it is what this proves does not happen.
check "it starts at the top"       "0"   "$(selected_index)"
check "showing the third's entry"  '${ARTIFACTS_DIR}/mytool' "$(ui_value $SOURCE_ID)"

section "164. selecting the row already selected leaves the payload alone"
select_component_row 0
select_payload_row 2
check "row 2 is selected"          "2"   "$(selected_index)"
select_component_row 0
# This is what makes refresh_component_list safe to call after every edit that
# changes a row: it reselects the current row, and the echo has to be inert.
check "still row 2"                "2"   "$(selected_index)"

section "165. a title or an identifier renames the row in the list"
omc_fire PackageBuilder.field.changed $COMPONENT_TITLE_ID "Widget App"
check "the row shows the title"    "Widget App" "$(component_row_cell 0 1)"
omc_fire PackageBuilder.field.changed $COMPONENT_TITLE_ID ""
# With no title of its own, and more than one component, a row falls back to the
# last element of the identifier.
check "and falls back to the id"   "widget" "$(component_row_cell 0 1)"
omc_fire PackageBuilder.field.changed $IDENTIFIER_ID "com.example.pkg.mainapp"
check "renaming the id renames it" "mainapp" "$(component_row_cell 0 1)"
check "and the row is still selected" "0" "$(ui_selection $COMPONENT_TABLE_ID)"

section "166. [-] removes the selected component and its payload with it"
select_component_row 1
omc_run PackageBuilder.component.remove
check "two left"                   "2"   "$(component_total)"
check "the one below took its place" "com.example.pkg.helper" "$(component_field IDENTIFIER 1)"
check "and is current"             "1"   "$(current_component)"
check "the list has two rows"      "2"   "$(ui_row_count $COMPONENT_TABLE_ID)"
check "with its payload intact"    "1"   "$(payload_total 1)"
omc_run PackageBuilder.component.remove
check "one left"                   "1"   "$(component_total)"
check "the survivor is current"    "0"   "$(current_component)"
check "and kept its three entries" "3"   "$(payload_total 0)"
check "remove is disabled again"   "0"   "$(ui_enabled $COMPONENT_REMOVE_ID)"
# Only reachable through a stale click, since the button is disabled - which is
# exactly why the handler refuses it rather than trusting the button.
omc_run PackageBuilder.component.remove
check "the last one is refused"    "1"   "$(component_total)"
check "and says why"               "1"   "$(printf '%s' "$(ui_value $STATUS_ID)" | /usr/bin/grep -c 'needs a component')"

section "167. up and down move a component, payload and all"
new_project Reorder.pkgbld
pl set string "com.example.pkg.first" "$(model_file)" /COMPONENTS/0/IDENTIFIER
omc_drop "$artifacts/Widget.app"
omc_run PackageBuilder.payload.drop
omc_run PackageBuilder.component.add
omc_drop "$artifacts/mytool" "$artifacts/readme.txt"
omc_run PackageBuilder.payload.drop
check "the first has one entry"    "1"   "$(payload_total 0)"
check "the second has two"         "2"   "$(payload_total 1)"
check "the second is current"      "1"   "$(current_component)"
omc_trigger $COMPONENT_UP_ID
omc_run PackageBuilder.component.move
check "still two components"       "2"   "$(component_total)"
check "the second is now first"    "com.example.pkg.component2" "$(component_field IDENTIFIER 0)"
# The whole point of swapping subtrees rather than fields: a component's payload
# is part of it and has to travel with it.
check "and brought its payload"    "2"   "$(payload_total 0)"
check "the first is now second"    "com.example.pkg.first" "$(component_field IDENTIFIER 1)"
check "with its own payload"       "1"   "$(payload_total 1)"
check "the selection followed"     "0"   "$(current_component)"
check "up is disabled at the top"  "0"   "$(ui_enabled $COMPONENT_UP_ID)"
check "down is enabled"            "1"   "$(ui_enabled $COMPONENT_DOWN_ID)"
omc_trigger $COMPONENT_DOWN_ID
omc_run PackageBuilder.component.move
check "back where it started"      "com.example.pkg.first" "$(component_field IDENTIFIER 0)"
check "payloads back too"          "1"   "$(payload_total 0)"
check "and the selection with it"  "1"   "$(current_component)"

section "168. every handler that edits a component says which one first"
# A structural check, not a behavioral one. The component index defaults to the
# first, so a handler that reads or writes a component field without resolving
# the selection edits component 1 no matter which row is selected - silently,
# and in a way no assertion about component 1 can see. There is no way to make
# that impossible, so it is made findable: adding a handler that forgets fails
# here by name rather than in a bug report about edits going to the wrong place.
handlers_missing_component_index() {
    local dir="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts" script missing=""
    for script in "$dir"/PackageBuilder.*.sh; do
        /usr/bin/grep -qE 'payload_(count|get|set|key|archs_get|archs_set|bool_get|bool_set|universal_get|universal_set|signed_get|signed_set|append_from_path|remove_at|swap|tab_heading)|component_(get|set|key|get_bool|get_bool_str|set_bool|title)|selected_payload_index|repopulate_payload|populate_payload_table|ensure_payload_verify' \
            "$script" || continue
        # Any of these establishes it: three set it outright, and
        # push_model_to_window resolves it through repopulate_components.
        /usr/bin/grep -qE 'load_current_component_index|set_current_component_index|show_component_selection|repopulate_components|push_model_to_window' \
            "$script" && continue
        missing="$missing $(/usr/bin/basename "$script")"
    done
    printf '%s' "$missing"
}
check "no handler forgets"         ""    "$(handlers_missing_component_index)"

section "169. an identifier that collides is kept, and warned about"
new_project Conflict.pkgbld
pl set string "com.example.pkg.first" "$(model_file)" /COMPONENTS/0/IDENTIFIER
omc_run PackageBuilder.component.add
# The second component is current. Typing the first one's identifier makes a
# document that cannot be built, and the window says so rather than refusing the
# edit - a text field reports its value when it is committed, and a rename is
# usually half done at that moment.
omc_fire PackageBuilder.field.changed $IDENTIFIER_ID "com.example.pkg.first"
check "the edit was kept"          "com.example.pkg.first" "$(component_field IDENTIFIER 1)"
check "and the status says why"    "1"   "$(printf '%s' "$(ui_value $STATUS_ID)" | /usr/bin/grep -c 'already has the identifier')"
# The punctuation twin is the one nobody spots by reading: both reduce to one
# choice id and one package file name.
omc_fire PackageBuilder.field.changed $IDENTIFIER_ID "com.example.pkg-first"
check "the twin is kept too"       "com.example.pkg-first" "$(component_field IDENTIFIER 1)"
check "and named as a twin"        "1"   "$(printf '%s' "$(ui_value $STATUS_ID)" | /usr/bin/grep -c 'only in punctuation')"
# A component is not in conflict with itself, which is what the exempt index is
# for - without it every rename would warn about the name being replaced.
omc_fire PackageBuilder.field.changed $IDENTIFIER_ID "com.example.pkg.second"
check "a clean rename lands"       "com.example.pkg.second" "$(component_field IDENTIFIER 1)"
# The status still holds the previous warning, so this asks whether a FRESH one
# was raised: a warning about this rename would have named it.
check "with no fresh warning"      "0"   "$(printf '%s' "$(ui_value $STATUS_ID)" | /usr/bin/grep -c 'com.example.pkg.second')"

section "170. an add that fails partway leaves no half-built component behind"
new_project AddFails.pkgbld
check "one to start with"          "1"   "$(component_total)"
# The array grows before any field of the new component is written, so a failure
# in between leaves a bare dict nobody can see: the handler reports the failure
# and does not repopulate, and the next ordinary edit would save it.
omc_stub plister <<'STUB'
#!/bin/sh
case "$*" in
    *"set string"*IDENTIFIER*) exit 1 ;;
esac
exec "$OMCTEST_REAL_SUPPORT/plister" "$@"
STUB
omc_run PackageBuilder.component.add
omc_unstub plister
check "still one component"        "1"   "$(component_total)"
check "and the list agrees"        "1"   "$(ui_row_count $COMPONENT_TABLE_ID)"
check "the window said so"         "1"   "$(printf '%s' "$(ui_value $STATUS_ID)" | /usr/bin/grep -c 'Could not add')"

section "171. a swap that fails leaves the order exactly as it was"
new_project SwapFails.pkgbld
pl set string "com.example.pkg.first" "$(model_file)" /COMPONENTS/0/IDENTIFIER
omc_drop "$artifacts/Widget.app"
omc_run PackageBuilder.payload.drop
omc_run PackageBuilder.component.add
omc_drop "$artifacts/mytool" "$artifacts/readme.txt"
omc_run PackageBuilder.payload.drop
# Fail only the last of the four copies - the one that writes the crossed-over
# array back. The obvious ordering wrote the model twice, and a failure between
# those two writes left one component at BOTH indices and the other one only in
# a scratch file. Whole-array-out, cross, one write back is what makes this
# assertion possible at all.
omc_stub plister <<'STUB'
#!/bin/sh
# Only "set copy ... /COMPONENTS" - the write back. "get count <file>
# /COMPONENTS" and "append dict <file> /COMPONENTS" end the same way, and
# blocking those would break the handler before it reached the swap at all.
case "$*" in
    "set copy "*" /COMPONENTS") exit 1 ;;
esac
exec "$OMCTEST_REAL_SUPPORT/plister" "$@"
STUB
omc_trigger $COMPONENT_UP_ID
omc_run PackageBuilder.component.move
omc_unstub plister
check "still two components"       "2"   "$(component_total)"
check "the first is untouched"     "com.example.pkg.first" "$(component_field IDENTIFIER 0)"
check "the second is untouched"    "com.example.pkg.component2" "$(component_field IDENTIFIER 1)"
check "no component was duplicated" "1"  "$(payload_total 0)"
check "and none lost its payload"  "2"   "$(payload_total 1)"
check "the window said so"         "1"   "$(printf '%s' "$(ui_value $STATUS_ID)" | /usr/bin/grep -c 'Could not reorder')"

section "172. a refused import leaves the component selection where it was"
new_project Refused.pkgbld
omc_run PackageBuilder.component.add
check "two components"             "2"   "$(component_total)"
check "the second is current"      "1"   "$(current_component)"
printf 'not a project at all\n' > "$OMCTEST_WORK/broken.pkgproj"
omc_dialog_answer choose_file "$OMCTEST_WORK/broken.pkgproj"
omc_run PackageBuilder.import.pkgproj
check "nothing was imported"       "2"   "$(component_total)"
check "and the window says so"     "1"   "$(printf '%s' "$(ui_value $STATUS_ID)" | /usr/bin/grep -c 'Nothing usable')"
# An import lands in the first component, so it has to pin the index it writes
# through - but only in a shell variable. Pinning it the persisted way would
# move the window's own state on a refusal that changed nothing: the sidebar
# would go on showing the second component while every handler edited the first.
check "the selection did not move" "1"   "$(current_component)"
omc_fire PackageBuilder.field.changed $INSTALL_LOCATION_ID "/opt"
check "the edit went to it"        "/opt" "$(component_field INSTALL_LOCATION 1)"
check "and not to the first"       "/"   "$(component_field INSTALL_LOCATION 0)"

section "173. a component may carry a version, or take the project's"
new_project Versions.pkgbld
pl set string "2.4" "$(model_file)" /PROJECT/VERSION
omc_run PackageBuilder.component.add
check "the second is current"      "1"   "$(current_component)"
omc_fire PackageBuilder.field.changed $COMPONENT_VERSION_ID "1.0"
check "it went to the second"      "1.0" "$(component_field VERSION 1)"
check "the first still inherits"   ""    "$(component_field VERSION 0)"
check "and the project is untouched" "2.4" "$(model /PROJECT/VERSION)"
# An empty field is not "no version", it is "the project's" - and for a version
# that distinction is the number the receipt database records, so the window
# says which one out loud rather than leaving a blank.
select_component_row 0
check "the field is empty"         ""    "$(ui_value $COMPONENT_VERSION_ID)"
check "and says what it inherits"  "project: 2.4" "$(ui_value $COMPONENT_VERSION_HINT_ID)"
select_component_row 1
check "the override is shown"      "1.0" "$(ui_value $COMPONENT_VERSION_ID)"
check "with nothing to inherit"    ""    "$(ui_value $COMPONENT_VERSION_HINT_ID)"
# The caption has to follow both halves of the answer, not only a selection: a
# caption refreshed once per click goes on naming a version this component would
# no longer inherit, which for a version is worse than no caption at all.
omc_fire PackageBuilder.field.changed $COMPONENT_VERSION_ID ""
check "clearing it brings the hint back" "project: 2.4" "$(ui_value $COMPONENT_VERSION_HINT_ID)"
omc_fire PackageBuilder.field.changed $VERSION_ID "2.5"
check "and the project's edit moves it" "project: 2.5" "$(ui_value $COMPONENT_VERSION_HINT_ID)"
omc_fire PackageBuilder.field.changed $COMPONENT_VERSION_ID "1.0"
check "an override hides it again" ""    "$(ui_value $COMPONENT_VERSION_HINT_ID)"

section "174. the options disclosure opens on a component that is hiding one"
new_project Disclosure.pkgbld
check "closed on a fresh component" "false" "$(ui_state $COMPONENT_OPTIONS_ID isExpanded)"
# The state is decided on arrival at a component, so these switch away and back
# rather than re-selecting the row already selected - which is a no-op by
# design, and is what section 164 is about.
omc_run PackageBuilder.component.add
# A collapsed disclosure quietly holding a preinstall script is worse than no
# disclosure at all, so it opens itself when there is something inside.
pl set string "/tmp/pre.sh" "$(model_file)" /COMPONENTS/0/PREINSTALL
select_component_row 0
check "open once one is set"       "true"  "$(ui_state $COMPONENT_OPTIONS_ID isExpanded)"
pl set string "" "$(model_file)" /COMPONENTS/0/PREINSTALL
pl set bool false "$(model_file)" /COMPONENTS/0/SELECTED
select_component_row 1
select_component_row 0
check "and for an unticked choice" "true"  "$(ui_state $COMPONENT_OPTIONS_ID isExpanded)"
pl set bool true "$(model_file)" /COMPONENTS/0/SELECTED
select_component_row 1
select_component_row 0
check "closed again once it is all default" "false" "$(ui_state $COMPONENT_OPTIONS_ID isExpanded)"

section "175. the choice-list note appears only while Customize is Never"
new_project Customize.pkgbld
check "never is the default"       "never" "$(model /DISTRIBUTION/CUSTOMIZE)"
check "so the note is there"       "1"   "$(printf '%s' "$(ui_value $COMPONENT_CHOICE_NOTE_ID)" | /usr/bin/grep -c 'no choice list')"
# Customize is on the Distribution tab, so the note has to follow an edit made
# somewhere else - not wait for the next time a component is selected.
omc_fire PackageBuilder.field.changed $CUSTOMIZE_ID "allow"
check "and gone once it can show one" "" "$(ui_value $COMPONENT_CHOICE_NOTE_ID)"

section "176. a stage that reports brings the Build tab forward"
new_project Reporting.pkgbld
omc_drop "$artifacts/mytool"
omc_run PackageBuilder.payload.drop
pl set string "com.example.pkg.tool" "$(model_file)" /COMPONENTS/0/IDENTIFIER
pl set string "Tool" "$(model_file)" /PROJECT/NAME
pl set string "1.0" "$(model_file)" /PROJECT/VERSION
clear_payload_assertions
# The log used to be a pane that was always on screen. It is a tab now, so a
# stage that reports into it from another tab reports to nobody.
omc_run PackageBuilder.step.verify
check "the Build tab is showing"   "$BUILD_TAB_INDEX" "$(ui_value $TABVIEW_ID)"

section "177. require-scripts has a control at last"
new_project RequireScripts.pkgbld
# In the schema and read by the build since the beginning; no window field ever
# wrote it, so it could only ever be the default.
check "off by default"             "false" "$(model /DISTRIBUTION/REQUIRE_SCRIPTS)"
omc_fire PackageBuilder.field.changed $REQUIRE_SCRIPTS_ID "true"
check "the toggle writes it"       "true"  "$(model /DISTRIBUTION/REQUIRE_SCRIPTS)"

# The sidebar's ids are new, so this is the run that would catch one of them
# missing from the window JSON - a write the engine discards in silence.
check "no undeclared ids"          ""    "$(ui_unknown_writes)"

omctest_end
