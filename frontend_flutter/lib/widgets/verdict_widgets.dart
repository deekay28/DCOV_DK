import 'package:flutter/material.dart';
import '../services/matching.dart';
import '../theme/dcov_theme.dart';

const Map<String, String> kBannerSub = {
  'chinese': 'Do not fit. Record the finding against the inspection.',
  'non_chinese': 'No Chinese-origin record matched this marking. This is not a clearance.',
  'unknown_origin': 'The part is in the catalogue but its origin was never established.',
  'not_found': 'Nothing in the catalogue matches this marking.',
};

class VerdictBanner extends StatelessWidget {
  final Verdict verdict;
  const VerdictBanner({super.key, required this.verdict});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final fg = DcovColors.forBanner(verdict.banner, b);
    final bg = DcovColors.bgForBanner(verdict.banner, b);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: bg, border: Border.all(color: fg), borderRadius: BorderRadius.circular(3)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('VERDICT', style: TextStyle(color: fg.withValues(alpha: 0.85), fontFamily: 'RobotoMono',
            fontSize: 10, letterSpacing: 2, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(verdict.headline, style: TextStyle(color: fg, fontSize: 24, fontWeight: FontWeight.w800,
            letterSpacing: -0.3, height: 1.15)),
        const SizedBox(height: 8),
        Text(kBannerSub[verdict.result] ?? '', style: TextStyle(color: fg, fontSize: 13.5, height: 1.4)),
        if (verdict.escalate || verdict.action.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                border: Border.all(color: fg, style: BorderStyle.solid),
                borderRadius: BorderRadius.circular(2)),
            child: Text(
              verdict.escalate
                  ? 'Escalate. ${verdict.escalationNote}'
                  : verdict.action,
              style: TextStyle(color: fg, fontSize: 12.5, height: 1.45),
            ),
          ),
        ],
      ]),
    );
  }
}

class ReadoutPanel extends StatelessWidget {
  final String asRead;
  final String searched;
  final int elapsedMs;
  final String method;
  final double score;
  final List<TraceStep> trace;
  const ReadoutPanel({super.key, required this.asRead, required this.searched,
      required this.elapsedMs, required this.method, required this.score, required this.trace});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: t.panel2, border: Border.all(color: t.rule),
          borderRadius: BorderRadius.circular(3)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _silk(context, 'MARKING AS READ \u2192 AS SEARCHED'),
        const SizedBox(height: 8),
        _GlyphRow(text: searched),
        const SizedBox(height: 4),
        Text('$asRead \u2192 $searched  \u00b7  ${elapsedMs}ms  \u00b7  $method @ ${score.toStringAsFixed(0)}%',
            style: TextStyle(fontFamily: 'RobotoMono', fontSize: 11.5, color: t.silk)),
        const SizedBox(height: 12),
        Divider(color: t.rule, height: 1),
        const SizedBox(height: 10),
        _silk(context, 'MATCHING CASCADE'),
        const SizedBox(height: 6),
        ...trace.map((s) => _TraceRow(step: s)),
      ]),
    );
  }

  Widget _silk(BuildContext context, String text) => Text(text, style: TextStyle(
      fontFamily: 'RobotoMono', fontSize: 10, letterSpacing: 2,
      fontWeight: FontWeight.w600, color: context.tokens.silk));
}

class _GlyphRow extends StatelessWidget {
  final String text;
  const _GlyphRow({required this.text});
  @override
  Widget build(BuildContext context) {
    return Wrap(children: text.split('').map((ch) => Container(
      width: 17, margin: const EdgeInsets.only(right: 2),
      alignment: Alignment.center,
      child: Text(ch, style: TextStyle(fontFamily: 'RobotoMono', fontSize: 18,
          fontWeight: FontWeight.w600, color: context.tokens.ink)),
    )).toList());
  }
}

class _TraceRow extends StatelessWidget {
  final TraceStep step;
  const _TraceRow({required this.step});
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = step.hit ? DcovColors.forBanner('GREEN', Theme.of(context).brightness) : t.silk;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 14, child: Text(step.hit ? '\u25cf' : '\u25cb',
            style: TextStyle(color: color, fontFamily: 'RobotoMono', fontWeight: FontWeight.bold))),
        const SizedBox(width: 10),
        SizedBox(width: 128, child: Text(step.layer.toUpperCase(), style: TextStyle(
            fontFamily: 'RobotoMono', fontSize: 10.5, letterSpacing: 0.8,
            color: step.hit ? t.ink : t.ink2))),
        const SizedBox(width: 10),
        Expanded(child: Text(step.detail, style: TextStyle(fontSize: 12, color: t.ink2))),
      ]),
    );
  }
}

class SpecList extends StatelessWidget {
  final List<MapEntry<String, String>> specs;
  const SpecList({super.key, required this.specs});
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final visible = specs.where((e) => e.value.trim().isNotEmpty).toList();
    return Column(children: visible.map((e) => Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.rule))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 132, child: Text(e.key.toUpperCase(), style: TextStyle(
            fontFamily: 'RobotoMono', fontSize: 10, letterSpacing: 1.4, color: t.silk))),
        Expanded(child: Text(e.value, style: const TextStyle(fontSize: 13.5))),
      ]),
    )).toList());
  }
}

class Tag extends StatelessWidget {
  final String text;
  final bool critical;
  const Tag(this.text, {super.key, this.critical = false});
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = critical ? DcovColors.forBanner('RED', Theme.of(context).brightness) : t.ink2;
    return Container(
      margin: const EdgeInsets.only(right: 5, bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(border: Border.all(color: critical ? color : t.rule),
          borderRadius: BorderRadius.circular(2)),
      child: Text(text, style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
          letterSpacing: 1, color: color)),
    );
  }
}
