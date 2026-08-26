# Changelog

## 0.1.0-beta.4

- Keep tracking a mistyped trigger until whitespace or another reset boundary,
  allowing Backspace corrections to return to a valid expansion key.
- Document the Chromium Wayland IME flags required for consistent Fcitx event
  delivery in extension and other embedded text fields.

## 0.1.0-beta.3

- Add a validated 1–120 minute 1Password broker idle timeout to Settings while
  preserving the existing nine-minute default.

## 0.1.0-beta.2

- Document the safe cutover from the private Command Palette so its legacy
  Fcitx addon cannot expand the same trigger alongside Omaspansion.

## 0.1.0-beta.1

- Initial GitHub beta.
- Searchable `Alt+E` overlay with an empty-by-default expansion catalog.
- Configurable typed prefix and per-application exclusions through Fcitx 5.
- `$|$` cursor markers and date substitutions for ordinary expansions.
- Local-keyring secure entries.
- 1Password, Bitwarden, LastPass, and Proton Pass provider adapters.
- Explicit legacy import and data-preserving uninstall paths.
