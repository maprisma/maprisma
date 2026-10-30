import 'dart:io';
import 'package:maprisma_core/src/desktop.dart';
import 'package:test/test.dart';

/// COSMIC's terminal among the known ones (task 003), as desktop_generic has it.
void main() {
  test('cosmic-term is found and takes the program after --', () {
    final bin = Directory.systemTemp.createTempSync('terminals');
    addTearDown(() => bin.deleteSync(recursive: true));
    final program = File('${bin.path}/cosmic-term')
      ..writeAsStringSync('#!/bin/sh\n');
    Process.runSync('chmod', ['+x', program.path]);
    final desktop = GenericDesktop({'PATH': bin.path, 'HOME': bin.path});
    expect(desktop.terminal(), [program.path, '--']);
  });
}
