# Reenv: https://github.com/omakoto/reenv

function _reenv_maybe_usage() {
    local arg
    local show_help=0
    for arg in "$@"; do
        if [[ "$arg" == "-h" || "$arg" == "--help" ]] ; then
            show_help=1
            break
        fi
    done

    if (( ! show_help )); then
        return 1
    fi

    cat <<'EOF'

Reenv

Reenv tracks changes to the shell environment (variables, functions, and aliases)
between two points in time and emits them as sourceable bash code.
This lets you capture environment changes made in one shell and replay
them in another.

Usage:
  reenv-base [-b BASELINE_NAME]
      Capture baseline state of the environment.
  reenv-cap [-b BASELINE_NAME] [-f CURRENT_NAME] [-o OUTPUT_FILE]
      Print environment delta since the baseline state.

Options:
  -b BASELINE_NAME  Specify baseline snapshot name (default is temporary file)
  -f CURRENT_NAME   Specify current snapshot name (default is temporary file)
  -o OUTPUT_FILE    Write the environment delta to OUTPUT_FILE instead of stdout

See https://github.com/omakoto/reenv for more details.

EOF
    return 0
}

function doit() {
    if (( ${_reenv_verbose:-0} )) ; then
        echo "$@" 1>&2
    fi
    "$@"
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
# and all direct and indirect child processes, so "cap" inside a child shell
# would work too.
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

function _reenv_comm() {
    LC_ALL=C comm -z "$@"
}

# Filter names using grep -E.
function _reenv_filter() {
    local custom_skip="${REENV_SKIP:-}"
    if [[ -n "$custom_skip" ]]; then
        grep -E -v "$_reenv_default_skip" | grep -E -v "$custom_skip"
    else
        grep -E -v "$_reenv_default_skip"
    fi
}

# Dump all variables, functions, and aliases.
function _reenv_dump() {
    local _reenv_file="$1"
    if ! (( ${_reenv_quiet:-0} )) ; then
        echo "Dumping to $_reenv_file..." 1>&2
    fi
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
    } | LC_ALL=C sort -z > "$_reenv_file"
}

# Dump all variables / etc with `unset`.
# We use it to detect deleted entries.
function _reenv_dump_unset() {
    local _reenv_file="$1"
    if ! (( ${_reenv_quiet:-0} )) ; then
        echo "Dumping clear commands to $_reenv_file...." 1>&2
    fi
    {
        compgen -v | _reenv_filter | while IFS= read -r name; do
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
    } | LC_ALL=C sort -z > "$_reenv_file"
}

# The actual filenames used in reenv-base and reenv-cap.
_reenv_active_base_file=""
_reenv_active_unset_base_file=""
_reenv_active_cur_file=""
_reenv_active_unset_cur_file=""
_reenv_active_out_file=""

function _reenv_parse_args() {
    local _reenv_opt_base=""
    local _reenv_opt_cur=""
    local _reenv_opt_out=""

    local _reenv_cmd="$1"
    shift

    local _reenv_options=""
    if [[ "$_reenv_cmd" == "reenv-base" ]]; then
        _reenv_options="b:"
    elif [[ "$_reenv_cmd" == "reenv-cap" ]]; then
        _reenv_options="b:f:o:"
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
            -o)
                _reenv_opt_out="$2"
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

    # Set active filenames (defaults first, override if option was given)
    _reenv_active_base_file="$_reenv_file_base"
    _reenv_active_unset_base_file="$_reenv_file_unset_base"
    _reenv_active_cur_file="$_reenv_file_cur"
    _reenv_active_unset_cur_file="$_reenv_file_unset_cur"
    _reenv_active_out_file="$_reenv_opt_out"

    if [[ -n "$_reenv_opt_base" ]]; then
        _reenv_active_base_file="${_reenv_opt_base}.sh"
        _reenv_active_unset_base_file="${_reenv_opt_base}-clear.sh"
    fi

    if [[ -n "$_reenv_opt_cur" ]]; then
        _reenv_active_cur_file="${_reenv_opt_cur}.sh"
        _reenv_active_unset_cur_file="${_reenv_opt_cur}-clear.sh"
    fi

    return 0
}

# Capture the "base" environment.
function reenv-base() {
    (
        set -e
        _reenv_maybe_usage "$@" && return 0
        _reenv_parse_args "reenv-base" "$@" || return 1

        _reenv_dump "$_reenv_active_base_file"
        _reenv_dump_unset "$_reenv_active_unset_base_file"

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
        _reenv_maybe_usage "$@" && return 0
        _reenv_parse_args "reenv-cap" "$@" || return 1

        if ! [[ -s "$_reenv_active_base_file" ]] ; then
            echo "reenv: Use reenv-base to capture the base line environment first!" 1>&2
            return 1
        fi

        _reenv_dump "$_reenv_active_cur_file"
        _reenv_dump_unset "$_reenv_active_unset_cur_file"

        _reenv_cap_out_block() {
            {
                # Dump deleted variables and functions with `unset`.
                doit _reenv_comm -23 "$_reenv_active_unset_base_file" "$_reenv_active_unset_cur_file"

                # Dump added or changed variables and functions.
                doit _reenv_comm -13 "$_reenv_active_base_file" "$_reenv_active_cur_file"
            } | tr -d '\0'
        }

        if [[ -n "${_reenv_active_out_file:-}" ]]; then
            _reenv_cap_out_block > "$_reenv_active_out_file"
        else
            _reenv_cap_out_block
        fi
    )
}
