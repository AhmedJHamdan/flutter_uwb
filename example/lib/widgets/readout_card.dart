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
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF13182F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Brand.muted.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label.toUpperCase(), style: readoutLabelStyle()),
          const SizedBox(height: 2),
          Text(
            value,
            style: readoutValueStyle().copyWith(fontSize: 16, height: 1.1),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
