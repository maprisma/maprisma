import 'package:maprisma_core/src/hyprland.dart';
import 'package:test/test.dart';

/// The popup's place: top right under the bar on the focused monitor, in
/// logical pixels (a 4K monitor at scale 2 as on Uwe's PC, the VM's 1280 ×
/// 800), its size kept inside the free area; the Lua it is placed with.
void main() {
  final clients = [
    {'pid': 7, 'address': '0xabc'},
    {'pid': 42, 'address': '0x55aa'},
  ];
  test('a 4K monitor at scale 2 with a 30 px bar', () {
    final g = popupGeometry(
      [
        {'focused': false, 'x': 0, 'y': 0, 'width': 1280, 'height': 800},
        {
          'focused': true,
          'x': 1280,
          'y': 0,
          'width': 3840,
          'height': 2160,
          'scale': 2,
          'reserved': [0, 30, 0, 0],
        },
      ],
      clients,
      42,
      1100,
      760,
    )!;
    expect(g.address, '0x55aa');
    expect(
      (g.x, g.y, g.width, g.height),
      (1280 + 1920 - 1100 - 10, 40, 1100, 760),
    );
  });

  test('too big for the monitor: kept inside its free area', () {
    final g = popupGeometry(
      [
        {
          'focused': true,
          'x': 0,
          'y': 0,
          'width': 1280,
          'height': 800,
          'scale': 1,
          'reserved': [0, 26, 0, 0],
        },
      ],
      clients,
      42,
      1600,
      1000,
    )!;
    expect((g.x, g.y, g.width, g.height), (10, 36, 1260, 754));
  });

  test('no own window or no monitor: nothing to place', () {
    final monitors = [
      {'x': 0, 'y': 0, 'width': 1280, 'height': 800},
    ];
    expect(popupGeometry(monitors, clients, 99, 900, 600), isNull);
    expect(popupGeometry(const [], clients, 42, 900, 600), isNull);
    expect(
      popupGeometry(
        monitors,
        [
          {'pid': 42, 'address': "0x1'); os.exit(1) --"},
        ],
        42,
        900,
        600,
      ),
      isNull,
    ); // only a plain address goes into the Lua
  });

  test('the Lua that places it', () {
    expect(
      popupDispatches((
        address: '0x55aa',
        x: 3090,
        y: 40,
        width: 1100,
        height: 760,
      )),
      [
        "hl.dsp.window.float({action='enable', window='address:0x55aa'})",
        "hl.dsp.window.resize({x=1100, y=760, window='address:0x55aa'})",
        "hl.dsp.window.move({x=3090, y=40, window='address:0x55aa'})",
      ],
    );
  });

  test("the windows' rounding from getoption", () {
    expect(
      parseRounding('{"option": "decoration:rounding", "int": 0, "set": true}'),
      0,
    );
    expect(parseRounding('{"int": 8}'), 8);
    expect(parseRounding('{"int": 99}'), 24);
    expect(parseRounding('{"int": true}'), isNull);
    expect(parseRounding('no json'), isNull);
  });
}
