#!/usr/bin/env bash

set -o pipefail

TEST_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_TMP_BASE="${TMPDIR:-/tmp}"
TEST_TMP_ROOT="${TEST_TMP_ROOT:-${TEST_TMP_BASE%/}/nvim-workspace-tests}"
mkdir -p "$TEST_TMP_ROOT"
LUA_FIXTURE_PATHS=()

# shellcheck source=tests/nvim-runtime.sh
. "$TEST_ROOT/tests/nvim-runtime.sh"

_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

_pass() {
  printf 'ok: %s\n' "$*"
}

_assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    _pass "$desc"
  else
    printf 'FAIL: %s\nexpected:\n%s\nactual:\n%s\n' "$desc" "$expected" "$actual" >&2
    exit 1
  fi
}

_assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    _pass "$desc"
  else
    printf 'FAIL: %s\nmissing:\n%s\nactual:\n%s\n' "$desc" "$needle" "$haystack" >&2
    exit 1
  fi
}

_tmpdir() {
  mktemp -d "$TEST_TMP_ROOT/tmp.XXXXXXXX"
}

_realpath() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

_set_fixture_paths() {
  local assignment
  for assignment; do
    LUA_FIXTURE_PATHS+=("NVIM_WORKSPACE_TEST_PATH_$assignment")
  done
}

_nvim_lua() (
  local nvim_state='' fixture socket_root='' run_fixture status=0
  trap '_clean_nvim_socket_root "$nvim_state" "$socket_root";
    [[ -z "$nvim_state" ]] || rm -rf -- "$nvim_state"' EXIT
  _trap_nvim_signals
  nvim_state=$(
    trap '' HUP INT TERM
    _tmpdir
  ) || return
  [[ "$nvim_state" == /* ]] || nvim_state="$PWD/$nvim_state"
  _nvim_socket_root "$nvim_state" socket_root || return
  mkdir "$nvim_state/tmp" || return
  fixture="$nvim_state/fixture.lua"

  # A suite passes shell fixture paths to _set_fixture_paths and reads them
  # through fixture_paths in Lua. Those paths never become Lua source.
  {
    cat <<'LUA' || return
local test_root = vim.env.NVIM_WORKSPACE_TEST_ROOT
package.path = test_root .. '/lua/?.lua;' .. test_root .. '/lua/?/init.lua;'
  .. test_root .. '/tests/?.lua;' .. package.path
vim.opt.runtimepath:prepend(test_root)
local fixture_paths = setmetatable({}, {
  __index = function(_, name)
    local path = vim.env['NVIM_WORKSPACE_TEST_PATH_' .. name]
    assert(path and path ~= '', 'missing Lua fixture path: ' .. name)
    return path
  end,
})
-- Keep snippet output separate from the editor message display.
local function print(...)
  local fields = {}
  for index = 1, select('#', ...) do
    fields[index] = tostring(select(index, ...))
  end
  io.stdout:write(table.concat(fields, ' '), '\n')
  io.stdout:flush()
end
LUA
    printf '%s\n' "$1"
  } >"$fixture" || return

  # Some distro legs predate `nvim -l`. A regular :lua startup error can be
  # followed by a successful :qa!, so explicitly exit nonzero on exceptions.
  run_fixture='lua
    local ok = xpcall(function()
      dofile(vim.env.NVIM_WORKSPACE_TEST_FIXTURE)
    end, function(err)
      io.stderr:write(debug.traceback(tostring(err), 2), "\n")
    end)
    if not ok then vim.cmd("cquit 1") end
  '

  # Keep the caller HOME available to tests of workspace root policy while
  # routing editor-owned files into the fixture.
  # Persistence fixtures can pass their own scratch MRU file as the second arg.
  unset NVIM NVIM_APPNAME NVIM_LISTEN_ADDRESS
  _run_nvim env ${LUA_FIXTURE_PATHS[@]+"${LUA_FIXTURE_PATHS[@]}"} \
    XDG_CONFIG_HOME="$nvim_state/config" XDG_DATA_HOME="$nvim_state/data" \
    XDG_CACHE_HOME="$nvim_state/cache" XDG_STATE_HOME="$nvim_state/state" \
    XDG_RUNTIME_DIR="$nvim_state" TMPDIR="$socket_root/tmp" \
    NVIM_LOG_FILE="$nvim_state/native.log" \
    NVIM_WORKSPACE_TEST_ROOT="$TEST_ROOT" NVIM_WORKSPACE_TEST_FIXTURE="$fixture" \
    NVIM_WORKSPACE_RECENT_FILE="${2:-}" \
    nvim --headless --noplugin -u NONE -i NONE --listen "$socket_root/s" \
    -c "$run_fixture" -c 'qa!' >"$nvim_state/output" 2>&1 || status=$?
  if ((status != 0)); then
    tr -d '\r' <"$nvim_state/output" >&2
    return "$status"
  fi
  tr -d '\r' <"$nvim_state/output"
)
