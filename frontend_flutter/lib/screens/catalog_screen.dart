import 'package:flutter/material.dart';
import '../services/app_state.dart';
import '../services/matching.dart';
import '../theme/dcov_theme.dart';

class CatalogScreen extends StatefulWidget {
  final AppState app;
  final void Function(String marking) onOpen;
  const CatalogScreen({super.key, required this.app, required this.onOpen});
  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final _q = TextEditingController();
  String _origin = '', _subsystem = '', _criticality = '';
  // _country has matching filter logic below but no UI control wired to
  // set it yet (unlike origin/subsystem/criticality, which have working
  // dropdowns) - flagged by `flutter analyze` as "could be final" because
  // nothing ever reassigns it, which is the honest reason: it's an
  // unfinished filter, not a deliberately constant one. Left final and
  // noted here rather than silently building out a country dropdown as a
  // drive-by addition.
  final String _country = '';

  List<ComponentRow> _filtered() {
    final index = widget.app.catalog.index;
    final q = _q.text.trim().toLowerCase();
    final qk = normalizeMarking(_q.text);
    return index.rows.where((c) {
      if (_origin.isNotEmpty && c['is_chinese'] != _origin) return false;
      if (_subsystem.isNotEmpty && c['drone_subsystem'] != _subsystem) return false;
      if (_criticality.isNotEmpty && c['criticality'] != _criticality) return false;
      if (_country.isNotEmpty && c['country_of_origin'] != _country) return false;
      if (q.isEmpty) return true;
      final key = (c['search_key'] as String?) ?? '';
      if (qk.isNotEmpty && key.startsWith(qk)) return true;
      return [c['component_name'], c['manufacturer'], c['chip_number'], c['part_number'],
              c['remarks'], c['drone_subsystem'], c['supplier']]
          .any((f) => (f?.toString() ?? '').toLowerCase().contains(q));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final rows = _filtered();
    final catalog = widget.app.catalog;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Card(child: Padding(padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('CATALOGUE SEARCH', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
                letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            TextField(controller: _q, onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: 'Part number, manufacturer, subsystem\u2026',
                    prefixIcon: Icon(Icons.search, size: 20))),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _filterChip('Origin', _origin, {'': 'All', 'YES': 'Chinese', 'NO': 'Non-Chinese', 'UNKNOWN': 'Unknown'},
                  (v) => setState(() => _origin = v)),
              _filterChip('Subsystem', _subsystem,
                  {'': 'All', for (final v in catalog.distinctValues('drone_subsystem')) v: v},
                  (v) => setState(() => _subsystem = v)),
              _filterChip('Criticality', _criticality,
                  {'': 'All', for (final v in catalog.distinctValues('criticality')) v: v},
                  (v) => setState(() => _criticality = v)),
            ]),
            const SizedBox(height: 10),
            Text('${rows.length} of ${catalog.count} records',
                style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10.5, letterSpacing: 1.4, color: t.silk)),
          ]),
        )),
      ),
      Expanded(child: rows.isEmpty
          ? Center(child: Text('No records match', style: TextStyle(color: t.ink2)))
          : ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: rows.length > 300 ? 300 : rows.length,
              separatorBuilder: (_, __) => Divider(color: t.rule, height: 1),
              itemBuilder: (_, i) => _ComponentTile(row: rows[i], onTap: widget.onOpen),
            )),
    ]);
  }

  Widget _filterChip(String label, String value, Map<String, String> options,
      void Function(String) onSelect) {
    return PopupMenuButton<String>(
      onSelected: onSelect,
      itemBuilder: (_) => options.entries
          .map((e) => PopupMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      child: Chip(label: Text('$label: ${options[value] ?? 'All'}',
          style: const TextStyle(fontSize: 12))),
    );
  }
}

class _ComponentTile extends StatelessWidget {
  final ComponentRow row;
  final void Function(String marking) onTap;
  const _ComponentTile({required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final isChinese = row['is_chinese']?.toString() ?? 'UNKNOWN';
    final color = DcovColors.forBanner(
        isChinese == 'YES' ? 'RED' : isChinese == 'NO' ? 'GREEN' : 'YELLOW',
        Theme.of(context).brightness);
    final marking = (row['chip_number']?.toString().isNotEmpty ?? false)
        ? row['chip_number'].toString() : row['part_number']?.toString() ?? '';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(width: 10, height: 10, margin: const EdgeInsets.only(top: 6),
          decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      title: Text(row['component_name']?.toString() ?? '', style: const TextStyle(fontSize: 14)),
      subtitle: Text('$marking \u00b7 ${row['manufacturer'] ?? ''} \u00b7 ${row['country_of_origin'] ?? '\u2014'}',
          style: TextStyle(fontFamily: 'RobotoMono', fontSize: 11.5, color: t.ink2)),
      trailing: row['criticality'] == 'CRITICAL'
          ? Text('CRITICAL', style: TextStyle(fontSize: 10, color: DcovColors.forBanner('RED', Theme.of(context).brightness)))
          : null,
      onTap: () => onTap(marking),
    );
  }
}
