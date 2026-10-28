# Asterism core — phase 1

Pure Dart, no Flutter import. `CoreService` owns settings, identity, desktop
selection/theme reading and service translation lookup. The UI uses
`IsolateTransport`; `bin/asterism-core.dart` exposes the same bounded JSON-lines
protocol for differential tests. It has no worker or provider-watch subcommands
yet.

Ported routes: `settings.get`, `settings.update`, `app.theme`, `app.identity`,
`desktop.snapshot`, `i18n.lookup`. Unported routes are refused in Dart. The
Flutter router may send them to `PythonTransport` only with the compile-time
`ASTERISM_DEVEL=true` flag; the Linux build also requires the Devel application
identity. Production builds remain blocked until the core is complete.

`Posix` is Linux-only and uses libc `openat`, `statx` on an open descriptor,
nonblocking regular-file reads, exclusive creation, `fchmod`, `fsync`,
`renameat`/`unlinkat`, plus pidfd identity/UID guards. It fails closed if these
primitives are unavailable; it never substitutes unsafe path-based writes or
bare-PID signals. PTY/session launching and provider processes remain phase 4.
The Omarchy current-theme directory intentionally supports its managed symlink;
private settings writes resolve trusted ancestor links once, then pin the
resolved chain without following further links. Both passes require user/root
ownership and refuse writable directories unless sticky.

From the repository root, with the Flutter SDK on PATH:

```sh
tools/flutter-dev check
```

This generates built-in service assets from the repository's reference defaults
and translations, runs core format/analyze/`dart test`, fixture differentials,
an AOT transport exclusion check, and Flutter checks. `tools/diff-core.py` can
also run selected fixture documents from `tests/core-fixtures/`. Each side has
its own temporary HOME; only that HOME prefix is normalized in responses and
file bytes. Refusals and file modes are compared too. The harness resolves a
native SDK Dart binary without executing PATH wrappers; `--dart` also refuses
shell scripts. Mount guards run before fixture traversal and cleanup, reporting
unexpected mounts without recursing into them. New routes must add normal
and hostile cases before joining `portedRoutes`.

No release is ready. All other service routes, full agent/project snapshots,
readers, previews, workers and process management still use the Devel reference.
See `docs/plan-flutter-dart-core.md` in the repository root; stop after phase 1
for review.
