# Security

Omaspansion handles values intended to be typed into the currently focused
application. Treat the plugin, its provider CLIs, Fcitx, Hyprland, and ydotool
as part of the same trusted desktop-user boundary.

## Design guarantees

- A fresh install contains an empty expansion catalog.
- Password-manager values are not written to Omaspansion configuration.
- Secure expansion does not use the clipboard or put a secret in a command-line
  argument.
- Provider references are validated before execution.
- No user-provided value is evaluated as shell code.
- Provider failures stop the expansion rather than falling back to clipboard.

## Provider boundaries

- 1Password uses its desktop-app SDK authorization and a mode-`0600` local Unix
  socket. Authorization behavior is controlled by 1Password. The broker idle
  timeout defaults to nine minutes and is constrained to 1–120 minutes.
- Bitwarden requires a decryption session key. Omaspansion stores that key in
  the desktop login keyring and passes it only in the `bw` child environment.
- LastPass relies on the `lpass` cache and agent. While unlocked, other
  processes running as the same user may also invoke `lpass`.
- Proton Pass relies on the authenticated `pass-cli` session and its own local
  storage and locking behavior.
- Local secrets rely on the desktop login keyring. They are available whenever
  that keyring permits access.

## Limitations

Synthetic typing is visible to the receiving application and to software with
equivalent desktop-user privileges. Omaspansion cannot protect a secret from a
compromised desktop session, malicious input method, keylogger, target
application, provider CLI, or unsandboxed Omarchy plugin.

Provider references may reveal vault, item, or field names. Prefer opaque IDs.

## Reporting

Do not open a public issue containing credentials, provider references, vault
names, catalog files, logs with secrets, or reproduction data from a real
account. Open a minimal issue with synthetic data and request a private contact
channel if sensitive details are required.
