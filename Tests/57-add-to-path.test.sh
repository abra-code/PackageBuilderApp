#!/bin/sh
# Tests/57-add-to-path.test.sh - components that only run scripts, and Add to PATH.
#
# Two things the per-user packages of agent-vm and replay need. A component
# may have no payload when it has install scripts, and is then built with
# pkgbuild --nopayload. And a component may ask for a folder in the home folder
# to be put on the user's PATH: PackageBuilder then writes its postinstall
# script, which runs pb_add_to_path.sh, shipped inside the app and inside the
# package.
#
# The script is tested directly against scratch home folders - it takes the
# home folder, the user and the shell as arguments for exactly this reason - and
# the package is checked by expanding it. Nothing here installs a package.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.packagebuilder.sh"

path_script="$OMC_APP_BUNDLE_PATH/Contents/Resources/InstallerScripts/pb_add_to_path.sh"
me="$(/usr/bin/id -un)"

# A fresh, empty home folder. Arguments: its name under the work area
scratch_home() {
    /bin/rm -rf "$OMCTEST_WORK/homes/$1"
    /bin/mkdir -p "$OMCTEST_WORK/homes/$1"
    printf '%s' "$OMCTEST_WORK/homes/$1"
}

# Run the script for a scratch home. Arguments: home, shell, then any extra
# arguments. Prints what the script printed; its exit status is kept in
# add_status.
add_to_path() {
    local home="$1" shell="$2"
    shift 2
    add_status=""
    /bin/sh "$path_script" --home "$home" --user "$me" --folder .local/bin --name tool --shell "$shell" "$@" > "$OMCTEST_WORK/add-to-path.out" 2>&1
    add_status=$?
    /bin/cat "$OMCTEST_WORK/add-to-path.out"
}

# Every file under a home folder, one relative path per line, sorted.
home_files() {
    ( cd "$1" && /usr/bin/find . \( -type f -o -type l \) | /usr/bin/sort )
}

section "191. the PATH script, zsh, nothing there yet"
check "the script ships in the app" "yes"                     "$([ -f "$path_script" ] && echo yes || echo no)"
check "sh accepts it"            "0"                          "$(/bin/sh -n "$path_script" 2>/dev/null; echo $?)"
home="$(scratch_home zsh-empty)"
add_to_path "$home" /bin/zsh >/dev/null; said="$(/bin/cat "$OMCTEST_WORK/add-to-path.out")"
check "it exits 0"               "0"                          "$add_status"
check "it made ~/.zprofile"      "./.zprofile"                "$(home_files "$home")"
check "and says so"              "1"                          "$(printf '%s' "$said" | /usr/bin/grep -c 'created ~/.zprofile')"
check "one marked block"         "1 1"                        "$(/usr/bin/grep -c '^# >>> tool installer >>>$' "$home/.zprofile") $(/usr/bin/grep -c '^# <<< tool installer <<<$' "$home/.zprofile")"
# The block has to work, not just be there: read twice, the folder is on the
# PATH once, in front.
zsh_path="$(HOME="$home" PATH=/usr/bin:/bin /bin/zsh -f -c ". \"$home/.zprofile\"; . \"$home/.zprofile\"; printf '%s' \"\$PATH\"")"
check "sourcing it puts the folder first" "$home/.local/bin:/usr/bin:/bin" "$zsh_path"

section "192. the PATH script is idempotent"
before="$(hash_of "$home/.zprofile")"
add_to_path "$home" /bin/zsh >/dev/null; said="$(/bin/cat "$OMCTEST_WORK/add-to-path.out")"
check "a second run changes nothing" "$before"                "$(hash_of "$home/.zprofile")"
check "and says why"             "1"                          "$(printf '%s' "$said" | /usr/bin/grep -c 'already mentions .local/bin')"
check "still exits 0"            "0"                          "$add_status"

section "193. the PATH script appends to what is there"
home="$(scratch_home zsh-existing)"
# No newline at the end: the marker must not be glued onto the user's line.
printf 'export EDITOR=vi' > "$home/.zprofile"
add_to_path "$home" /bin/zsh >/dev/null
check "the user's line is intact" "export EDITOR=vi"          "$(/usr/bin/head -n 1 "$home/.zprofile")"
check "the marker starts a line" "# >>> tool installer >>>"   "$(/usr/bin/sed -n 2p "$home/.zprofile")"

section "194. a line some other installer added is respected"
# uv puts '. "$HOME/.local/bin/env"' in ~/.zshrc. A marker-only check would add a
# second line for everyone who has uv.
home="$(scratch_home zsh-uv)"
printf '. "$HOME/.local/bin/env"\n' > "$home/.zshrc"
add_to_path "$home" /bin/zsh >/dev/null; said="$(/bin/cat "$OMCTEST_WORK/add-to-path.out")"
check "no ~/.zprofile was made"  "./.zshrc"                   "$(home_files "$home")"
check "it names the file"        "1"                          "$(printf '%s' "$said" | /usr/bin/grep -c '~/.zshrc already mentions')"
# Only a path in the home folder counts. The bare text "bin" is in Homebrew's
# line, which most ~/.zprofile files carry, and ~/bin is not on the PATH.
home="$(scratch_home zsh-brew)"
printf 'eval "$(/opt/homebrew/bin/brew shellenv)"\n' > "$home/.zprofile"
/bin/sh "$path_script" --home "$home" --user "$me" --folder bin --name tool --shell /bin/zsh >/dev/null 2>&1
check "Homebrew's /opt/homebrew/bin is not ~/bin" "1"         "$(/usr/bin/grep -c 'tool installer >>>' "$home/.zprofile")"
home="$(scratch_home zsh-forms)"
printf 'path=(~/.local/bin $path)\n' > "$home/.zshrc"
add_to_path "$home" /bin/zsh >/dev/null
check "~/.local/bin counts too"  "./.zshrc"                   "$(home_files "$home")"

section "195. a startup file that is a link is not written through"
home="$(scratch_home zsh-linked)"
printf '# dotfiles\n' > "$OMCTEST_WORK/homes/dotfiles-zprofile"
/bin/ln -s "$OMCTEST_WORK/homes/dotfiles-zprofile" "$home/.zprofile"
add_to_path "$home" /bin/zsh >/dev/null; said="$(/bin/cat "$OMCTEST_WORK/add-to-path.out")"
check "the linked file is unchanged" "# dotfiles"             "$(/bin/cat "$OMCTEST_WORK/homes/dotfiles-zprofile")"
check "the link is still a link" "yes"                        "$([ -L "$home/.zprofile" ] && echo yes || echo no)"
check "it says why"              "1"                          "$(printf '%s' "$said" | /usr/bin/grep -c 'is a symbolic link')"
check "and exits 0"              "0"                          "$add_status"

section "196. bash uses the file bash already reads"
home="$(scratch_home bash-profile)"
printf 'x=1\n' > "$home/.profile"
add_to_path "$home" /bin/bash >/dev/null
check "appended to ~/.profile"   "1"                          "$(/usr/bin/grep -c 'tool installer >>>' "$home/.profile")"
# Creating ~/.bash_profile here would stop bash reading ~/.profile at all.
check "no ~/.bash_profile made"  "no"                         "$([ -e "$home/.bash_profile" ] && echo yes || echo no)"
home="$(scratch_home bash-login)"
printf 'x=1\n' > "$home/.bash_login"
printf 'y=1\n' > "$home/.profile"
add_to_path "$home" /bin/bash >/dev/null
check "~/.bash_login before ~/.profile" "1 0"                 "$(/usr/bin/grep -c 'tool installer >>>' "$home/.bash_login") $(/usr/bin/grep -c 'tool installer' "$home/.profile")"
home="$(scratch_home bash-none)"
add_to_path "$home" /bin/bash >/dev/null
check "none there: ~/.bash_profile" "./.bash_profile"         "$(home_files "$home")"
bash_path="$(HOME="$home" PATH=/usr/bin:/bin /bin/bash --noprofile --norc -c ". \"$home/.bash_profile\"; . \"$home/.bash_profile\"; printf '%s' \"\$PATH\"")"
check "and it works in bash"     "$home/.local/bin:/usr/bin:/bin" "$bash_path"

section "197. fish gets a file of its own"
home="$(scratch_home fish)"
add_to_path "$home" /opt/homebrew/bin/fish >/dev/null
check "a conf.d file"            "./.config/fish/conf.d/tool.fish" "$(home_files "$home")"
check "that adds the folder"     "1"                          "$(/usr/bin/grep -c '^fish_add_path -g "$HOME/.local/bin"$' "$home/.config/fish/conf.d/tool.fish")"
home="$(scratch_home fish-linked)"
/bin/mkdir -p "$OMCTEST_WORK/homes/elsewhere"
/bin/ln -s "$OMCTEST_WORK/homes/elsewhere" "$home/.config"
add_to_path "$home" /opt/homebrew/bin/fish >/dev/null
check "a linked ~/.config is not written through" "" "$(/bin/ls -A "$OMCTEST_WORK/homes/elsewhere")"

section "198. anything the script cannot do safely changes nothing"
home="$(scratch_home tcsh)"
add_to_path "$home" /bin/tcsh >/dev/null; said="$(/bin/cat "$OMCTEST_WORK/add-to-path.out")"
check "an unknown shell: no files" ""                         "$(home_files "$home")"
check "it says what to do"       "1"                          "$(printf '%s' "$said" | /usr/bin/grep -c 'add ~/.local/bin to the PATH by hand')"
check "exit 0"                   "0"                          "$add_status"
home="$(scratch_home zdotdir)"
printf 'export ZDOTDIR="$HOME/.config/zsh"\n' > "$home/.zshenv"
add_to_path "$home" /bin/zsh >/dev/null; said="$(/bin/cat "$OMCTEST_WORK/add-to-path.out")"
check "ZDOTDIR: no ~/.zprofile"  "./.zshenv"                  "$(home_files "$home")"
check "and it says where to add it" "1"                       "$(printf '%s' "$said" | /usr/bin/grep -c 'sets ZDOTDIR')"
check "exit 0 there too"         "0"                          "$add_status"
home="$(scratch_home bad-args)"
/bin/sh "$path_script" --home "$home" --user "$me" --folder '../x' --name tool --shell /bin/zsh >/dev/null 2>&1
check "a .. folder is refused"   ""                           "$(home_files "$home")"
/bin/sh "$path_script" --home "$home" --user "$me" --folder '.local/bin' --name 'a b' --shell /bin/zsh >/dev/null 2>&1
check "a name with a space is refused" ""                     "$(home_files "$home")"
/bin/sh "$path_script" --home "$home" --user "$me" --folder '.local/$(x)' --name tool --shell /bin/zsh >/dev/null 2>&1
check "shell syntax in the folder is refused" ""              "$(home_files "$home")"
/bin/sh "$path_script" --home "$OMCTEST_WORK/homes/not-there" --user "$me" --folder .local/bin --name tool --shell /bin/zsh >/dev/null 2>&1
check "a missing home exits 0"   "0"                          "$?"
check "and creates nothing"      "no"                         "$([ -e "$OMCTEST_WORK/homes/not-there" ] && echo yes || echo no)"
# An option with no value used to spin "shift 2" forever, holding up Installer.
/usr/bin/perl -e 'alarm 10; exec @ARGV' /bin/sh "$path_script" --home "$home" --user >/dev/null 2>&1
check "an option with no value exits 0" "0"                   "$?"

# The replay project, installing for the user, plus a second component that
# only adds ~/.local/bin to the PATH - the shape of agent-vm's package.
setup_path_project() {
    setup_replay_project
    omc_fire PackageBuilder.field.changed $DOMAIN_ID "user"
    for tool_index in 0 1 2 3; do
        tool_name="$(/usr/bin/basename "$(payload_field "$tool_index" DESTINATION)")"
        pl set string "~/.local/bin/$tool_name" "$(model_file)" "/COMPONENTS/0/PAYLOAD/$tool_index/DESTINATION"
    done
    pl insert 1 dict "$(model_file)" /COMPONENTS
    pl set string "com.abracode.pkg.replay.path" "$(model_file)" /COMPONENTS/1/IDENTIFIER
    pl set string "Add ~/.local/bin to your shell's PATH" "$(model_file)" /COMPONENTS/1/TITLE
    pl set string "~" "$(model_file)" /COMPONENTS/1/INSTALL_LOCATION
    pl set string "User" "$(model_file)" /COMPONENTS/1/AUTH
    pl set string "~/.local/bin" "$(model_file)" /COMPONENTS/1/ADD_TO_PATH
    pl set array "$(model_file)" /COMPONENTS/1/PAYLOAD
    pl set string "allow" "$(model_file)" /DISTRIBUTION/CUSTOMIZE
}

section "199. a component that only adds a folder to the PATH"
setup_path_project
omc_run PackageBuilder.step.component
check "both components built"    "2"                          "$(built_pkg_count)"
check "the log says it has no payload" "1"                    "$(log_says 'no payload - this component only runs its install scripts')"
omc_run PackageBuilder.step.distribution
check "the distribution built"   "yes"                        "$([ -f "$(built_dist)" ] && echo yes || echo no)"
/bin/rm -rf "$OMCTEST_WORK/path-expand"
/usr/sbin/pkgutil --expand "$(built_dist)" "$OMCTEST_WORK/path-expand" >/dev/null 2>&1
path_component="$OMCTEST_WORK/path-expand/com_abracode_pkg_replay_path.pkg"
check "no payload, no Bom"       "no no"                      "$([ -e "$path_component/Payload" ] && echo yes || echo no) $([ -e "$path_component/Bom" ] && echo yes || echo no)"
check "the postinstall and the script ship" "yes yes"         "$([ -x "$path_component/Scripts/postinstall" ] && echo yes || echo no) $([ -f "$path_component/Scripts/pb_add_to_path.sh" ] && echo yes || echo no)"
check "the shipped script is the app's" "yes"                 "$(/usr/bin/cmp -s "$path_component/Scripts/pb_add_to_path.sh" "$path_script" && echo yes || echo no)"
check "the postinstall names the folder and the product" "1"  "$(/usr/bin/grep -c -- "--folder '.local/bin' --name 'replay'" "$path_component/Scripts/postinstall" | /usr/bin/tr -d ' ')"
check "installed at the home root" 'install-location="/"'     "$(pkginfo_attr "$path_component" install-location)"
check "overwrite-permissions patched" 'overwrite-permissions="false"' "$(pkginfo_attr "$path_component" overwrite-permissions)"
check "the payload component has no postinstall" "no"         "$([ -e "$OMCTEST_WORK/path-expand/com_abracode_pkg_replay.pkg/Scripts/postinstall" ] && echo yes || echo no)"
check "two choices"              "2"                          "$(/usr/bin/grep -c '<choice id=' "$(state_dir)/Distribution.xml" | /usr/bin/tr -d ' ')"
# What Installer would run, run against a scratch home: $2 is the home folder
# for a component installed at "~". The shell comes from the directory service,
# so which file it writes depends on the account running the suite; exactly one
# file carrying the marker is what must hold.
home="$(scratch_home installed)"
/bin/sh "$path_component/Scripts/postinstall" "$(built_dist)" "$home" / / > "$OMCTEST_WORK/postinstall.out" 2>&1
check "the postinstall exits 0"  "0"                          "$?"
check "one startup file carries the block" "1"                "$(/usr/bin/grep -rl '# >>> replay installer >>>' "$home" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

section "200. an empty payload still needs a reason"
setup_path_project
pl set string "" "$(model_file)" /COMPONENTS/1/ADD_TO_PATH
omc_run PackageBuilder.step.component
check "no payload, no scripts: refused" "1"                   "$(log_says 'Component 2: The payload is empty')"
check "nothing was built"        ""                           "$(built_pkg)"
# A document's own postinstall is enough, in a system package too.
setup_replay_project
printf '#!/bin/sh\nexit 0\n' > "$OMCTEST_WORK/only-post.sh"
pl insert 1 dict "$(model_file)" /COMPONENTS
pl set string "com.abracode.pkg.replay.post" "$(model_file)" /COMPONENTS/1/IDENTIFIER
pl set string "$OMCTEST_WORK/only-post.sh" "$(model_file)" /COMPONENTS/1/POSTINSTALL
pl set array "$(model_file)" /COMPONENTS/1/PAYLOAD
omc_run PackageBuilder.step.component
check "a postinstall-only component builds" "2"               "$(built_pkg_count)"

section "201. Add to PATH refuses what it cannot do safely"
setup_path_project
pl set string "~/../bin" "$(model_file)" /COMPONENTS/1/ADD_TO_PATH
omc_run PackageBuilder.step.component
check "a .. folder"              "1"                          "$(log_says 'Add to PATH "~/../bin" must be a folder in the home folder')"
pl set string '~/.local/$(touch x)' "$(model_file)" /COMPONENTS/1/ADD_TO_PATH
omc_run PackageBuilder.step.component
check "shell syntax"             "1"                          "$(log_says 'must be a folder in the home folder, written ~/')"
pl set string "/usr/local/bin" "$(model_file)" /COMPONENTS/1/ADD_TO_PATH
omc_run PackageBuilder.step.component
check "a system path"            "1"                          "$(log_says 'Add to PATH "/usr/local/bin" must be a folder')"
pl set string "~/.local/bin" "$(model_file)" /COMPONENTS/1/ADD_TO_PATH
pl set string "$OMCTEST_WORK/only-post.sh" "$(model_file)" /COMPONENTS/1/POSTINSTALL
omc_run PackageBuilder.step.component
check "beside a postinstall"     "1"                          "$(log_says 'so the component cannot also have one')"
pl set string "" "$(model_file)" /COMPONENTS/1/POSTINSTALL
pl set string "~/.local" "$(model_file)" /COMPONENTS/1/INSTALL_LOCATION
omc_run PackageBuilder.step.component
check "below the home folder"    "1"                          "$(log_says 'needs the component'"'"'s install location to be ~')"
check "nothing built from any of them" ""                     "$(built_pkg)"
pl set string "~" "$(model_file)" /COMPONENTS/1/INSTALL_LOCATION
omc_fire PackageBuilder.field.changed $DOMAIN_ID "system"
omc_run PackageBuilder.step.component
check "in a system package"      "1"                          "$(log_says 'Add to PATH needs a package that installs for the user')"

section "202. the exported script builds the same scripts"
setup_path_project
# A preinstall on the first component: the exported script used to share one
# scripts folder between components, which carried it into the second.
printf '#!/bin/sh\nexit 0\n' > "$OMCTEST_WORK/pre.sh"
pl set string "$OMCTEST_WORK/pre.sh" "$(model_file)" /COMPONENTS/0/PREINSTALL
pl set bool false "$(model_file)" /SIGNING/ENABLED
path_export="$OMCTEST_WORK/makepkg.path.sh"
/bin/rm -f "$path_export"
omc_dialog_answer save_as "$path_export"
omc_run PackageBuilder.export.script
check "the script was written"   "yes"                        "$([ -f "$path_export" ] && echo yes || echo no)"
check "and sh accepts it"        "0"                          "$(/bin/sh -n "$path_export" 2>/dev/null; echo $?)"
check "one scripts folder each"  "1 1"                        "$(/usr/bin/grep -c "^scripts_dir=\"\$staging_dir\"/'scripts'\$" "$path_export" | /usr/bin/tr -d ' ') $(/usr/bin/grep -c "^scripts_dir=\"\$staging_dir\"/'scripts-1'\$" "$path_export" | /usr/bin/tr -d ' ')"
/bin/rm -rf "$OMCTEST_WORK/path-out"
/bin/sh "$path_export" --unsigned --output-dir "$OMCTEST_WORK/path-out" > "$OMCTEST_WORK/path-run.log" 2>&1
check "the script succeeded"     "0"                          "$?"
/bin/rm -rf "$OMCTEST_WORK/path-script-expand"
/usr/sbin/pkgutil --expand "$OMCTEST_WORK/path-out/replay_2.2-unsigned.pkg" "$OMCTEST_WORK/path-script-expand" >/dev/null 2>&1
script_path_component="$OMCTEST_WORK/path-script-expand/com_abracode_pkg_replay_path.pkg"
check "the preinstall stayed in its component" "no"           "$([ -e "$script_path_component/Scripts/preinstall" ] && echo yes || echo no)"
check "and is in the first"      "yes"                        "$([ -e "$OMCTEST_WORK/path-script-expand/com_abracode_pkg_replay.pkg/Scripts/preinstall" ] && echo yes || echo no)"
check "no payload here either"   "no"                         "$([ -e "$script_path_component/Bom" ] && echo yes || echo no)"
omc_run PackageBuilder.step.component
omc_run PackageBuilder.step.distribution
/bin/rm -rf "$OMCTEST_WORK/path-app-expand"
/usr/sbin/pkgutil --expand "$(built_dist)" "$OMCTEST_WORK/path-app-expand" >/dev/null 2>&1
app_path_component="$OMCTEST_WORK/path-app-expand/com_abracode_pkg_replay_path.pkg"
check "the same postinstall"     "yes"                        "$(/usr/bin/cmp -s "$script_path_component/Scripts/postinstall" "$app_path_component/Scripts/postinstall" && echo yes || echo no)"
check "the same script"          "yes"                        "$(/usr/bin/cmp -s "$script_path_component/Scripts/pb_add_to_path.sh" "$app_path_component/Scripts/pb_add_to_path.sh" && echo yes || echo no)"
check "XML identical to the app's" "yes"                      "$(/usr/bin/cmp -s "$OMCTEST_WORK/path-script-expand/Distribution" "$OMCTEST_WORK/path-app-expand/Distribution" && echo yes || echo no)"
# A value the app refuses is refused in the script, and none of it is written.
pl set string "~/x'y" "$(model_file)" /COMPONENTS/1/ADD_TO_PATH
bad_path_export="$OMCTEST_WORK/makepkg.badpath.sh"
/bin/rm -f "$bad_path_export"
omc_dialog_answer save_as "$bad_path_export"
omc_run PackageBuilder.export.script
check "refused in the script"    "1"                          "$(/usr/bin/grep -c "^fail 'Component 2: Add to PATH" "$bad_path_export" | /usr/bin/tr -d ' ')"
check "and the postinstall is not written" "0"                "$(/usr/bin/grep -c 'PB_ADD_TO_PATH_POSTINSTALL' "$bad_path_export" | /usr/bin/tr -d ' ')"

section "203. Add to PATH imports back as the setting"
setup_path_project
omc_run PackageBuilder.step.component
omc_run PackageBuilder.step.distribution
path_built="$OMCTEST_WORK/replay-path.pkg"
/bin/cp "$(built_dist)" "$path_built"
setup_replay_project
omc_dialog_answer choose_file "$path_built"
omc_run PackageBuilder.import.pkg
check "two components"           "2"                          "$(component_total)"
check "the second adds the folder" "~/.local/bin"             "$(component_field ADD_TO_PATH 1)"
check "with no payload"          "0"                          "$(payload_total 1)"
check "the first adds nothing"   ""                           "$(component_field ADD_TO_PATH 0)"
check "not reported as lost scripts" "0"                      "$(log_says 'install scripts, which are in the package but were not extracted')"
check "the log names it"         "1"                          "$(log_says 'Add to PATH: ~/.local/bin')"

section "204. the window, the verifier and the CLI know the key"
setup_path_project
select_component_row 1
check "the field shows it"       "~/.local/bin"               "$(ui_value $ADD_TO_PATH_ID)"
check "and the options are open" "true"                       "$(ui_state $COMPONENT_OPTIONS_ID isExpanded)"
omc_fire PackageBuilder.field.changed $ADD_TO_PATH_ID "~/bin"
check "an edit reaches the document" "~/bin"                  "$(component_field ADD_TO_PATH 1)"
path_doc="$OMCTEST_WORK/path.pkgbld"
/bin/cp "$(model_file)" "$path_doc"
pbcli validate "$path_doc" >/dev/null 2>"$OMCTEST_WORK/path-validate.txt"
check "validate is quiet about it" "0"                        "$(/usr/bin/grep -c 'ADD_TO_PATH\|empty payload' "$OMCTEST_WORK/path-validate.txt" | /usr/bin/tr -d ' ')"
pbcli set "$path_doc" /COMPONENTS/1/ADD_TO_PATH "~/../x" >/dev/null 2>&1
pbcli validate "$path_doc" >/dev/null 2>"$OMCTEST_WORK/path-validate.txt"
check "validate names a bad folder" "1"                       "$(/usr/bin/grep -c 'COMPONENTS/1/ADD_TO_PATH "~/../x" must be ~/' "$OMCTEST_WORK/path-validate.txt" | /usr/bin/tr -d ' ')"
pl set string "~/.local/bin" "$path_doc" /COMPONENTS/1/ADD_TO_PATH
pl set string "system" "$path_doc" /DISTRIBUTION/DOMAIN
pbcli validate "$path_doc" >/dev/null 2>"$OMCTEST_WORK/path-validate.txt"
check "and a system document"    "1"                          "$(/usr/bin/grep -c 'ADD_TO_PATH is set, but DISTRIBUTION/DOMAIN is not user' "$OMCTEST_WORK/path-validate.txt" | /usr/bin/tr -d ' ')"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids"        ""                           "$(ui_unknown_writes)"

omctest_end
