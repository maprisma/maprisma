import 'package:flutter/material.dart';

import 'app_look.dart' show StatusColors;

class AgentListView extends StatelessWidget {
  const AgentListView({
    super.key,
    required this.catalog,
    required this.search,
    required this.selected,
    required this.busy,
    required this.tr,
    required this.onSearch,
    required this.onSelected,
  });
  final List<Map<String, dynamic>> catalog;
  final String search;
  final String? selected;
  final bool busy;
  final String Function(String) tr;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onSelected;
  @override
  Widget build(BuildContext context) {
    final agents = catalog.where(
      (agent) => '${agent['name']} ${agent['command']}'.toLowerCase().contains(
        search.toLowerCase(),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextFormField(
            initialValue: search,
            decoration: InputDecoration(
              labelText: tr('Search'),
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
            ),
            onChanged: onSearch,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(tr('Agents')),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final agent in agents)
                ListTile(
                  selected: agent['command'] == selected,
                  leading: Icon(
                    Icons.smart_toy_outlined,
                    color: agent['installed'] == true ? StatusColors.ok : null,
                  ),
                  title: Text(agent['name'] as String),
                  subtitle: Text(
                    tr(
                      agent['installed'] == true
                          ? 'Installed'
                          : 'Not installed',
                    ),
                  ),
                  onTap: busy
                      ? null
                      : () => onSelected(agent['command'] as String),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
