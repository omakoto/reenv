# reenv

`reenv` is a lightweight Bash utility designed to track changes to the shell environment (variables, functions, and aliases) between two points in time and serialize those changes as sourceable Bash code. 

This enables you to capture environment modifications (e.g., made within a subshell, a build script, or an installer) and replay them in your current shell or another shell session.

## Table of Contents
- [Features](#features)
- [How it Works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage Guide](#usage-guide)
  - [1. Basic Environment Tracking](#1-basic-environment-tracking)
  - [2. Capturing Subshell Changes](#2-capturing-subshell-changes)
  - [3. Exporting and Applying Aliases and Functions](#3-exporting-and-applying-aliases-and-functions)
- [Configuration](#configuration)
  - [Excluding Variables (REENV_SKIP)](#excluding-variables-reenv_skip)
  - [macOS / BSD Support (REENV_USE_COMM_FALLBACK)](#macos--bsd-support-reenv_use_comm_fallback)
  - [Suppressing Output (_reenv_quiet)](#suppressing-output-_reenv_quiet)
- [Running Tests](#running-tests)
- [License](#license)

---

## Features

- **Tracks Variables, Functions, and Aliases:** Detects new, modified, and deleted items.
- **Robust Serialization:** Uses `declare -p` and NUL-terminated inputs internally to handle multi-line variable values, whitespace, and special characters safely.
- **Sourcing Safety:** Replaces local `declare` statements with `declare -g` in the output, ensuring variables are declared globally even if sourced inside a function.
- **Preserves Export Status:** Correctly tracks and reapplies export status (`export` / `declare -x`) for variables and functions.
- **Customizable Filter:** Easily ignore specific variables or functions using a regular expression.
- **macOS / BSD Friendly:** Includes a Python 3 fallback for platforms where the GNU `comm -z` command is not available.

## How it Works

`reenv` exposes two main commands:

1. `reenv-base`: Captures the "before" snapshot (baseline) of all defined variables, functions, and aliases.
2. `reenv-cap`: Captures the "after" snapshot, calculates the delta from the baseline, and prints sourceable Bash code representing the difference (e.g., adding/modifying environment variables, declaring functions, unsetting removed variables).

## Requirements

- **Bash 4.2** or later (required for `declare -g` global declarations).
- **GNU `comm`** (from `coreutils`, supporting the `-z` flag).
- **Python 3** (optional; required only if using the macOS/BSD compatibility fallback).

## Installation

Simply clone the repository and source the script in your Bash shell or add it to your `.bashrc` / `.bash_profile`:

```bash
source /path/to/reenv.bash
```

---

## Usage Guide

### 1. Basic Environment Tracking

To track modifications in your active terminal:

```bash
# 1. Start the baseline snapshot
reenv-base

# 2. Modify the environment
export NEW_VAR="Hello World"
my_func() { echo "This is a function"; }
alias my_alias="echo 'This is an alias'"

# 3. Print the delta as sourceable bash code
reenv-cap
```

This will print:
```bash
#a:my_alias(alias)
alias my_alias='echo '\''This is an alias'\'''
#f:my_func()
my_func () 
{ 
    echo "This is a function"
}
#v:NEW_VAR
declare -g -x NEW_VAR="Hello World"
```

### 2. Capturing Subshell Changes

If you run setup scripts or installer routines inside a subshell (or within a script) and want to load their environment changes back into your main shell:

```bash
# 1. Capture baseline in the main shell
reenv-base

# 2. Perform work in a subshell, dumping the delta to a file
(
    export DEBIAN_FRONTEND=noninteractive
    export PATH="/opt/my-app/bin:$PATH"
    
    # Capture modifications made inside this subshell
    reenv-cap > /tmp/env_delta.sh
)

# 3. Replay changes in the parent shell
source /tmp/env_delta.sh
```

### 3. Exporting and Applying Aliases and Functions

Since `reenv-cap` generates standard shell declarations, any aliases and exported/unexported functions will be properly re-applied:

```bash
reenv-base

# Add an exported function
my_exported_func() {
    echo "Exported function!"
}
export -f my_exported_func

# Delete an existing variable
unset SOME_OLD_VAR

# Capture the delta
reenv-cap > /tmp/delta.sh
```
Applying `/tmp/delta.sh` in another shell session will unset `SOME_OLD_VAR`, define `my_exported_func`, and call `export -f my_exported_func` to ensure it is available to child processes.

---

## Configuration

`reenv` can be customized using the following environment variables:

### Excluding Variables (`REENV_SKIP`)
By default, `reenv` ignores internal Bash variables and read-only shell attributes (e.g., `BASH_*`, `FUNCNAME`, `RANDOM`, `USER`, `PWD`, `COLUMNS`, etc.). 

If you want to ignore additional variables or functions, define `REENV_SKIP` with a regular expression pattern matching their names:

```bash
# Ignore any variables starting with "TEMP_" or containing "SECRET"
export REENV_SKIP="(^TEMP_|_SECRET_)"

# Take baseline
reenv-base
```

### macOS / BSD Support (`REENV_USE_COMM_FALLBACK`)
By default, `reenv` uses `comm -z` to compute environment differences. The `-z` flag (NUL-delimited lines) is a GNU extension. On macOS/OS X or BSD, the default `comm` command does not support `-z`.

If you receive errors about `comm`, set `REENV_USE_COMM_FALLBACK=1`. `reenv` will fall back to using a lightweight python3 wrapper to perform the set operations:

```bash
export REENV_USE_COMM_FALLBACK=1
```

### Suppressing Output (`_reenv_quiet`)
By default, `reenv-base` prints a message to standard error when it successfully captures a baseline:
`reenv: Captured baseline. Use reenv-cap to print the delta.`

To silence this message, set:
```bash
export _reenv_quiet=1
```

---

## Running Tests

`reenv` comes with a comprehensive test suite in `reenv.bash.test`. To run the tests, execute the script directly:

```bash
./reenv.bash.test
```

## License

This project is licensed under the [MIT License](LICENSE).
