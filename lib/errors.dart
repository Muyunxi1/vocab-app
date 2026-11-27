import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'diag.dart';

/// 把异常翻成用户能读懂的一句话。
///
/// 不要把 Exception.toString() 直接丢到界面上：PlatformException 会拼上 details，
/// release 包里还会带 R8 混淆过的堆栈帧，用户既读不懂，又会以为 App 崩了。
/// 原始信息走 debugPrint，只在开发时可见。
String humanizeError(Object? error) {
  if (error == null) return '操作失败，请重试';

  // 我们自己抛的异常，message 本来就是给用户看的
  if (error is ApiException) return error.message;

  // 其余业务异常（SpeechException / NeuralTtsException / ArticleException 等）
  // 也都带一个给用户看的 message。这里按字段探测，避免 errors.dart 反向依赖各业务文件。
  try {
    final dynamic dyn = error;
    final Object? message = dyn.message;
    if (message is String && message.trim().isNotEmpty) return message.trim();
  } catch (_) {
    // 没有 message 字段，继续走通用分支
  }

  if (error is PlatformException) {
    final code = error.code.toLowerCase();
    final message = (error.message ?? '').toLowerCase();
    if (code.contains('camera_access_denied') || message.contains('camera permission')) {
      return '没有相机权限，去系统设置里允许「词学家」使用相机';
    }
    if (code.contains('camera_access_restricted')) {
      return '系统策略限制了相机访问';
    }
    if (code.contains('photo_access_denied') || message.contains('photo permission')) {
      return '没有相册权限，去系统设置里允许「词学家」读取照片';
    }
    if (code.contains('no_available_camera')) {
      return '这台设备没有可用的相机';
    }
    if (code.contains('camera_access_failed') || message.contains('camera')) {
      return '打不开相机，可能被别的应用占用了，稍后再试';
    }
    return '调用系统相机或相册失败，请重试';
  }

  if (error is FormatException) return '数据格式不对，请检查内容后重试';
  if (error is FileSystemException) return '读写文件失败，检查存储空间后再试';
  if (error is TimeoutException) return '请求超时，检查网络后重试';

  final text = error.toString();
  // 短且不含类型名的，本身就是一句人话
  if (text.length <= 40 &&
      !text.contains('Exception') &&
      !text.contains('Error') &&
      !text.contains('#')) {
    return text;
  }
  return '操作失败，请重试';
}

/// 记录原始异常。debug 下打到控制台，release 下同样输出到系统日志（logcat），
/// 出故障时还能抓现场。只进日志，不往界面上抛。
///
/// 同时进 [Diag] 的环形缓冲：「我的」页导出的诊断报告就是从这里取的。
/// 之前只有朗读与神经语音两处自己记 Diag，导入、翻译、恢复备份出的错在报告里
/// 一条都看不到，用户发来的报告等于只有半截信息。
void logError(String where, Object? error, [StackTrace? stack]) {
  debugPrint('[error] $where: $error');
  if (stack != null) debugPrint('$stack');
  Diag.record(where, error);
}
