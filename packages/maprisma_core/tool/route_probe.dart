// Dev tool (tools/protocol.py): which of the given method names the core
// serves. Each name is sent with one parameter no route takes, in an empty
// HOME with an empty PATH; the caller runs it without a network. A route the
// core does not know answers unported_route, every other outcome (a result or
// its own refusal) means it is served.
import 'dart:convert';
import 'dart:io';
import 'package:maprisma_core/maprisma_core.dart';

void main() {
  final names = (jsonDecode(stdin.readLineSync()!) as List).cast<String>();
  final home = Directory.systemTemp.createTempSync('route-probe');
  Directory('${home.path}/bin').createSync();
  final core = CoreService(
    environment: {
      'HOME': home.path,
      'PATH': '${home.path}/bin',
      'MAPRISMA_DESKTOP': 'generic',
      'MAPRISMA_SCAN_PROC': '${home.path}/proc',
      'LANG': 'C.UTF-8',
    },
  );
  final served = <String>[];
  for (final name in names) {
    try {
      core.dispatch(name, {'__contract_probe__': true});
      served.add(name);
    } on ServiceError catch (e) {
      if (e.code != 'unported_route') served.add(name);
    } catch (_) {
      served.add(name);
    }
  }
  home.deleteSync(recursive: true);
  stdout.writeln(jsonEncode(served));
  exit(0);
}
