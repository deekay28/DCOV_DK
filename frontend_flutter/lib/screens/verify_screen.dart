import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:vibration/vibration.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../services/marking.dart';
import '../services/matching.dart';
import '../services/ocr_ranking.dart';
import '../services/ocr_service.dart';
import '../theme/dcov_theme.dart';
import '../widgets/verdict_widgets.dart';

class VerifyScreen extends StatefulWidget {
  final AppState app;
  const VerifyScreen({super.key, required this.app});
  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen> {
  final _controller = TextEditingController();
  /// Other lines printed on the package (country / lot / site codes). Feeds
  /// the anti-remark marking check; optional for typed entries.
  final _extraLines = TextEditingController();
  final _focus = FocusNode();
  VerifyOutcome? _outcome;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    _extraLines.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _verifyTyped() {
    final extra = _extraLines.text.trim();
    _runVerify(_controller.text,
        ocrText: extra.isEmpty ? '' : '${_controller.text.trim()}\n$extra');
  }

  Future<void> _runVerify(String raw, {String mode = 'manual', String ocrText = '',
      String imageRef = '', String symbology = ''}) async {
    if (raw.trim().isEmpty) return;
    setState(() => _busy = true);
    VerifyOutcome outcome;
    try {
      outcome = await widget.app.verify(raw, mode: mode, ocrText: ocrText,
          imageRef: imageRef, symbology: symbology);
    } catch (e) {
      // verify() handles network failure itself; anything reaching here is a
      // genuine fault - report it instead of leaving the spinner running.
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Verification failed: $e')));
      }
      return;
    }
    if (outcome.verdict.vibrate) {
      // vibration has no Windows/Linux/web implementation - never let a
      // missing platform channel break the verify flow itself.
      try {
        if (await Vibration.hasVibrator()) {
          Vibration.vibrate(pattern: [0, 90, 60, 90, 60, 180]);
        }
      } catch (_) {/* not supported on this platform - the banner still shows */}
    }
    if (!mounted) return;
    setState(() {
      _outcome = outcome;
      _busy = false;
    });
  }

  static bool get _cameraScanSupported =>
      kIsWeb || defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  Future<void> _scanCode() async {
    if (!_cameraScanSupported) {
      // mobile_scanner has no Windows/Linux camera implementation. A USB or
      // Bluetooth barcode scanner works anywhere: it types into the field.
      _focus.requestFocus();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          duration: Duration(seconds: 6),
          content: Text('Camera barcode scanning is not available on this platform. '
              'Use a USB/Bluetooth barcode scanner (it types into the marking field), '
              'or type the code.')));
      return;
    }
    final result = await Navigator.of(context).push<(String, String)>(
      MaterialPageRoute(builder: (_) => const _CodeScannerPage()),
    );
    if (result != null) {
      _controller.text = result.$1.replaceAll(RegExp(r'[\x00-\x1f]'), ' ').trim();
      _extraLines.clear();
      _runVerify(result.$1, mode: result.$2 == 'qrCode' ? 'qr' : 'barcode',
          symbology: result.$2);
    }
  }

  Future<void> _photographChip() async {
    final picker = ImagePicker();
    XFile? file;
    final cameraAvailable = kIsWeb || defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    try {
      file = cameraAvailable
          ? await picker.pickImage(source: ImageSource.camera, maxWidth: 2400,
              imageQuality: 92, preferredCameraDevice: CameraDevice.rear)
          : await picker.pickImage(source: ImageSource.gallery, maxWidth: 2400, imageQuality: 92);
    } on PlatformException catch (e) {
      if (!mounted) return;
      final denied = e.code.contains('access_denied') || e.code.contains('permission');
      final choice = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
        title: Text(denied ? 'Camera permission needed' : 'Camera unavailable'),
        content: Text(denied
            ? 'DCOV needs the camera to photograph chip markings. Allow it in your '
              'phone\'s Settings > Apps > DCOV > Permissions > Camera, then try again. '
              'You can also pick an existing photo or type the marking.'
            : 'The camera could not be opened (${e.message ?? e.code}). You can pick an '
              'existing photo instead, or type the marking.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCEL')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'gallery'),
              child: const Text('PICK A PHOTO')),
        ],
      ));
      if (choice != 'gallery') return;
      try {
        file = await picker.pickImage(source: ImageSource.gallery, maxWidth: 2400, imageQuality: 92);
      } catch (_) {
        return;
      }
    } catch (_) {
      // Desktop builds without a camera delegate: choose an image file.
      try {
        file = await picker.pickImage(source: ImageSource.gallery, maxWidth: 2400, imageQuality: 92);
      } catch (_) {
        return;
      }
    }
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    _showOcrSheet(bytes, file.path);
  }

  void _showOcrSheet(Uint8List bytes, String path) {
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      builder: (_) => _OcrUploadSheet(
        app: widget.app, bytes: bytes, path: path,
        onResolved: (raw, fullText, imageRef) {
          Navigator.pop(context);
          _controller.text = raw;
          // Show what OCR read so the inspector can see/correct the other lines.
          _extraLines.text = fullText;
          _runVerify(raw, mode: 'ocr', ocrText: fullText, imageRef: imageRef);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final samples = _sampleChips(widget.app.catalog.index);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _EntryCard(
          controller: _controller, extraLines: _extraLines, focus: _focus, busy: _busy,
          onVerify: _verifyTyped,
          onScan: _scanCode, onPhoto: _photographChip,
          catalogCount: widget.app.catalog.count,
        ),
        // Wrapped in its own AnimatedBuilder rather than the whole screen -
        // activeInspectionId can change from the Inspections screen while
        // this one stays mounted underneath the bottom nav's IndexedStack,
        // and this is the one piece of UI here that depends on AppState
        // rather than this widget's own local _busy/_outcome state.
        AnimatedBuilder(
          animation: widget.app,
          builder: (context, _) => widget.app.activeInspectionId == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      border: Border.all(color: DcovColors.forBanner(
                          'GREEN', Theme.of(context).brightness)),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Row(children: [
                      Icon(Icons.radio_button_checked, size: 13,
                          color: DcovColors.forBanner('GREEN', Theme.of(context).brightness)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(
                          'Scans tagged to ${widget.app.activeInspectionNumber}',
                          style: const TextStyle(fontSize: 12))),
                      TextButton(
                          // Same fix as the VERIFY/CLEAR button crashes -
                          // this Row sits under a Column
                          // (crossAxisAlignment: start) that can hand it
                          // unbounded constraints; an explicit style with
                          // minimumSize is the proven fix in this codebase,
                          // applied here pre-emptively rather than waiting
                          // for this specific button to crash on tap.
                          style: TextButton.styleFrom(minimumSize: const Size(50, 32)),
                          onPressed: widget.app.clearActiveInspection,
                          child: const Text('STOP', style: TextStyle(fontSize: 11))),
                    ]),
                  ),
                ),
        ),
        const SizedBox(height: 14),
        Card(child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('TRY A MARKING FROM THE CATALOGUE', style: TextStyle(fontFamily: 'RobotoMono',
                fontSize: 10, letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: samples.map((s) => OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 12)),
              onPressed: () { _controller.text = s.$1; _extraLines.clear(); _runVerify(s.$1); },
              child: Text.rich(TextSpan(children: [
                TextSpan(text: s.$1, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 12)),
                TextSpan(text: '  \u00b7 ${s.$2}', style: TextStyle(color: t.silk, fontSize: 12)),
              ])),
            )).toList()),
          ]),
        )),
        if (_outcome != null) ...[
          const SizedBox(height: 14),
          _StatusStrip(outcome: _outcome!),
          const SizedBox(height: 8),
          VerdictBanner(verdict: _outcome!.verdict),
          const SizedBox(height: 14),
          _EvidenceCard(outcome: _outcome!),
          if (_outcome!.marking.findings.isNotEmpty) ...[
            const SizedBox(height: 14),
            _MarkingFindingsCard(analysis: _outcome!.marking),
          ],
          const SizedBox(height: 14),
          ReadoutPanel(
            asRead: normalizeMarking(_outcome!.entry.raw), searched: _outcome!.match.normalizedInput,
            elapsedMs: _outcome!.elapsedMs, method: _outcome!.match.method,
            score: _outcome!.match.score, trace: _outcome!.match.trace,
          ),
          const SizedBox(height: 14),
          _ComponentCard(match: _outcome!.match),
        ],
      ]),
    );
  }

  List<(String, String)> _sampleChips(ComponentIndex index) {
    ComponentRow? pick(String v) => index.rows.cast<ComponentRow?>().firstWhere(
        (r) => r?['is_chinese'] == v && ((r?['chip_number'] as String?)?.length ?? 0) > 5,
        orElse: () => null);
    final out = <(String, String)>[];
    final cn = pick('YES');
    final nc = pick('NO');
    final unk = pick('UNKNOWN');
    if (cn != null) {
      out.add((cn['chip_number'] as String, 'Chinese'));
    }
    if (nc != null) {
      out.add(((nc['chip_number'] as String?)?.isNotEmpty == true
          ? nc['chip_number'] as String : nc['part_number'] as String, 'Non-Chinese'));
    }
    if (unk != null) {
      out.add((unk['chip_number'] as String, 'Unknown'));
    }
    out.add(('stm32 f3o2-c8t6', 'OCR misread'));
    out.add(('STM32G4A1KCU6 GQ23J 1B9U', 'With lot code'));
    out.add(('SN74LVC1G08', 'Not in catalogue'));
    return out;
  }
}

class _EntryCard extends StatelessWidget {
  final TextEditingController controller;
  final TextEditingController extraLines;
  final FocusNode focus;
  final bool busy;
  final VoidCallback onVerify, onScan, onPhoto;
  final int catalogCount;
  const _EntryCard({required this.controller, required this.extraLines, required this.focus,
      required this.busy,
      required this.onVerify, required this.onScan, required this.onPhoto, required this.catalogCount});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Card(child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('MARKING ENTRY', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
            letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text('Type the marking exactly as etched, or scan a coded label. '
             'Case, spaces and dashes are ignored.',
            style: TextStyle(fontSize: 12.5, color: t.ink2)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(
            controller: controller, focusNode: focus,
            textCapitalization: TextCapitalization.characters,
            style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 16, letterSpacing: 1),
            decoration: const InputDecoration(hintText: 'STM32F302C8T6'),
            onSubmitted: (_) => onVerify(),
          )),
          const SizedBox(width: 8),
          ElevatedButton(
              // Was `SizedBox(height: 52, child: ElevatedButton(...))` -
              // a real runtime crash, not a lint: inside a Row, a SizedBox
              // with only `height` set passes UNBOUNDED width through to
              // its child (Row gives non-Expanded children maxWidth:
              // infinity), and ElevatedButton's internal layout cannot
              // resolve an infinite width - "BoxConstraints forces an
              // infinite width" the moment this screen first rendered.
              // Sizing via the button's own style avoids the whole
              // class of bug: the button computes its own bounded
              // intrinsic width instead of inheriting the Row's.
              style: ElevatedButton.styleFrom(minimumSize: const Size(64, 52)),
              onPressed: busy ? null : onVerify,
              child: busy
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('VERIFY')),
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: extraLines,
          minLines: 1, maxLines: 3,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13, letterSpacing: 0.5),
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Other lines on the package (optional)',
            hintText: 'e.g.  CHN 30 2B1',
            helperText: 'Used to detect re-marked chips: country and site codes are cross-checked.',
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: OutlinedButton.icon(
              onPressed: onScan, icon: const Icon(Icons.qr_code_scanner, size: 18),
              label: const Text('SCAN CODE'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(
              onPressed: onPhoto, icon: const Icon(Icons.center_focus_strong, size: 18),
              label: const Text('PHOTOGRAPH CHIP'))),
        ]),
        const SizedBox(height: 10),
        Text('$catalogCount records loaded. Works with no network \u2014 nothing you '
             'type leaves this device unless you are signed in and online.',
            style: TextStyle(fontSize: 12, color: t.ink2)),
      ]),
    ));
  }
}

class _ComponentCard extends StatelessWidget {
  final MatchResult match;
  const _ComponentCard({required this.match});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = match.component;
    if (c == null) {
      return Card(child: Padding(padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('NO RECORD', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
              letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(
            ['conflict', 'ambiguous_prefix', 'ambiguous_fuzzy'].contains(match.method)
                ? 'The catalogue holds more than one candidate and they do not agree. '
                  'Pick the correct record by eye, or refer it for adjudication.'
                : 'Photograph the package, note where it was fitted, and queue it for '
                  'the database manager. An unknown part is a gap in the catalogue, not a pass.',
            style: TextStyle(fontSize: 13, color: t.ink2)),
          if (match.notes.isNotEmpty) ...[
            const SizedBox(height: 10),
            ...match.notes.map((n) => Padding(padding: const EdgeInsets.only(bottom: 4),
                child: Text('\u2022 $n', style: TextStyle(fontSize: 12, color: t.ink2)))),
          ],
        ]),
      ));
    }
    final comp = Component.fromMap(c);
    return Card(child: Padding(padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('CATALOGUE RECORD', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
            letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(comp.componentName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Wrap(children: [
          Tag(comp.componentId),
          if (comp.criticality == 'CRITICAL') const Tag('Critical subsystem', critical: true)
          else Tag(comp.criticality),
          if (comp.militaryGrade == 'YES') const Tag('Mil grade'),
        ]),
        SpecList(specs: [
          MapEntry('Marking', comp.chipNumber.isNotEmpty ? comp.chipNumber : comp.partNumber),
          MapEntry('Manufacturer', comp.manufacturer),
          MapEntry('Country of origin', comp.countryOfOrigin.isEmpty ? 'Not established' : comp.countryOfOrigin),
          MapEntry('Subsystem', comp.droneSubsystem),
          MapEntry('Function', comp.function),
          MapEntry('Acceptance policy', comp.criticalityPolicy),
          MapEntry('Found in', comp.supplier),
          MapEntry('Remarks', comp.remarks),
          MapEntry('Evidence', comp.verificationSource),
          MapEntry('Confidence', '${comp.confidenceScore.toStringAsFixed(0)}%'),
          MapEntry('Barcode', comp.barcode),
        ]),
        if (comp.alternatives.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('APPROVED ALTERNATIVES', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
              letterSpacing: 1.4, color: t.silk)),
          const SizedBox(height: 6),
          ...comp.alternatives.map((a) => Padding(padding: const EdgeInsets.only(bottom: 2),
              child: Text(a, style: const TextStyle(fontSize: 13)))),
        ],
        if (match.notes.isNotEmpty) ...[
          const SizedBox(height: 10),
          ...match.notes.map((n) => Padding(padding: const EdgeInsets.only(bottom: 4),
              child: Text('\u2022 $n', style: TextStyle(fontSize: 12, color: t.ink2)))),
        ],
      ]),
    ));
  }
}

/// Full-screen barcode/QR reader. Pops with (payload, symbology).
class _CodeScannerPage extends StatefulWidget {
  const _CodeScannerPage();
  @override
  State<_CodeScannerPage> createState() => _CodeScannerPageState();
}

class _CodeScannerPageState extends State<_CodeScannerPage> {
  final _controller = MobileScannerController(
    formats: const [
      BarcodeFormat.qrCode, BarcodeFormat.code128, BarcodeFormat.code39,
      BarcodeFormat.code93, BarcodeFormat.ean13, BarcodeFormat.ean8,
      BarcodeFormat.upcA, BarcodeFormat.upcE, BarcodeFormat.dataMatrix,
      BarcodeFormat.pdf417, BarcodeFormat.aztec, BarcodeFormat.itf,
    ],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;
  List<Barcode> _choices = const [];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _finish(Barcode b) {
    if (_handled) return;
    _handled = true;
    Navigator.pop(context, (b.rawValue ?? '', b.format.name));
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final codes = capture.barcodes.where((b) => (b.rawValue ?? '').isNotEmpty).toList();
    if (codes.isEmpty) return;
    final distinct = <String, Barcode>{for (final b in codes) b.rawValue!: b};
    if (distinct.length == 1) {
      _finish(codes.first);
    } else {
      // Several codes in view (reel label: part no., lot, qty...). Do not
      // guess which one is the component - let the inspector pick.
      setState(() => _choices = distinct.values.toList());
      _controller.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SCAN CODE'), actions: [
        IconButton(icon: const Icon(Icons.flash_on), tooltip: 'Torch',
            onPressed: () => _controller.toggleTorch()),
      ]),
      body: Stack(children: [
        MobileScanner(controller: _controller, onDetect: _onDetect),
        // Permission denied / camera busy / unsupported: explain instead of a
        // black screen. Read from the controller state (stable across
        // mobile_scanner 5-7), not the version-specific errorBuilder.
        ValueListenableBuilder<MobileScannerState>(
          valueListenable: _controller,
          builder: (context, state, _) {
            final err = state.error;
            if (err == null) return const SizedBox.shrink();
            final denied = err.errorCode == MobileScannerErrorCode.permissionDenied;
            return Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              padding: const EdgeInsets.all(24),
              alignment: Alignment.center,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(denied ? Icons.no_photography : Icons.error_outline, size: 40),
                const SizedBox(height: 12),
                Text(denied ? 'Camera permission denied' : 'Camera not available',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(denied
                    ? 'Allow camera access in Settings > Apps > DCOV > Permissions, then '
                      'come back. You can also type the code or use a USB/Bluetooth scanner.'
                    : 'The camera could not be started (${err.errorCode.name}). Close other '
                      'camera apps and try again, or type the code.',
                    textAlign: TextAlign.center),
                const SizedBox(height: 16),
                OutlinedButton(onPressed: () => Navigator.pop(context),
                    child: const Text('BACK')),
                if (!denied) TextButton(onPressed: () => _controller.start(),
                    child: const Text('RETRY')),
              ]),
            );
          },
        ),
        if (_choices.isNotEmpty)
          Positioned(left: 0, right: 0, bottom: 0, child: Material(
            color: Theme.of(context).cardColor,
            child: SafeArea(top: false, child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('Several codes detected - choose the one to verify:',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                for (final b in _choices)
                  ListTile(dense: true,
                      title: Text(b.rawValue!.replaceAll(RegExp(r'[\x00-\x1f]'), ' '),
                          maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontFamily: 'RobotoMono')),
                      subtitle: Text(b.format.name),
                      onTap: () => _finish(b)),
                TextButton(onPressed: () {
                  setState(() => _choices = const []);
                  _controller.start();
                }, child: const Text('SCAN AGAIN')),
              ]),
            )),
          )),
      ]),
    );
  }
}

/// Bottom sheet for photo-based lookup: on-device OCR (ML Kit, Android/iOS,
/// no network) runs immediately; server OCR (Tesseract ensemble) is offered
/// as a second opinion when the server is reachable. The inspector always
/// confirms or corrects the marking before it is verified - OCR never
/// silently picks the part number.
class _OcrUploadSheet extends StatefulWidget {
  final AppState app;
  final Uint8List bytes;
  final String path;
  final void Function(String raw, String fullText, String imageRef) onResolved;
  const _OcrUploadSheet({required this.app, required this.bytes, required this.path,
      required this.onResolved});
  @override
  State<_OcrUploadSheet> createState() => _OcrUploadSheetState();
}

class _OcrUploadSheetState extends State<_OcrUploadSheet> {
  bool _deviceBusy = false;
  bool _serverBusy = false;
  String? _error;
  List<String> _candidates = [];
  List<String> _warnings = [];
  String _fullText = '';
  String _source = '';
  String _imageRef = '';
  final _manual = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Post-frame: setState may not be called while initState is running.
    if (OnDeviceOcr.supported) {
      _deviceBusy = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _runDeviceOcr());
    }
  }

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  void _apply(RankedOcr r, String source) {
    _candidates = r.candidates;
    _warnings = r.warnings;
    _fullText = r.fullText;
    _source = source;
    // Pre-fill only when exactly one part number is evident. With several,
    // the inspector must choose.
    if (r.best.isNotEmpty && !r.multipleParts && _manual.text.isEmpty) {
      _manual.text = r.best;
    }
  }

  Future<void> _runDeviceOcr() async {
    setState(() { _deviceBusy = true; _error = null; });
    final r = await OnDeviceOcr.read(widget.path);
    if (!mounted) return;
    setState(() { _deviceBusy = false; _apply(r, 'on-device OCR'); });
  }

  Future<void> _runServerOcr() async {
    setState(() { _serverBusy = true; _error = null; });
    try {
      await widget.app.ensureFreshToken();
      final result = await widget.app.api.scanImage(
        clientUuid: 'img-${DateTime.now().microsecondsSinceEpoch}',
        imageBytes: widget.bytes, filename: 'chip.jpg', deviceId: widget.app.store.deviceId,
        autoLookup: false, inspectionId: widget.app.activeInspectionId,
      );
      final ocr = (result['ocr'] as Map?)?.cast<String, dynamic>() ?? const {};
      final cands = ((ocr['candidates'] as List?) ?? const []).map((e) => e.toString()).toList();
      final full = ocr['full_text']?.toString() ?? '';
      final warns = ((ocr['warnings'] as List?) ?? const []).map((e) => e.toString()).toList();
      if (!mounted) return;
      setState(() {
        _serverBusy = false;
        _imageRef = result['image_path']?.toString() ?? '';
        _candidates = cands;
        _fullText = full;
        _warnings = warns;
        _source = 'server OCR';
        final best = ocr['best']?.toString() ?? '';
        if (best.isNotEmpty && ocr['multiple_parts'] != true) _manual.text = best;
      });
    } catch (e) {
      if (mounted) setState(() { _serverBusy = false; _error = 'Server OCR unavailable: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final yellow = DcovColors.forBanner('YELLOW', Theme.of(context).brightness);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.8, minChildSize: 0.5, maxChildSize: 0.95, expand: false,
        builder: (_, controller) => Container(
          decoration: BoxDecoration(color: t.panel,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12))),
          padding: const EdgeInsets.all(16),
          child: ListView(controller: controller, children: [
            ClipRRect(borderRadius: BorderRadius.circular(4),
                child: Image.memory(widget.bytes, height: 220, fit: BoxFit.contain)),
            const SizedBox(height: 12),
            if (_deviceBusy)
              const Row(children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10), Text('Reading marking on this device…'),
              ])
            else if (!OnDeviceOcr.supported)
              Text('On-device OCR is not available on this platform.',
                  style: TextStyle(color: t.ink2, fontSize: 12.5)),
            const SizedBox(height: 8),
            if (widget.app.online && widget.app.isLoggedIn)
              OutlinedButton.icon(
                onPressed: _serverBusy ? null : _runServerOcr,
                icon: _serverBusy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.document_scanner, size: 18),
                label: Text(_serverBusy ? 'READING…' : 'SECOND OPINION: SERVER OCR'))
            else
              Text(OnDeviceOcr.supported
                  ? 'Server OCR (second opinion) needs a signed-in connection to the server.'
                  : 'Offline - server OCR needs a connection. Type the marking below.',
                  style: TextStyle(color: t.ink2, fontSize: 12)),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: yellow, fontSize: 12.5))),
            for (final w in _warnings) Padding(padding: const EdgeInsets.only(top: 6),
                child: Text('⚠ $w', style: TextStyle(color: yellow, fontSize: 12.5))),
            if (_candidates.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('CANDIDATES${_source.isNotEmpty ? ' ($_source)' : ''} - TAP THE PART NUMBER',
                  style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
                      letterSpacing: 1.4, color: t.silk)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: _candidates.map((c) => ActionChip(
                label: Text(c, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 12)),
                onPressed: () => setState(() => _manual.text = c),
              )).toList()),
            ],
            if (_fullText.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('ALL LINES READ', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
                  letterSpacing: 1.4, color: t.silk)),
              const SizedBox(height: 4),
              Text(_fullText, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 12)),
            ],
            const SizedBox(height: 14),
            TextField(controller: _manual, textCapitalization: TextCapitalization.characters,
                style: const TextStyle(fontFamily: 'RobotoMono'),
                decoration: const InputDecoration(labelText: 'Marking to search (confirm or correct)')),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                if (_manual.text.trim().isNotEmpty) {
                  widget.onResolved(_manual.text.trim(), _fullText, _imageRef);
                }
              },
              child: const Text('VERIFY THIS MARKING')),
          ]),
        ),
      ),
    );
  }
}

/// ONLINE VERIFIED / OFFLINE - PENDING SYNC / LOCAL ONLY, plus scan ID,
/// operator and time - so a device-only check is never mistaken for a
/// centrally recorded one.
class _StatusStrip extends StatelessWidget {
  final VerifyOutcome outcome;
  const _StatusStrip({required this.outcome});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final b = Theme.of(context).brightness;
    final (label, band, icon) = switch (outcome.status) {
      ScanStatus.onlineVerified => ('ONLINE VERIFIED', 'GREEN', Icons.cloud_done),
      ScanStatus.pendingSync => ('OFFLINE — PENDING SYNCHRONISATION', 'YELLOW', Icons.cloud_queue),
      _ => ('LOCAL ONLY — NOT RECORDED CENTRALLY', 'GREY', Icons.cloud_off),
    };
    final c = DcovColors.forBanner(band, b);
    final when = DateFormat('yyyy-MM-dd HH:mm:ss').format(outcome.at);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(border: Border.all(color: c), borderRadius: BorderRadius.circular(3)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 16, color: c),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: TextStyle(color: c, fontFamily: 'RobotoMono',
              fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1))),
        ]),
        const SizedBox(height: 4),
        Text([
          'Scan ${outcome.scanId.isNotEmpty ? outcome.scanId : outcome.clientUuid.substring(0, 8)}',
          when,
          if (outcome.operator.isNotEmpty) 'operator ${outcome.operator}',
          outcome.serverVerdict != null ? 'server catalogue' : 'device catalogue',
        ].join('  ·  '), style: TextStyle(fontSize: 11.5, color: t.ink2)),
        if (outcome.status == ScanStatus.pendingSync)
          Text('Verdict computed on this device. It will be recorded on the server '
              'automatically when the connection returns.',
              style: TextStyle(fontSize: 11.5, color: t.ink2)),
        if (outcome.status == ScanStatus.localOnly && outcome.operator.isEmpty)
          Text('Not signed in: this result exists only on this device.',
              style: TextStyle(fontSize: 11.5, color: t.ink2)),
        if (outcome.syncError.isNotEmpty)
          Text(outcome.syncError, style: TextStyle(fontSize: 11.5, color: c)),
        if (outcome.repeatOf != null)
          Text('Repeat scan: the same marking was verified at '
              '${DateFormat('HH:mm:ss').format(outcome.repeatOf!.at)} '
              '(${outcome.repeatOf!.banner.isNotEmpty ? outcome.repeatOf!.banner : outcome.repeatOf!.result}). '
              'Recorded again as a separate scan.',
              style: TextStyle(fontSize: 11.5, color: t.ink2)),
        for (final n in outcome.serverNotes)
          Text('• $n', style: TextStyle(fontSize: 11.5, color: t.ink2)),
      ]),
    );
  }
}

/// Everything the verdict rests on, in one place: what was read, what it
/// matched, how, how confidently, where the origin claim comes from, and
/// what the configured policy says.
class _EvidenceCard extends StatelessWidget {
  final VerifyOutcome outcome;
  const _EvidenceCard({required this.outcome});

  static const _methodLabels = {
    'exact_code': 'Exact barcode/QR payload',
    'label_mpn': 'Reel/bag label - manufacturer part number',
    'normalized': 'Exact part number (case/spacing ignored)',
    'lot_code_stripped': 'Part number after discarding trailing lot/date code',
    'ocr_corrected': 'Single-character OCR correction',
    'ocr_folded': 'Multi-character OCR correction (approximate)',
    'ocr_folded_stripped': 'Multi-character OCR correction + lot code stripped (approximate)',
    'prefix': 'Partial marking (approximate)',
    'fuzzy': 'Closest similar part number (approximate)',
    'conflict': 'Conflicting records - manual adjudication',
    'ambiguous_prefix': 'Several possible parts - manual choice',
    'ambiguous_fuzzy': 'Several near-equal parts - manual choice',
    'none': 'No match',
  };
  static const _evidenceLabels = {
    'component': 'Documented for this component',
    'manufacturer': 'Manufacturer/OEM home country only',
    'unit_marking': 'Country code marked on this package',
    'none': 'No documented origin',
  };

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final v = outcome.verdict;
    final m = outcome.match;
    final c = m.component;
    final comp = c == null ? null : Component.fromMap(c);
    final country = comp == null ? '' :
        (comp.countryOfOrigin.isEmpty ? 'Not established' : comp.countryOfOrigin);
    return Card(child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('EVIDENCE', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
            letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        SpecList(specs: [
          MapEntry('Read', outcome.entry.raw.replaceAll(RegExp(r'[\x00-\x1f]'), ' ')),
          MapEntry('Searched as', m.normalizedInput),
          MapEntry('Component', comp == null ? 'No catalogue record'
              : '${comp.componentName} (${comp.componentId})'),
          MapEntry('Catalogue marking', comp == null ? '' :
              (comp.chipNumber.isNotEmpty ? comp.chipNumber : comp.partNumber)),
          MapEntry('Barcode', comp?.barcode ?? ''),
          MapEntry('Manufacturer', comp?.manufacturer ?? ''),
          MapEntry('Origin', country),
          MapEntry('Origin evidence', _evidenceLabels[v.originEvidence] ?? v.originEvidence),
          MapEntry('Evidence detail', v.evidenceDetail),
          MapEntry('Match method', _methodLabels[m.method] ?? m.method),
          MapEntry('Match score', '${m.score.toStringAsFixed(0)}%'),
          MapEntry('Confidence', '${v.confidence.toStringAsFixed(0)}%'),
          MapEntry('Subsystem', comp == null ? '' :
              '${comp.droneSubsystem} (${comp.criticality})'),
          MapEntry('Policy decision', v.policyDecision),
          MapEntry('Review', v.reviewRequired ? 'REQUIRED' : 'Not required'),
        ]),
      ]),
    ));
  }
}


/// Anti-remark findings - see lib/services/marking.dart.
class _MarkingFindingsCard extends StatelessWidget {
  final MarkingAnalysis analysis;
  const _MarkingFindingsCard({required this.analysis});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final b = Theme.of(context).brightness;
    String bandFor(String sev) => sev == 'red' ? 'RED' : sev == 'yellow' ? 'YELLOW' : 'GREY';
    return Card(child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('MARKING CONSISTENCY', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
            letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
        if (analysis.countryCode != null) ...[
          const SizedBox(height: 6),
          Text('Country code read: ${analysis.countryCode} (${analysis.country})',
              style: TextStyle(fontSize: 12.5, color: t.ink2)),
        ],
        for (final f in analysis.findings) ...[
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(f.severity == 'red' ? Icons.error_outline : Icons.warning_amber_rounded,
                size: 18, color: DcovColors.forBanner(bandFor(f.severity), b)),
            const SizedBox(width: 8),
            Expanded(child: Text(f.message,
                style: const TextStyle(fontSize: 12.5, height: 1.4))),
          ]),
        ],
      ]),
    ));
  }
}
