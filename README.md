# Reenv

Reenv tracks changes to the shell environment (variables and functions)
between two points in time and emits them as sourceable bash code.
This lets you capture environment changes made in one shell (or subshell)
and replay them in another.

# Usage

```bash
source /path/to/reenv.bash   # load the functions

reenv-base                   # snapshot the current environment as baseline
... make changes ...
reenv-cap                    # print everything that changed since reenv-base
```

The output of `reenv-cap` is valid bash: source it (or pipe it through bash)
to apply the same changes — including variable deletions and function changes —
to another shell.

# Examples

## Capture env changes and apply them in the same shell

```bash
source reenv.bash
reenv-base
export TOKEN="secret"
function greet() { echo "hello $1"; }
reenv-cap > /tmp/env-delta.sh

# Later, or in a new terminal:
source reenv.bash
source /tmp/env-delta.sh
# TOKEN and greet() are now set
```

## Propagate env changes made inside a subshell to the parent

```bash
source reenv.bash
reenv-base

(
    export BUILD_FLAGS="-O2 -DNDEBUG"
    unset DEBUG
    reenv-cap > /tmp/env-delta.sh
)

source /tmp/env-delta.sh
# BUILD_FLAGS is now set and DEBUG is unset in the current shell
```

## Use with a build or config script that modifies the environment

```bash
source reenv.bash
reenv-base
source ./setup-env.sh       # sets up PATH, exports, defines helpers
reenv-cap > /tmp/setup-delta.sh

# Share /tmp/setup-delta.sh so others can replay the same setup:
#   source /tmp/setup-delta.sh
```
