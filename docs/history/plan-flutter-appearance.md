# Flutter appearance and map-light frame rate (2026-10-28)

Uwe requested persisted Settings choices for map lights: **20 fps (default), 30,
60**, plus **System / Light / Dark** themes with small previews. No additional
performance measurement is requested. Keep all work uncommitted; no push, plugin
sync or real-desktop run.

- Add strict service settings with defaults and preserve existing settings.
- Wire the selected maximum frame rate to the light clock; retain idle,
  visibility and reduced-motion guards. Make the selected cadence reliable at
  display vsync boundaries and verify it with synthetic-clock tests.
- Add accessible theme preview choices and apply explicit brightness without
  retaining an incompatible desktop background. System continues to follow the
  existing desktop theme/appearance route.
- Translate new UI text into all eight languages, document both choices in all
  manuals, and rebuild their PDFs.
- Run focused tests, Flutter format/analyzer/full tests, Python checks, and an
  isolated Devel build. Do not rerun CPU/GPU benchmarks.
- Answer in `plan-flutter-appearance-responses.md` and state the next migration
  steps from `plan-flutter.md`; do not start the later Omarchy/packaging slices.
