import 'dart:io';

import 'package:vocab_app/csv_stream.dart';

Future<void> main(List<String> args) async {
  for (final path in args) {
    var count = 0;
    String? first;
    String? last;
    final sw = Stopwatch()..start();
    try {
      await for (final rec
          in CsvStreamReader.read(File(path), maxBytes: 200 * 1024 * 1024)) {
        count++;
        first ??= rec;
        last = rec;
        if (rec.contains('abandon')) {
          stdout.writeln('   引号换行记录=${_short(rec)}');
        }
      }
      sw.stop();
      final name = path.split(RegExp(r'[\\/]')).last;
      stdout.writeln('$name 条数=$count 用时=${sw.elapsedMilliseconds}ms');
      stdout.writeln('   first=${_short(first)}');
      stdout.writeln('   last=${_short(last)}');
    } catch (e) {
      sw.stop();
      stdout.writeln('$path 读取失败：$e');
    }
  }
}

String _short(String? s) {
  if (s == null) return '(null)';
  final shown = s.replaceAll('\n', '\\n');
  return shown.length <= 60 ? shown : '${shown.substring(0, 60)}…(${s.length}字)';
}
