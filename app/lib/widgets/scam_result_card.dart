import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Renders the rich scam-detector verdict: risk banner + score bar + each
/// matched pattern with its WHY and WHAT-TO-DO + overall advice.
/// Expects the `core.logic.scam.check_message` contract:
///   {score, verdict, level, label, emoji, patterns:[{key,name,level,why,do}],
///    advice, summary}
class ScamResultCard extends StatelessWidget {
  final Map<String, dynamic> result;
  const ScamResultCard({super.key, required this.result});

  Color _verdictColor(String? verdict) {
    switch (verdict) {
      case 'scam':
        return Colors.red;
      case 'suspicious':
        return Colors.orange;
      default:
        return Colors.green;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final verdict = result['verdict'] as String?;
    final color = _verdictColor(verdict);
    final score = (result['score'] ?? 0) as int;
    final patterns = (result['patterns'] as List?) ?? const [];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // banner
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.5)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(result['emoji'] ?? '', style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(result['label'] ?? '',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: (score / 100).clamp(0.0, 1.0),
                  minHeight: 8,
                  backgroundColor: color.withOpacity(0.15),
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(t.scamRiskScore(score),
                style: TextStyle(fontWeight: FontWeight.bold, color: color)),
          ]),
          if (result['summary'] != null) ...[
            const SizedBox(height: 8),
            Text(result['summary'], style: const TextStyle(fontSize: 12)),
          ],
        ]),
      ),
      const SizedBox(height: 14),

      if (patterns.isNotEmpty) ...[
        Text(t.scamMatchedSignals, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        for (final p in patterns)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.flag,
                      size: 16, color: _verdictColor(p['level'] == 'high'
                          ? 'scam'
                          : p['level'] == 'medium'
                              ? 'suspicious'
                              : 'safe')),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(p['name'] ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ]),
                if (p['why'] != null) ...[
                  const SizedBox(height: 6),
                  Text(p['why'], style: const TextStyle(fontSize: 13)),
                ],
                if (p['do'] != null) ...[
                  const SizedBox(height: 6),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.check_circle_outline, size: 15, color: Colors.green),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(p['do'],
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                    ),
                  ]),
                ],
              ]),
            ),
          ),
      ],

      if (result['advice'] != null) ...[
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(result['advice'],
              style: TextStyle(fontWeight: FontWeight.w600, color: color)),
        ),
      ],
    ]);
  }
}
