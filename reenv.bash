# Reenv: https://github.com/omakoto/reenv

function _reenv_maybe_usage() {
    if ! [[ "$1" == "-h" || "$1" == "--help" ]] ; then
        return 1
    fi
    cat <<'EOF'

Reenv

Reenv tracks changes to the shell environment (variables and functions)
between two points in time and emits them as sourceable bash code.
This lets you capture environment changes made in one shell (or subshell)
and replay them in another.

See https://github.com/omakoto/reenv for more details.

EOF
    return 0
}

# Check if we have all the necessary commands
function _reenv_pre_check() {
    if ! command -v comm >&/dev/null ; then
        echo 'reenv: Requires `comm` command. Install with `apt install coreutils`.' 1>&2
        return 1
    fi
    return 0
}

_reenv_pre_check

_reenv_file_base="${_reenv_file_base:-$(mktemp --suffix _reenv_base)}"
_reenv_file_current="${_reenv_file_current:-$(mktemp --suffix _reenv_cur)}"
_reenv_file_unset_base="${_reenv_file_unset_base:-$(mktemp --suffix _reenv_unset_base)}"
_reenv_file_unset_current="${_reenv_file_unset_current:-$(mktemp --suffix _reenv_unset_cur)}"

function _reenv_clear() {
    echo -n > "$_reenv_file_base"
    echo -n > "$_reenv_file_current"
    echo -n > "$_reenv_file_unset_base"
    echo -n > "$_reenv_file_unset_current"
}
_reenv_clear

function _reenv_init() {
    _reenv_custom_skip="${REENV_SKIP:-}"
}

# Detect if a variable (or function) name should be skipped.
function _reenv_skip() {
    local name="$1"
    if [[ "$name" =~ ^(reenv|_reenv|REENV|BASH|FUNCNAME$|RANDOM$|SRANDOM$|EPOCHREALTIME$|EPOCHSECONDS$|SECONDS$|USER$|PWD$|_$|COLUMNS$|LINES$) ]] ; then
        return 0
    fi
    if [[ "$_reenv_custom_skip" != "" && "$name" =~ ${_reenv_custom_skip} ]] ; then
        return 0
    fi
    return 1
}

# Dump all variables and functions
function _reenv_dump() {
    {
        # Dump variables.
        compgen -v | while IFS= read -r name; do
            # Skip certain variables
            _reenv_skip "$name" && continue
            echo "#v:$name"
            declare -p "$name"
            printf '\0'
        done | sed -e 's! ! -g !' # Make variables global

        # Dump functions.
        compgen -A function | while IFS= read -r name; do
            _reenv_skip "$name" && continue
            echo "#f:$name()"
            declare -p -f "$name"
            printf '\0'
        done

        # Dump aliases
        compgen -a | while IFS= read -r name; do
            _reenv_skip "$name" && continue
            echo "#a:$name(alias)"
            alias "$name"
            printf '\0'
        done
    } | LC_ALL=C sort -z
}

# Dump all variables with `unset`. We use it to detect deleted entries.
function _reenv_dump_unset() {
    {
        compgen -v | while IFS= read -r name; do
            _reenv_skip "$name" && continue
            # Use double quotes just so it's easier to write the expected
            # text in tests.
            printf "unset -v %q\n\0" "$name"
        done

        # functions
        compgen -A function | while IFS= read -r name; do
            _reenv_skip "$name" && continue
            printf "unset -f %q\n\0" "$name"
        done

        # aliases
        compgen -a | while IFS= read -r name; do
            _reenv_skip "$name" && continue
            printf "unalias %q\n\0" "$name"
        done
    } | LC_ALL=C sort -z
}

# Capture the "base" environment.
function reenv-base() {
    (
        set -e
        _reenv_init
        _reenv_maybe_usage "$*" && return 1

        _reenv_dump > "$_reenv_file_base"
        _reenv_dump_unset > "$_reenv_file_unset_base"

        if ! (( $_reenv_quiet )) ; then
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

        if ! [[ -s "$_reenv_file_base" ]] ; then
            echo "reenv: Use reenv-base to capture the base line environment first!" 1>&2
            return 1
        fi

        _reenv_dump > "$_reenv_file_current"
        _reenv_dump_unset > "$_reenv_file_unset_current"

        {
            # Dump deleted variables and functions with `unset`.
            LC_ALL=C comm -23 -z "$_reenv_file_unset_base" "$_reenv_file_unset_current"

            # Dump added or changed variables and functions
            LC_ALL=C comm -13 -z "$_reenv_file_base" "$_reenv_file_current"
        } | tr -d '\0'
    )
}
