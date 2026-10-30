import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG 2.2 AA, 2.5.8: targets of at least 24 × 24 (a desktop app; the 44
/// and 48 of the mobile guidelines are for touch).
const desktopTapTargets = MinimumTapTargetGuideline(
  size: Size(24, 24),
  link: 'https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum',
);
