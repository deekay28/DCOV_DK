import 'package:flutter/material.dart';
import '../services/app_state.dart';
import '../theme/dcov_theme.dart';

class AboutScreen extends StatelessWidget {
  final AppState app;
  const AboutScreen({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final counts = app.catalog.counts;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(child: Padding(padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('WHAT A RESULT MEANS', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
              letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
                color: DcovColors.bgForBanner('YELLOW', Theme.of(context).brightness),
                border: Border.all(color: DcovColors.forBanner('YELLOW', Theme.of(context).brightness)),
                borderRadius: BorderRadius.circular(3)),
            child: Text.rich(TextSpan(style: TextStyle(
                color: DcovColors.forBanner('YELLOW', Theme.of(context).brightness), fontSize: 13, height: 1.5),
              children: const [
                TextSpan(text: 'A green result means '),
                TextSpan(text: 'no Chinese-origin record matched this marking', style: TextStyle(fontWeight: FontWeight.w700)),
                TextSpan(text: '. It is not proof that the part is not Chinese.'),
              ])),
          ),
          const SizedBox(height: 14),
          _p(context, 'Three things can put a Chinese part behind a green banner. Markings '
              'can be counterfeited or re-marked, and the package will read as whatever the '
              're-marker chose. A part can be absent from the catalogue entirely, in which '
              'case you get grey, not green \u2014 but a near-miss marking can fuzzy-match the '
              'wrong record. And the catalogue is only as current as its last import.'),
          _p(context, 'Of the ${counts['total']} records in the current catalogue, '
              '${counts['unknown']} have no established country of origin at all. Those return '
              'yellow. Yellow is not a soft green; it means nobody has yet done the work to '
              'establish where that part was made.'),
          _p(context, 'Use this as screening support for a trained inspector: it finds the '
              'known-bad fast and it shows its reasoning. It does not clear a part, and it '
              'does not replace a teardown.'),
        ]),
      )),
      const SizedBox(height: 14),
      Card(child: Padding(padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('MATCHING CASCADE', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
              letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          _p(context, 'Every lookup runs the same six layers, cheapest first, and stops at the '
              'first hit: coded payload, normalised key, lot-code strip, single-glyph OCR repair, '
              'glyph-class folding, then fuzzy matching over a trigram-blocked candidate set. The '
              'result screen shows which layer fired and why the others did not.'),
          _p(context, 'Below 82% similarity nothing is auto-accepted; two candidates within 2 '
              'points of each other are reported as ambiguous rather than guessed. Where two '
              'records share a marking but disagree on origin, the app refuses the verdict and '
              'hands both to you.'),
          _p(context, 'This exact cascade runs three times over: in the backend, in the offline '
              'web demo, and in this app \u2014 kept in sync deliberately, so the verdict does not '
              'change depending on whether you have signal.'),
        ]),
      )),
      const SizedBox(height: 14),
      Card(child: Padding(padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('DATA PROVENANCE', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
              letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          _p(context, 'Catalogue source: ${app.catalog.source == "server" ? "live server sync" : app.catalog.source == "server_cache" ? "last server sync, cached on this device" : "bundled offline seed"}'
              '${app.catalog.loadedAt != null ? " \u00b7 loaded ${app.catalog.loadedAt}" : ""}. '
              '${counts['total']} records drawn from the OEM landscape, the component '
              'identification worksheet, the teardown observations and the standing watchlist, '
              'cross-referenced against the critical/non-critical acceptance matrix and the '
              'NDDA / Blue UAS approved list.'),
        ]),
      )),
    ]);
  }

  Widget _p(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 11),
      child: Text(text, style: TextStyle(fontSize: 13.5, height: 1.55, color: context.tokens.ink2)));
}
