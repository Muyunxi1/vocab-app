import 'dart:convert';

import 'package:archive/archive.dart';

/// 把 .docx 的正文抽成「一行一个词条」的纯文本，同一条记录里的单元格用 Tab 分隔。
///
/// 词书在 Word 里基本就两种排法：
///   1) 表格：一行一个词条，单元格是 单词 / 音标 / 词性 / 释义；
///   2) 段落：`abandon /əˈbændən/ v. 放弃`、`1. abandon 放弃` 这种一行一词。
/// 表格按行拼 Tab（上层按列取），段落按段原样输出（上层按「英文部分 + 中文部分」切），
/// 所以这里只负责还原结构，不猜哪一列是单词。
///
/// 只依赖 archive 与 dart:convert，能直接跑在后台 isolate 里。
class WordbookReader {
  /// docx 一般几 MB。超过这个量基本是塞了大量图片，读进内存会拖垮中端机。
  static const int maxBytes = 80 * 1024 * 1024;

  /// 正文 XML 解压后的上限。
  ///
  /// zip 的压缩比能到上百倍：一个 80MB 的包可以解出几百 MB 的 document.xml，
  /// 解压本身不报错，炸的是后面按表格/段落跑的两条跨行正则。所以解压拿到条目后
  /// 先按未压缩大小拦一道，不让超大正文进处理器。
  /// 注意这道检查在解压之后，挡不住「解压阶段就把内存吃满」，真正的前置防线是
  /// 上面的 [maxBytes] 和调用方读文件前的 stat 预检。
  static const int maxXmlBytes = 96 * 1024 * 1024;

  static String docxToText(List<int> bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException('这个 docx 太大了，先把图片删掉再导入');
    }
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('读不开这个文件，确认是 .docx 而不是改了后缀的 .doc');
    }
    final file = archive.findFile('word/document.xml');
    if (file == null) throw const FormatException('这个文件里没有 Word 正文');
    if (file.size > maxXmlBytes) {
      throw const FormatException('这个 Word 的正文解压后太大了，先把图片和批注删掉再导入');
    }
    return _xmlToText(utf8.decode(file.content, allowMalformed: true));
  }

  /// 表格整段先处理，剩下的部分按段落处理。
  /// 两个正则都用了非贪婪的跨行匹配：docx 的正文是单行 XML，按行切会全废。
  static String _xmlToText(String xml) {
    final out = StringBuffer();
    final tableRe = RegExp(r'<w:tbl(?:\s[^>]*)?>[\s\S]*?</w:tbl>');
    var last = 0;
    for (final m in tableRe.allMatches(xml)) {
      if (m.start > last) _appendParagraphs(xml.substring(last, m.start), out);
      _appendTable(m.group(0)!, out);
      last = m.end;
    }
    if (last < xml.length) _appendParagraphs(xml.substring(last), out);
    return out.toString();
  }

  static void _appendParagraphs(String xml, StringBuffer out) {
    for (final m in RegExp(r'<w:p(?:\s[^>]*)?>[\s\S]*?</w:p>')
        .allMatches(xml)) {
      final text = _textOf(m.group(0)!);
      if (text.trim().isEmpty) continue;
      out.writeln(text);
    }
  }

  static void _appendTable(String xml, StringBuffer out) {
    for (final row in RegExp(r'<w:tr(?:\s[^>]*)?>[\s\S]*?</w:tr>')
        .allMatches(xml)) {
      final cells = <String>[];
      for (final cell in RegExp(r'<w:tc(?:\s[^>]*)?>[\s\S]*?</w:tc>')
          .allMatches(row.group(0)!)) {
        cells.add(_textOf(cell.group(0)!).trim());
      }
      if (cells.isEmpty) continue;
      if (cells.every((c) => c.isEmpty)) continue;
      out.writeln(cells.join('\t'));
    }
  }

  /// 只取 `<w:t>` 里的文字：图片、批注锚点这些没有文本节点，自然被跳过。
  static String _textOf(String xml) {
    final buf = StringBuffer();
    for (final m in RegExp(r'<w:t(?:\s[^>]*)?>([\s\S]*?)</w:t>').allMatches(xml)) {
      buf.write(_unescape(m.group(1)!));
    }
    return buf.toString();
  }

  static String _unescape(String s) {
    return s
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }

  /// 一行自由文本 → [单词, 释义, 音标]。
  ///
  /// 词书在 Word 里的常见写法都要能吃下：
  ///   `abandon /əˈbændən/ v. 放弃`（段落，一行一词）
  ///   `abandon\t/əˈbændən/\tv.\t放弃`（表格，单元格已是分列）
  ///   `1. abandon 放弃`（带编号的段落）
  /// 段落走「英文部分 + 中文部分」：第一个汉字之前是词（可能夹音标、词性），之后是释义。
  static List<String> splitLoose(String line) {
    var t = line.trim();
    if (t.isEmpty) return const <String>[];

    // 表格行：单元格本身就是列，别再把整行当成一个词
    if (t.contains('\t')) {
      String word = '';
      String definition = '';
      String phonetic = '';
      for (final raw in t.split('\t')) {
        final c = raw.trim();
        if (c.isEmpty) continue;
        if (phonetic.isEmpty && RegExp(r'^/[^/]+/|^\[[^\]]+\]').hasMatch(c)) {
          phonetic = c;
          continue;
        }
        if (RegExp(r'[\u4e00-\u9fff]').hasMatch(c)) {
          if (definition.isEmpty) definition = c;
          continue;
        }
        if (word.isEmpty) {
          final w = wordRun(c);
          if (w.isNotEmpty) word = w;
        }
      }
      if (word.isEmpty) return const <String>[];
      return <String>[word, definition, phonetic];
    }

    // 行首编号：1. / 1、/ (1) / 1) 之类
    t = t.replaceFirst(RegExp(r'^[\(（]?[0-9]{1,4}[\)）、.．:：]\s*'), '');
    final cn = RegExp(r'[\u4e00-\u9fff]').firstMatch(t);
    if (cn == null) {
      final w = wordRun(t);
      return w.isEmpty ? const <String>[] : <String>[w];
    }
    final head = t.substring(0, cn.start);
    final tail = t.substring(cn.start).trim();
    final word = wordRun(head);
    if (word.isEmpty) return const <String>[];
    final pm =
        RegExp(r'/[^/\s][^/]{0,40}/|\[[^\]\s][^\]]{0,40}\]').firstMatch(head);
    return <String>[word, tail, pm?.group(0)?.trim() ?? ''];
  }

  /// 从「单词 + 音标 + 词性」里取出单词本体，短语（look up）也算一个词。
  static String wordRun(String head) {
    var cut = head.length;
    final slash = head.indexOf('/');
    if (slash >= 0 && slash < cut) cut = slash;
    final bracket = head.indexOf('[');
    if (bracket >= 0 && bracket < cut) cut = bracket;
    final pos = RegExp(
            r'\b(?:n|v|vt|vi|adj|adv|prep|conj|pron|num|art|int|aux|abbr)\s*\.')
        .firstMatch(head);
    if (pos != null && pos.start < cut) cut = pos.start;
    final piece = head.substring(0, cut).trim();
    // 只认字母开头的东西：编号、分隔线、符号一律丢掉
    final m = RegExp(r"[A-Za-z][A-Za-z0-9'\-]*(?:\s+[A-Za-z][A-Za-z0-9'\-]*){0,2}")
        .firstMatch(piece);
    return m?.group(0)?.trim() ?? '';
  }
}
