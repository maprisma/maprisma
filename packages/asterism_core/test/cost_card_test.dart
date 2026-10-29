import 'package:asterism_core/src/costs.dart';
import 'package:test/test.dart';

void main() {
  final spent = <String, dynamic>{
    'today': 1.5,
    'week': 12.25,
    'month': 40.0,
    'by_model': {
      'claude-opus-5-5': [
        'anthropic',
        [1000000, 200000, 5000000, 0],
        [4.0, 4.0, 1.0, 0.0],
      ],
      'gpt-5.5': [
        'openai',
        [10, 0, 0, 0],
        [0.00005, 0.0, 0.0, 0.0],
      ],
    },
    'unpriced': {'qwen3:8b': 120000},
    'reported': 0.0,
  };

  test('paid per token: API cost against the day\'s limit', () {
    final card = costCard(
      spent: spent,
      name: 'Claude Code',
      installed: true,
      hasSessions: true,
      paying: true,
      plan: '',
      currency: 'eur',
      limit: 10,
      usdPerEur: 1.25,
      tr: (t) => t,
    )!;
    expect(card['title'], 'API cost');
    expect(card['summary'], '1.20 € today · 9.80 € in 7 days');
    expect(card['tiles'][0], ['Today', '1.20 €', "12 % of the day's limit"]);
    final models = card['models'] as List;
    expect(models.first['heading'], 'claude-opus-5-5, last 30 days');
    expect(models.first['rows'], [
      ['Input', '1M tokens · 3.20 €'],
      ['Output', '200k tokens · 3.20 €'],
      ['Cache read', '5M tokens · 0.80 €'],
      ['In all', '7.20 €'],
    ]);
    expect(models.last['rows'].last, ['In all', '<0.01 €']);
    expect(
      (card['notes'] as List).first,
      'No API cost: qwen3:8b (120k) (tokens of models without a price, such as local LLMs).',
    );
    expect((card['notes'] as List).last, contains('as of 2026-10-23'));
  });

  test(
    'on a plan: API value, covered by it; unknown without readable sessions',
    () {
      final card = costCard(
        spent: spent,
        name: 'Claude Code',
        installed: true,
        hasSessions: true,
        paying: false,
        plan: 'Max',
        currency: 'usd',
        limit: 100,
        usdPerEur: null,
        tr: (t) => t,
      )!;
      expect(card['title'], 'API value');
      expect(
        card['tiles'][0][2],
        'covered by your {0} plan'.replaceAll('{0}', 'Max'),
      );
      expect(
        (card['notes'] as List).last,
        endsWith('Not what a plan costs: the plan covers it.'),
      );
      final unknown = costCard(
        spent: null,
        name: 'Goose',
        installed: true,
        hasSessions: false,
        paying: false,
        plan: '',
        currency: 'usd',
        limit: 100,
        usdPerEur: null,
        tr: (t) => t,
      )!;
      expect(unknown['summary'], 'not known');
      expect(
        costCard(
          spent: null,
          name: 'Goose',
          installed: true,
          hasSessions: true,
          paying: false,
          plan: '',
          currency: 'usd',
          limit: 100,
          usdPerEur: null,
          tr: (t) => t,
        ),
        isNull,
      );
    },
  );
}
