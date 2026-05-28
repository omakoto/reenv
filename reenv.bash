# Reenv: https://github.com/omakoto/reenv

function _reenv_maybe_usage() {
    if ! [[ "$1" == "-h" || "$1" == "--help" ]] ; then
        return 1
    fi
    cat <<'EOF'

Reenv

Reenv tracks changes to the shell environment (variables and functions)
between two points in time and emits them as sourceable bash code.
This lets you capture environment changes made in one shell and replay
them in another.

See https://github.com/omakoto/reenv for more details.

EOF
    return 0
}

# Check if we have all the necessary commands and correct Bash version
function _reenv_pre_check() {
    # Check Bash version (requires 4.2+ for declare -g)
    if [[ -z "${BASH_VERSINFO[0]}" ]] || (( BASH_VERSINFO[0] < 4 )) || { (( BASH_VERSINFO[0] == 4 )) && (( BASH_VERSINFO[1] < 2 )); }; then
        echo "reenv: Requires Bash 4.2 or later." 1>&2
        return 1
    fi

    if ! command -v comm >&/dev/null ; then
        echo 'reenv: Requires `comm` command. Install with `apt install coreutils`.' 1>&2
        return 1
    fi
    return 0
}

_reenv_pre_check || return 1 2>/dev/null || exit 1

# Create temp files. We keep using the same files in the same shell
# and all direct and indirect child processes.
export _reenv_file_base="${_reenv_file_base:-$(mktemp "${TMPDIR:-/tmp}/reenv_base.XXXXXX")}"
export _reenv_file_cur="${_reenv_file_cur:-$(mktemp "${TMPDIR:-/tmp}/reenv_cur.XXXXXX")}"
export _reenv_file_unset_base="${_reenv_file_unset_base:-$(mktemp "${TMPDIR:-/tmp}/reenv_unset_base.XXXXXX")}"
export _reenv_file_unset_cur="${_reenv_file_unset_cur:-$(mktemp "${TMPDIR:-/tmp}/reenv_unset_cur.XXXXXX")}"

# Default ignore variables.
_reenv_default_skip='^('
_reenv_default_skip+='(reenv|_reenv|REENV|BASH|COMP).*|'
_reenv_default_skip+='FUNCNAME|RANDOM|SRANDOM|EPOCHREALTIME|EPOCHSECONDS|SECONDS|'
_reenv_default_skip+='USER|PWD|_|COLUMNS|LINES|'
_reenv_default_skip+='EUID|PPID|SHELLOPTS|UID|GROUPS|SHLVL|LINENO|HISTCMD|PIPESTATUS|'
_reenv_default_skip+='OPTIND|OPTARG|DIRSTACK'
_reenv_default_skip+=')$'

function _reenv_clear() {
    echo -n > "$_reenv_file_base"
    echo -n > "$_reenv_file_cur"
    echo -n > "$_reenv_file_unset_base"
    echo -n > "$_reenv_file_unset_cur"
}
[[ -z "${_reenv_initialized:-}" ]] && _reenv_clear
export _reenv_initialized=1

function _reenv_init() {
    _reenv_custom_skip="${REENV_SKIP:-}"
}

# Filter names using grep -E.
function _reenv_filter() {
    if [[ -n "$_reenv_custom_skip" ]]; then
        grep -E -v "$_reenv_default_skip" | grep -E -v "$_reenv_custom_skip"
    else
        grep -E -v "$_reenv_default_skip"
    fi
}

# Dump all variables and functions
function _reenv_dump() {
    {
        # Dump variables.
        compgen -v | _reenv_filter | while IFS= read -r name; do
            echo "#v:$name"
            declare -p "$name"
            printf '\0'
        done | sed -e 's/^declare /declare -g /'

        # Dump functions.
        compgen -A function | _reenv_filter | while IFS= read -r name; do
            echo "#f:$name()"
            declare -p -f "$name"
            printf '\0'
        done

        # Dump aliases.
        compgen -a | _reenv_filter | while IFS= read -r name; do
            echo "#a:$name(alias)"
            alias "$name"
            printf '\0'
        done
    } | LC_ALL=C sort -z
}

# Dump all variables with `unset`. We use it to detect deleted entries.
function _reenv_dump_unset() {
    {
        compgen -v | _reenv_filter | while IFS= read -r name; do
            # Use double quotes just so it's easier to write the expected
            # text in tests.
            printf "unset -v %q\n\0" "$name"
        done

        # functions
        compgen -A function | _reenv_filter | while IFS= read -r name; do
            printf "unset -f %q\n\0" "$name"
        done

        # aliases
        compgen -a | _reenv_filter | while IFS= read -r name; do
            printf "unalias %q\n\0" "$name"
        done
    } | LC_ALL=C sort -z
}

function _reenv_comm() {
    if [[ "${REENV_USE_COMM_FALLBACK:-}" == "1" ]]; then
        _reenv_comm_z "$@"
    else
        LC_ALL=C comm -z "$@"
    fi
}

# Simulate `comm -z` using python3, in case comm isn't installed.
function _reenv_comm_z() {
    local mode="$1"
    local file1="$2"
    local file2="$3"

    python3 -c '
import sys
mode, f1, f2 = sys.argv[1:]
with open(f1, "rb") as h1, open(f2, "rb") as h2:
    s1 = set(h1.read().split(b"\0"))
    s2 = set(h2.read().split(b"\0"))
    res = s1 - s2 if mode == "-23" else s2 - s1
    for line in sorted(res):
        if line:
            sys.stdout.buffer.write(line + b"\0")
' "$mode" "$file1" "$file2"
}

_reenv_opt_base=""
_reenv_opt_cur=""
_reenv_active_base_file=""
_reenv_active_unset_base_file=""
_reenv_active_cur_file=""
_reenv_active_unset_cur_file=""

function _reenv_parse_args() {
    _reenv_opt_base=""
    _reenv_opt_cur=""
    _reenv_active_base_file=""
    _reenv_active_unset_base_file=""
    _reenv_active_cur_file=""
    _reenv_active_unset_cur_file=""

    local _reenv_cmd="$1"
    shift

    local _reenv_options=""
    if [[ "$_reenv_cmd" == "reenv-base" ]]; then
        _reenv_options="b:"
    elif [[ "$_reenv_cmd" == "reenv-cap" ]]; then
        _reenv_options="b:f:"
    fi

    local _reenv_parsed
    if ! _reenv_parsed=$(getopt -o "$_reenv_options" -- "$@"); then
        return 1
    fi
    eval set -- "$_reenv_parsed"

    while true; do
        case "$1" in
            -b)
                _reenv_opt_base="$2"
                shift 2
                ;;
            -f)
                _reenv_opt_cur="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                echo "reenv: Internal option parsing error" 1>&2
                return 1
                ;;
        esac
    done

    if [[ $# -gt 0 ]]; then
        echo "reenv: Unexpected argument: $1" 1>&2
        return 1
    fi

    # Set active filenames
    if [[ -n "${_reenv_opt_base:-}" ]]; then
        _reenv_active_base_file="${_reenv_opt_base}.sh"
        _reenv_active_unset_base_file="${_reenv_opt_base}-clear.sh"
    else
        _reenv_active_base_file="$_reenv_file_base"
        _reenv_active_unset_base_file="$_reenv_file_unset_base"
    fi

    if [[ -n "${_reenv_opt_cur:-}" ]]; then
        _reenv_active_cur_file="${_reenv_opt_cur}.sh"
        _reenv_active_unset_cur_file="${_reenv_opt_cur}-clear.sh"
    else
        _reenv_active_cur_file="$_reenv_file_cur"
        _reenv_active_unset_cur_file="$_reenv_file_unset_cur"
    fi

    return 0
}

# Capture the "base" environment.
function reenv-base() {
    (
        set -e
        _reenv_init
        _reenv_maybe_usage "$*" && return 1
        _reenv_parse_args "reenv-base" "$@" || return 1

        _reenv_dump > "$_reenv_active_base_file"
        _reenv_dump_unset > "$_reenv_active_unset_base_file"

        if ! (( ${_reenv_quiet:-0} )) ; then
            echo "reenv: Captured baseline. Use reenv-cap to print the delta." 1>&2
        fi
    )
}

# Dump the part of the current environment that has changed since
# reenv-base in a format that can be source'd later.
function reenv-cap() {
    (
        set -e
        _reenv_init
        _reenv_maybe_usage "$*" && return 1
        _reenv_parse_args "reenv-cap" "$@" || return 1

        if ! [[ -s "$_reenv_active_base_file" ]] ; then
            echo "reenv: Use reenv-base to capture the base line environment first!" 1>&2
            return 1
        fi

        _reenv_dump > "$_reenv_active_cur_file"
        _reenv_dump_unset > "$_reenv_active_unset_cur_file"

        {
            # Dump deleted variables and functions with `unset`.
            _reenv_comm -23 "$_reenv_active_unset_base_file" "$_reenv_active_unset_cur_file"

            # Dump added or changed variables and functions.
            _reenv_comm -13 "$_reenv_active_base_file" "$_reenv_active_cur_file"
        } | tr -d '\0'
    )
}
