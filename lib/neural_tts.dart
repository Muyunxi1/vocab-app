import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'diag.dart';

/// 一个可下载的离线神经音色。
///
/// 模型不打进 APK：包一旦内置，APK 会从 96MB 涨到 170MB 且每个音色都要重打包。
/// 改成首次使用时下载到应用私有目录，音色想加几个加几个。
class NeuralVoice {
  const NeuralVoice({
    required this.id,
    required this.label,
    required this.note,
    required this.url,
    required this.bytes,
    required this.hfRepo,
    required this.onnxName,
    required this.onnxBytes,
  });

  /// 目录名，同时是设置页里的标识。
  final String id;

  /// 给用户看的中文名。
  final String label;

  /// 一句说明，讲清这是什么声音。
  final String note;

  /// 官方 GitHub 包地址，作为镜像不可用时的备用源。
  final String url;

  /// GitHub 包体积，用于在界面上先讲清代价。
  final int bytes;

  /// HuggingFace 镜像仓库名，例如 csukuangfj/vits-piper-en_US-lessac-medium。
  ///
  /// GitHub 直连在国内实测只有 48KB/s 且会中途断流，hf-mirror 能跑到 1.2MB/s，
  /// 所以镜像散装下载是主源，官方 tar.bz2 只当兜底。
  final String hfRepo;

  /// 镜像仓库里的 onnx 文件名。
  final String onnxName;

  /// onnx 的字节数，用于进度换算和下载后的完整性校验。
  final int onnxBytes;

  /// 下载包的体积。界面统一用十进制 MB，跟手机「设置-应用-存储」里的写法一致，
  /// 否则 67MB 的包会被显示成 64MB，跟下载进度对不上。
  String get sizeLabel => _mb(bytes);

  /// 解压后的占用估算：onnx 63MB + 音素表 + espeak-ng 数据，实测 lessac 为 81,193,997 字节。
  ///
  /// 只讲「下载 67MB」会让用户以为装好也只占这么多，实际翻了一倍。
  String get footprintLabel => _mb(footprintBytes);

  int get footprintBytes => onnxBytes + 17992572;

  static String _mb(int value) => '${(value / 1000000).round()} MB';
}

/// 首批两个音色，都是一男一女的美式英语。
const List<NeuralVoice> neuralVoices = [
  NeuralVoice(
    id: 'lessac',
    label: '清晰女声',
    note: 'Piper lessac，美式英语，吐字干净，适合背单词和读文章',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-medium.tar.bz2',
    bytes: 67230653,
    hfRepo: 'csukuangfj/vits-piper-en_US-lessac-medium',
    onnxName: 'en_US-lessac-medium.onnx',
    onnxBytes: 63201425,
  ),
  NeuralVoice(
    id: 'ryan',
    label: '沉稳男声',
    note: 'Piper ryan，美式英语，音色偏低沉',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-ryan-medium.tar.bz2',
    bytes: 67213100,
    hfRepo: 'csukuangfj/vits-piper-en_US-ryan-medium',
    onnxName: 'en_US-ryan-medium.onnx',
    onnxBytes: 63201425,
  ),
];

/// 离线神经语音：下载语音包、解压、加载模型、合成 wav。
///
/// 模型来自 sherpa-onnx 官方发布的 Piper 包（tar.bz2）。解压是流式的：
/// 先 bz2 解到临时 tar，再自己按 512 字节块解析 tar 写盘，全程不把整包读进内存，
/// 避免 67MB 模型在手机上解压时把堆打爆。
class NeuralTts {
  NeuralTts._();

  static final NeuralTts instance = NeuralTts._();

  static const String _userAgent = 'vocab-app/1.7';

  /// tokens.txt 在镜像上的大小，几乎固定，用作进度总量估算。
  static const int _tokensBytes = 921;

  Directory? _root;
  final Map<String, bool> _installed = {};

  /// 持久化诊断日志文件：纯内存的 Diag 在进程被原生 abort 杀掉时会一起丢，
  /// 关键阶段额外落盘到应用私有目录，下次启动还能读到崩在哪一步。
  File? _logFile;

  /// 合成线程。模型加载与推理全在它里面，主 isolate 只收发文本和文件路径。
  ///
  /// 为什么必须是独立 isolate，三个原因都对应一个用户能看到的故障：
  /// 1. 63MB 的 onnx 在主 isolate 加载要一到三秒，UI 线程占满，系统按 ANR
  ///    直接把进程杀掉——用户说的是「点了神经语音就闪退」，而这在 Dart 侧
  ///    连异常都收不到，日志里也没有痕迹。
  /// 2. 推理占着主 isolate 时，播放器的播完事件只能排队等推理结束才被处理，
  ///    整篇连读每块都要空一拍，听起来就是「一顿一顿」。
  /// 3. native 句柄只在创建它的 isolate 里使用和释放，切音色由它自己 free，
  ///    主线程不碰指针，也就不再有「释放与推理打架」这条崩溃路径。
  Isolate? _worker;
  SendPort? _workerPort;
  ReceivePort? _workerReply;
  Completer<void>? _workerReady;
  String? _workerVoice;
  int _jobSeq = 0;
  final Map<int, Completer<Map<String, Object?>>> _jobs = {};

  /// 有合成任务在跑。这时不主动放模型，否则上下文切过去又得重新加载。
  bool _jobRunning = false;

  /// 是否有安装任务在跑，见 [install]。
  bool _installing = false;

  /// 下载进度回调，参数是 0..1。
  void Function(String id, double progress)? onProgress;

  /// 最近一次失败的原因，界面直接显示这一句。
  String? get lastError => _lastError;
  set lastError(String? value) {
    _lastError = value;
    if (value != null && value.isNotEmpty) Diag.record('神经语音', value);
  }

  String? _lastError;

  String _rootPath(Directory root) => p.join(root.path, 'neural_tts');

  Future<Directory> _ensureRoot() async {
    final cached = _root;
    if (cached != null && await cached.exists()) return cached;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(_rootPath(base));
    await dir.create(recursive: true);
    _root = dir;
    return dir;
  }

  Future<File> _logFileHandle() async {
    final cached = _logFile;
    if (cached != null) return cached;
    final root = await _ensureRoot();
    final file = File(p.join(root.path, 'diag.log'));
    _logFile = file;
    return file;
  }

  /// 写一条诊断记录：同时进内存 Diag 和落盘日志。落盘失败不影响朗读。
  Future<void> _log(String message) async {
    final text = message.trim();
    if (text.isEmpty) return;
    Diag.record('神经语音', text);
    try {
      final file = await _logFileHandle();
      final stamp = DateTime.now().toIso8601String();
      await file.writeAsString('[$stamp] $text\n',
          mode: FileMode.append, flush: true);
    } catch (_) {
      // 日志写不掉不阻断功能
    }
  }

  /// 校验已定位的模型三件套是否完整可用。返回 null 表示通过，否则给一句原因。
  ///
  /// 安装判定只看目录存在不够：散装下载少几个语料文件、onnx 半截，原生加载
  /// 时会直接 abort，Dart 侧收不到异常。这里在进原生引擎前把能查的都查一遍。
  String? _validate(NeuralVoice voice, Map<String, String> located) {
    try {
      final onnx = File(located['onnx']!);
      final tokens = File(located['tokens']!);
      final espeak = Directory(located['espeak']!);

      if (!onnx.existsSync()) return '模型文件缺失（onnx）';
      final onnxLen = onnx.lengthSync();
      if (onnxLen != voice.onnxBytes) {
        return '模型不完整（onnx $onnxLen / ${voice.onnxBytes} 字节），请删掉重下';
      }
      if (!tokens.existsSync()) return '音素表缺失（tokens.txt）';
      if (tokens.lengthSync() < 500) return '音素表不完整，请删掉重下';
      if (!espeak.existsSync()) return '发音语料目录缺失（espeak-ng-data）';

      final files = espeak
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .toList();
      if (files.length < 100) {
        return '发音语料不完整（仅 ${files.length} 个文件），请删掉重下';
      }
      final names = files
          .map((e) => p.basename(e.path).toLowerCase())
          .toSet();
      if (!names.contains('phontab')) return '发音语料缺 phontab 文件，请删掉重下';
      if (!names.any((n) => n.startsWith('en'))) {
        return '发音语料缺英文数据，请删掉重下';
      }
      return null;
    } on FileSystemException catch (e) {
      debugPrint('neural tts validate fs error: $e');
      return '模型目录读取失败，请删掉重下';
    }
  }

  Future<Directory> _voiceDir(String id) async {
    final root = await _ensureRoot();
    return Directory(p.join(root.path, id));
  }

  /// 扫一遍已装状态。安装判定不只看目录存在，还要真的找得到模型三个部件。
  Future<void> refresh() async {
    final root = await _ensureRoot();
    for (final voice in neuralVoices) {
      _installed[voice.id] = _locate(Directory(p.join(root.path, voice.id))) != null;
    }
    final installed = neuralVoices
        .where((v) => _installed[v.id] == true)
        .map((v) => v.id)
        .join(',');
    await _log('刷新已装音色：${installed.isEmpty ? "无" : installed}');
  }

  bool isInstalled(String id) => _installed[id] ?? false;

  /// 解压后在目录里找齐 onnx / tokens.txt / espeak-ng-data。
  ///
  /// 不写死路径：官方包结构是 `<包名>/en_US-lessac-medium.onnx` 这种，
  /// 但不同音色的命名不一样，扫描比猜路径可靠。
  Map<String, String>? _locate(Directory dir) {
    if (!dir.existsSync()) return null;
    String? onnx;
    String? tokens;
    String? espeak;
    try {
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          final name = p.basename(entity.path).toLowerCase();
          if (name == 'tokens.txt' && tokens == null) {
            tokens = entity.path;
          } else if (name.endsWith('.onnx') && onnx == null) {
            onnx = entity.path;
          }
        } else if (entity is Directory) {
          if (p.basename(entity.path).toLowerCase() == 'espeak-ng-data' &&
              espeak == null) {
            espeak = entity.path;
          }
        }
      }
    } on FileSystemException {
      return null;
    }
    if (onnx == null || tokens == null || espeak == null) return null;
    return {'onnx': onnx, 'tokens': tokens, 'espeak': espeak};
  }

  /// 下载并安装一个音色。失败时抛异常，调用方负责显示原因。
  ///
  /// 同一时刻只允许一个安装任务：设置页自己的 _installing 只能在当前页面挡住重复点击，
  /// 退出页面再进来就绕过了，两个音色会同时往 .tmp 里写，互相踩。
  Future<void> install(NeuralVoice voice) async {
    if (_installing) {
      throw const NeuralTtsException('已经有一个语音包在下载，等它下完再试');
    }
    _installing = true;
    try {
      await _installLocked(voice);
    } finally {
      _installing = false;
    }
  }

  Future<void> _installLocked(NeuralVoice voice) async {
    final root = await _ensureRoot();
    final tmp = Directory(p.join(root.path, '.tmp'));
    await tmp.create(recursive: true);

    final archive = File(p.join(tmp.path, '${voice.id}.tar.bz2'));
    final staging = Directory(p.join(tmp.path, '${voice.id}_unpack'));

    try {
      await _resetDir(staging);

      // 主源是 hf-mirror 散装文件：GitHub 直连实测 48KB/s 且会断流，
      // 镜像能跑到 1.2MB/s，67MB 的包从二十多分钟降到一两分钟。
      Object? mirrorError;
      try {
        await _installFromMirror(voice, staging);
      } catch (error) {
        mirrorError = error;
        await _resetDir(staging);
        // 兜底：官方 tar.bz2（一个请求、结构完整），镜像挂掉时仍能装
        try {
          await _installFromArchive(voice, staging, archive);
        } catch (archiveError) {
          throw NeuralTtsException(
            '语音包下载失败。镜像源：$mirrorError；官方源：$archiveError',
          );
        }
      }

      final located = _locate(staging);
      if (located == null) {
        throw const NeuralTtsException('语音包下载后没找到模型文件，可能不完整，请重试');
      }
      final bad = _validate(voice, located);
      if (bad != null) {
        await _log('安装校验失败 ${voice.id}: $bad');
        throw NeuralTtsException('语音包不完整：$bad');
      }

      // 校验通过再落到正式目录，避免半截模型被当成已安装
      final target = Directory(p.join(root.path, voice.id));
      if (await target.exists()) await target.delete(recursive: true);
      await staging.rename(target.path);
      _installed[voice.id] = true;
      onProgress?.call(voice.id, 1.0);
    } finally {
      if (await archive.exists()) {
        try {
          await archive.delete();
        } on FileSystemException {
          // 临时文件删不掉不影响使用，下次安装会覆盖
        }
      }
      if (await staging.exists()) {
        try {
          await staging.delete(recursive: true);
        } on FileSystemException {
          // 同上
        }
      }
    }
  }

  Future<void> _resetDir(Directory dir) async {
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
  }

  /// 官方源：下载一个 tar.bz2 再解压。
  ///
  /// GitHub Releases 直连在国内基本连不通（实测 "Connection closed before
  /// full header was received"，连响应头都收不到），所以先走两个公开反代，
  /// 最后才试原地址。反代都失败时把最后一个原因抛出去，别把真错误吞掉。
  Future<void> _installFromArchive(
    NeuralVoice voice,
    Directory staging,
    File archive,
  ) async {
    final candidates = <String>[
      'https://ghproxy.net/${voice.url}',
      'https://gh-proxy.com/${voice.url}',
      voice.url,
    ];
    Object? lastError;
    for (final url in candidates) {
      try {
        await _download(url, archive, (v) => onProgress?.call(voice.id, v));
        // 先按已知包体积粗查一遍，坏包不进去解压浪费一轮时间
        final size = await archive.length();
        if (size < voice.bytes * 98 ~/ 100) {
          throw NeuralTtsException('语音包不完整（$size / ${voice.bytes} 字节）');
        }
        await _extractBz2(archive, staging);
        return;
      } catch (error) {
        lastError = error;
        // 半截包留着会让下一次解压读到坏文件
        if (await archive.exists()) {
          try {
            await archive.delete();
          } on FileSystemException {
            // 删不掉下次覆盖写
          }
        }
        await _resetDir(staging);
      }
    }
    throw NeuralTtsException('$lastError');
  }

  /// 镜像源：直连 hf-mirror 把 onnx / tokens.txt / espeak-ng-data 逐个下到位。
  ///
  /// espeak 语料有 355 个小文件，清单从镜像 API 取，避免把文件列表硬编码进 APK。
  Future<void> _installFromMirror(NeuralVoice voice, Directory staging) async {
    final base = 'https://hf-mirror.com/${voice.hfRepo}/resolve/main/';
    final listingUrl = 'https://hf-mirror.com/api/models/${voice.hfRepo}'
        '/tree/main/espeak-ng-data?recursive=true';

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final listing = await _fetchJson(client, listingUrl);
      if (listing is! List) {
        throw const NeuralTtsException('镜像返回的文件清单无法识别');
      }

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
      if (espeakFiles.isEmpty) {
        throw const NeuralTtsException('镜像里的 espeak 语料清单是空的');
      }

      // 总量要先知道才能给百分比，否则进度条只能一直转圈
      final total = voice.onnxBytes + _tokensBytes + espeakBytes;
      var done = 0;
      var lastPercent = -1;
      void report(int delta) {
        done += delta;
        // 单文件重试会把同一段字节重算一次，这里封顶 99%，装完再发 1.0
        final percent = total <= 0 ? 0 : (done * 100 ~/ total).clamp(0, 99);
        if (percent == lastPercent) return;
        lastPercent = percent;
        onProgress?.call(voice.id, percent / 100.0);
      }

      final onnxFile = File(p.join(staging.path, voice.onnxName));
      await _downloadWithRetry(
        client,
        _mirrorUrl(base, voice.onnxName),
        onnxFile,
        report,
      );
      final onnxSize = await onnxFile.length();
      if (onnxSize != voice.onnxBytes) {
        throw NeuralTtsException('onnx 下载不完整（$onnxSize / ${voice.onnxBytes} 字节）');
      }

      final tokensFile = File(p.join(staging.path, 'tokens.txt'));
      await _downloadWithRetry(client, _mirrorUrl(base, 'tokens.txt'), tokensFile, report);
      final tokensSize = await tokensFile.length();
      // 音素表是几百行的字符映射，太小说明拿到的不是这份模型要的那份。
      // 不校验的话，坏包要等用户点朗读、引擎加载失败时才暴露。
      if (tokensSize < 500) {
        throw NeuralTtsException('音素表下载不完整（$tokensSize 字节）');
      }

      for (final path in espeakFiles) {
        final target = File(p.join(staging.path, path));
        await target.parent.create(recursive: true);
        await _downloadWithRetry(client, _mirrorUrl(base, path), target, report);
      }

      // 少下几个音素文件时引擎会静默读错音，这里补最后一道完整性检查
      if (espeakFiles.length < 100) {
        throw NeuralTtsException('音素数据不完整（只有 ${espeakFiles.length} 个文件）');
      }
    } finally {
      client.close();
    }
  }

  /// 清单里存在 `voices/!v/Mr serious` 这种带空格的文件名，
  /// 直接拼进 URL 会失败，必须逐段编码。
  String _mirrorUrl(String base, String relative) {
    final encoded = relative.split('/').map(Uri.encodeComponent).join('/');
    return '$base$encoded';
  }

  /// 355 个小文件里只要有一个失败整条镜像路就废了，所以单个文件给一次重试。
  Future<void> _downloadWithRetry(
    HttpClient client,
    String url,
    File target,
    void Function(int delta) onBytes,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _downloadInto(client, url, target, onBytes);
        return;
      } catch (error) {
        lastError = error;
      }
    }
    throw NeuralTtsException('下载失败：$lastError');
  }

  Future<Object?> _fetchJson(HttpClient client, String url) async {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    final resp = await req.close();
    if (resp.statusCode != HttpStatus.ok) {
      await resp.drain<void>();
      throw NeuralTtsException('镜像清单请求失败，服务器返回 ${resp.statusCode}');
    }
    return jsonDecode(await utf8.decodeStream(resp));
  }

  /// 单文件下载，按块回调字节增量，交给调用方自己换算总进度。
  Future<void> _downloadInto(
    HttpClient client,
    String url,
    File target,
    void Function(int delta) onBytes,
  ) async {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    final resp = await req.close();
    if (resp.statusCode != HttpStatus.ok) {
      await resp.drain<void>();
      throw NeuralTtsException('下载失败，服务器返回 ${resp.statusCode}');
    }
    // 先写 .part 再改名：中途断网、杀进程只留下半截临时文件，
    // 不会被当成「已装好」的模型去加载。
    final tmp = File('${target.path}.part');
    IOSink? sink;
    var written = 0;
    try {
      sink = tmp.openWrite();
      // 卡住不动的连接要能自己断，否则进度条永远停在某个百分比
      await for (final chunk in resp.timeout(const Duration(seconds: 60))) {
        sink.add(chunk);
        written += chunk.length;
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
          // 出错时关闭失败无需处理
        }
      }
    }
    final expected = resp.contentLength;
    if (expected > 0 && written != expected) {
      // 有的镜像（实测 hf-mirror 经部分移动网络时）给出的 Content-Length
      // 和实际实体差几个字节，比如 tokens.txt 声明 946、实际 921。
      // 这种偏差不是下载断了，硬判失败会把整条可用路径废掉，
      // 所以只在小幅偏差内放行；真正的完整性由调用方按已知字节数校验。
      if (!_withinSlack(expected, written)) {
        throw NeuralTtsException('下载不完整（$written / $expected 字节）');
      }
    }
    await tmp.rename(target.path);
  }

  /// 声明长度与实际字节的允许偏差：2% 且不超过 4KB。
  ///
  /// 25 字节那种偏差常见于代理改写，而真正的断流一次少几十 KB 以上。
  static bool _withinSlack(int expected, int written) {
    final diff = (expected - written).abs();
    final tolerance = expected * 2 ~/ 100;
    final limit = tolerance > 4096 ? 4096 : tolerance;
    return diff <= (limit < 64 ? 64 : limit);
  }

  /// 删除已装音色，释放空间。模型文件约 63MB，加上音素表约 81MB。
  Future<void> uninstall(NeuralVoice voice) async {
    // 先让合成线程把模型放掉再删目录：onx 被映射着直接删，句柄会指向不存在的文件
    if (_workerVoice == voice.id) {
      await _sendFree();
    }
    final dir = await _voiceDir(voice.id);
    if (await dir.exists()) await dir.delete(recursive: true);
    // 只删模型不清缓存的话，这个音色合成过的 wav 还留在 .cache 里继续占空间
    await _clearCacheFor(voice.id);
    _installed[voice.id] = false;
  }

  /// 清掉某个音色的合成缓存。缓存文件名带音色前缀，所以能精确定位。
  Future<void> _clearCacheFor(String voiceId) async {
    try {
      final root = await _ensureRoot();
      final dir = Directory(p.join(root.path, '.cache'));
      if (!await dir.exists()) return;
      final prefix = '${_voiceKey(voiceId)}_';
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.wav')) continue;
        if (!p.basename(entity.path).startsWith(prefix)) continue;
        try {
          await entity.delete();
        } on FileSystemException {
          continue;
        }
      }
    } on FileSystemException {
      // 清缓存失败不影响删除音色
    }
  }

  /// 音色 id 进文件名前先压成安全字符，避免带斜杠之类把路径拼坏。
  String _voiceKey(String voiceId) =>
      voiceId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');

  Future<void> _download(
    String url,
    File target,
    void Function(double) onProgress,
  ) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    IOSink? sink;
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final resp = await req.close();
      if (resp.statusCode != HttpStatus.ok) {
        throw NeuralTtsException('下载失败，服务器返回 ${resp.statusCode}');
      }
      final total = resp.contentLength;
      sink = target.openWrite();
      var received = 0;
      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (total > 0 && !_withinSlack(total, received)) {
        throw const NeuralTtsException('下载不完整，请检查网络后重试');
      }
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } on Exception {
          // 出错时关闭失败无需处理
        }
      }
      client.close();
    }
  }

  /// bz2 解到临时 tar，再逐条写盘。
  ///
  /// 这两步是纯 CPU/IO：几十 MB 的包在主 isolate 上要十几秒，期间连
  /// 「正在解压」都刷不出来，用户看到的就是装模型时整个 App 卡死。
  /// 整段挪到后台 isolate，主线程只等结果。
  Future<void> _extractBz2(File bz2, Directory outDir) async {
    await Isolate.run(() => _unpackArchive(bz2.path, outDir.path));
  }
  /// 起合成线程，等它把原生库绑定好再返回。
  ///
  /// 绑定（initBindings）必须在真正创建 OfflineTts 的那个 isolate 里做：
  /// 函数表是进程级静态变量，但句柄的生命周期是按 isolate 划分的，
  /// 让创建和使用落在同一个 isolate 里，才能谈得上安全释放。
  Future<void> _ensureWorker() async {
    final pending = _workerReady;
    if (pending != null && !pending.isCompleted) return pending.future;
    if (_worker != null && _workerPort != null && pending != null) return;

    final ready = Completer<void>();
    _workerReady = ready;

    final reply = ReceivePort();
    _workerReply = reply;
    reply.listen((msg) {
      if (msg is Map && msg['ready'] == true) {
        _workerPort = msg['port'] as SendPort?;
        if (!ready.isCompleted) ready.complete();
        return;
      }
      // 分段阶段消息：只落盘留痕，不进等待队列。原生 abort 前最后一条阶段
      // 消息能帮下次启动定位崩在绑定、建引擎还是推理哪一步。
      if (msg is Map && msg['phase'] != null) {
        final detail = (msg['errorDetail'] ?? msg['detail'] ?? '').toString();
        final voice = (msg['voiceId'] ?? '').toString();
        _log('worker ${msg['phase']}${voice.isEmpty ? '' : ' $voice'}'
            '${detail.isEmpty ? '' : ' · $detail'}');
        return;
      }
      if (msg is Map) _onWorkerReply(msg);
    });

    final exit = ReceivePort();
    exit.listen((_) {
      exit.close();
      _onWorkerDead('合成线程意外退出，已重置，请再点一次');
    });

    try {
      _worker = await Isolate.spawn(
        _neuralWorker,
        reply.sendPort,
        onExit: exit.sendPort,
        onError: exit.sendPort,
        debugName: 'neural-tts',
      );
    } catch (e) {
      debugPrint('neural tts spawn failed: $e');
      _workerReady = null;
      _worker = null;
      _workerPort = null;
      reply.close();
      _workerReply = null;
      exit.close();
      Diag.record('神经语音', '合成线程起不来，已提示重开');
      throw const NeuralTtsException('语音合成线程起不来，重开一次 App 再试');
    }
    return ready.future;
  }

  /// 合成线程的回复：按 seq 找对应的等待者。
  void _onWorkerReply(Map<dynamic, dynamic> msg) {
    final seq = msg['seq'];
    if (seq is! int) return;
    final job = _jobs.remove(seq);
    if (job != null && !job.isCompleted) {
      job.complete(Map<String, Object?>.from(msg));
    }
  }

  /// 合成线程没了（崩溃、被系统回收、原生 abort）。
  ///
  /// 这一支以前根本不存在：主 isolate 里那张 table 一旦出问题就是整个进程没了，
  /// 现在最坏只是这一个音色这次读不出来，下一次点会重建线程。
  void _onWorkerDead(String reason) {
    final hadWorker = _worker != null;
    _worker = null;
    _workerPort = null;
    _workerVoice = null;
    _jobRunning = false;

    final ready = _workerReady;
    _workerReady = null;
    if (ready != null && !ready.isCompleted) ready.complete();

    final jobs = _jobs.values.toList();
    _jobs.clear();
    for (final job in jobs) {
      if (!job.isCompleted) {
        job.complete(<String, Object?>{'ok': false, 'error': reason});
      }
    }

    final reply = _workerReply;
    _workerReply = null;
    reply?.close();
    if (hadWorker) {
      Diag.record('神经语音', reason);
      // 线程退出（含原生 abort 被杀）把原因落盘，下次启动还能查到。
      unawaited(_log('worker dead: $reason'));
    }
  }

  /// 让合成线程把模型放掉（约 200MB）。下次合成会自动重新加载。
  Future<void> _sendFree() async {
    final port = _workerPort;
    if (port == null) return;
    final seq = ++_jobSeq;
    final done = Completer<Map<String, Object?>>();
    _jobs[seq] = done;
    port.send(<String, Object?>{'kind': 'free', 'seq': seq});
    try {
      await done.future.timeout(const Duration(seconds: 20));
      _workerVoice = null;
    } on TimeoutException {
      _jobs.remove(seq);
    }
  }

  Map<String, String>? _locateSync(String voiceId) {
    final root = _root;
    if (root == null) return null;
    return _locate(Directory(p.join(root.path, voiceId)));
  }

  /// 合成一句，返回 wav 文件路径。同一句同音色同语速命中缓存，不重复推理。
  Future<String> synthesize({
    required String text,
    required String voiceId,
    double speed = 1.0,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const NeuralTtsException('没有要读的内容');
    await _log('请求合成 $voiceId，文本长度 ${trimmed.length}');
    final root = await _ensureRoot();

    final cacheDir = Directory(p.join(root.path, '.cache'));
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    final key = sha1
        .convert(utf8.encode('$voiceId|${speed.toStringAsFixed(2)}|$trimmed'))
        .toString();
    final file = File(p.join(cacheDir.path, '${_voiceKey(voiceId)}_$key.wav'));
    if (await file.exists()) {
      // 命中也要验：上次合成写到一半被杀，留下的半截 wav 同样「存在」，
      // 直接拿去播就是一声不吭或者放半句，用户会以为这词没声音。
      if (await _isValidWav(file)) return file.path;
      try {
        await file.delete();
      } on FileSystemException {
        // 删不掉也没关系，下面会覆盖写
      }
    }

    final located = _locateSync(voiceId);
    if (located == null) {
      throw const NeuralTtsException('这个音色的语音包还没下载好');
    }
    final voice = neuralVoices.firstWhere(
      (v) => v.id == voiceId,
      orElse: () => neuralVoices.first,
    );
    final bad = _validate(voice, located);
    if (bad != null) {
      await _log('合成前校验失败 $voiceId: $bad');
      throw NeuralTtsException(bad);
    }

    // 从这里开始全部交给合成线程：主 isolate 只等一个「文件写好了」的回复，
    // 加载模型和推理都不占 UI 线程，播完事件能照常处理。
    await _ensureWorker();
    final port = _workerPort;
    if (port == null) {
      throw const NeuralTtsException('语音合成线程没起来，重开一次 App 再试');
    }
    // 换了音色就让线程先把旧模型放掉，避免两个 63MB 模型同时驻留
    if (_workerVoice != null && _workerVoice != voiceId) {
      await _sendFree();
    }

    final seq = ++_jobSeq;
    final done = Completer<Map<String, Object?>>();
    _jobs[seq] = done;
    _jobRunning = true;
    port.send(<String, Object?>{
      'kind': 'synth',
      'seq': seq,
      'text': trimmed,
      'voiceId': voiceId,
      'speed': speed,
      'out': file.path,
      'paths': located,
    });

    Map<String, Object?> reply;
    try {
      reply = await done.future.timeout(_jobTimeout(trimmed));
    } on TimeoutException {
      throw const NeuralTtsException('这一句合成超时了，换一句或换个音色试试');
    } finally {
      _jobs.remove(seq);
      _jobRunning = false;
    }
    if (reply['ok'] != true) {
      final error = (reply['error'] ?? '').toString();
      throw NeuralTtsException(error.isEmpty ? '合成失败，换一句试试' : error);
    }
    _workerVoice = voiceId;
    // 线程已经校验过一次长度，这里再按文件头确认一遍，防止写到一半被系统杀掉
    if (!await _isValidWav(file)) {
      throw const NeuralTtsException('合成出来的音频不完整，请再试一次');
    }
    unawaited(_trimCache(cacheDir));
    return file.path;
  }

  /// 一句合成最多等多久。
  ///
  /// 合成不在主线程了，所以不必再压到「一眨眼」的量级：第一次要算上加载模型
  /// 的三四秒，之后按文本长度线性放宽，40 词一句约 19 秒，上限 90 秒。
  Duration _jobTimeout(String text) {
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    final seconds = 12 + words ~/ 6;
    return Duration(seconds: seconds > 90 ? 90 : seconds);
  }

  // 写 wav 的动作挪到类外的 _writeWavFile：它只碰文件与字节，不读 App 状态，
  // 放在顶层才能被合成线程直接调用。

  /// 缓存文件是不是一份完整的 wav：头齐全、data 段长度与文件长度对得上。
  ///
  /// 只判断「文件存在」是不够的——写到一半被杀就是这个半截文件。
  static Future<bool> _isValidWav(File file) async {
    try {
      final len = await file.length();
      if (len < 44) return false;
      final raf = await file.open();
      try {
        await raf.setPosition(0);
        final head = await raf.read(12);
        if (head.length < 12) return false;
        if (String.fromCharCodes(head.sublist(0, 4)) != 'RIFF') return false;
        if (String.fromCharCodes(head.sublist(8, 12)) != 'WAVE') return false;
        await raf.setPosition(36);
        final tag = await raf.read(4);
        if (String.fromCharCodes(tag) != 'data') return false;
        await raf.setPosition(40);
        final sizeBytes = await raf.read(4);
        if (sizeBytes.length < 4) return false;
        final dataLen =
            ByteData.sublistView(sizeBytes).getUint32(0, Endian.little);
        return len == 44 + dataLen;
      } finally {
        await raf.close();
      }
    } on FileSystemException {
      return false;
    }
  }

  /// 合成缓存按「字节上限 + 条数上限」双向裁剪。
  ///
  /// 只按条数限制是不靠谱的：一条 wav 的大小跟句子长度走，长句子一条几百 KB，
  /// 300 条攒下来能吃掉几十 MB，而且用户完全看不到。
  static const int _cacheMaxBytes = 48000000; // 48MB
  static const int _cacheMaxFiles = 300;

  Future<void> _trimCache(Directory dir) async {
    try {
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.wav'))
          .cast<File>()
          .toList();
      if (files.length <= 1) return;
      final stats = <MapEntry<File, DateTime>>[];
      var totalBytes = 0;
      for (final f in files) {
        try {
          final st = await f.stat();
          totalBytes += st.size;
          stats.add(MapEntry(f, st.modified));
        } on FileSystemException {
          continue;
        }
      }
      if (totalBytes <= _cacheMaxBytes && stats.length <= _cacheMaxFiles) return;
      stats.sort((a, b) => a.value.compareTo(b.value));
      // 从最旧的开始删，删到字节数和条数都回到线内；最后一条永远留着
      var i = 0;
      while (i < stats.length - 1 &&
          (totalBytes > _cacheMaxBytes || stats.length - i > _cacheMaxFiles)) {
        final f = stats[i].key;
        try {
          final size = await f.length();
          await f.delete();
          totalBytes -= size;
        } on FileSystemException {
          // 删不掉就跳过，继续处理下一条
        }
        i++;
      }
    } on FileSystemException {
      // 清缓存失败不影响发音
    }
  }

  /// 释放模型占用的内存。切走音色或退出朗读时调用。
  ///
  /// 放模型这件事交给合成线程自己完成，主线程不碰 native 句柄，
  /// 也就不存在「释放时正好推理到一半」这条崩溃路径。
  /// 有任务在跑时不打断，留着下次合成继续用。
  void release() {
    if (_workerPort == null || _jobRunning) return;
    unawaited(_sendFree());
  }

  Future<int> installedBytes(NeuralVoice voice) async {
    final dir = await _voiceDir(voice.id);
    if (!await dir.exists()) return 0;
    return _dirBytes(dir);
  }

  /// 所有已装音色一共占多少，含模型、词表和音素库。
  Future<int> modelsBytes() async {
    var total = 0;
    for (final voice in neuralVoices) {
      if (!isInstalled(voice.id)) continue;
      total += await installedBytes(voice);
    }
    return total;
  }

  /// 合成结果缓存目录。
  Future<Directory> _cacheDir() async {
    final root = await _ensureRoot();
    final dir = Directory(p.join(root.path, '.cache'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 合成缓存占了多少字节。
  Future<int> cacheBytes() async => _dirBytes(await _cacheDir());

  /// 下载临时目录 + 没装完的音色目录一共占多少。
  ///
  /// 这两块必须算进「存储占用」：下载中断会留下 .tmp 和半截的语音目录，
  /// 不算的话用户看到模型目录占着几十 MB、清缓存却只释放几百 KB，
  /// 会以为缓存根本没清掉。
  Future<int> pendingBytes() async {
    final root = await _ensureRoot();
    var total = 0;
    final tmp = Directory(p.join(root.path, '.tmp'));
    if (await tmp.exists()) total += await _dirBytes(tmp);
    for (final voice in neuralVoices) {
      if (isInstalled(voice.id)) continue;
      final dir = Directory(p.join(root.path, voice.id));
      if (await dir.exists()) total += await _dirBytes(dir);
    }
    return total;
  }

  /// 清掉合成缓存，返回释放了多少字节。模型文件不动，下次朗读重新合成一遍。
  Future<int> clearCache() async {
    final dir = await _cacheDir();
    var freed = 0;
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        try {
          final size = await entity.length();
          await entity.delete();
          // 删成功才记账：删不掉也加进「已释放」，用户看到的数字就是假的
          freed += size;
        } on FileSystemException {
          // 删不掉就跳过，不影响剩下的清理
        }
      }
    } on FileSystemException {
      // 目录读不动就当没缓存
    }
    return freed;
  }

  /// 递归累加一个目录下所有文件的字节数，读不到就当 0。
  static Future<int> _dirBytes(Directory dir) async {
    var total = 0;
    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        try {
          total += await entity.length();
        } on FileSystemException {
          continue;
        }
      }
    } on FileSystemException {
      return total;
    }
    return total;
  }
}

class NeuralTtsException implements Exception {
  const NeuralTtsException(this.message);

  final String message;

  @override
  String toString() => message;
}

// ---------------- 合成线程 ----------------
//
// 这个 isolate 只做一件事：加载模型、推理、写 wav。
// OfflineTts 的句柄由它自己创建、自己释放，主 isolate 只通过消息要文件。

/// 合成线程入口：绑定原生库 → 回传自己的收件口 → 循环处理 synth/free。
Future<void> _neuralWorker(SendPort replyTo) async {
  final inbox = ReceivePort();
  try {
    sherpa.initBindings();
  } catch (e) {
    // 绑定失败就把原因回给主线程：界面上只给一句话，原始异常留在日志里
    debugPrint('neural worker initBindings failed: $e');
    replyTo.send(<String, Object?>{
      'ready': false,
      'error': '语音引擎的底层库没加载起来，建议重新安装这个包',
    });
    inbox.close();
    return;
  }
  replyTo.send(<String, Object?>{'ready': true, 'port': inbox.sendPort});
  replyTo.send(<String, Object?>{'phase': 'bindings_ok'});

  sherpa.OfflineTts? engine;
  String? engineVoice;

  // 刻意不用 `engine?.free()`：sherpa 的 free 直接 destroyOfflineTts(ptr)，
  // 不判空，对空指针再来一次就是原生崩溃，Dart 侧连异常都没有。
  void dropEngine() {
    final current = engine;
    engine = null;
    engineVoice = null;
    if (current == null) return;
    try {
      if (current.ptr != nullptr) current.free();
    } catch (e) {
      debugPrint('neural worker free failed: $e');
    }
  }

  await for (final raw in inbox) {
    if (raw is! Map) continue;
    final kind = raw['kind'];
    if (kind == 'quit') break;
    final seq = raw['seq'] is int ? raw['seq'] as int : 0;

    if (kind == 'free') {
      dropEngine();
      replyTo.send(<String, Object?>{'seq': seq, 'ok': true});
      continue;
    }
    if (kind != 'synth') continue;

    try {
      final voiceId = (raw['voiceId'] ?? '').toString();
      final paths = Map<String, String>.from(raw['paths'] as Map);
      replyTo.send(<String, Object?>{
        'phase': 'synth_start',
        'voiceId': voiceId,
        'detail': 'onnx=${paths['onnx']}',
      });
      if (engine == null || engineVoice != voiceId) {
        dropEngine();
        replyTo.send(<String, Object?>{
          'phase': 'engine_create',
          'voiceId': voiceId,
        });
        engine = _createEngine(paths);
        engineVoice = voiceId;
        replyTo.send(<String, Object?>{
          'phase': 'engine_ready',
          'voiceId': voiceId,
          'detail': 'ptr=${engine == null ? "null" : engine!.ptr.address}',
        });
      }
      final audio = engine!.generate(
        text: (raw['text'] ?? '').toString(),
        speed: raw['speed'] is num ? (raw['speed'] as num).toDouble() : 1.0,
      );
      replyTo.send(<String, Object?>{
        'phase': 'generate_done',
        'detail': 'samples=${audio.samples.length} sr=${audio.sampleRate}',
      });
      if (audio.samples.isEmpty || audio.sampleRate <= 0) {
        replyTo.send(<String, Object?>{
          'seq': seq,
          'ok': false,
          'error': '合成没有返回音频，换一句试试',
        });
        continue;
      }
      await _writeWavFile(
        File((raw['out'] ?? '').toString()),
        audio.samples,
        audio.sampleRate,
      );
      replyTo.send(<String, Object?>{'seq': seq, 'ok': true});
    } catch (e) {
      // 合成线程自己不吞不崩：界面文案给人看，原始异常只进日志
      debugPrint('neural worker synth failed: $e');
      replyTo.send(<String, Object?>{
        'phase': 'synth_failed',
        'detail': '合成线程异常',
        'errorDetail': e.toString(),
      });
      replyTo.send(<String, Object?>{
        'seq': seq,
        'ok': false,
        'error': '合成失败，换一句或换个音色试试',
      });
    }
  }

  dropEngine();
  inbox.close();
}

/// 在合成线程里创建一个语音引擎，用完必须由创建它的线程 free。
sherpa.OfflineTts _createEngine(Map<String, String> paths) {
  final tts = sherpa.OfflineTts(
    sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        vits: sherpa.OfflineTtsVitsModelConfig(
          model: paths['onnx']!,
          tokens: paths['tokens']!,
          dataDir: paths['espeak']!,
        ),
        // 单线程：推理本来就在后台跑，不必和前台抢核；2 线程的线程池会把
        // 峰值内存再抬一截，低端机上更容易被系统直接杀掉。
        numThreads: 1,
      ),
    ),
  );
  if (tts.ptr == nullptr) {
    throw const NeuralTtsException('语音模型加载失败，可以删掉这个音色重新下载');
  }
  return tts;
}

/// 把浮点采样写成 16 位单声道 wav，先写 .part 再改名。
///
/// 半截 wav 顶替正片比没有声音更糟：下次命中缓存，用户会以为这个词坏了。
Future<void> _writeWavFile(File file, Float32List samples, int sampleRate) async {
  final data = Uint8List(44 + samples.length * 2);
  final view = ByteData.sublistView(data);
  data.setRange(0, 4, ascii.encode('RIFF'));
  view.setUint32(4, 36 + samples.length * 2, Endian.little);
  data.setRange(8, 12, ascii.encode('WAVE'));
  data.setRange(12, 16, ascii.encode('fmt '));
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little); // PCM
  view.setUint16(22, 1, Endian.little); // 单声道
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, sampleRate * 2, Endian.little);
  view.setUint16(32, 2, Endian.little);
  view.setUint16(34, 16, Endian.little);
  data.setRange(36, 40, ascii.encode('data'));
  view.setUint32(40, samples.length * 2, Endian.little);

  var offset = 44;
  for (final sample in samples) {
    final value = (sample * 32767.0).clamp(-32768.0, 32767.0).toInt();
    view.setInt16(offset, value, Endian.little);
    offset += 2;
  }
  final tmp = File('${file.path}.part');
  try {
    await tmp.writeAsBytes(data, flush: true);
    await tmp.rename(file.path);
  } on FileSystemException {
    try {
      await tmp.delete();
    } on FileSystemException {
      // 临时文件清不掉也不影响这次失败
    }
    rethrow;
  }
}

// ---------------- 后台 isolate 里的解包 ----------------
//
// 这几个函数必须放在类外：它们跑在 Isolate.run 里，只吃路径字符串，
// 不碰 App 的任何状态，所以能安全地搬离主 isolate。

/// bz2 解到临时 tar，再把 tar 逐条展开到 [outDirPath]。
void _unpackArchive(String bz2Path, String outDirPath) {
  final tarPath = '$bz2Path.tar';
  final tarFile = File(tarPath);
  final input = InputFileStream(bz2Path);
  final output = OutputFileStream(tarPath);
  try {
    final ok = BZip2Decoder().decodeStream(input, output);
    if (!ok) throw const NeuralTtsException('语音包解压失败，文件可能损坏');
  } finally {
    input.close();
    output.close();
  }
  try {
    _unpackTar(tarFile, outDirPath);
  } finally {
    try {
      if (tarFile.existsSync()) tarFile.deleteSync();
    } on FileSystemException {
      // 临时 tar 删不掉不影响本次安装
    }
  }
}

/// 按 tar 规范同步逐块展开：512 字节头 + 数据 + 512 字节对齐。
void _unpackTar(File tar, String outDirPath) {
  final raf = tar.openSync();
  try {
    final length = tar.lengthSync();
    var offset = 0;
    while (offset + 512 <= length) {
      raf.setPositionSync(offset);
      final header = raf.readSync(512);
      if (header.length < 512) break;
      final name = _tarNameOf(header);
      if (name.isEmpty) break; // 结束标记
      final size = _tarSizeOf(header);
      final type = header[156];
      offset += 512;

      // '0' 和 0 都是普通文件；'5' 是目录，不必单独处理（写文件时递归创建）
      if (type == 0x30 || type == 0 || type == 0x00) {
        final path = _safeJoinPath(outDirPath, name);
        if (path != null) {
          final target = File(path);
          target.parent.createSync(recursive: true);
          final sink = target.openSync(mode: FileMode.write);
          try {
            var remaining = size;
            var pos = offset;
            while (remaining > 0) {
              raf.setPositionSync(pos);
              final want = remaining > 262144 ? 262144 : remaining;
              final chunk = raf.readSync(want);
              if (chunk.isEmpty) break;
              sink.writeFromSync(chunk);
              remaining -= chunk.length;
              pos += chunk.length;
            }
          } finally {
            sink.closeSync();
          }
        }
      }

      offset += size;
      final pad = size % 512;
      if (pad != 0) offset += 512 - pad;
    }
  } finally {
    raf.closeSync();
  }
}

String _tarStringOf(Uint8List bytes, int start, int len) {
  final end = (start + len) > bytes.length ? bytes.length : start + len;
  final buf = StringBuffer();
  for (var i = start; i < end; i++) {
    final c = bytes[i];
    if (c == 0) break;
    buf.writeCharCode(c);
  }
  return buf.toString().trim();
}

String _tarNameOf(Uint8List header) {
  final name = _tarStringOf(header, 0, 100);
  final prefix = _tarStringOf(header, 345, 155);
  if (prefix.isEmpty) return name;
  return '$prefix/$name';
}

int _tarSizeOf(Uint8List header) {
  final raw = _tarStringOf(header, 124, 12).replaceAll(' ', '');
  if (raw.isEmpty) return 0;
  return int.tryParse(raw, radix: 8) ?? 0;
}

/// 挡住 tar 里的 `../` 越界条目，只允许写在目标目录内。
String? _safeJoinPath(String basePath, String name) {
  final normalized = p.normalize(name.replaceAll('\\', '/'));
  if (p.isAbsolute(normalized)) return null;
  if (normalized.startsWith('..')) return null;
  final full = p.normalize(p.join(basePath, normalized));
  if (full != basePath && !p.isWithin(basePath, full)) return null;
  return full;
}

