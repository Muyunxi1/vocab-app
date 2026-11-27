import 'dart:convert';
import 'dart:io';

import 'package:enough_convert/gbk.dart';

/// 逐块读文本文件并切成 CSV/TSV 记录，不把整份文件读进内存。
///
/// 三个约束决定了这个实现：
/// 1) 一本词书几万个词，小内存机上 `readAsBytes()` 一次就要几百 MB，会直接闪退；
/// 2) 切块必须按换行对齐 —— 换行是单字节，切点永远落在字符边界上，不会把中文切断；
/// 3) 编码只有两种候选 —— 前 128KB 能严格解成 UTF-8 就当 UTF-8，否则整份按 GBK。
///    Excel 在中文 Windows 上默认存 GBK，这个判定必须留着。
///
/// 引号内的换行属于字段内容：读的时候按物理行切，再由 [_CsvLineMerger] 拼回记录。
class CsvStreamReader {
  /// 单条记录最长能攒多少行。防止文件里有个没闭合的引号，把整个文件吞成一条。
  static const int _maxRecordLines = 200;

  /// [onBrokenRecord] 在交出坏记录时回调，参数是这条记录吞掉的物理行数。
  ///
  /// 引号一直没闭合时，后面的物理行会被拼成一条超长记录。上层若把它当普通行去
  /// 切字段，多半会切出一个假单词、只报「新增 1」，用户完全看不出丢了内容。
  /// 所以这里必须把「这条是坏的、吞了多少行」告诉调用方，由调用方记成坏行。
  static Stream<String> read(File file,
      {required int maxBytes, void Function(int lines)? onBrokenRecord}) async* {
    final length = await file.length();
    if (length > maxBytes) {
      throw CsvTooLargeException(length, maxBytes);
    }
    final isUtf8 = await _probeUtf8(file);
    final raf = await file.open();
    final merger = _CsvLineMerger();
    var carry = <int>[];
    var firstChunk = true;

    String decodeChunk(List<int> bytes) {
      var text = isUtf8
          ? utf8.decode(bytes, allowMalformed: true)
          : const GbkCodec(allowInvalid: true).decode(bytes);
      if (firstChunk) {
        firstChunk = false;
        // Windows 记事本存的 UTF-8 带 BOM，不剥掉表头第一格就变成 "﻿spelling"
        if (text.startsWith('\uFEFF')) text = text.substring(1);
      }
      return text;
    }

    Iterable<String> linesOf(List<int> bytes) {
      final parts = decodeChunk(bytes).split('\n');
      // 块以换行结尾时 split 会多出一个空串，它不是空行
      if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast();
      return parts;
    }

    try {
      while (true) {
        final chunk = await raf.read(256 * 1024);
        if (chunk.isEmpty) break;
        final all = <int>[...carry, ...chunk];
        final cut = all.lastIndexOf(0x0A);
        if (cut < 0) {
          // 一整块都没有换行：继续攒，攒到出现换行为止
          carry = all;
          continue;
        }
        final head = all.sublist(0, cut + 1);
        carry = all.sublist(cut + 1);
        for (final line in linesOf(head)) {
          final done = merger.feed(line);
          if (done != null) {
            if (merger.brokenLines > 0) onBrokenRecord?.call(merger.brokenLines);
            yield done;
          }
        }
      }
      if (carry.isNotEmpty) {
        for (final line in linesOf(carry)) {
          final done = merger.feed(line);
          if (done != null) {
            if (merger.brokenLines > 0) onBrokenRecord?.call(merger.brokenLines);
            yield done;
          }
        }
      }
      final rest = merger.finish();
      if (rest != null) {
        // finish 交出的记录如果是从未闭合引号里攒出来的，同样是坏行
        if (merger.brokenLines > 0) onBrokenRecord?.call(merger.brokenLines);
        yield rest;
      }
    } finally {
      await raf.close();
    }
  }

  /// 前 128KB 像不像 UTF-8。
  ///
  /// 不能直接 `utf8.decode` 试探：这 128KB 的切口几乎一定落在某个汉字中间，
  /// 那样连纯 UTF-8 文件都会被判成坏编码，整份按 GBK 解出来全是乱码。
  /// 所以这里按 UTF-8 的字节结构自己走一遍，尾部不完整的序列算截断、不算错。
  static Future<bool> _probeUtf8(File file) async {
    final raf = await file.open();
    try {
      final head = await raf.read(128 * 1024);
      return _looksUtf8(head);
    } finally {
      await raf.close();
    }
  }

  static bool _looksUtf8(List<int> bytes) {
    final n = bytes.length;
    var i = 0;
    while (i < n) {
      final b = bytes[i];
      final int need;
      if (b < 0x80) {
        need = 0;
      } else if (b >= 0xC2 && b <= 0xDF) {
        need = 1;
      } else if (b >= 0xE0 && b <= 0xEF) {
        need = 2;
      } else if (b >= 0xF0 && b <= 0xF4) {
        need = 3;
      } else {
        // 0x80-0xC1 不能当首字节（GBK 的汉字首字节大量落在这一带），0xF5-0xFF 更不是
        return false;
      }
      if (i + need >= n) return true;
      for (var k = 1; k <= need; k++) {
        final c = bytes[i + k];
        if (c < 0x80 || c > 0xBF) return false;
      }
      i += need + 1;
    }
    return true;
  }
}

class CsvTooLargeException implements Exception {
  final int size;
  final int limit;

  const CsvTooLargeException(this.size, this.limit);

  @override
  String toString() =>
      '文件 ${size ~/ (1024 * 1024)}MB，超过 ${limit ~/ (1024 * 1024)}MB 上限';
}

/// 把物理行拼回 CSV 记录：引号内的换行是字段内容，不是记录分隔。
///
/// 判断依据是 [_endsInsideQuote]，跟切字段的规则同源，
/// 释义里的英寸符号（5"）不会被误判成开引号。
class _CsvLineMerger {
  final StringBuffer _buf = StringBuffer();
  bool _open = false;
  int _lines = 0;

  /// 刚交出的这条记录是不是「引号一直没闭合」凑出来的坏记录：是则记下被它吞掉的
  /// 物理行数，正常记录一律归零。上层靠它把坏行计数报给用户。
  int brokenLines = 0;

  /// 喂一条物理行。返回完整记录；还停在引号里就返回 null，等下一行。
  String? feed(String line) {
    if (_open) {
      _buf.write('\n');
      _buf.write(line);
      _lines++;
      // 引号一直没闭合：别再无限攒，把这条当坏记录交出去
      if (_lines >= CsvStreamReader._maxRecordLines) {
        final broken = _buf.toString();
        _buf.clear();
        _open = false;
        brokenLines = _lines;
        _lines = 0;
        return broken;
      }
    } else {
      _buf.clear();
      _buf.write(line);
      _lines = 1;
      brokenLines = 0;
    }
    _open = _endsInsideQuote(_buf.toString());
    if (_open) return null;
    final out = _buf.toString();
    _buf.clear();
    _lines = 0;
    brokenLines = 0;
    return out;
  }

  /// 文件读完，把没等到闭合引号的那条也交出去（交给上层按坏行处理）。
  String? finish() {
    if (_buf.isEmpty) return null;
    final out = _buf.toString();
    final wasOpen = _open;
    _buf.clear();
    _open = false;
    brokenLines = wasOpen ? _lines : 0;
    _lines = 0;
    return out;
  }

  /// 这条记录是不是还停在引号里。
  ///
  /// 引号只有出现在字段起始才算开引号（行首、逗号后、Tab 后），
  /// 这样释义里的英寸符号（5"）不会把状态翻过来，否则整份文件都会被当成一条。
  static bool _endsInsideQuote(String text) {
    var inQuote = false;
    var prev = '\n';
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == '"') {
        if (inQuote) {
          // "" 是字段内的转义引号
          if (i + 1 < text.length && text[i + 1] == '"') {
            i++;
          } else {
            inQuote = false;
          }
        } else if (i == 0 ||
            prev == ',' ||
            prev == '\t' ||
            prev == '\n' ||
            prev == '\r') {
          inQuote = true;
        }
      }
      prev = ch;
    }
    return inQuote;
  }
}
