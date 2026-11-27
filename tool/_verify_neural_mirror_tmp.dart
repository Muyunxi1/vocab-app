import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// 临时校验脚本：拿 hf-mirror 的散装文件把 lib/neural_tts.dart 里
/// 「镜像源安装」那条路完整跑一遍，确认清单解析、逐文件落地、总量进度都成立。
///
/// 用法：dart run tool/_verify_neural_mirror_tmp.dart <仓库名> <onnx文件名> <输出目录>
Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('用法: dart run tool/_verify_neural_mirror_tmp.dart <repo> <onnx> <dir>');
    exit(64);
  }
  final repo = args[0];
  final onnxName = args[1];
  final staging = Directory(args[2]);
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  staging.createSync(recursive: true);

  final base = 'https://hf-mirror.com/$repo/resolve/main/';
  final listingUrl =
      'https://hf-mirror.com/api/models/$repo/tree/main/espeak-ng-data?recursive=true';

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  final sw = Stopwatch()..start();
  try {
    final listing = jsonDecode(await _fetchText(client, listingUrl));
    if (listing is! List) throw StateError('清单不是数组');
    final espeakFiles = <String>[];
    var espeakBytes = 0;
    for (final row in listing) {
      if (row is! Map) continue;
      if (row['type'] != 'file') continue;
      final path = row['path'];
      final size = row['size'];
      if (path is! String || size is! int) continue;
      espeakFiles.add(path);
      espeakBytes += size;
    }
    print('清单: espeak ${espeakFiles.length} 个文件 $espeakBytes 字节');

    const tokensBytes = 921;
    const onnxBytes = 63201425;
    final total = onnxBytes + tokensBytes + espeakBytes;
    print('总量 ${(total / 1024 / 1024).toStringAsFixed(1)} MB');

    var done = 0;
    var lastPercent = -1;
    var reports = 0;
    void report(int delta) {
      done += delta;
      final percent = total <= 0 ? 0 : done * 100 ~/ total;
      if (percent == lastPercent) return;
      lastPercent = percent;
      reports++;
      if (percent % 10 == 0) {
        print('  $percent%  ${(done / 1024 / 1024).toStringAsFixed(1)} MB  '
            '${sw.elapsed.inSeconds}s');
      }
    }

    final onnxFile = File(p.join(staging.path, onnxName));
    await _downloadInto(client, base + onnxName, onnxFile, report);
    final onnxSize = await onnxFile.length();
    print('onnx ${onnxSize} 字节');
    if (onnxSize != onnxBytes) throw StateError('onnx 大小不符');

    await _downloadInto(
        client, '${base}tokens.txt', File(p.join(staging.path, 'tokens.txt')), report);

    var failed = 0;
    for (final path in espeakFiles) {
      final target = File(p.join(staging.path, path));
      await target.parent.create(recursive: true);
      try {
        await _downloadInto(client, base + path, target, report);
      } catch (e) {
        failed++;
        if (failed <= 3) print('  失败 $path: $e');
      }
    }
    print('espeak 失败 $failed 个');

    var files = 0;
    var bytes = 0;
    String? onnxHit;
    String? tokensHit;
    String? espeakHit;
    for (final e in staging.listSync(recursive: true, followLinks: false)) {
      if (e is File) {
        files++;
        bytes += e.lengthSync();
        final name = p.basename(e.path).toLowerCase();
        if (name.endsWith('.onnx') && onnxHit == null) onnxHit = e.path;
        if (name == 'tokens.txt' && tokensHit == null) tokensHit = e.path;
      } else if (e is Directory &&
          p.basename(e.path).toLowerCase() == 'espeak-ng-data') {
        espeakHit = e.path;
      }
    }
    print('落地 $files 文件, ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB, '
        '进度回调 $reports 次, 耗时 ${sw.elapsed.inSeconds}s');
    print('onnx=${onnxHit != null} tokens=${tokensHit != null} espeak=${espeakHit != null}');
    for (final n in ['phontab', 'phonindex', 'intonations', 'en_dict']) {
      final f = File(p.join(espeakHit ?? '', n));
      print('  $n ${f.existsSync() ? '${f.lengthSync()}B' : '缺失'}');
    }
    exit((onnxHit != null && tokensHit != null && espeakHit != null && failed == 0)
        ? 0
        : 1);
  } finally {
    client.close();
  }
}

Future<String> _fetchText(HttpClient client, String url) async {
  final req = await client.getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.userAgentHeader, 'vocab-app/1.7');
  final resp = await req.close();
  if (resp.statusCode != HttpStatus.ok) {
    await resp.drain<void>();
    throw StateError('清单请求失败 ${resp.statusCode}');
  }
  return utf8.decodeStream(resp);
}

Future<void> _downloadInto(
  HttpClient client,
  String url,
  File target,
  void Function(int delta) onBytes,
) async {
  final req = await client.getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.userAgentHeader, 'vocab-app/1.7');
  final resp = await req.close();
  if (resp.statusCode != HttpStatus.ok) {
    await resp.drain<void>();
    throw StateError('下载失败 ${resp.statusCode} $url');
  }
  IOSink? sink;
  try {
    sink = target.openWrite();
    await for (final chunk in resp) {
      sink.add(chunk);
      onBytes(chunk.length);
    }
    await sink.flush();
    await sink.close();
    sink = null;
  } finally {
    if (sink != null) {
      try {
        await sink.close();
      } on Exception {
        // 忽略
      }
    }
  }
}
