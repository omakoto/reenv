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

    if ! command -v python3 >&/dev/null ; then
        echo 'reenv: Requires `python3`.' 1>&2
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

# Sort records separated by ###REENV###.
# Uses Python's list.sort() on bytes to guarantee LC_ALL=C byte-order sorting.
function reenv-sort() {
    python3 -c '
import sys
# Read entire stdin as bytes
content = sys.stdin.buffer.read()
# Split by record separator and filter out empty records
records = [r for r in content.split(b"###REENV###\n") if r]
# Sort records lexicographically by byte values (LC_ALL=C equivalent)
records.sort()
# Write sorted records back with the separator
if records:
    sys.stdout.buffer.write(b"###REENV###\n".join(records) + b"###REENV###\n")
'
}

# Compare two sorted files whose records are separated by ###REENV###.
# Implements GNU comm behavior (handling option combinations -1, -2, -3).
# Uses Python to process byte comparisons, ensuring LC_ALL=C comparison.
function reenv-comm() {
    python3 -c '
import sys

# Parse options to suppress specific columns
suppress1 = False
suppress2 = False
suppress3 = False

files = []
for arg in sys.argv[1:]:
    if arg.startswith("-") and len(arg) > 1:
        for char in arg[1:]:
            if char == "1":
                suppress1 = True
            elif char == "2":
                suppress2 = True
            elif char == "3":
                suppress3 = True
            else:
                sys.stderr.write(f"reenv-comm: invalid option -- {char}\n")
                sys.exit(1)
    else:
        files.append(arg)

if len(files) != 2:
    sys.stderr.write("Usage: reenv-comm [-1] [-2] [-3] <file1> <file2>\n")
    sys.exit(1)

file1, file2 = files[0], files[1]

# Load file contents
try:
    with open(file1, "rb") as f:
        content1 = f.read()
except Exception as e:
    sys.stderr.write(f"reenv-comm: {file1}: {e}\n")
    sys.exit(1)

try:
    with open(file2, "rb") as f:
        content2 = f.read()
except Exception as e:
    sys.stderr.write(f"reenv-comm: {file2}: {e}\n")
    sys.exit(1)

# Split contents into records
records1 = [r for r in content1.split(b"###REENV###\n") if r]
records2 = [r for r in content2.split(b"###REENV###\n") if r]

# Helper to write output matching comm columns and indentation
def write_col(col, val):
    if col == 1:
        if suppress1:
            return
        prefix = b""
    elif col == 2:
        if suppress2:
            return
        prefix = b"" if suppress1 else b"\t"
    else:
        if suppress3:
            return
        p1 = b"" if suppress1 else b"\t"
        p2 = b"" if suppress2 else b"\t"
        prefix = p1 + p2
    sys.stdout.buffer.write(prefix + val + b"###REENV###\n")

# Standard two-pointer comm comparison on sorted lists of bytes
i = 0
j = 0
while i < len(records1) and j < len(records2):
    if records1[i] < records2[j]:
        write_col(1, records1[i])
        i += 1
    elif records1[i] > records2[j]:
        write_col(2, records2[j])
        j += 1
    else:
        write_col(3, records1[i])
        i += 1
        j += 1

# Process remaining records
while i < len(records1):
    write_col(1, records1[i])
    i += 1

while j < len(records2):
    write_col(2, records2[j])
    j += 1
' "$@"
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
        # Use sed to add `-g` to all `declare` commands.
        compgen -v | _reenv_filter | while IFS= read -r name; do
            echo "#v:$name"
            declare -p "$name"
            printf '###REENV###\n'
        done | sed -e 's/^declare /declare -g /'

        # Dump functions.
        compgen -A function | _reenv_filter | while IFS= read -r name; do
            echo "#f:$name()"
            declare -p -f "$name"
            printf '###REENV###\n'
        done

        # Dump aliases.
        compgen -a | _reenv_filter | while IFS= read -r name; do
            echo "#a:$name(alias)"
            alias "$name"
            printf '###REENV###\n'
        done
    } | reenv-sort > "$_reenv_file"
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
            printf "unset -v %q\n###REENV###\n" "$name"
        done

        # functions
        compgen -A function | _reenv_filter | while IFS= read -r name; do
            printf "unset -f %q\n###REENV###\n" "$name"
        done

        # aliases
        compgen -a | _reenv_filter | while IFS= read -r name; do
            printf "unalias %q\n###REENV###\n" "$name"
        done
    } | reenv-sort > "$_reenv_file"
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
            # Dump deleted variables and functions with `unset`.
            doit reenv-comm -23 "$_reenv_active_unset_base_file" "$_reenv_active_unset_cur_file"

            # Dump added or changed variables and functions.
            doit reenv-comm -13 "$_reenv_active_base_file" "$_reenv_active_cur_file"
        }

        if [[ -n "${_reenv_active_out_file:-}" ]]; then
            _reenv_cap_out_block > "$_reenv_active_out_file"
        else
            _reenv_cap_out_block
        fi
    )
}
