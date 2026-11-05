# Review — Strata as a local LLM (task 064) and Show faded lines (task 065)

Reviewed together before release 0.14.1, against v0.14.0 (8cf3759).

## Round 1 (Codex, 2026-11-05, commit fa278c5)


1. **Medium — [strata.dart](/mnt/Data/Projects/maprisma/packages/maprisma_core/lib/src/strata.dart:164):** A Strata server process with an oversized numeric `--port` value makes `int.parse` throw during the Dart runtime scan, interrupting map data collection. Python catches the corresponding parse error. Use `int.tryParse` and fall back to the config or default port.

1. **Medium — [provider_strata.py](/mnt/Data/Projects/maprisma/provider_strata.py:130), [strata.dart](/mnt/Data/Projects/maprisma/packages/maprisma_core/lib/src/strata.dart:148):** Server detection accepts any executable path containing `/strata/terminal/`. An unrelated process under another directory with that substring and `serve.server` in its arguments can make the map report Strata as running. The ownership checks use the same substring. Verify the resolved executable is inside this user’s actual Strata data directory before claiming it.

1. **Medium — [provider_strata.py](/mnt/Data/Projects/maprisma/provider_strata.py:213):** The Python reference’s Configure actions execute `strata` by name. When `/usr/bin` precedes `~/.local/bin`, they launch the unrelated GTK file manager identified in the task document. Resolve the verified Strata binary for these actions, as start and stop already do.

1. **Medium — [llm_engine.py](/mnt/Data/Projects/maprisma/llm_engine.py:119):** Strata inherits `loaded_models`, which assumes a successful loopback JSON reply is an object with a list in `data`. A malformed reply such as `{"data":{}}` raises while building the animated map snapshot; the Dart reader handles non-list rows. Check both types before slicing or iterating.

1. **Medium — [manual.html](/mnt/Data/Projects/maprisma/docs/manual/manual.html:577):** The manual offers **Uninstall…** for Strata, but the task document confirms that the shipped Dart core has no local LLM uninstall route. Flutter users cannot perform the documented action. Add the route and UI action, or describe manual removal accurately.
tokens used
66,965
Review of `8cf3759..fa278c5` found five Medium issues. I read the stat, diff, and surrounding code statically; I used no network and ran no tests.

1. **Medium — [strata.dart](/mnt/Data/Projects/maprisma/packages/maprisma_core/lib/src/strata.dart:164):** A Strata server process with an oversized numeric `--port` value makes `int.parse` throw during the Dart runtime scan, interrupting map data collection. Python catches the corresponding parse error. Use `int.tryParse` and fall back to the config or default port.

1. **Medium — [provider_strata.py](/mnt/Data/Projects/maprisma/provider_strata.py:130), [strata.dart](/mnt/Data/Projects/maprisma/packages/maprisma_core/lib/src/strata.dart:148):** Server detection accepts any executable path containing `/strata/terminal/`. An unrelated process under another directory with that substring and `serve.server` in its arguments can make the map report Strata as running. The ownership checks use the same substring. Verify the resolved executable is inside this user’s actual Strata data directory before claiming it.

> Author (Strata branch, merged c639b76): all five fixed with failing-first tests in both cores —
> port text 1..65535 only (gpu_usage.port_number / portNumber, also older parsers); ownership and detection
> by real path inside this user's Strata folders; Configure… runs the verified binary; llm_engine.rows checks
> reply shapes for every engine; the manual says Maprisma does not uninstall Strata and how to remove it.

## Round 2 (Codex, 2026-11-05, commit c639b76)

1. **Medium** `provider_strata.py:95` model_ids()/last_preset() read a whole folder before taking their share.
   > Author: fixed: at most LIST_LIMIT (4000) entries in the folder's own order, as Dart's ScanFiles.list.
2. **Medium** `strata.dart:14` Dart `$` could match before a final newline.
   > Author: not a defect: Dart's `$` without multiLine matches only at the end of the input
   > (checked: `RegExp(r'^[a-z][a-z0-9_-]{0,47}$').hasMatch("office\n")` is false).
3. **Medium** `manual.html:546` "nothing of the download runs" while Strata's install.sh runs.
   > Author: fixed in all 8 languages: Strata is named as the exception.

## Round 3 (Codex, 2026-11-05, commit 374b216)

The round 2 folder cap and manual corrections are present; the Dart regex answer holds.

CLEAN
