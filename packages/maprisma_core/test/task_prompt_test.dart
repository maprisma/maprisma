import 'dart:io';

import 'package:maprisma_core/src/system_help.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('the command line only points to a private task file', () {
    final tmp = Directory.systemTemp.createTempSync('maprisma-task-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final env = {'XDG_CACHE_HOME': tmp.path};
    const prompt = 'Fix this: secret path /home/x/.ssh, then rm -rf build';
    final path = taskPromptPath(prompt, env, '/home/x');
    // Same prompt, same file: preview and apply agree.
    expect(taskPromptPath(prompt, env, '/home/x'), path);
    expect(p.dirname(path), p.join(tmp.path, 'maprisma', 'tasks'));
    final line = taskInstruction(prompt, env, '/home/x');
    expect(line, contains(path));
    expect(line, isNot(contains('secret')));
    expect(line, isNot(contains('rm -rf')));
    // Without XDG_CACHE_HOME: ~/.cache, inside the home the session starts in.
    expect(
      taskPromptPath(prompt, const {}, '/home/x'),
      startsWith('/home/x/.cache/maprisma/tasks/'),
    );
    writeTaskPrompt(prompt, env, '/home/x');
    final file = File(path);
    expect(file.readAsStringSync(), prompt);
    expect(file.statSync().mode & 0x1ff, 0x180);
    expect(Directory(p.dirname(path)).statSync().mode & 0x1ff, 0x1c0);
    // Written again (a second start): still one private file.
    writeTaskPrompt(prompt, env, '/home/x');
    expect(Directory(p.dirname(path)).listSync(), hasLength(1));
  });
}
