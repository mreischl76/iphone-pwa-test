# iPhone offline PWA test

A Godot 4.6.3 diagnostic project that proved, on 2026-11-27, that a Godot web
build can be installed to an iPhone's Home Screen and played **offline**, with
saves persisting and **in-place updates** working, with no App Store and no Mac.
Tested on iOS 18.7.

Live at <https://mreischl76.github.io/iphone-pwa-test/>, served by GitHub Pages
from `docs/` on `main`.

## Reusing this for a real phone game

1. **Copy `export.py`** and the web preset in `export_presets.cfg` (single-threaded,
   PWA enabled). Use the Compatibility renderer.
2. **Always export with `python export.py`, never from the editor's Export menu.**
   The script patches Godot's generated service worker after every export.
   Without the patch, an installed copy can stay stuck on an old build. The
   script's docstring explains both patches.
3. **Copy the update code from `main.gd`**: `DIAG_JS`'s `register` /
   `updatefound` / `__pwaApplyUpdate` parts and the "New build ready" button.
   Put the button somewhere that can't interrupt play, such as a title screen
   or pause menu.
4. **Show a build number on screen and bump it every export.** It is the only
   reliable way to tell which build the phone is running.
5. Push to a **public** repo (free-plan GitHub Pages requires one) with Pages
   serving `main` / `docs`. Keep `docs/.gdignore` and `docs/.nojekyll`.

**On the phone:** open the URL in Safari, then Share, then Add to Home Screen.
Launch from the icon, fully close it, and launch it again while online. That
second launch is the one that caches the engine. From then on it works in
airplane mode. Updates arrive by tapping the "New build ready" button, or by
relaunching.

The full set of pitfalls is in `~/claude-dotfiles/godot-engine-notes.md`,
section "Web export / offline PWA".
