# shellcheck shell=bash

# Set an absolute socket directory because fixtures can chdir before
# Neovim unlinks its socket. The name and its terminator must fit in
# sockaddr_un (104 bytes on macOS).
_nvim_socket_root() {
  local runtime_dir=$1 destination=$2 short_tmp=/tmp alias LC_ALL=C
  if ((${#runtime_dir} + 2 < 104)) && [[ "$runtime_dir" != *[![:alnum:]_./-]* ]]; then
    printf -v "$destination" '%s' "$runtime_dir"
    return 0
  fi

  # An alias keeps the actual socket inside the chosen runtime directory
  # without truncation. Neovim's shell-based wildcard expansion also needs
  # a temp path without shell metacharacters for its response files.
  if [[ ! -w "$short_tmp" && -n ${PREFIX:-} ]]; then
    short_tmp="$PREFIX/tmp"
  fi
  # The owner handles cancellation. The allocator must be able to report
  # the new path even when the signal targets the whole foreground group.
  alias=$(
    trap '' HUP INT TERM
    mktemp -d "$short_tmp/nw.XXXXXXXX"
  ) || return
  # Publish ownership before linking so the caller's EXIT trap can clean up
  # an interrupted setup as well as a completed run.
  printf -v "$destination" '%s' "$alias/r"
  if ((${#alias} + 4 >= 104)); then
    printf 'Neovim fixture cannot create a short socket path in %s\n' "$short_tmp" >&2
    return 1
  fi
  ln -s "$runtime_dir" "$alias/r"
}

_clean_nvim_socket_root() {
  local runtime_dir=$1 socket_dir=$2
  if [[ -n "$socket_dir" && "$socket_dir" != "$runtime_dir" ]]; then
    rm -rf -- "${socket_dir%/r}"
  fi
}

# During fixture setup a signal can arrive before a new resource is
# recorded. Defer cancellation until the owning shell has its handles.
_trap_nvim_signals() {
  nvim_interrupt=0
  trap '_interrupt_nvim 129' HUP
  trap '_interrupt_nvim 130' INT
  trap '_interrupt_nvim 143' TERM
}

_interrupt_nvim() {
  if ((nvim_interrupt == 0)); then
    nvim_interrupt=$1
  fi
  [[ -z ${nvim_child:-} ]] || _stop_nvim "$nvim_child" "$nvim_interrupt"
}

# Run inside the fixture's private shell. Give the editor its own process
# group so cancellation can stop subprocesses before the EXIT trap removes
# the directories they use. An asynchronous wait lets Bash handle signals.
_run_nvim() {
  local nvim_child='' status=0
  ((nvim_interrupt == 0)) || return "$nvim_interrupt"
  # An inherited monitor option does not imply actual job control in a subshell.
  set +m
  set -m
  "$@" &
  nvim_child=$!
  # The child remains in its own group. Disable job notices while waiting.
  set +m
  ((nvim_interrupt == 0)) || _stop_nvim "$nvim_child" "$nvim_interrupt"
  wait "$nvim_child" || status=$?
  nvim_child=''
  ((nvim_interrupt == 0)) || return "$nvim_interrupt"
  return "$status"
}

_stop_nvim() {
  local child=$1 status=$2 deadline=$((SECONDS + 2))
  trap '' HUP INT TERM
  kill -TERM -- "-$child" 2>/dev/null || :
  while kill -0 -- "-$child" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      kill -KILL -- "-$child" 2>/dev/null || :
      break
    fi
    sleep 0.02
  done
  wait "$child" 2>/dev/null || :
  exit "$status"
}
