#!/usr/bin/env bash

set -o pipefail

TEST_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_TMP_BASE="${TMPDIR:-/tmp}"
TEST_TMP_ROOT="${TEST_TMP_ROOT:-${TEST_TMP_BASE%/}/nvim-workspace-tests}"
mkdir -p "$TEST_TMP_ROOT"

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

_nvim_lua() (
  local lua_path="$TEST_ROOT/lua/?.lua;$TEST_ROOT/lua/?/init.lua;$TEST_ROOT/tests/?.lua"
  # Test snippets write observations directly to stdout, bypassing the editor
  # message display. Only their lexical print changes; loaded modules keep
  # Neovim's own print and logging behavior.
  local lua_setup="
    package.path = '$lua_path;' .. package.path
    vim.opt.runtimepath:prepend('$TEST_ROOT')
    local function print(...)
      local fields = {}
      for index = 1, select('#', ...) do
        fields[index] = tostring(select(index, ...))
      end
      io.stdout:write(table.concat(fields, ' '), '\n')
      io.stdout:flush()
    end
  "
  local nvim_state
  nvim_state=$(_tmpdir) || return
  trap 'rm -rf -- "$nvim_state"' EXIT
  # LSP and the native logger still open state files in headless mode.
  # An explicit MRU path takes precedence over -i NONE. Only persistence
  # fixtures may opt in by passing their own scratch file as the second arg.
  XDG_STATE_HOME="$nvim_state" NVIM_LOG_FILE="$nvim_state/native.log" \
    NVIM_WORKSPACE_RECENT_FILE="${2:-}" nvim --headless --noplugin -u NONE -i NONE \
    -c "lua $lua_setup $1" \
    -c 'qa!' 2>&1 | tr -d '\r'
)
