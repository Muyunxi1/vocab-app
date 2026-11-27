import 'package:flutter/material.dart' hide Ink;
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart';

/// 手写识别的一个笔画点：画板坐标 + 毫秒级时间戳。
///
/// 数字墨水引擎按笔画顺序和落笔时间判断字形，时间戳不能丢。
class InkPoint {
  const InkPoint(this.offset, this.timestamp);

  final Offset offset;
  final int timestamp;
}

/// 手写引擎侧失败，[message] 是给用户看的一句话。
class DigitalInkException implements Exception {
  const DigitalInkException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 端侧手写识别：把画板上的笔画矢量直接送进 ML Kit 数字墨水引擎。
///
/// 和拍照印刷体 OCR 不同，这一路吃的是笔画坐标序列，本来就是为手写设计的。
/// 英文模型按需下载一次，之后本机推理；首次下载失败或引擎报错时由调用方
/// 回退到截图 OCR 兜底。
class DigitalInk {
  DigitalInk._();

  static final DigitalInk instance = DigitalInk._();

  static const String _language = 'en';

  DigitalInkRecognizer? _recognizer;

  /// 只收字母词，允许中间连字符、撇号；和拍照取词同一套词形。
  static final RegExp _token = RegExp(r"[A-Za-z][A-Za-z'\-]*");

  /// 确保英文手写模型已下载到本机；未下载时按需拉取。
  ///
  /// 允许移动网络下载（约 20MB）：默认仅 Wi-Fi 会让离网环境下引擎一直不可用。
  /// 拉取失败会抛 [DigitalInkException]，调用方据此回退到现有截图 OCR。
  Future<void> ensureModel() async {
    final manager = DigitalInkRecognizerModelManager();
    final downloaded = await manager.isModelDownloaded(_language);
    if (downloaded) return;
    try {
      final ok = await manager.downloadModel(
        _language,
        isWifiRequired: false,
      );
      if (!ok) {
        throw const DigitalInkException('手写模型下载未完成，检查网络后重试');
      }
    } on DigitalInkException {
      rethrow;
    } catch (_) {
      throw const DigitalInkException('手写模型下载失败，检查网络后重试');
    }
  }

  /// 识别整板笔画，返回去重、按候选顺序保留的英文单词列表。
  ///
  /// [strokes] 为每一笔的点序列；[board] 是画板尺寸，用于告知书写区域。
  /// 引擎给出的候选按置信度从高到低排列，这里保留先后顺序。
  Future<List<String>> recognize(
    List<List<InkPoint>> strokes,
    Size board,
  ) async {
    final inkStrokes = <Stroke>[];
    for (final stroke in strokes) {
      final points = <StrokePoint>[];
      for (final pt in stroke) {
        if (!pt.offset.dx.isFinite || !pt.offset.dy.isFinite) continue;
        points.add(StrokePoint(
          x: pt.offset.dx,
          y: pt.offset.dy,
          t: pt.timestamp,
        ));
      }
      if (points.isNotEmpty) inkStrokes.add(Stroke()..points = points);
    }
    if (inkStrokes.isEmpty) return const [];
    final ink = Ink()..strokes = inkStrokes;

    final recognizer = _recognizer ??= DigitalInkRecognizer(languageCode: _language);
    final context = DigitalInkRecognitionContext(
      writingArea: WritingArea(width: board.width, height: board.height),
    );

    final List<RecognitionCandidate> candidates;
    try {
      candidates = await recognizer.recognize(ink, context: context);
    } catch (_) {
      throw const DigitalInkException('手写识别失败，请重试');
    }

    final words = <String>[];
    final seen = <String>{};
    for (final candidate in candidates) {
      for (final match in _token.allMatches(candidate.text)) {
        var word = match.group(0)!;
        word = word.replaceAll(RegExp(r"[-']+$"), '');
        if (word.isEmpty) continue;
        if (!seen.add(word.toLowerCase())) continue;
        words.add(word);
      }
    }
    return words;
  }

  /// 释放原生识别器；离开页面时调用。
  Future<void> close() async {
    await _recognizer?.close();
    _recognizer = null;
  }
}
