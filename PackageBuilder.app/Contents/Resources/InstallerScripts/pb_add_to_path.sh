#!/bin/sh
# pb_add_to_path.sh - put a folder in the user's home on their login shell's PATH
#
# Shipped inside an installer package by PackageBuilder, and run by the
# postinstall script PackageBuilder writes beside it. It edits one of the
# user's shell startup files, once, so that a folder such as ~/.local/bin is on
# the PATH of every new Terminal window.
#
# Usage:
#   pb_add_to_path.sh --home <dir> --user <name> --folder <path under home>
#                     --name <product name> [--shell <login shell>]
#
#   --home    the user's home folder. Taken from what Installer passes the
#             postinstall script, never from this process's environment.
#   --user    the user who owns it. Files this script creates are given to
#             them, even when it runs as root.
#   --folder  the folder to add, relative to the home folder: ".local/bin".
#   --name    names the marker comments around the added lines, and the fish
#             file, so a later uninstall can find and remove exactly them.
#   --shell   the login shell. Read from the directory service when omitted.
#
# What it does:
#   - Leaves every file alone when any startup file of that shell already
#     mentions the folder, or already carries this script's marker. That also
#     catches a line some other installer added, such as uv's
#     '. "$HOME/.local/bin/env"'.
#   - zsh: appends to ~/.zprofile. macOS's /etc/zprofile runs path_helper,
#     which reorders PATH; ~/.zprofile runs after it, and login shells - which
#     Terminal opens - read it.
#   - bash: appends to the first of ~/.bash_profile, ~/.bash_login, ~/.profile
#     that exists, and creates ~/.bash_profile when none does. Creating
#     ~/.bash_profile beside an existing ~/.profile would stop bash reading
#     ~/.profile.
#   - fish: writes ~/.config/fish/conf.d/<name>.fish, a file of its own.
#   - any other shell: changes nothing and says why.
#   - A startup file that is a symbolic link (a dotfiles repository) is not
#     written through; it is reported and left alone.
#
# The added lines sit between "# >>> <name> installer >>>" and
# "# <<< <name> installer <<<", and prepend the folder only when PATH does not
# already hold it, so reading the file twice adds nothing.
#
# It never fails the install. Everything it does or declines to do is printed
# on stdout, which Installer copies to /var/log/install.log, and it always
# exits 0: a profile edit that did not happen must not look like a failed
# installation.
#
# POSIX sh (macOS /bin/sh, bash 3.2). Validate with "sh -n".

say() {
    printf '%s\n' "pb_add_to_path: $*"
}

home=""
user=""
folder=""
name=""
login_shell=""

while [ "$#" -gt 0 ]; do
    # Every option takes a value. Without one, "shift 2" would shift nothing
    # and this loop would never end, holding up the installation.
    if [ "$#" -lt 2 ]; then
        say "\"$1\" has no value - nothing was changed"
        exit 0
    fi
    case "$1" in
        --home)   home="$2"; shift 2 ;;
        --user)   user="$2"; shift 2 ;;
        --folder) folder="$2"; shift 2 ;;
        --name)   name="$2"; shift 2 ;;
        --shell)  login_shell="$2"; shift 2 ;;
        *)
            say "unknown argument \"$1\" - nothing was changed"
            exit 0
            ;;
    esac
done

# --- The arguments ------------------------------------------------------------
# Each value lands in a file the user's shell will execute, so each is held to a
# character set that cannot carry shell syntax, rather than quoted and hoped
# for. PackageBuilder refuses the same values before it builds.
case "$home" in
    /*) ;;
    *) say "the home folder \"$home\" is not an absolute path - nothing was changed"; exit 0 ;;
esac
home="${home%/}"
if [ -z "$home" ] || [ ! -d "$home" ]; then
    say "the home folder \"$home\" is not there - nothing was changed"
    exit 0
fi
case "$user" in
    ''|*[!A-Za-z0-9._-]*) say "the user name \"$user\" is not usable - nothing was changed"; exit 0 ;;
esac
folder="${folder#/}"
folder="${folder%/}"
case "$folder" in
    ''|*[!A-Za-z0-9._/-]*) say "the folder \"$folder\" is not usable - nothing was changed"; exit 0 ;;
esac
case "/$folder/" in
    */../*|*/./*|*//*) say "the folder \"$folder\" is not a plain path under the home folder - nothing was changed"; exit 0 ;;
esac
case "$name" in
    ''|*[!A-Za-z0-9._-]*) say "the name \"$name\" is not usable - nothing was changed"; exit 0 ;;
esac

marker_begin="# >>> $name installer >>>"
marker_end="# <<< $name installer <<<"

# --- The login shell ------------------------------------------------------------
# From the directory service, not $SHELL: Installer runs this script in an
# environment of its own, and $SHELL there says nothing about the user's choice.
# /Search rather than the local node alone, so a network account is found too;
# a local account is found there first.
if [ -z "$login_shell" ]; then
    dscl_output="$(/usr/bin/dscl /Search -read "/Users/$user" UserShell 2>/dev/null)"
    login_shell="${dscl_output#UserShell: }"
    login_shell="$(printf '%s' "$login_shell" | /usr/bin/head -n 1 | /usr/bin/tr -d ' \t')"
fi
shell_name="${login_shell##*/}"
if [ -z "$shell_name" ]; then
    say "could not read the login shell of $user - nothing was changed"
    exit 0
fi

# --- Already there? ---------------------------------------------------------------
# The folder counts as mentioned only as a path in the home folder - after
# $HOME, ${HOME}, "$HOME", ~ or the home folder spelled out - and only as a
# whole path component. The bare text would match far too much: "bin" is in
# the Homebrew line "eval "$(/opt/homebrew/bin/brew shellenv)"" that most
# ~/.zprofile files carry. uv's '. "$HOME/.local/bin/env"' still counts.
# The folder's only regular-expression character is the dot; the home folder
# may hold any, so all of them are escaped.
folder_pattern="$(printf '%s' "$folder" | /usr/bin/sed 's/\./\\./g')"
home_pattern="$(printf '%s' "$home" | /usr/bin/sed 's/[][\\.*^$+?(){}|]/\\&/g')"
mention_pattern="(\\\$HOME|\\\$\\{HOME\\}|~|$home_pattern)\"?/$folder_pattern([^A-Za-z0-9._-]|\$)"

# Succeed when one existing file mentions the folder or carries the marker.
# Arguments: the file. A missing or unreadable file mentions nothing.
file_mentions_folder() {
    local candidate="$1"
    [ -f "$candidate" ] || return 1
    [ -r "$candidate" ] || return 1
    # grep -c prints 0 and exits 1 when nothing matches, so the count is what
    # is tested, not the status.
    local folder_hits="$(/usr/bin/grep -c -E -e "$mention_pattern" "$candidate" 2>/dev/null)"
    local marker_hits="$(/usr/bin/grep -c -F -e "$marker_begin" "$candidate" 2>/dev/null)"
    case "$folder_hits" in ''|*[!0-9]*) folder_hits=0 ;; esac
    case "$marker_hits" in ''|*[!0-9]*) marker_hits=0 ;; esac
    [ "$folder_hits" -gt 0 ] || [ "$marker_hits" -gt 0 ]
}

# Every startup file the shell reads, so a line in any of them counts. The
# files are read through symbolic links: reading one is harmless, and a dotfiles
# repository that already adds the folder is exactly the case to leave alone.
case "$shell_name" in
    zsh)  startup_files=".zshenv .zprofile .zshrc .zlogin" ;;
    bash) startup_files=".bash_profile .bash_login .profile .bashrc" ;;
    fish) startup_files=".config/fish/config.fish .config/fish/fish_variables" ;;
    *)
        say "the login shell of $user is $login_shell, which this installer does not know how to configure - add ~/$folder to the PATH by hand"
        exit 0
        ;;
esac

# Set by the loop below.
startup_file=""
for startup_file in $startup_files; do
    if file_mentions_folder "$home/$startup_file"; then
        say "~/$startup_file already mentions $folder - nothing was changed"
        exit 0
    fi
done
if [ "$shell_name" = "fish" ] && [ -d "$home/.config/fish/conf.d" ]; then
    for startup_file in "$home/.config/fish/conf.d"/*.fish; do
        if file_mentions_folder "$startup_file"; then
            say "${startup_file#"$home"/} already mentions $folder - nothing was changed"
            exit 0
        fi
    done
fi

# zsh reads its startup files from $ZDOTDIR when ~/.zshenv sets it, and a line
# in ~/.zprofile would then never be read while this script reported success.
# Where $ZDOTDIR points is only known by running the user's ~/.zshenv, which
# this script will not do, so it declines and says so.
if [ "$shell_name" = "zsh" ] && [ -f "$home/.zshenv" ]; then
    zdotdir_hits="$(/usr/bin/grep -c ZDOTDIR "$home/.zshenv" 2>/dev/null)"
    case "$zdotdir_hits" in ''|*[!0-9]*) zdotdir_hits=0 ;; esac
    if [ "$zdotdir_hits" -gt 0 ]; then
        say "~/.zshenv sets ZDOTDIR, so zsh reads its startup files from another folder - nothing was changed; add ~/$folder to the PATH in that folder's .zprofile"
        exit 0
    fi
fi

# --- Which file ---------------------------------------------------------------------
# Set in the branches below.
target=""
case "$shell_name" in
    zsh) target="$home/.zprofile" ;;
    bash)
        for startup_file in .bash_profile .bash_login .profile; do
            if [ -e "$home/$startup_file" ] || [ -L "$home/$startup_file" ]; then
                target="$home/$startup_file"
                break
            fi
        done
        [ -n "$target" ] || target="$home/.bash_profile"
        ;;
    fish) target="$home/.config/fish/conf.d/$name.fish" ;;
esac
shown_target="~/${target#"$home"/}"

if [ -L "$target" ]; then
    say "$shown_target is a symbolic link, so it was not written through - add ~/$folder to the PATH in the file it points to"
    exit 0
fi
if [ -e "$target" ] && [ ! -f "$target" ]; then
    say "$shown_target is not a regular file - nothing was changed"
    exit 0
fi

# The folders above a fish conf.d file may not exist yet. Created one level at a
# time, so every one this makes can be handed to the user; a symbolic link on
# the way is refused for the same reason as a linked startup file.
if [ "$shell_name" = "fish" ]; then
    # Set by the loop below.
    fish_dir=""
    for fish_dir in "$home/.config" "$home/.config/fish" "$home/.config/fish/conf.d"; do
        if [ -L "$fish_dir" ]; then
            say "~/${fish_dir#"$home"/} is a symbolic link, so nothing was written through it - add ~/$folder to the PATH by hand"
            exit 0
        fi
        if [ ! -d "$fish_dir" ]; then
            /bin/mkdir "$fish_dir" 2>/dev/null
            mkdir_status=$?
            if [ "$mkdir_status" -ne 0 ]; then
                say "could not create ~/${fish_dir#"$home"/} - nothing was changed"
                exit 0
            fi
            /usr/sbin/chown "$user" "$fish_dir" 2>/dev/null
        fi
    done
fi

# --- The lines ------------------------------------------------------------------------
created=0
[ -e "$target" ] || created=1

# A file whose last line has no newline would have the marker glued onto it.
separator=""
if [ "$created" = "0" ] && [ -s "$target" ]; then
    last_byte="$(/usr/bin/tail -c 1 "$target" 2>/dev/null | /usr/bin/od -An -c | /usr/bin/tr -d ' ')"
    [ "$last_byte" = '\n' ] || separator="
"
fi

if [ "$shell_name" = "fish" ]; then
    block="$marker_begin
# Added by the $name installer: puts ~/$folder on the PATH.
fish_add_path -g \"\$HOME/$folder\"
$marker_end
"
else
    block="$marker_begin
# Added by the $name installer: puts ~/$folder on the PATH.
case \":\$PATH:\" in
    *\":\$HOME/$folder:\"*) ;;
    *) export PATH=\"\$HOME/$folder:\$PATH\" ;;
esac
$marker_end
"
fi

printf '%s%s' "$separator" "$block" >> "$target" 2>/dev/null
write_status=$?
if [ "$write_status" -ne 0 ]; then
    say "could not write $shown_target - add ~/$folder to the PATH by hand"
    exit 0
fi

# Given to the user whoever ran this. Installer runs a per-user package's
# scripts as that user, so this is normally a no-op; it matters when the script
# turns out to run as root, which would otherwise leave a root-owned startup
# file the user cannot edit.
if [ "$created" = "1" ]; then
    /usr/sbin/chown "$user" "$target" 2>/dev/null
    /bin/chmod 644 "$target" 2>/dev/null
    say "created $shown_target, which adds ~/$folder to the PATH of new $shell_name sessions"
else
    say "added ~/$folder to the PATH in $shown_target, for new $shell_name sessions"
fi
exit 0
