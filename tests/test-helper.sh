#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
export XDG_CONFIG_HOME="$TEST_ROOT/config"
export XDG_STATE_HOME="$TEST_ROOT/state"
mkdir -p "$HOME"

HELPER="$ROOT/bin/omaspansion"
"$HELPER" migrate

jq -e '.version == 2 and .entries == []' "$XDG_CONFIG_HOME/omaspansion/entries.json" >/dev/null
jq -e '.version == 1 and .prefix == ";" and .excludedPrograms == []' "$XDG_CONFIG_HOME/omaspansion/settings.json" >/dev/null
[[ "$(stat -c %a "$XDG_CONFIG_HOME/omaspansion/entries.json")" == "600" ]]

valid_catalog='{
  "version": 2,
  "entries": [
    {"key":"op","description":"","category":"Secure","type":"onepassword-paste","value":"op://Vault/Item/password"},
    {"key":"bw","description":"","category":"Secure","type":"bitwarden-paste","value":"12345678-1234-1234-1234-123456789abc"},
    {"key":"lp","description":"","category":"Secure","type":"lastpass-paste","value":"123456789"},
    {"key":"pp","description":"","category":"Secure","type":"protonpass-paste","value":"pass://Vault/Item/password"}
  ]
}'
printf '%s\n' "$valid_catalog" | jq -c . | "$HELPER" save

typed_file="$XDG_CONFIG_HOME/omaspansion/typed-entries.dat"
[[ "$(grep -ao $'\001secure' "$typed_file" | wc -l)" -eq 4 ]]
! grep -aFq 'op://Vault' "$typed_file"
! grep -aFq '123456789abc' "$typed_file"
! grep -aFq 'pass://Vault' "$typed_file"

invalid_catalog='{
  "version": 2,
  "entries": [
    {"key":"bad","description":"","category":"Secure","type":"lastpass-paste","value":"display name"}
  ]
}'
if printf '%s\n' "$invalid_catalog" | jq -c . | "$HELPER" save >/dev/null 2>&1; then
  printf '%s\n' "invalid LastPass reference was accepted" >&2
  exit 1
fi

jq -e '.entries | length == 4' "$XDG_CONFIG_HOME/omaspansion/entries.json" >/dev/null

export HOME="$TEST_ROOT/legacy-home"
export XDG_CONFIG_HOME="$TEST_ROOT/legacy-config"
export XDG_STATE_HOME="$TEST_ROOT/legacy-state"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/omarchy-command-palette"
printf '%s\n' '{"version":2,"entries":[{"key":"legacy","description":"Imported","category":"Custom","type":"paste","value":"safe example"}]}' \
  > "$XDG_CONFIG_HOME/omarchy-command-palette/entries.json"
printf '%s\n' '{"version":1,"enabled":true,"prefix":"!","excludedPrograms":["example.app"]}' \
  > "$XDG_CONFIG_HOME/omarchy-command-palette/settings.json"
"$HELPER" migrate
"$HELPER" import-legacy >/dev/null
jq -e '.entries[0].key == "legacy"' "$XDG_CONFIG_HOME/omaspansion/entries.json" >/dev/null
jq -e '.prefix == "!" and .excludedPrograms == ["example.app"]' "$XDG_CONFIG_HOME/omaspansion/settings.json" >/dev/null
if "$HELPER" import-legacy >/dev/null 2>&1; then
  printf '%s\n' "legacy import overwrote a non-empty catalog" >&2
  exit 1
fi

printf '%s\n' "helper tests passed"
