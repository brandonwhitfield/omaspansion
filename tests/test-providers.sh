#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
export XDG_CONFIG_HOME="$TEST_ROOT/config"
export XDG_STATE_HOME="$TEST_ROOT/state"
export PATH="$TEST_ROOT/bin:$PATH"
export CAPTURE_FILE="$TEST_ROOT/captured"
mkdir -p "$HOME" "$TEST_ROOT/bin"

make_mock() {
  local name="$1"
  local body="$2"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$body" > "$TEST_ROOT/bin/$name"
  chmod 0755 "$TEST_ROOT/bin/$name"
}

make_mock hyprctl '
if [[ "$*" == "-j activewindow" ]]; then
  printf '\''{"address":"0xtest"}\n'\''
elif [[ "$*" == "-j clients" ]]; then
  printf '\''[{"address":"0xtest"}]\n'\''
fi'
make_mock ydotool '[[ "$1" == "type" ]]; cat > "$CAPTURE_FILE"'
make_mock notify-send 'exit 0'
make_mock wl-copy 'exit 99'
make_mock wl-paste 'exit 99'
make_mock secret-tool '
if [[ "$1" == "lookup" && "$*" == *"bitwarden-session"* ]]; then
  printf '\''test-session\n'\''
elif [[ "$1" == "lookup" && "$*" == *"local-secret:"* ]]; then
  printf '\''local-result\n'\''
else
  exit 1
fi'
make_mock bw '
[[ "${BW_SESSION:-}" == "test-session" ]]
[[ "$*" == "get password 12345678-1234-1234-1234-123456789abc" ]]
printf '\''bitwarden-result\n'\'''
make_mock lpass '
[[ "$*" == "show --sync=auto --password 123456789" ]]
printf '\''lastpass-result\n'\'''
make_mock pass-cli '
[[ "$*" == "item view pass://Vault/Item/password" ]]
printf '\''proton-result\n'\'''

HELPER="$ROOT/bin/omaspansion"
"$HELPER" migrate
catalog='{
  "version": 2,
  "entries": [
    {"key":"bw","description":"","category":"Secure","type":"bitwarden-paste","value":"12345678-1234-1234-1234-123456789abc"},
    {"key":"lp","description":"","category":"Secure","type":"lastpass-paste","value":"123456789"},
    {"key":"pp","description":"","category":"Secure","type":"protonpass-paste","value":"pass://Vault/Item/password"},
    {"key":"local","description":"","category":"Secure","type":"local-secret-paste","value":"local-secret:12345678-1234-1234-1234-123456789abc"}
  ]
}'
printf '%s\n' "$catalog" | jq -c . | "$HELPER" save

run_and_expect() {
  local key="$1"
  local expected="$2"
  : > "$CAPTURE_FILE"
  "$HELPER" run "$key" 0xtest
  [[ "$(<"$CAPTURE_FILE")" == "$expected" ]]
}

run_and_expect bw bitwarden-result
run_and_expect lp lastpass-result
run_and_expect pp proton-result
run_and_expect local local-result

printf '%s\n' "provider tests passed"
