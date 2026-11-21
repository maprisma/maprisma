// ignore_for_file: file_names
import 'dart:io';
import 'package:maprisma_core/src/feature_worker.dart';
import 'package:maprisma_core/src/features/project_supervisor.dart';
import 'package:maprisma_core/src/plan_worker.dart';

Future<void> main(List<String> args) async {
  if (args.firstOrNull == 'worker') {
    exitCode = await runWorker(args.sublist(1));
    return;
  }
  if (args.firstOrNull == 'supervise') {
    final code = await runProjectSupervisor();
    try {
      await stdout.flush();
    } on Object {
      // The controller is gone; the tree is already empty.
    }
    exit(code);
  }
  await serveFeaturePlugin(const String.fromEnvironment('MAPRISMA_FEATURE_ID'));
}
