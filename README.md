# reenv

`reenv` is a lightweight Bash utility designed to track changes to the shell environment (variables, functions, and aliases) between two points in time and serialize those changes as sourceable Bash code. 

This enables you to capture environment modifications (e.g., made within a subshell, a build script, or an installer) and replay them in your current shell or another shell session.

## Table of Contents
- [reenv](#reenv)
  - [Table of Contents](#table-of-contents)
  - [Features](#features)
  - [How it Works](#how-it-works)
  - [Requirements](#requirements)
  - [Installation](#installation)
  - [What is NOT Captured](#what-is-not-captured)
  - [Usage Guide](#usage-guide)
    - [1. Basic Environment Tracking](#1-basic-environment-tracking)
    - [2. Capturing Subshell Changes](#2-capturing-subshell-changes)
    - [3. Exporting and Applying Aliases and Functions](#3-exporting-and-applying-aliases-and-functions)
  - [Configuration](#configuration)
    - [Excluding Variables (`REENV_SKIP`)](#excluding-variables-reenv_skip)
  - [Running Tests](#running-tests)
  - [License](#license)

---

## Features

- **Tracks Variables, Functions, and Aliases:** Detects new, modified, and deleted items.
- **Preserves Export Status:** Correctly tracks and reapplies export status (`export` / `declare -x`) for variables and functions.
- **Customizable Filter:** Easily ignore specific variables or functions using a regular expression.

## How it Works

`reenv` exposes two main commands:

1. `reenv-base`: Captures the "before" snapshot (baseline) of all defined variables, functions, and aliases.
2. `reenv-cap`: Captures the "after" snapshot, calculates the delta from the baseline, and prints sourceable Bash code representing the difference (e.g., adding/modifying environment variables, declaring functions, unsetting removed variables).

## Requirements

- **Bash 4.2** or later (required for `declare -g` global declarations).
- **GNU `comm`** (from `coreutils`. Reenv requires the `-z` flag).

## Installation

Simply clone the repository and source the script in your Bash shell or add it to your `.bashrc` / `.bash_profile`:

```bash
source /path/to/reenv.bash
```

---

## What is NOT Captured

`reenv` only tracks shell variables, functions, and aliases. It does **not** capture other aspects of the shell or system state, including:

- **System/Process State:**
  - File system changes (creation, modification, or deletion of files/directories).
  - Background or foreground processes started during the session.
  - Active file descriptors, network connections, or pipe/stream redirections.
- **Shell Attributes & Settings:**
  - The current working directory (e.g., calling `cd` changes directory, but the directory path changes are not captured as `cd` commands; `PWD` itself is ignored by default).
  - Active shell options (e.g., flags set via `shopt` or `set -o`).
  - The file creation mask (`umask`).
  - Signal trap handlers (`trap`).
  - Terminal settings (`stty`).
- **Ignored Variables:**
  - Read-only shell variables and internal Bash/environment variables (e.g., `BASH_*`, `FUNCNAME`, `RANDOM`, `USER`, `SECONDS`, etc., which are filtered out to prevent corruption during replay).

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

---

## Running Tests

`reenv` comes with a comprehensive test suite in `reenv.bash.test`. To run the tests, execute the script directly:

```bash
./reenv.bash.test
```

## License

This project is licensed under the [MIT License](LICENSE).
