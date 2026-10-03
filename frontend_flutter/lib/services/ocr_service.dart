import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'ocr_ranking.dart';

/// On-device OCR with Google ML Kit text recognition (Latin script model,
/// bundled in the APK - no network, no Google Play download at run time).
///
/// Android and iOS only. On Windows/Linux/macOS/web [supported] is false and
/// the photo flow falls back to server OCR (when reachable) or manual entry.
class OnDeviceOcr {
  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Reads the image at [path]. Never throws: failures come back as a result
  /// with no candidates and an explanatory warning, so the caller can always
  /// fall through to manual entry.
  static Future<RankedOcr> read(String path) async {
    if (!supported) {
      return RankedOcr(const [], const [],
          const ['On-device OCR is not available on this platform.'], false);
    }
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final text = await recognizer.processImage(InputImage.fromFilePath(path));
      final lines = <String>[
        for (final block in text.blocks)
          for (final line in block.lines) line.text,
      ];
      return rankOcrLines(lines);
    } catch (e) {
      return RankedOcr(const [], const [], ['On-device OCR failed: $e'], false);
    } finally {
      try {
        await recognizer.close();
      } catch (_) {/* already closed */}
    }
  }
}
