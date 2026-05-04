import 'package:flutter/material.dart';

import '../brand.dart';

/// Small column with a value (large, mono) and a label (small, muted).
class ReadoutCard extends StatelessWidget {
  const ReadoutCard({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF13182F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Brand.muted.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: readoutValueStyle()),
          const SizedBox(height: 4),
          Text(label.toUpperCase(), style: readoutLabelStyle()),
        ],
      ),
    );
  }
}
