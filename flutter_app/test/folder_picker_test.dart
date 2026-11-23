import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/folder_picker.dart';

/// The folder dialog's sidebar (Uwe 2026-11-23: mounted folders like Data).
void main() {
  const mounts = '''
/dev/nvme0n1p2 / btrfs rw 0 0
/dev/nvme0n1p2 /home btrfs rw 0 0
/dev/nvme0n1p1 /boot vfat rw 0 0
/dev/nvme0n1p3 /mnt/Data ext4 rw 0 0
/dev/nvme1n1p3 /mnt/Games ext4 rw 0 0
/dev/mapper/omarchy /mnt/omarchy-root btrfs rw 0 0
/dev/sda1 /run/media/uwe/My\\040Stick vfat rw 0 0
tmpfs /mnt/ram tmpfs rw 0 0
proc /proc proc rw 0 0
''';
  const cosmic = '''[
    Home,
    Documents,
    Path("/mnt/Data"),
    Path("/mnt/Data/Ai"),
    Path("/gone"),
]''';
  const kde = '''
<bookmark href="file:///home/uwe"><title>Home</title></bookmark>
<bookmark href="file:///mnt/Data/Projects"><title>Projects</title></bookmark>
<bookmark href="file:///home/uwe/My%20Work/"><title>Work</title></bookmark>
<bookmark href="trash:/"><title>Trash</title></bookmark>
''';

  test('mounted data disks first, then pinned folders, once each', () {
    final shortcuts = folderShortcuts(
      mounts: mounts,
      home: '/home/uwe',
      cosmicFavorites: cosmic,
      kdePlaces: kde,
      isDir: (path) => path != '/gone',
      isSystemRoot: (path) => path == '/mnt/omarchy-root',
    );
    expect(shortcuts, [
      '/mnt/Data',
      '/mnt/Games',
      '/run/media/uwe/My Stick',
      '/mnt/Data/Ai',
      '/mnt/Data/Projects',
      '/home/uwe/My Work',
    ]);
  });

  test('nothing to add without mounts or pins', () {
    expect(
      folderShortcuts(mounts: '', home: '/home/uwe', isDir: (_) => true),
      isEmpty,
    );
  });
}
