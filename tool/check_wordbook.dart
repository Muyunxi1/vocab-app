import 'dart:io';

import 'package:vocab_app/wordbook.dart';

void main(List<String> args) {
  final bytes = File(args[0]).readAsBytesSync();
  final text = WordbookReader.docxToText(bytes);
  final lines = text.split('\n');
  stdout.writeln('== docx 抽行 lines=${lines.length}');
  for (final line in lines) {
    stdout.writeln('|${line.replaceAll('\t', ' <TAB> ')}');
  }

  stdout.writeln('== 切词');
  final seen = <String>{};
  for (final line in lines) {
    final cells = WordbookReader.splitLoose(line);
    if (cells.isEmpty) {
      stdout.writeln('  跳过: $line');
      continue;
    }
    final key = cells[0].toLowerCase();
    final tag = seen.add(key) ? '新' : '重复';
    stdout.writeln('  [$tag] word="${cells[0]}" def="${cells.length > 1 ? cells[1] : ''}" '
        'ph="${cells.length > 2 ? cells[2] : ''}"');
  }
}
