import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'languages.dart';

/// Callback for download progress updates.
/// [progress] is 0.0 to 1.0.
typedef DownloadProgressCallback = void Function(double progress);

/// Downloads AI4Bharat IndicConformer INT8 ONNX models from HuggingFace
/// for fully offline on-device speech recognition.
///
/// Source: https://huggingface.co/parismitaglobalsolutions/indicconformer-sherpa-onnx
/// Models are ~150–200 MB per language, INT8 quantized.
class ModelDownloader {
  ModelDownloader._();

  static const String _baseUrl =
      'https://huggingface.co/parismitaglobalsolutions/indicconformer-sherpa-onnx/resolve/main';

  /// Check if STT models are already downloaded for [lang].
  static Future<bool> areModelsAvailable(Lang lang) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelPath = '${appDir.path}/${lang.sttModel}';
      final tokensPath = '${appDir.path}/${lang.sttTokens}';
      return await File(modelPath).exists() &&
          await File(tokensPath).exists();
    } catch (_) {
      return false;
    }
  }

  /// Download STT model + tokens for [lang].
  ///
  /// Reports progress via [onProgress] (0.0–1.0).
  /// Returns `true` on success, `false` on failure.
  static Future<bool> downloadModels(
    Lang lang, {
    DownloadProgressCallback? onProgress,
  }) async {
    final appDir = await getApplicationDocumentsDirectory();

    try {
      // Download model (70% of progress).
      await _downloadFile(
        '$_baseUrl/${lang.iso639}/model.int8.onnx',
        '${appDir.path}/${lang.sttModel}',
        onProgress: (p) => onProgress?.call(p * 0.7),
      );

      // Download tokens (remaining 30% of progress).
      // Indic languages share a tokens file; English has its own.
      final tokensUrl = lang.iso639 == 'en'
          ? '$_baseUrl/en/tokens.txt'
          : '$_baseUrl/tokens.txt';
      await _downloadFile(
        tokensUrl,
        '${appDir.path}/${lang.sttTokens}',
        onProgress: (p) => onProgress?.call(0.7 + p * 0.3),
      );

      onProgress?.call(1.0);
      return true;
    } catch (e) {
      // Clean up partial downloads on failure.
      try {
        final modelFile = File('${appDir.path}/${lang.sttModel}');
        final tokensFile = File('${appDir.path}/${lang.sttTokens}');
        if (await modelFile.exists()) await modelFile.delete();
        if (await tokensFile.exists()) await tokensFile.delete();
      } catch (_) {}
      return false;
    }
  }

  /// Download a single file from [url] to [destPath] with progress.
  static Future<void> _downloadFile(
    String url,
    String destPath, {
    DownloadProgressCallback? onProgress,
  }) async {
    final file = File(destPath);
    // Ensure parent directory exists.
    await file.parent.create(recursive: true);

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close().timeout(
            const Duration(seconds: 30),
          );

      if (response.statusCode != 200) {
        throw HttpException(
          'HTTP ${response.statusCode} for $url',
        );
      }

      final totalBytes = response.contentLength;
      var receivedBytes = 0;

      final sink = file.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          onProgress?.call(receivedBytes / totalBytes);
        }
      }
      await sink.close();
    } finally {
      client.close();
    }
  }
}
