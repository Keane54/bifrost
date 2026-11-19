#!/bin/sh
# Checks the bundled files of the Live details mod and of the skills plugin.
#
# Usage: scripts/check-bundled.sh <app> [<repo root>]
#
# The repo owns the mod files (App/Bifrost/Resources/live-mod) and the skills folder
# (App/Bifrost/Resources/bifrost-skills). The app build copies the two folders to
# Contents/Resources, and the folder sync of the app installs them from there. The default repo
# root is the parent folder of this script.
#
# The script finds these faults:
# - The repo copy has no file for a mod file, or the skills folder of the repo has no files.
# - The app has no file for a mod file, or other bytes for it.
# - The skills folder of the app does not have the regular files of the repo copy with the same
#   bytes, or it has an extra file.
# - One of the four folders is a link or has a link in it.
# A link is not a regular file, and the script does not go into a link.
# The list of the mod files is the list of FolderSync.modFiles. Change the two lists together.
#
# The script prints one line for each fault and exits 1. With no fault, it prints "bundled files
# ok" and exits 0. A bad argument exits 2. The script only reads files. It never reads the
# Electron repo.
set -u

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: scripts/check-bundled.sh <app> [<repo root>]" >&2
    exit 2
fi
app=$1
if [ "$#" -eq 2 ]; then
    root=$2
else
    root=$(cd "$(dirname "$0")/.." && pwd) || exit 2
fi
resources="$app/Contents/Resources"
if [ ! -d "$resources" ]; then
    echo "error: $app has no Contents/Resources folder" >&2
    exit 2
fi
repo_mod="$root/App/Bifrost/Resources/live-mod"
repo_skills="$root/App/Bifrost/Resources/bifrost-skills"
app_mod="$resources/live-mod"
app_skills="$resources/bifrost-skills"

mod_files='.claude-plugin/plugin.json
.claude-plugin/marketplace.json
hooks/hooks.json
hooks/register.ts'

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT

faults=0
fault() {
    echo "$1"
    faults=$((faults + 1))
}

# Returns 0 for a regular file that is not a link.
is_file() {
    [ -f "$1" ] && [ ! -L "$1" ]
}

# Returns 0 for a folder that is not a link.
is_folder() {
    [ -d "$1" ] && [ ! -L "$1" ]
}

# Writes the regular files below a folder to a file, as relative paths in byte order. find does
# not follow a link.
list_files() {
    (cd "$1" && find . -type f) | sed 's|^\./||' | LC_ALL=C sort >"$2"
}

# Reports a fault for a folder that is a link and for each link in a folder. The second
# argument names the folder.
report_links() {
    if [ -L "$1" ]; then
        fault "$2 is a link"
    elif [ -d "$1" ]; then
        (cd "$1" && find . -type l) | sed 's|^\./||' | LC_ALL=C sort >"$tmp/links"
        while IFS= read -r file; do
            fault "$2 has a link $file"
        done <"$tmp/links"
    fi
}

report_links "$repo_mod" "the mod folder of the repo"
report_links "$repo_skills" "the skills folder of the repo"
report_links "$app_mod" "the mod folder of the app"
report_links "$app_skills" "the skills folder of the app"

for file in $mod_files; do
    if ! is_file "$repo_mod/$file"; then
        fault "the repo copy has no mod file $file"
    elif ! is_file "$app_mod/$file"; then
        fault "the app has no mod file $file"
    elif ! cmp -s "$repo_mod/$file" "$app_mod/$file"; then
        fault "the app has other bytes for the mod file $file"
    fi
done

if ! is_folder "$repo_skills"; then
    fault "the repo has no skills folder"
elif ! is_folder "$app_skills"; then
    fault "the app has no skills folder"
else
    list_files "$repo_skills" "$tmp/repo"
    list_files "$app_skills" "$tmp/app"
    if [ ! -s "$tmp/repo" ]; then
        fault "the skills folder of the repo has no files"
    fi
    while IFS= read -r file; do
        if ! is_file "$app_skills/$file"; then
            fault "the app has no skills file $file"
        elif ! cmp -s "$repo_skills/$file" "$app_skills/$file"; then
            fault "the app has other bytes for the skills file $file"
        fi
    done <"$tmp/repo"
    LC_ALL=C comm -13 "$tmp/repo" "$tmp/app" >"$tmp/extra"
    while IFS= read -r file; do
        fault "the app has an extra skills file $file"
    done <"$tmp/extra"
fi

if [ "$faults" -ne 0 ]; then
    exit 1
fi
echo "bundled files ok"
