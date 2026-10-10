# shellcheck shell=bash
# Read and write settings in .env (in the current directory). Sourced by
# toolkit.sh and the scripts it runs.

env_value() {  # env_value KEY DEFAULT
  local v
  v=$(grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2-)
  v=${v#\"}; v=${v%\"}
  echo "${v:-${2:-}}"
}

set_env() {  # set_env KEY VALUE  (.env holds secrets: owner-only, replaced atomically)
  local rest tmp
  rest=$(grep -v -E "^$1=" .env 2>/dev/null || true)
  tmp=$(umask 077 && mktemp .env.XXXXXX)
  printf '%s\n%s=%s\n' "$rest" "$1" "$2" > "$tmp"
  mv "$tmp" .env
}
