# Omaspansion

Omaspansion is an Omarchy Quattro text expander and searchable command palette.
It ships with an empty catalog and can resolve individual fields from supported
password managers without saving the resolved value in its configuration or
placing it on the clipboard.

> Beta software: review the code and security notes before connecting a vault.
> Omarchy plugins run unsandboxed with your user permissions.

## Features

- Press `Alt+E` to search, run, create, edit, and delete expansions.
- Type a configurable punctuation prefix (default `;`) followed by an entry key
  to expand it immediately, without Space or Enter.
- Correct a mistyped key with Backspace without retyping the prefix or the
  entire key; tracking ends at whitespace and normal input boundaries.
- Put `$|$` once in ordinary paste text to set the final cursor position.
- Exclude applications from typed expansion by application ID.
- Store local secure values in the desktop login keyring.
- Resolve references through 1Password, Bitwarden, LastPass, and Proton Pass.
- Keep secure entries opaque inside the Fcitx runtime cache.

Omaspansion includes no built-in entries, blocked applications, vault names,
item IDs, secret references, or credentials.

## Install the GitHub beta

```bash
omarchy plugin add https://github.com/brandonwhitfield/omaspansion.git --enable
~/.config/omarchy/plugins/brandon.omaspansion/install
fcitx5 -rd
```

Setup checks the required commands, builds the user-local Fcitx addon, and
builds the optional 1Password broker when Go is available. It does not install
system packages or modify your Hyprland configuration.

Go is optional and is used only to compile the 1Password SDK broker. Ordinary
expansions, local-keyring entries, Bitwarden, LastPass, and Proton Pass do not
use Go. If Go is unavailable, setup skips the broker and completes normally.
You can install Go later and rerun `install` to add 1Password support.

On Omarchy, install Go and build the optional broker with:

```bash
omarchy pkg add go
go version
~/.config/omarchy/plugins/brandon.omaspansion/install
```

The final command reruns Omaspansion setup; existing entries and settings are
preserved.

### Choose a launcher binding

Omaspansion does not require `Alt+E`; you can use any Hyprland binding you
prefer. Check the current bindings first:

```bash
omarchy menu keybindings --print
```

Then add your choice to `~/.config/hypr/bindings.lua`. If that combination is
already assigned, call `hl.unbind(...)` before replacing it. For example, use
this only after confirming what currently owns `Alt+E`:

```lua
hl.unbind("ALT + E")
o.bind("ALT + E", "Omaspansion", "$HOME/.local/bin/omaspansion")
```

If your chosen combination is unbound, add only the `o.bind(...)` line with
that combination. Hyprland reloads the Lua configuration automatically; verify
the result with `hyprctl reload` followed by `hyprctl configerrors`.

### Chromium extension fields

Typed expansion depends on the application sending keystrokes through Fcitx.
For native-Wayland Chromium, make sure `~/.config/chromium-flags.conf` contains:

```text
--ozone-platform=wayland
--enable-wayland-ime
--wayland-text-input-version=3
```

Close every Chromium window and reopen it after changing flags. If a specific
extension deliberately disables its input-method context, Fcitx cannot observe
that field; run Chromium through XWayland with `GTK_IM_MODULE=fcitx` as the
compatibility fallback for that browser session.

## Migrate from the private Command Palette

The two Fcitx addons must not remain enabled with the same prefix. Use this
cutover sequence:

1. Open the old Command Palette manager, turn off typed expansion, and save.
2. Install Omaspansion and run its setup as described above.
3. Import the old catalog, settings, and local-keyring records:

```bash
omaspansion import-legacy
```

4. Change the `Alt+E` binding to `$HOME/.local/bin/omaspansion`.
5. Disable the old overlay with
   `omarchy plugin disable brandon.command-palette`.
6. Restart Fcitx once with `fcitx5 -rd`.

The import command refuses to overwrite a non-empty Omaspansion catalog. It
does not delete or modify the legacy catalog, so the old plugin remains a
fallback until you deliberately remove it.

Required runtime/build tools are Bash, jq, wl-clipboard, wtype, ydotool,
Fcitx 5 development files, CMake, and a C++ compiler. `secret-tool` is required
for local secrets and Bitwarden session storage. Go is required only to build
the 1Password SDK broker.

## Expansion types

| Action | Saved value | Runtime requirement |
| --- | --- | --- |
| Paste | Ordinary text | `wl-copy`, `wtype` |
| Copy | Ordinary text | `wl-copy` |
| Open URL/file | URL or path | `xdg-open` |
| Local secret | Random opaque ID | `secret-tool` |
| 1Password | `op://vault/item/field` | 1Password desktop app, CLI config, Go-built broker |
| Bitwarden | Stable item UUID | `bw`, unlocked Omaspansion session |
| LastPass | Numeric unique item ID | `lpass`, active login/agent |
| Proton Pass | `pass://vault/item/field` | `pass-cli`, active login |

Use stable vault/item IDs where the provider supports them. Names can be
ambiguous and may reveal organizational information in the local catalog.

### 1Password

Install and sign in to the 1Password desktop app and CLI. The first expansion
starts a user-only broker and asks the desktop app to authorize Omaspansion.
The broker exits after a configurable idle period, measured from its most
recent request. The default is nine minutes and Settings accepts 1–120 minutes.
This is the only provider integration that requires Go, because setup compiles
its SDK broker locally.

### Bitwarden

Log in with the Bitwarden CLI, then unlock it specifically for Omaspansion:

```bash
bw login
omaspansion provider-login bitwarden
```

The resulting Bitwarden session key is stored in the desktop login keyring,
not in `entries.json`. Revoke it with:

```bash
omaspansion provider-logout bitwarden
```

### LastPass

Authenticate interactively before using an expansion:

```bash
lpass login you@example.com
```

Omaspansion requests one password by numeric item ID with `--sync=auto`. Never
use LastPass CLI's `--plaintext-key` option.

### Proton Pass

Authenticate interactively and save a complete field reference in the entry:

```bash
pass-cli login
```

Example reference: `pass://Personal/GitHub/password`. Stable share and item IDs
are preferable to names.

## Data and security model

- Catalog: `~/.config/omaspansion/entries.json`, mode `0600`.
- Settings: `~/.config/omaspansion/settings.json`, mode `0600`. This includes
  typed expansion controls and the 1Password broker idle timeout.
- The catalog stores ordinary expansion text and provider references. It never
  stores resolved password-manager values.
- Secure values are resolved only after activation and sent directly to
  `ydotool` over standard input. They are not placed on the clipboard.
- Provider subprocesses run as your desktop user. Omaspansion cannot provide a
  stronger isolation boundary than the provider CLI itself.
- Typed expansion observes keystrokes handled by Fcitx. Use the blocked-program
  list for applications where expansion must never run.
- Ordinary Paste temporarily uses the clipboard and restores it afterward.
  Copy intentionally leaves its value on the clipboard.

See [SECURITY.md](SECURITY.md) for provider-specific tradeoffs and reporting.

## Remove

Run the cleanup before removing the Git checkout:

```bash
~/.config/omarchy/plugins/brandon.omaspansion/uninstall
omarchy plugin remove brandon.omaspansion
fcitx5 -rd
```

Configuration is preserved by default. To remove the catalog, settings, and
local-keyring entries too, use `uninstall --purge-data`.

## Development

```bash
omarchy plugin validate .
bash -n bin/omaspansion install uninstall scripts/omaspansion-wrapper
./tests/test-helper.sh
./tests/test-providers.sh
cmake -S fcitx5 -B build/fcitx5 -DCMAKE_BUILD_TYPE=Release
cmake --build build/fcitx5 --parallel
ctest --test-dir build/fcitx5 --output-on-failure
(cd onepassword-broker && go test ./...)
```

Omaspansion is licensed under the MIT License.
