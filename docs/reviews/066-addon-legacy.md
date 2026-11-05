# Review — add-ons left over from Asterism (task 066)

Against v0.14.1 (938cb0d). Cause: 24 Asterism-era add-ons in the user folder (old key) hid the bundled ones, so
every card said "Not available in this version".

## Round 1 (Codex, 2026-11-06, commit 4d54932: fallback to the app's copy)

Three Mediums: a removed user copy let the system copy switch back on at the start; a refused user copy could no
longer be removed in the app; Python/Dart chose differently for signed code add-ons.
> Author: simplified on Uwe's choice: the fallback was reverted (26c5b40); instead such add-ons are recognised by
> their old signature and their card says to remove them (bfdf50e).

## Round 2 (Codex, 2026-11-06, commit bfdf50e)

1. **Medium** routes.json: addons.list had no result shape; the item shape lacked legacy.
   > Author: fixed in 51fbcc2 (both routes describe their items, docs regenerated).
Lows (fixed too): reload/snapshot not proven by a test; the manual lacked the guidance.

## Round 3 (Codex, 2026-11-06, commit 51fbcc2)

No Medium or higher; legacy add-ons cannot load.

CLEAN
