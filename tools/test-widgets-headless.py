#!/usr/bin/env python3
"""Run widget suites with the cached Flutter engine and no VM-service sockets.

Development fallback for environments where `flutter test` cannot create its
reporting socket. It runs the original test declarations through test_api's
Invoker, preserving setup, teardown, skips and assertions. Each file gets its
own engine process. This uses internal SDK/test APIs and must be rechecked when
those dependencies change. It does not change filesystem or network policies.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from dart_sdk import resolve_dart


HARNESS = r'''
import 'dart:io';
import 'package:flutter_test/flutter_test.dart' show AutomatedTestWidgetsFlutterBinding;
import 'package:test_api/src/backend/declarer.dart';
import 'package:test_api/src/backend/group.dart';
import 'package:test_api/src/backend/test.dart';
import 'package:test_api/src/backend/suite.dart';
import 'package:test_api/src/backend/suite_platform.dart';
import 'package:test_api/src/backend/runtime.dart';
import 'package:test_api/src/backend/operating_system.dart';
import 'package:test_api/src/backend/state.dart';
import 'package:test_api/src/backend/invoker.dart';
__IMPORTS__

Future<void> main() async {
  await Invoker.guard(() async {
    AutomatedTestWidgetsFlutterBinding();
    final declarer = Declarer();
    final selected = int.parse(Platform.environment['MAPRISMA_HEADLESS_SUITE']!);
    await declarer.declare(() async {
      switch (selected) {
        __CASES__
      }
    });
    var suite = Suite(declarer.build(), SuitePlatform(Runtime.vm, os: OperatingSystem.linux));
    final name = Platform.environment['MAPRISMA_HEADLESS_NAME'];
    if (name != null) suite = suite.filter((test) => test.name.contains(name));
    print('HEADLESS_SUITE tests=${suite.group.testCount}');
    if (suite.group.testCount == 0) {
      print('No tests matched the requested selection.');
      print('HEADLESS_RESULTS passed=0 failed=1 skipped=0');
      exit(1);
    }
    var passed = 0, failed = 0, skipped = 0;
    Future<bool> run(Test test, List<Group> groups) async {
      print('RUN ${test.name}');
      final live = test.load(suite, groups: groups);
      live.onError.listen((error) => print('ERROR ${test.name}: ${error.error}\n${error.stackTrace}'));
      live.onMessage.listen((message) => print(message.text));
      await live.run();
      await live.close();
      if (live.state.result == Result.success) {
        passed++;
        print('PASS ${test.name}');
        return true;
      }
      if (live.state.result == Result.skipped) {
        skipped++;
        print('SKIP ${test.name}');
        return true;
      }
      failed++;
      print('FAIL ${test.name}');
      return false;
    }
    Future<void> visit(Group group, List<Group> ancestors) async {
      final groups = [...ancestors, group];
      final ready = group.setUpAll == null || await run(group.setUpAll!, groups);
      if (ready) {
        for (final entry in group.entries) {
          if (entry.metadata.skip) {
            skipped++;
            print('SKIP ${entry.name}');
          } else if (entry is Group) {
            await visit(entry, groups);
          } else if (entry is Test) {
            await run(entry, groups);
          }
        }
      }
      if (group.tearDownAll != null) await run(group.tearDownAll!, groups);
    }
    await visit(suite.group, []);
    print('HEADLESS_RESULTS passed=$passed failed=$failed skipped=$skipped');
    exit(failed == 0 ? 0 : 1);
  });
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('files', nargs='*', type=Path)
    parser.add_argument('--all', action='store_true')
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--flutter-root', type=Path)
    parser.add_argument('--name', help='Run tests whose names contain this text')
    parser.add_argument('--timeout', type=int, default=300, help='seconds per test file (individual test timeouts still apply)')
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    if sys.platform != 'linux':
        parser.error('This fallback currently supports the Linux Flutter engine only')
    root = args.root.resolve()
    app = root / 'flutter_app'
    if bool(args.files) == args.all:
        parser.error('Pass test files or --all')
    files = sorted((app / 'test').glob('*_test.dart')) if args.all else [
        (root / p).resolve() for p in args.files
    ]
    if not files or any(not p.is_file() or not p.is_relative_to(app / 'test') for p in files):
        parser.error('Select existing test files inside flutter_app/test')
    # Library annotations and custom test executables need normal runner support;
    # refuse rather than silently ignore their configuration.
    if (app / 'test/flutter_test_config.dart').exists() or (app / 'flutter_test_config.dart').exists():
        parser.error('Custom flutter_test_config.dart requires the normal runner')
    for file in files:
        if re.search(r'@(?:TestOn|Tags|Skip|Timeout)\s*\(', file.read_text()):
            parser.error(f'Library-level test configuration requires the normal runner: {file}')
    dart = Path(resolve_dart())
    flutter = (args.flutter_root or Path(os.environ.get('FLUTTER_ROOT', dart.parents[4]))).resolve()
    engine = flutter / 'bin/cache/artifacts/engine'
    tester = engine / 'linux-x64/flutter_tester'
    frontend = engine / 'linux-x64/frontend_server_aot.dart.snapshot'
    packages = app / '.dart_tool/package_config.json'
    if not all(p.is_file() for p in (tester, frontend, packages)):
        parser.error('Cached Flutter Linux tools and flutter_app package configuration are required')
    output_root = root / '.flutter-previews/headless-widget-tests'
    output_root.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='run-', dir=output_root))
    source, kernel = output / 'runner.dart', output / 'runner.dill'
    imports = []
    for i, file in enumerate(files):
        literal = json.dumps(file.as_uri()).replace('$', r'\$')
        imports.append(f'import {literal} as t{i};')
    imports = '\n'.join(imports)
    cases = '\n'.join(f'case {i}: await Future<void>.sync(t{i}.main); break;' for i in range(len(files)))
    source.write_text(HARNESS.replace('__IMPORTS__', imports).replace('__CASES__', cases))
    with (output / 'compile.log').open('w') as log:
        built = subprocess.run([
            str(dart.with_name('dartaotruntime')), str(frontend),
            '--sdk-root', str(engine / 'common/flutter_patched_sdk'),
            '--target=flutter', '--enable-asserts', '--no-print-incremental-dependencies',
            '--packages', str(packages), '--output-dill', str(kernel), str(source),
        ], cwd=app, stdout=log, stderr=subprocess.STDOUT, timeout=120)
    if built.returncode:
        print((output / 'compile.log').read_text()[-6000:])
        raise SystemExit(built.returncode)
    results = []
    for i, file in enumerate(files):
        environment = {**os.environ, 'FLUTTER_TEST': 'true', 'MAPRISMA_HEADLESS_SUITE': str(i)}
        environment.pop('MAPRISMA_HEADLESS_NAME', None)
        if args.name is not None:
            environment['MAPRISMA_HEADLESS_NAME'] = args.name
        log_path = output / f'{file.stem}.log'
        timed_out = False
        with log_path.open('w') as log:
            try:
                result = subprocess.run([
                    str(tester), '--disable-vm-service', '--non-interactive',
                    '--enable-software-rendering', '--use-test-fonts',
                    f'--icu-data-file-path={engine / "linux-x64/icudtl.dat"}',
                    f'--flutter-assets-dir={app / "build/unit_test_assets"}', str(kernel),
                ], cwd=app, env=environment, stdout=log, stderr=subprocess.STDOUT,
                    timeout=args.timeout)
                code = result.returncode
            except subprocess.TimeoutExpired:
                code, timed_out = 124, True
        text = log_path.read_text(errors='replace')
        match = re.search(r'HEADLESS_RESULTS passed=(\d+) failed=(\d+) skipped=(\d+)', text)
        entry = {'file': str(file.relative_to(root)), 'exit': code, 'timed_out': timed_out,
                 'name_filter': args.name,
                 'passed': int(match[1]) if match else 0,
                 'failed': int(match[2]) if match else 1,
                 'skipped': int(match[3]) if match else 0, 'log': str(log_path)}
        results.append(entry)
        print(f'{"PASS" if code == 0 else "FAIL"} {entry["file"]}: '
              f'{entry["passed"]} passed, {entry["failed"]} failed', flush=True)
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(f'Results: {output / "results.json"}', flush=True)
    raise SystemExit(1 if any(r['exit'] != 0 for r in results) else 0)


if __name__ == '__main__':
    main()
