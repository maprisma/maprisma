import 'package:maprisma/interrupted_jobs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('each interrupted job: where it stopped, Continue, Discard', (
    tester,
  ) async {
    final continued = <String>[], discarded = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InterruptedJobs(
            jobs: [
              {
                'id': 'a',
                'kind': 'model',
                'title': 'm.gguf · llama.cpp',
                'state': 'interrupted',
                'fraction': 0.426,
              },
              {
                'id': 'b',
                'kind': 'pull',
                'title': 'gemma · Ollama',
                'state': 'interrupted',
                'fraction': 0,
              },
            ],
            busy: false,
            tr: (k) => k,
            onContinue: (j) => continued.add('${j['id']}'),
            onDiscard: (j) => discarded.add('${j['id']}'),
          ),
        ),
      ),
    );
    expect(
      find.text('Interrupted at 43 % · Continue goes on where it stopped'),
      findsOneWidget,
    );
    await tester.tap(find.text('Continue').first);
    await tester.tap(find.text('Discard').last);
    expect(continued, ['a']);
    expect(discarded, ['b']);
  });
}
