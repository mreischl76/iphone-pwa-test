"""Export the web build, then patch Godot's generated service worker.

Usage:  python export.py

Why the patch exists (found on an iPhone, iOS 18.7, Godot 4.6.3):

Godot's generated service worker serves cache-first, which is what makes the
game work offline. But it has two gaps that left the phone stuck on an old
build even after a newer one was deployed and its worker had taken over:

1. Cache misses are fetched with the browser's DEFAULT cache mode, so the
   ordinary HTTP cache can answer them. GitHub Pages lets browsers reuse
   files for 10 minutes, so a new worker could be handed the previous
   build's index.pck -- and then store that stale copy in its own cache,
   where cache-first serving keeps it forever. Patched to ask the server to
   revalidate ('no-cache': a cheap 304 when the file has not changed).

2. A new worker waits until every page it would take over has closed, and
   the only way to skip that is an 'update' message the default page never
   sends. Patched to call skipWaiting() on install, so a new version takes
   over by itself. It does NOT reload the running game -- the page already
   loaded keeps running; the new build is used from the next launch (or
   when the player taps the in-game "new build ready" button).

Each patch is an exact-text replacement that must match exactly once. If a
future Godot version changes its worker template, this script stops with an
error instead of silently shipping an unpatched worker.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GODOT = os.environ.get("GODOT", "C:/GodotEngine/Godot.exe.exe")
OUT_HTML = os.path.join(HERE, "docs", "index.html")
SW_PATH = os.path.join(HERE, "docs", "index.service.worker.js")

PATCHES = [
    (
        "install: take over immediately, and fill the cache from the server",
        "event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(CACHED_FILES)));",
        "self.skipWaiting(); // PATCHED by export.py: activate without waiting\n"
        "\tevent.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(\n"
        "\t\t// PATCHED by export.py: bypass the HTTP cache so a new version\n"
        "\t\t// never stores the previous version's files.\n"
        "\t\tCACHED_FILES.map((f) => new Request(f, { cache: 'reload' })))));",
    ),
    (
        "cache misses: revalidate with the server instead of trusting the HTTP cache",
        "response = await self.fetch(event.request);",
        "// PATCHED by export.py: non-navigation fetches (index.pck, index.wasm...)\n"
        "\t\t// revalidate with the server so a stale HTTP-cache copy is never stored.\n"
        "\t\tresponse = await self.fetch(event.request.mode === 'navigate'\n"
        "\t\t\t? event.request\n"
        "\t\t\t: new Request(event.request, { cache: 'no-cache' }));",
    ),
]


def main() -> int:
    print(f"Exporting with {GODOT} ...")
    result = subprocess.run(
        [GODOT, "--headless", "--path", HERE, "--export-release", "Web", OUT_HTML],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        print("EXPORT FAILED")
        return 1

    with open(SW_PATH, encoding="utf-8") as f:
        sw = f.read()
    for name, old, new in PATCHES:
        count = sw.count(old)
        if count != 1:
            print(f"PATCH FAILED ({name}): expected the target text once, found {count}.")
            print("Godot's service-worker template has probably changed -- update PATCHES.")
            return 1
        sw = sw.replace(old, new)
        print(f"patched: {name}")
    with open(SW_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write(sw)
    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
