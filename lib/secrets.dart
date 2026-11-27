import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 有道密钥的存取包装。
///
/// 严格讲这不是加密——掩码由固定盐派生，算法也在包里，谁拿到数据库文件谁都能还原。
/// 目的只是不让 appKey / appSecret 以明文躺在 app_meta 表里，随手翻库、导出、
/// 日志里都不至于直接看到。
///
/// 真正的屏障在 AndroidManifest：allowBackup 已关闭，备份与换机规则也排除了
/// sharedpref / database，adb backup 和云备份都带不走这份库。要做 Keystore 级别的
/// 保护需要额外的平台通道与依赖，本项目约定不引入新依赖，故维持混淆级实现。
class SecretVault {
  static const String _tag = 'v1:';

  static final List<int> _mask =
      sha256.convert(utf8.encode('vocab_app_secret_vault_v1')).bytes;

  /// 加密存储。空字符串返回空字符串，交给上层决定是否删行。
  static String pack(String plain) {
    final data = utf8.encode(plain);
    final mixed = List<int>.generate(
      data.length,
      (i) => data[i] ^ _mask[i % _mask.length],
    );
    return _tag + base64Url.encode(mixed);
  }

  /// 解密。没有标记的老数据（1.5.1 及以前直接存明文）原样返回，保证升级不断档。
  static String unpack(String stored) {
    if (!stored.startsWith(_tag)) return stored;
    final data = base64Url.decode(stored.substring(_tag.length));
    final mixed = List<int>.generate(
      data.length,
      (i) => data[i] ^ _mask[i % _mask.length],
    );
    return utf8.decode(mixed);
  }
}
