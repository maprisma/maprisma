# Review: task 073 fresh-install (Maprisma side)

## Round 1 — Codex (2026-11-14), code review of 91610ef..83955a9

Found issues; **not CLEAN**. Most severe first:

1. **P1 — Test setup failure can delete the real `/home`.** [tests/release_install_test.sh:7](/mnt/Data/Projects/maprisma-claude/tests/release_install_test.sh:7)  
   `mktemp` failure leaves `T` empty, but execution continues because the script lacks `set -e` or an explicit guard. `H="$T/home"` becomes `/home`, and `fresh()` executes `rm -rf /home`. This happened during the attempted run with read-only `/tmp`; the sandbox blocked the removals. An unwritable or full `TMPDIR` on an otherwise writable system is a concrete destructive scenario.

2. **P1 — Journal records are not parseable, disabling rollback.** [packaging/install.sh:170](/mnt/Data/Projects/maprisma-claude/packaging/install.sh:170)  
   `note "new\t$new"` passes literal backslash-plus-`t`, and `printf '%s\n'` preserves it. Recovery splits on actual tabs, so it recognizes none of `new`, `old`, `bak`, `tmp`, or `outer`. A failure after moving the old folder leaves the installation missing; failure after activation leaves a partial upgrade. Successful upgrades also leave old folders and backups behind. I confirmed the delimiter mismatch with an in-memory Bash reproduction.

3. **P1 — Recovery itself is not restartable.** [packaging/install.sh:158](/mnt/Data/Projects/maprisma-claude/packaging/install.sh:158)  
   Even after fixing the delimiters, interrupt recovery after deleting the staged `$new`, but before removing the journal. On the next run, `$new` no longer exists, so recovery assumes it was activated and deletes `$lib`—which can still be the untouched old installation. Likewise, interruption after restoring `$old` but before journal removal causes the next recovery to delete that restored installation. Existence alone cannot distinguish these transaction states.

4. **P1 — Recovery accepts paths outside the installation.** [packaging/install.sh:146](/mnt/Data/Projects/maprisma-claude/packaging/install.sh:146)  
   Prefix globs accept paths such as `/opt/maprisma.old.x/../../somewhere`, and temporary paths need only match `*/.maprisma-new.*`. Recovery then uses these in `rm -rf`, `rm -f`, and `mv`. It also follows a journal symlink and does not validate journal ownership, modes, record completeness, or duplicates. A malformed journal can therefore direct recovery outside the fixed paths, including during `--system`. Recovery runs before receipt validation.

5. **P1 — The replacement bundle is unlocked during the transaction.** [packaging/install.sh:337](/mnt/Data/Projects/maprisma-claude/packaging/install.sh:337)  
   The exclusive descriptor acquired at line 125 refers to the **old** bundle’s lock inode. Renaming that folder preserves the lock correctly, but the newly activated bundle contains a different, unlocked inode. A GUI launched after activation acquires its shared lock and starts while outer files are still being replaced. Subsequent rollback can remove that running GUI’s bundle. Fresh installation has the same gap because no instance lock is acquired at all.

6. **P1 — System installation preserves the archive owner’s control of installed code.** [packaging/install.sh:290](/mnt/Data/Projects/maprisma-claude/packaging/install.sh:290)  
   `cp -a` preserves ownership when run as root. With the normal workflow—user extracts the archive, then runs `sudo ./install.sh --system`—executables, libraries, and `data/instance.lock` remain owned by that user. Only selected installer files and the top directory receive root ownership implicitly. That user can subsequently replace code executed by every other user and replace the lock file to bypass coordination.

7. **P1 — Root safety checks omit icon destination ancestors.** [packaging/install.sh:76](/mnt/Data/Projects/maprisma-claude/packaging/install.sh:76)  
   Validation stops at `$share/icons`; it never checks `hicolor/scalable/apps`. If, for example, `hicolor` is a symlink into a user-controlled directory, a system install follows it when creating and replacing the icon. The initial foreign-file check passes when the final icon is absent. Root therefore writes through a path explicitly forbidden by the agreed model.

8. **P2 — A failed command-link preparation can still commit successfully.** [packaging/install.sh:340](/mnt/Data/Projects/maprisma-claude/packaging/install.sh:340)  
   The `ln ... && mv ...` list suppresses `errexit` and `ERR` for failure of `ln`. If `$bin/.maprisma-new.$$` already exists as a directory, `ln` fails, `mv` is skipped, and installation continues through `done`. A fresh install reports success without installing the command link. This temporary path is also neither securely allocated nor journaled.

9. **P2 — Dependency checks miss loader incompatibilities and staged executability.** [packaging/install.sh:228](/mnt/Data/Projects/maprisma-claude/packaging/install.sh:228)  
   Only `version \`GLIBC` is recognized, so `GLIBCXX_*` and `CXXABI_*` version failures can pass when the final `ldd` invocation succeeds. The file list also omits versioned shared objects and other bundled ELFs. Conversely, a nonzero final `ldd` aborts at the assignment before diagnostics or `--ignore-missing` handling. The staged check repeats only the GLIBC grep and never runs the planned `maprisma-core --version`.

10. **P2 — Launch-record permissions and directory safety are not enforced.** [install_presence.dart:91](/mnt/Data/Projects/maprisma-claude/packages/maprisma_core/lib/src/install_presence.dart:91)  
    Existing directories are followed without checking ownership, symlinks, or permissions. A symlinked `maprisma` directory redirects the write elsewhere. Also, when an existing record already contains the desired text, the early return preserves an insecure mode such as `0666`; existing `0777` directories remain unchanged. Thus the promised `0700` directory / `0600` record properties are not maintained.

11. **P2 — The glibc release gate silently accepts failed ELF inspection.** [tools/check-bundle.py:72](/mnt/Data/Projects/maprisma-claude/tools/check-bundle.py:72)  
    `objdump`’s return code is ignored. An ELF that `objdump -T` cannot inspect contributes no requirement, allowing the baseline check to pass and potentially writing an understated `glibc` requirement. Inspection failure must fail the audit.

`bash -n` passed for both packaging scripts and the test script. The integration test could not run meaningfully because `/tmp` was read-only. No code changes were made.
### Answers (Claude, each checked in the code)

1. **Test can rm -rf /home** — confirmed (no guard after `mktemp`). Fixed: the test exits unless the
   temp folder exists and has the expected name; `fresh()` only removes `$T/home`.
2. **Journal tabs** — not confirmed: the journal lines contain real tab characters (`cat -A` shows
   `^I`), and the rollback tests at every step passed. No change.
3. **Recovery not restartable** — confirmed. Each staged folder now carries the run's id
   (`.install-id`, written first) and recovery decides by it, not by existence; every recovery step
   checks the state first. New tests stop recovery itself at three points and run again.
4. **Journal trusted too much** — confirmed. The journal must be a private regular file of the user
   (root for --system, no symlink); every path must match exactly `<lib>.new|old.XXXXXX`,
   `<parent>/.maprisma-backup.XXXXXX` or `<target dir>/.maprisma-new.XXXXXX`; unknown keys,
   duplicates, more than 32 lines → refused, nothing touched. Tests: a forged `..` path, a symlinked
   journal.
5. **New bundle unlocked** — confirmed. The new folder's instance lock is taken exclusively before
   activation (and kept through the rename).
6. **--system keeps the archive owner** — confirmed. Copy without ownership, `chmod -R go-w`,
   `chown -R 0:0` of the new folder and its receipt.
7. **Icon folders not checked** — confirmed. root_safe for every target folder, before and again after
   `mkdir -p`.
8. **Command link** — confirmed. The link is made at a journaled `mktemp -u` name with `ln -sT` (no -f)
   as its own statement, then renamed like the other outer files.
9. **Dependency checks** — confirmed. Every ELF in the bundle; any `version \`…' not found` (GLIBCXX,
   CXXABI …); ldd failures no longer abort; the staged copy is checked the same way and its core is
   started (`--installer-check`: exit 64 = loaded, 127 = loader failure). Also fixed: the package
   check's `dpkg | cut` pipeline hid `rpm`.
10. **Launch record modes** — confirmed. The folder must be a real folder of the user (no link) and is
    made 0700; a record with a loose mode is rewritten. Test added.
11. **objdump failures** — confirmed. An unreadable ELF fails the audit.

Also found while fixing: under `pipefail`, `tr </dev/urandom | head` ended the script (SIGPIPE); the
run id comes from `od -N3` now. Tests: 52 installer checks, 8 Dart tests.

## Round 2 — Codex (2026-11-14), review of cb9ecd9 and 27cd60c

**Not CLEAN — three findings remain.**

1. **P1 — Recovery restores a bundle without locking it.** [packaging/install.sh:188](/mnt/Data/Projects/maprisma-claude/packaging/install.sh:188)  
   After a crash at `moved-old`, `$lib` is absent, so the initial instance-lock check acquires nothing. Recovery restores `$old` to `$lib`, then installation proceeds without locking that restored bundle. A GUI launched after restoration can acquire its shared lock; the installer subsequently replaces and deletes its running bundle. After a crash at `activated`, the initially acquired lock similarly belongs to the discarded new bundle. Acquire the restored bundle’s lock before proceeding.

2. **P1 — Interrupted recursive deletion can destroy recovery’s transaction identity.** [packaging/install.sh:186](/mnt/Data/Projects/maprisma-claude/packaging/install.sh:186)  
   Recovery identifies the activated folder through its internal `.install-id`, then recursively deletes that same folder. If recovery is killed after `.install-id` is removed but before the directory disappears, the next run no longer recognizes `$lib` as this transaction’s folder. It leaves the partial bundle and cannot restore `$old`, because `$lib` still exists. The new tests interrupt between recovery steps; they do not cover interruption inside this deletion. Recovery needs identity/state that survives partial folder removal.

3. **P2 — Journal validation still accepts incomplete records and can operate on `/bin`.** [packaging/install.sh:174](/mnt/Data/Projects/maprisma-claude/packaging/install.sh:174)  
   Only `txn` is required after parsing. A journal containing:
   
   ```text
   txn	abcdef
   outer	bin
   ```
   
   passes validation with `bak=""`. Line 180 consequently evaluates `$bak/$name` as `/bin` and attempts to move it onto the command target. Under `--system`, this can move the system’s `/bin` symlink. I confirmed the attempted operation using the actual parser/recovery with mutations mocked. Validate required records and their relationships before recovery performs any mutations; duplicate `outer` and `done` records also remain accepted.

Round-1 verification: **1, 6–11 are fixed; 3–5 have the remaining issues above. Finding 2 was incorrect:** the original journal entries contain actual tabs.

`bash -n` passed. Path-escaping probes passed, and the function-local lock descriptor remains open after return. Integration and Dart tests were skipped because filesystem access is read-only. No files changed.
### Answers (Claude)

1. **Restored bundle unlocked** — confirmed. Before recovery the installer locks every candidate:
   `$lib`, `$lib.old.*`, `$lib.new.*`; the locks follow the folders through renames. Test 9f: a
   Maprisma running from the moved-away old folder blocks the next run, which recovers once it ends.
2. **Deletion destroys the id** — confirmed. Recovery first renames the activated folder back to its
   staged name (atomic) and only then deletes it; a cut-short deletion is finished next time without
   needing the id. Test 9e.
3. **Incomplete journal** — confirmed. The journal is written whole (txn, new, bak) to a temp file and
   renamed into place before the folders exist; recovery requires all three; duplicate `outer`/`done`
   refused. Test 9d. 57 installer checks.
