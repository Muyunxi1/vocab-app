import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'errors.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'api.dart';
import 'diag.dart';
import 'neural_tts.dart';

/// 系统里装的一个朗读引擎（Android 的 TextToSpeech 服务）。
class SpeechEngine {
  const SpeechEngine({required this.name, required this.label});

  /// 传给 setEngine 的完整包名。
  final String name;

  /// 给人看的名字，取不到时等于 [name]。
  final String label;
}

/// 某个引擎下的一个音色。
class SpeechVoice {
  const SpeechVoice({required this.name, required this.locale, required this.label});

  /// 传给 setVoice 的标识。
  final String name;

  final String locale;

  /// 给人看的名字，已去掉 Android 那串内部前缀。
  final String label;
}

/// 朗读。三种来源：
/// - 离线系统：走系统 TTS 引擎，不联网，音质由设备决定（多数国产机只有拼音素，很难听）；
/// - 离线神经：下载 Piper 语音包到应用私有目录，本机推理，音色接近真人，不需要联网；
/// - 在线：有道词典的词条真人发音（dictvoice），不需要密钥，但只收录词条——
///   单词和短语是现成录音，长句只能拆成词逐个播。
///
/// 后两者失败都会降级回系统语音，保证至少读得出来，失败原因留在 [lastError]。
class Speech {
  Speech._();

  static final Speech instance = Speech._();

  static const String metaMode = 'tts_mode';
  static const String metaEngine = 'tts_engine';
  static const String metaVoice = 'tts_voice';
  static const String metaNeuralVoice = 'tts_neural_voice';
  static const String metaRate = 'tts_rate';
  static const String metaDictAccent = 'tts_dict_accent';

  static const String modeSystem = 'system';
  static const String modeNeural = 'neural';

  /// 有道词典的单词真人发音：不需要密钥、不需要签名，也不依赖系统引擎。
  /// 设备上「换音色不生效、语音包没下载、合成要密钥」都卡住时，这是最稳的一路。
  static const String modeDict = 'dict';

  /// 用户在上一个版本里选过「在线 · 有道语音合成」。
  ///
  /// 那条路要用户自己去有道智云申请私钥、再开通合成服务，普通用户走不通，已经从
  /// 界面上撤掉。启动时把这种旧配置改成词典真人发音——它同样不需要密钥、同样是真人
  /// 录音，是与其最接近的替代，避免老用户停在「换了模式却没声音」的状态。
  ///
  /// （翻译页用的有道翻译接口是另一回事，那一路仍在用密钥，与本项无关。）
  static const String _legacyOnlineMode = 'online';

  /// 试听用的句子，短、包含连读和常见音素。
  static const String sample = 'Learning a new word is easier when you hear it out loud.';

  /// 词典发音的试听词。
  ///
  /// 这一路只能取词典收录的词条，整句会直接 500（实测 "Learning a new word"
  /// 就取不到），所以试听必须用单词，否则用户一进来就只看到红字。
  static const String dictSample = 'dictionary';

  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _player = AudioPlayer();

  bool _ready = false;
  bool _prefsLoaded = false;

  /// 语音来源：[modeSystem]、[modeNeural] 或 [modeDict]。
  String mode = modeSystem;

  /// 用户在语音设置里选的值，null / 空表示跟随系统。
  String? engine;
  String? voiceName;

  /// 离线神经音色的 id，对应 [neuralVoices] 里的一项。
  String? neuralVoice;

  /// 语速，1.0 是引擎的常速，朗读用 0.55 左右比默认好听。
  double rate = 0.55;

  /// 词典真人发音的口音：'2' 美音、'1' 英音。
  ///
  /// 这两个是不同的录音，换一下能明显听出差别，而且不需要密钥、不需要下载，
  /// 是设备上唯一「点一下就真的换声音」的免费路径。
  String dictAccent = '2';

  /// 最近一次配置或朗读的失败原因，设置页会显示出来。
  ///
  /// 走 setter 顺手记一份到诊断日志：用户报「没声音」时，报告里就能看到
  /// 到底是哪个模式、哪一步出的错，不用再靠回忆。
  String? get lastError => _lastError;
  set lastError(String? value) {
    _lastError = value;
    if (value != null && value.isNotEmpty) Diag.record('朗读', value);
  }

  String? _lastError;

  /// 实际生效的语言，没成功时为 null。
  String? activeLanguage;

  Future<void> _loadPrefs() async {
    if (_prefsLoaded) return;
    _prefsLoaded = true;
    // 播完不要释放底层播放器。audioplayers 默认 ReleaseMode.release，每块音频
    // 播完就销毁 MediaPlayer，下一块 play() 又得起一个新的，中间一百到三百毫秒
    // 的空档正好落在块与块的交界上，连读听起来就是「一顿一顿」。
    try {
      await _player.setReleaseMode(ReleaseMode.stop);
    } catch (_) {
      // 个别机型设不上也不影响出声，只是块间多一点启动开销
    }
    try {
      mode = await Api.instance.metaGet(metaMode) ?? modeSystem;
      // 老配置里存着已下线的在线合成模式，改成词典真人发音：同样是真人录音、
      // 同样不要密钥，是它最接近的替代，别让人停在"换了模式却没声音"。
      if (mode == _legacyOnlineMode) {
        mode = modeDict;
        await Api.instance.metaSet(metaMode, modeDict);
      }
      engine = await Api.instance.metaGet(metaEngine);
      voiceName = await Api.instance.metaGet(metaVoice);
      neuralVoice = await Api.instance.metaGet(metaNeuralVoice);
      dictAccent = await Api.instance.metaGet(metaDictAccent) ?? dictAccent;
      final stored = double.tryParse(await Api.instance.metaGet(metaRate) ?? '');
      if (stored != null) rate = stored.clamp(0.25, 1.0);
    } catch (_) {
      // 读不到配置就用默认值，不影响朗读
    }
  }

  /// 语音页打开时先把用户上次的选择读回来。
  ///
  /// [mode] 的默认值是 system，只有第一次朗读才回读数据库。设置页如果不等这一步，
  /// 重启后页面会先亮起「系统语音」——用户看到的就是"设置被重置了"，
  /// 而这时如果他随手点一下别的项，旧配置就被真的覆盖掉。
  Future<void> ensureLoaded() => _loadPrefs();

  /// 把语言、语速、引擎、音色整套下发给系统。换引擎会重置语言，所以每次都重下。
  Future<bool> _apply({String? engine, String? voiceName, required double rate}) async {
    lastError = null;
    try {
      if (engine != null && engine.isNotEmpty) {
        final ok = await _tts.setEngine(engine);
        if (ok == 0) lastError = '切换语音引擎失败，已沿用系统默认';
      }
      // en-US 不一定装了，按常用口音依次退
      String? picked;
      for (final lang in const ['en-US', 'en-GB', 'en-AU', 'en']) {
        final ok = await _tts.isLanguageAvailable(lang);
        if (ok == true) {
          picked = lang;
          break;
        }
      }
      if (picked == null) {
        lastError = '这台设备没有可用的英文语音包';
        activeLanguage = null;
        return false;
      }
      await _tts.setLanguage(picked);
      activeLanguage = picked;
      await _tts.setSpeechRate(rate);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      if (voiceName != null && voiceName.isNotEmpty) {
        // flutter_tts 的 Android 端在 setVoice 里要求 name 和 locale 同时精确相等
        // （ttsVoice.name == name && ttsVoice.locale.toLanguageTag() == locale），
        // 否则直接回 0。以前这里传的是我们自己探测出来的 en-US，而引擎里这个音色
        // 的语言代码常常是 en-GB / en_US / en-us，于是永远匹配不上、声音一辈子不变。
        // 改成本地查一遍 voices，用音色自己的 locale 传回去。
        var voiceLocale = picked;
        try {
          final raw = await _tts.getVoices;
          if (raw is List) {
            for (final item in raw) {
              if (item is Map && (item['name'] ?? '').toString() == voiceName) {
                final loc = (item['locale'] ?? '').toString();
                if (loc.isNotEmpty) voiceLocale = loc;
                break;
              }
            }
          }
        } catch (_) {
          // 查不到就用探测出来的 locale 兜底
        }
        final voiced = await _tts.setVoice({'name': voiceName, 'locale': voiceLocale});
        if (voiced == 0 && lastError == null) {
          // 到这里才是引擎里真的没有这个音色（或它拒绝），说清是匹配失败，
          // 别写成「不支持换音色」——那会把人引到错误的方向。
          lastError = '引擎里没有这个音色（名字或语言代码对不上），声音仍是原来的';
        }
        // setVoice 会让部分引擎把语言清掉，设完音色再确认一次语言
        await _tts.setLanguage(picked);
        activeLanguage = picked;
      }
      return true;
    } catch (e) {
      lastError = humanizeError(e);
      return false;
    }
  }

  Future<bool> _ensure() async {
    if (_ready) return true;
    await _loadPrefs();
    _ready = await _apply(engine: engine, voiceName: voiceName, rate: rate);
    return _ready;
  }

  /// 最近一次朗读的文本与时间，用来挡重复点击。
  String? _lastSpeakText;
  DateTime? _lastSpeakAt;

  /// 正在等「这一句播完」的那个完成器。点停止时直接放开它，
  /// 否则整篇连读要一直等到超时才退出。
  Completer<void>? _waitDone;

  /// 词典发音逐词朗读时，用户点了停止：每播完一个词检查一次，别把剩下的词读完。
  bool _aborted = false;

  /// 逐词朗读的代号。新的一次朗读把代号 +1，上一句的循环看到代号变了就自己退出。
  int _dictRun = 0;

  /// 每次 [speakAndWait] 递增一次。回调里用它确认「这个完成信号属于当前这一句」，
  /// 避免上一次朗读残留的 cancel/error 回调把这一次提前判成播完。
  int _waitSeq = 0;

  /// 朗读一段英文，返回是否成功出声。
  ///
  /// [allowFallback] 为 false 时，神经/词典两条路失败就直接返回失败，不再
  /// 偷偷换成系统语音。设置页试听必须走这个模式：否则用户在没下载语音包、
  /// 没填密钥时听到的还是系统引擎的声音，会觉得「三种模式一模一样」。
  ///
  /// [wait] 为 true 时等音频真的播完再返回，整篇连读靠它串行；
  /// 单词点读不需要，立刻返回才不会卡住界面。
  Future<bool> speak(String text,
      {bool allowFallback = true, bool wait = false}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    // 连点同一句时不再合成第二遍：语音引擎不会自己排队，两路声音会直接叠在一起。
    final now = DateTime.now();
    final last = _lastSpeakAt;
    if (_lastSpeakText == trimmed && last != null && now.difference(last).inMilliseconds < 600) {
      return true;
    }
    _lastSpeakText = trimmed;
    _lastSpeakAt = now;
    await _loadPrefs();

    if (mode == modeNeural) {
      final ok = await _speakNeural(trimmed);
      if (ok) return true;
      // 试听不静默回退，直接把失败原因留给调用方显示
      if (!allowFallback) return false;
      // 模型没下、加载失败、合成失败都退回系统语音
      if (lastError != null) lastError = '$lastError（已改读系统语音）';
    } else if (mode == modeDict) {
      final ok = await _speakDict(trimmed, wait: wait);
      if (ok) return true;
      if (!allowFallback) return false;
      // 长句、生僻词取不到音频时退回系统语音，至少还有声音
      if (lastError != null) lastError = '$lastError（已改读系统语音）';
    }

    if (!await _ensure()) return false;
    try {
      await _stopPlayer();
      await _tts.stop();
      final result = await _tts.speak(trimmed);
      return result == 1;
    } catch (e) {
      _ready = false;
      lastError = humanizeError(e);
      return false;
    }
  }

  /// 朗读一句并等到它真的播完。
  ///
  /// 整篇连读靠它串行：以前直接调 [speak] 就进下一句，系统语音和 audioplayers
  /// 的 play() 都在「开始播」时就返回，循环会一路跑到最后一句，用户只听到尾巴。
  ///
  /// 三种来源的「播完」信号不一样，必须分开判：
  /// - 系统语音走 flutter_tts 的完成回调，这里 [AudioPlayer] 全程不参与，
  ///   状态恒为 stopped。上一版用 `_player.state` 当条件，系统语音这一支被整段
  ///   跳过，等于默认语音来源下「听全文」只能听到最后一块。
  /// - 神经语音落到 [AudioPlayer]，播完会发 onPlayerComplete。
  /// - 词典真人发音是逐词播完才返回，这里不能再等。
  ///
  /// [prefetchNext] 是接下来要读的那一段：这一句开始播之后顺手把它合成好，
  /// 下一段就不用再等推理，整篇听下来才连得上。
  Future<bool> speakAndWait(String text, {String? prefetchNext}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;

    final done = Completer<void>();
    // 每次调用一个序号：上一次残留的回调（尤其是 cancel）不能把这一次提前判完成
    final token = ++_waitSeq;
    void finish() {
      if (token != _waitSeq) return;
      if (!done.isCompleted) done.complete();
    }

    // 系统语音没有开 awaitSpeakCompletion，只能靠回调知道说完了。
    // 这几个 setHandler 在 flutter_tts 里是同步方法，返回 void，不能 await。
    try {
      _tts.setCompletionHandler(finish);
      _tts.setCancelHandler(finish);
      _tts.setErrorHandler((_) => finish());
    } catch (_) {
      // 个别引擎不支持回调，退化成下面的超时兜底
    }

    // 播放器路径：audioplayers 播完才有事件，play() 本身不阻塞
    final sub = _player.onPlayerComplete.listen((_) => finish());

    _waitDone = done;
    try {
      final ok = await speak(trimmed, wait: true);
      if (!ok) return false;
      final next = prefetchNext?.trim();
      if (next != null && next.isNotEmpty) {
        // 先让这一段播起来，再开始算下一段。推理已经在合成线程里跑，
        // 不占 UI 也不占播放回调，所以不必再等 300ms——越早算完，下一段越不会等。
        unawaited(Future<void>.delayed(
          const Duration(milliseconds: 120),
          () => prefetch(next),
        ));
      }
      if (mode != modeDict && !done.isCompleted) {
        // 不合格的合成或卡死的播放不能让队列停在这里。上界按「这段要读多久」
        // 估算再放宽一倍，短句不会等满长句的额度，引擎不回回调时也只慢一块。
        final budget = _waitBudget(trimmed);
        await done.future.timeout(Duration(seconds: budget), onTimeout: () {});
      }
      return true;
    } finally {
      if (identical(_waitDone, done)) _waitDone = null;
      await sub.cancel();
    }
  }

  /// 一段文本最长要读多久（秒）。按词数除以语速估，再给一倍余量：
  /// 神经语音首次推理慢，不能按系统语音的节奏卡死。
  int _waitBudget(String text) {
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    final perWord = 0.42 / rate.clamp(0.3, 1.2);
    final seconds = (words * perWord).ceil();
    return seconds < 8 ? 12 : seconds * 2 + 6;
  }

  /// 有道词典的单词真人发音：不需要密钥、不需要签名，也不碰系统引擎。
  ///
  /// 接口 GET dictvoice?audio=<词>&type=2（2 = 美音，1 = 英音）直接回一段 mp3。
  /// 词典只收录词条，整句会被 500 掉，所以文章朗读要按词走：
  /// 一个词直接播，一句话就拆成词、按顺序逐个播完再下一个。
  Future<bool> _speakDict(String text, {bool wait = false}) async {
    final q = text.trim();
    if (q.isEmpty) return false;
    final words = _dictWords(q);
    if (words.isEmpty) {
      lastError = '这段话里没有可读的英文单词';
      return false;
    }

    // 单词和短语（look up）本身就是词条，整段丢给接口最准
    if (words.length <= 3 && !RegExp(r'[.,;:!?…“”"()]').hasMatch(q) &&
        q.length <= 40) {
      final path = await _dictPath(q);
      if (path == null) return false;
      await _tts.stop();
      await _stopPlayer();
      return wait
          ? _playLocalAndWait(path, '这段发音没能播放，文件可能坏了，换个词再试')
          : _playLocal(path, '这段发音没能播放，文件可能坏了，换个词再试');
    }

    // 整句/整段：逐词播。取不到的词跳过，不能因为一个生僻词就整段退回系统语音。
    var played = 0;
    var missed = 0;
    _aborted = false;
    // 又点了一句时，让上一句的逐词循环自己退出，别两句话叠着播
    final run = ++_dictRun;
    // 系统语音可能还在念上一句，先停掉，不然两个声音会叠在一起
    try {
      await _tts.stop();
    } catch (_) {
      // 停不动也无所谓，下面播放时会被音频焦点顶掉
    }
    await _stopPlayer();
    // 播放第 i 个词的同时，后面 2 个词已经在下载，避免一句话等成一条队
    final inflight = <int, Future<String?>>{};
    var next = 0;
    void pump() {
      while (next < words.length && inflight.length < 3) {
        final i = next++;
        inflight[i] = _dictPath(words[i], quiet: true);
      }
    }

    for (var i = 0; i < words.length; i++) {
      if (_aborted || run != _dictRun) break;
      pump();
      final path = await inflight.remove(i);
      if (path == null) {
        missed++;
        continue;
      }
      if (_aborted || run != _dictRun) break;
      final ok =
          await _playLocalAndWait(path, '这段发音没能播放，文件可能坏了，换个词再试');
      if (ok) {
        played++;
      } else {
        missed++;
      }
    }
    if (run != _dictRun) {
      // 被新的一次朗读顶掉：不算失败，也不要去改状态提示
      return true;
    }
    if (played == 0) {
      lastError = '这些词都没取到真人发音（词典只收录词条，生僻词和变形词可能没有）';
      return false;
    }
    lastError = missed > 0 ? '有 $missed 个词没取到真人发音，已跳过' : null;
    return true;
  }

  /// 文本里能读音的英文词。撇号、连字符是词的一部分，其余都当分隔。
  List<String> _dictWords(String text) {
    final out = <String>[];
    for (final raw in text.split(RegExp(r"[^A-Za-z'\-]+"))) {
      final w = raw.replaceAll(RegExp(r"^['\-]+|['\-]+$"), '');
      if (w.isEmpty || w.length > 40) continue;
      out.add(w);
    }
    return out;
  }

  /// 取一个词条的音频文件路径；取不到返回 null。
  ///
  /// [quiet] 为 true 时不写 [lastError]：整段朗读里单个词失败不该覆盖掉
  /// 整段的状态，最后统一报「有几个词跳过」。
  Future<String?> _dictPath(String q, {bool quiet = false}) async {
    try {
      final word = q.trim();
      if (word.isEmpty) return null;
      final file = await _dictCacheFile(word);
      if (!await file.exists() || await file.length() < 1024) {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 15);
        try {
          final uri = Uri.parse(
              'https://dict.youdao.com/dictvoice?audio=${Uri.encodeQueryComponent(word)}&type=$dictAccent');
          final request = await client.getUrl(uri).timeout(const Duration(seconds: 15));
          // 有道对没有浏览器身份标识的请求会 403：Dart 默认 UA 太显眼。
          request.headers
            ..set(HttpHeaders.userAgentHeader,
                'Mozilla/5.0 (Linux; Android 13; Pixel 6) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36')
            ..set(HttpHeaders.refererHeader, 'https://dict.youdao.com/')
            ..set(HttpHeaders.acceptHeader, 'audio/mpeg,audio/*,*/*');
          final response = await request.close().timeout(const Duration(seconds: 20));
          if (response.statusCode == 500 || response.statusCode == 404) {
            // 有道只给收录进词典的词条录音，自己拼的句子会直接报错。
            if (!quiet) {
              lastError = '这个词条取不到真人发音：只有词典收录的单词和短语有录音，整句不支持';
            }
            return null;
          }
          if (response.statusCode != 200) {
            if (!quiet) lastError = '词典发音接口返回 HTTP ${response.statusCode}';
            return null;
          }
          final bytes = <int>[];
          await for (final chunk in response) {
            bytes.addAll(chunk);
          }
          if (bytes.length < 1024) {
            if (!quiet) lastError = '这段没取到真人发音，可能不是单词或短语';
            return null;
          }
          // 先写 .part 再改名，半截文件不会被当成缓存
          final tmp = File('${file.path}.part');
          await tmp.writeAsBytes(bytes, flush: true);
          await tmp.rename(file.path);
        } finally {
          client.close(force: true);
        }
      }
      return file.path;
    } catch (e) {
      if (!quiet) lastError = humanizeError(e);
      return null;
    }
  }

  /// 词典真人发音缓存目录。
  Future<Directory> _dictDir() async {
    // 用应用自己的私有目录。Directory.systemTemp 在部分机型上不可写，
    // 写失败会被当成"发音失败"，看起来像接口坏了。
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/dict_voice');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 词典发音缓存：按文本哈希，同一句只下一次。
  Future<File> _dictCacheFile(String text) async {
    final hash = sha1.convert(utf8.encode('dict|$dictAccent|$text')).toString();
    final dir = await _dictDir();
    return File('${dir.path}/$hash.mp3');
  }

  /// 词典真人发音缓存占了多少字节。
  Future<int> dictCacheBytes() async {
    var total = 0;
    try {
      final dir = await _dictDir();
      await for (final entity in dir.list()) {
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

  /// 清掉词典真人发音缓存，返回释放了多少字节。下次点词会重新下载。
  Future<int> clearDictCache() async {
    var freed = 0;
    try {
      final dir = await _dictDir();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        try {
          freed += await entity.length();
          await entity.delete();
        } on FileSystemException {
          // 删不掉就跳过
        }
      }
    } on FileSystemException {
      // 目录读不动就当没缓存
    }
    return freed;
  }

  /// 系统 TTS 的 rate 0.55 约等于正常人语速，Piper 的 speed 1.0 才是正常语速。
  double get _neuralSpeed => (rate / 0.55).clamp(0.5, 1.5);

  /// 神经模式下提前把下一段合成了。
  ///
  /// 整篇朗读是逐段串行的，每段都要现场推理一次（一句 50 词要一两秒），
  /// 段与段之间就空出这段静默，听起来一顿一顿。播当前段的时候把下一段算好放进缓存，
  /// 轮到它时直接读文件，间隔就只剩几十毫秒。
  ///
  /// 推理在合成线程里做，不占 UI 线程，也不挡播放器的播完回调，所以这段
  /// 计算不会打断正在放的声音。
  Future<void> prefetch(String text) async {
    if (mode != modeNeural) return;
    final voiceId = neuralVoice;
    final trimmed = text.trim();
    if (voiceId == null || voiceId.isEmpty || trimmed.isEmpty) return;
    try {
      await NeuralTts.instance.synthesize(
        text: trimmed,
        voiceId: voiceId,
        speed: _neuralSpeed,
      );
    } catch (e) {
      // 预合成失败不影响当前这段，轮到它时再走正常流程并把原因报给界面
      debugPrint('neural prefetch failed: $e');
    }
  }

  /// 本地神经语音：模型在应用私有目录里，合成结果进缓存。
  Future<bool> _speakNeural(String text) async {
    try {
      final voiceId = neuralVoice;
      if (voiceId == null || voiceId.isEmpty) {
        lastError = '还没选离线语音音色';
        return false;
      }
      if (!NeuralTts.instance.isInstalled(voiceId)) {
        await NeuralTts.instance.refresh();
      }
      if (!NeuralTts.instance.isInstalled(voiceId)) {
        lastError = '这个音色的语音包还没下载好';
        return false;
      }
      final path = await NeuralTts.instance.synthesize(
        text: text,
        voiceId: voiceId,
        speed: _neuralSpeed,
      );
      await _tts.stop();
      await _stopPlayer();
      return await _playLocal(
        path,
        '合成出来的音频没能播放，文件可能坏了，删掉这个音色重新下载',
      );
    } catch (e) {
      lastError = humanizeError(e);
      return false;
    }
  }

  Future<void> _stopPlayer() async {
    try {
      await _player.stop();
    } catch (_) {
      // 停止失败无所谓
    }
  }

  /// 等播放器真的进了 playing（极短音频可能直接跳到 completed，也算响过）。
  ///
  /// 以前是 play() 之后死等 250ms 再读状态：一是每句话都凭空多出 0.25 秒空白，
  /// 整篇连读听起来一顿一顿；二是短词（一个 "a" 不到 0.25 秒）播完状态已是 stopped，
  /// 会被当成「放不出来」，整篇朗读在第一个短词那里就断掉。
  Future<bool> _waitPlaying() async {
    if (_player.state == PlayerState.playing) return true;
    final started = Completer<void>();
    final sub = _player.onPlayerStateChanged.listen((state) {
      if (!started.isCompleted &&
          (state == PlayerState.playing || state == PlayerState.completed)) {
        started.complete();
      }
    });
    try {
      await started.future
          .timeout(const Duration(milliseconds: 700), onTimeout: () {});
    } finally {
      await sub.cancel();
    }
    return started.isCompleted || _player.state == PlayerState.playing;
  }

  /// 播放本地音频并确认真的开始出声。
  ///
  /// play() 只负责把请求交给播放器：文件损坏、格式不支持、被系统音频焦点打断
  /// 都不会在这一步报错，用户看到的只是"点了没声音"。这里用播放器自己的状态事件
  /// 判断它到底响没响，不用固定等待。
  Future<bool> _playLocal(String path, String failMessage) async {
    try {
      await _player.play(DeviceFileSource(path));
      if (!await _waitPlaying()) {
        lastError = failMessage;
        return false;
      }
      lastError = null;
      return true;
    } catch (e) {
      lastError = humanizeError(e);
      return false;
    }
  }

  /// 播放到音频结束才返回。整篇连读和逐词朗读用这个，否则一句话还没读完就进了下一句。
  Future<bool> _playLocalAndWait(String path, String failMessage) async {
    final done = Completer<void>();
    // 订阅要在 play 之前挂上：极短音频可能在「确认响没响」期间就播完了
    final sub = _player.onPlayerComplete.listen((_) {
      if (!done.isCompleted) done.complete();
    });
    try {
      await _player.play(DeviceFileSource(path));
      if (!await _waitPlaying()) {
        lastError = failMessage;
        return false;
      }
      // 兜底上界：真卡住不能让整篇朗读挂死在这里
      await done.future.timeout(const Duration(seconds: 15), onTimeout: () {});
      lastError = null;
      return true;
    } catch (e) {
      lastError = humanizeError(e);
      return false;
    } finally {
      await sub.cancel();
    }
  }

  Future<void> stop() async {
    // 正在整篇连读时点停止：先放开等待，循环才能马上退出
    _aborted = true;
    final waiter = _waitDone;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    await _stopPlayer();
    try {
      await _tts.stop();
    } catch (_) {
      // 停止失败无所谓
    }
  }

  /// 系统里可选的引擎。iOS 没有这个概念，会返回空列表。
  Future<List<SpeechEngine>> engines() async {
    try {
      final raw = await _tts.getEngines;
      if (raw is List) {
        final list = <SpeechEngine>[];
        for (final item in raw) {
          if (item is! Map) continue;
          final name = (item['name'] ?? '').toString();
          if (name.isEmpty) continue;
          final label = (item['label'] ?? '').toString();
          list.add(SpeechEngine(name: name, label: label.isEmpty ? name : label));
        }
        return list;
      }
    } catch (_) {
      // 查询不到就按"只有默认引擎"处理
    }
    return const [];
  }

  /// 英文音色列表。Android 会返回一堆带 #female_1 之类后缀的内部名，统一整理成好看的形式。
  Future<List<SpeechVoice>> voices() async {
    try {
      final raw = await _tts.getVoices;
      if (raw is List) {
        final list = <SpeechVoice>[];
        for (final item in raw) {
          if (item is! Map) continue;
          final name = (item['name'] ?? '').toString();
          final locale = (item['locale'] ?? item['language'] ?? '').toString();
          if (name.isEmpty || !locale.toLowerCase().startsWith('en')) continue;
          list.add(SpeechVoice(name: name, locale: locale, label: _prettyVoice(name)));
        }
        return list;
      }
    } catch (_) {
      // 同上
    }
    return const [];
  }

  /// Android 的 voice 名形如 en-us-x-sfg#female_1-local，只留 # 之后那段。
  String _prettyVoice(String name) {
    final hash = name.indexOf('#');
    if (hash >= 0 && hash + 1 < name.length) return name.substring(hash + 1);
    return name;
  }

  /// 语音设置页改完参数后调这个：落库、重新下发、返回是否生效。
  Future<bool> applyConfig({
    required String mode,
    required String? engine,
    required String? voiceName,
    required double rate,
    String? neuralVoice,
    String? dictAccent,
  }) async {
    this.mode = mode;
    this.engine = engine;
    this.voiceName = voiceName;
    this.neuralVoice = neuralVoice;
    this.rate = rate;
    if (dictAccent != null && dictAccent.isNotEmpty) this.dictAccent = dictAccent;
    _prefsLoaded = true;
    try {
      await Api.instance.metaSet(metaMode, mode);
      await Api.instance.metaSet(metaEngine, engine);
      await Api.instance.metaSet(metaVoice, voiceName);
      await Api.instance.metaSet(metaNeuralVoice, neuralVoice);
      await Api.instance.metaSet(metaDictAccent, this.dictAccent);
      await Api.instance.metaSet(metaRate, rate.toStringAsFixed(2));
    } catch (_) {
      // 存不上不影响本次生效
    }
    await stop();
    if (mode == modeNeural) {
      // 神经音色在本地推理，不依赖系统引擎，但状态卡要显示它是否可用
      _ready = false;
      activeLanguage =
          (neuralVoice == null || neuralVoice.isEmpty) ? null : '本地模型';
      lastError = null;
      return true;
    }
    if (mode == modeDict) {
      // 不用本地模型了，把 onnx 从内存里放掉；它常驻要占几十 MB，
      // 之前 release() 建好了却没人调用，等于一直不释放
      NeuralTts.instance.release();
      // 这条路不依赖系统引擎，但保留语言探测结果给状态卡显示
      _ready = false;
      activeLanguage = 'en-US';
      lastError = null;
      return true;
    }
    // 系统引擎模式同样用不到本地模型，一并释放，免得几十 MB 白占
    NeuralTts.instance.release();
    _ready = await _apply(engine: engine, voiceName: voiceName, rate: rate);
    return _ready;
  }
}
