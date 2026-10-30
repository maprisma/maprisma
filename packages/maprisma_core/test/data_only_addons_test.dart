import 'package:maprisma_core/src/addons.dart';
import 'package:test/test.dart';

/// Maprisma takes add-ons as data only: an add-on that brings code is
/// refused (it once was Asterism's Insights, signed for the GTK era), a data
/// add-on is not.
void main() {
  Addon addon(String id, String kind, Map<String, List<int>> files) =>
      Addon('/addons/$id')
        ..kind = kind
        ..files = files;

  test('code is refused, data is not', () {
    expect(
      AddonRegistry.dataOnlyRefusal(
        addon('insights', 'feature', {'addon.json': [], 'addon.py': []}),
      ),
      contains('takes add-ons as data only'),
    );
    expect(
      AddonRegistry.dataOnlyRefusal(
        addon('agent-x', 'agent', {'addon.json': [], 'hooks.py': []})
          ..provides = ['no-such-hook'],
      ),
      contains('takes add-ons as data only'),
    );
    expect(
      AddonRegistry.dataOnlyRefusal(
        addon('agent-claude', 'agent', {'addon.json': [], 'agent.toml': []}),
      ),
      isNull,
    );
  });
}
