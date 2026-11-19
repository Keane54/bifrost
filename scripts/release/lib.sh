# Shared functions of the release scripts (docs/release.md). Each script reads this file with ".".
# The scripts are POSIX sh. summary.sh also runs on the Linux runner. The other scripts need macOS.

# Prints the message and stops the script with exit 1. The arguments are the parts of one message,
# joined with a space, so a long message can continue on the next line of a script. In GitHub
# Actions, the message is also an error annotation of the run.
fail() {
    if [ "${GITHUB_ACTIONS-}" = true ]; then
        printf '::error::%s\n' "$*" >&2
    else
        printf 'error: %s\n' "$*" >&2
    fi
    exit 1
}

# Returns 0 when $1 is a version of the form <major>.<minor>.<patch>, with digits only and no
# leading zero.
is_version() {
    case $1 in
        *[!0-9.]*) return 1 ;;
    esac
    printf '%s\n' "$1" | grep -E -q -x '(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
}

# Makes a new empty folder for temporary files and prints its path. The folder is in RUNNER_TEMP
# in GitHub Actions, else in TMPDIR.
temp_folder() {
    mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bifrost-release.XXXXXX"
}
