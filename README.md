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
    - [Excluding Items (`REENV_SKIP`)](#excluding-items-reenv_skip)
  - [Advanced Usage](#advanced-usage)
    - [Specifying Custom Base/Cap/Output Files (`-b`, `-f`, `-o`)](#specifying-custom-basecapoutput-files--b--f--o)
  - [Running Tests](#running-tests)
  - [License](#license)

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

## What is NOT Captured

`reenv` only tracks shell and environment variables, functions, and aliases. It does **not** capture other aspects of the shell or system state, including:

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

## Configuration

`reenv` can be customized using the following environment variables:

### Excluding Items (`REENV_SKIP`)
By default, `reenv` ignores internal Bash variables and read-only shell attributes (e.g., `BASH_*`, `FUNCNAME`, `RANDOM`, `USER`, `PWD`, `COLUMNS`, etc.). 

If you want to ignore additional variables or functions, define `REENV_SKIP` with a regular expression pattern matching their names:

```bash
# Ignore any variables starting with "TEMP_" or containing "SECRET"
export REENV_SKIP="(^TEMP_|_SECRET_)"

# Take baseline
reenv-base
```

## Advanced Usage

By default, `reenv` writes environment snapshots to temporary files. If you want to use specific files instead of the default temporary files, you can specify custom file paths using the `-b` and `-f` options.

### Specifying Custom Base/Cap/Output Files (`-b`, `-f`, `-o`)

- **In `reenv-base`**:
  Use `-b FILENAME` to capture the baseline snapshot. This will save the baseline state into `FILENAME.sh` and the unset definitions into `FILENAME-clear.sh`.
  ```bash
  reenv-base -b /tmp/my_baseline
  ```

- **In `reenv-cap`**:
  - Use `-b FILENAME` to load the baseline snapshot from `FILENAME.sh` and `FILENAME-clear.sh` instead of the default temporary files.
  - Use `-f FILENAME` to save the "after" state snapshot into `FILENAME.sh` and `FILENAME-clear.sh`.
  - Use `-o FILENAME` to write the generated environment delta directly to `FILENAME` instead of printing to standard output.

  If `-o` is not specified, `reenv-cap` prints the environment delta to standard output:

  ```bash
  # Calculate delta comparing custom baseline and custom current snapshot, and redirect stdout to a file
  reenv-cap -b /tmp/my_baseline -f /tmp/my_current > /tmp/delta.sh

  # Alternatively, write the delta directly using the -o option
  reenv-cap -b /tmp/my_baseline -f /tmp/my_current -o /tmp/delta.sh
  ```

## Limitations

`reenv` tracks entire environment states and variables rather than identifying changes *within* individual variables.

- **No Internal/Incremental Deltas (e.g., `PATH` modifications)**:
  If a variable's value is modified (for example, appending a path to `PATH` using `export PATH="$PATH:/new/path"`), `reenv` captures and re-emits the entire new value of `PATH` (e.g., `declare -x PATH="...:/new/path"`). It does not detect the incremental change or output self-referential definitions like `export PATH="$PATH:/new/path"`.

- **Local Variables Applied as Global**:
  If a variable is local to an active shell function (i.e., declared with `local`), `reenv` captures its value at the time of tracking. However, when the generated delta script is replayed, all captured variables are re-applied as global variables (using `declare -g`).

## Running Tests

`reenv` comes with a comprehensive test suite in `reenv.bash.test`. To run the tests, execute the script directly:

```bash
./reenv.bash.test
```

## License

This project is licensed under the [MIT License](LICENSE).
