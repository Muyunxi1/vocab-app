import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// 临时校验脚本：拿真实的模型包验证 lib/neural_tts.dart 里那套
/// bz2 流式解压 + 手写 tar 解析能不能正确落地。
///
/// 用法：dart run tool/_verify_neural_tar_tmp.dart <tar.bz2> <输出目录>
Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('用法: dart run tool/_verify_neural_tar_tmp.dart <tar.bz2> <目录>');
    exit(64);
  }
  final src = File(args[0]);
  final outDir = Directory(args[1]);
  if (!src.existsSync()) {
    stderr.writeln('找不到 ${src.path}');
    exit(66);
  }
  if (outDir.existsSync()) outDir.deleteSync(recursive: true);
  outDir.createSync(recursive: true);

  final tarFile = File('${src.path}.tar');
  if (tarFile.existsSync()) tarFile.deleteSync();

  final stopwatch = Stopwatch()..start();
  final input = InputFileStream(src.path);
  final output = OutputFileStream(tarFile.path);
  bool ok;
  try {
    ok = BZip2Decoder().decodeStream(input, output);
  } finally {
    input.close();
    output.close();
  }
  print('bz2 解码: $ok, 耗时 ${stopwatch.elapsedMilliseconds}ms, tar ${tarFile.lengthSync()} 字节');

  await _extractTar(tarFile, outDir);
  print('tar 解包耗时 ${stopwatch.elapsedMilliseconds}ms');

  var files = 0;
  var bytes = 0;
  String? onnx;
  String? tokens;
  String? espeak;
  await for (final e in outDir.list(recursive: true, followLinks: false)) {
    if (e is File) {
      files++;
      bytes += e.lengthSync();
      final name = p.basename(e.path).toLowerCase();
      if (name.endsWith('.onnx') && onnx == null) onnx = e.path;
      if (name == 'tokens.txt' && tokens == null) tokens = e.path;
    } else if (e is Directory) {
      if (p.basename(e.path).toLowerCase() == 'espeak-ng-data' && espeak == null) {
        espeak = e.path;
      }
    }
  }
  print('文件 $files 个, 共 ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB');
  print('onnx: ${onnx ?? '没找到'}');
  print('tokens: ${tokens ?? '没找到'}');
  print('espeak-ng-data: ${espeak ?? '没找到'}');
  if (onnx != null) print('onnx 大小 ${(File(onnx).lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB');

  print('---- 目录结构（前 20 行）');
  var shown = 0;
  await for (final e in outDir.list(recursive: true, followLinks: false)) {
    if (shown++ >= 20) break;
    final suffix = e is Directory ? '/' : ' (${(e as File).lengthSync()}B)';
    print('  ${p.relative(e.path, from: outDir.path)}$suffix');
  }

  if (espeak == null) {
    print('结论：包里没有 espeak-ng-data，需要额外下载 espeak-ng-data.tar.bz2');
    exit(1);
  }
  print('结论：包内自带 espeak-ng-data，只需下载模型包');
  exit(0);
}

Future<void> _extractTar(File tar, Directory outDir) async {
  final raf = await tar.open();
  try {
    final length = await tar.length();
    var offset = 0;
    var entries = 0;
    while (offset + 512 <= length) {
      await raf.setPosition(offset);
      final header = await raf.read(512);
      if (header.length < 512) break;
      final name = _tarName(header);
      if (name.isEmpty) break;
      final size = _tarSize(header);
      final type = header[156];
      offset += 512;

      if (type == 0x30 || type == 0 || type == 0x00) {
        final path = _safeJoin(outDir, name);
        if (path != null) {
          final target = File(path);
          await target.parent.create(recursive: true);
          final sink = target.openWrite();
          try {
            var remaining = size;
            var pos = offset;
            while (remaining > 0) {
              await raf.setPosition(pos);
              final want = remaining > 262144 ? 262144 : remaining;
              final chunk = await raf.read(want);
              if (chunk.isEmpty) break;
              sink.add(chunk);
              remaining -= chunk.length;
              pos += chunk.length;
            }
          } finally {
            await sink.close();
          }
          entries++;
        }
      }

      offset += size;
      final pad = size % 512;
      if (pad != 0) offset += 512 - pad;
    }
    print('写入 $entries 个文件');
  } finally {
    await raf.close();
  }
}

String _tarString(Uint8List bytes, int start, int len) {
  final end = (start + len) > bytes.length ? bytes.length : start + len;
  final buf = StringBuffer();
  for (var i = start; i < end; i++) {
    final c = bytes[i];
    if (c == 0) break;
    buf.writeCharCode(c);
  }
  return buf.toString().trim();
}

String _tarName(Uint8List header) {
  final name = _tarString(header, 0, 100);
  final prefix = _tarString(header, 345, 155);
  if (prefix.isEmpty) return name;
  return '$prefix/$name';
}

int _tarSize(Uint8List header) {
  final raw = _tarString(header, 124, 12).replaceAll(' ', '');
  if (raw.isEmpty) return 0;
  return int.tryParse(raw, radix: 8) ?? 0;
}

String? _safeJoin(Directory base, String name) {
  final normalized = p.normalize(name.replaceAll('\\', '/'));
  if (p.isAbsolute(normalized)) return null;
  if (normalized.startsWith('..')) return null;
  final full = p.normalize(p.join(base.path, normalized));
  if (full != base.path && !p.isWithin(base.path, full)) return null;
  return full;
}
