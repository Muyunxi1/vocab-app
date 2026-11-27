import '../errors.dart';
import 'package:flutter/material.dart';

import '../neural_tts.dart';
import '../speech.dart';
import '../theme.dart';
import '../version_tag.dart';

/// 朗读语音设置：选来源（离线系统引擎 / 离线神经语音包 / 在线词典真人发音），再挑音色和语速。
///
/// 设备上能听到什么声音由引擎决定，这个页面只负责把能用的挑出来；
/// 挑不到就明确告诉用户原因，而不是装作在读。
class VoicePage extends StatefulWidget {
  const VoicePage({super.key});

  @override
  State<VoicePage> createState() => _VoicePageState();
}

class _VoicePageState extends State<VoicePage> {
  bool _loading = true;
  bool _busy = false;
  String? _error;

  /// 这个引擎试过 setVoice 并失败了。之后再让用户逐条点音色，
  /// 只会反复撞同一句「不支持切换音色」，把列表换成一句说明更实在。
  bool _voiceUnsupported = false;

  List<SpeechEngine> _engines = const [];
  List<SpeechVoice> _voices = const [];

  String _mode = Speech.modeSystem;
  String? _engine;
  String? _voice;
  String? _neuralVoice;
  String _dictAccent = '2';
  double _rate = 0.55;

  /// 各音色是否已下载好，键是 [NeuralVoice.id]。
  final Map<String, bool> _installed = {};

  /// 正在下载的音色 id 与进度 0..1。
  String? _installing;
  final Map<String, double> _progress = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 必须先读回上次的选择，否则重启后 mode 还是默认的 system，
      // 页面会把「系统语音」显示成当前项，看起来像设置被重置了。
      await Speech.instance.ensureLoaded();
      final engines = await Speech.instance.engines();
      final voices = await Speech.instance.voices();
      final s = Speech.instance;
      try {
        await NeuralTts.instance.refresh();
      } catch (_) {
        // 读不到已装状态就按没装处理，不影响其他项
      }
      if (!mounted) return;
      setState(() {
        _engines = engines;
        _voices = voices;
        _mode = s.mode;
        _engine = s.engine;
        _voice = s.voiceName;
        _neuralVoice = s.neuralVoice;
        _dictAccent = s.dictAccent;
        _rate = s.rate;
        _installed.clear();
        for (final v in neuralVoices) {
          _installed[v.id] = NeuralTts.instance.isInstalled(v.id);
        }
        if (voices.isEmpty && s.mode == Speech.modeSystem) {
          _error = '这台设备上没有可用的英文音色。可以切到下面的「词典真人发音」，或到系统设置里装英文语音包。';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = humanizeError(e));
    } finally {
      // 初始化失败也要退出转圈，否则这个页面永远打不开
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 保存当前各项并试听。
  Future<void> _apply({bool preview = true}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await Speech.instance.applyConfig(
        mode: _mode,
        engine: _engine,
        voiceName: _voice,
        rate: _rate,
        neuralVoice: _neuralVoice,
        dictAccent: _dictAccent,
      );
      final canPreview = preview &&
          !(_mode == Speech.modeNeural &&
              (_neuralVoice == null || _installed[_neuralVoice] != true));
      if (canPreview && ok) {
        // 词典发音只覆盖词条，整句会被接口拒掉，所以这一路用单词试听
        final text = _mode == Speech.modeDict ? Speech.dictSample : Speech.sample;
        await Speech.instance.speak(text, allowFallback: false);
      }
      if (!mounted) return;
      final err = Speech.instance.lastError;
      setState(() {
        _error = err;
        if (err != null && err.contains('引擎里没有这个音色')) _voiceUnsupported = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = humanizeError(e));
    } finally {
      // 不管中间哪一步抛了，_busy 都要落下来，否则整页按钮全部失效
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickMode(String mode) async {
    if (_busy) return;
    setState(() {
      _mode = mode;
      _error = null;
    });
    await _apply();
  }

  bool _anyNeuralInstalled() =>
      neuralVoices.any((v) => _installed[v.id] == true);

  /// 下载语音包。首页会被模型撑到 67MB，全程给进度，失败讲原因。
  Future<void> _download(NeuralVoice voice) async {
    if (_installing != null) return;
    setState(() {
      _installing = voice.id;
      _progress[voice.id] = 0;
      _error = null;
    });
    NeuralTts.instance.onProgress = (id, value) {
      if (!mounted) return;
      if (id != _installing) return;
      setState(() => _progress[id] = value);
    };
    try {
      await NeuralTts.instance.install(voice);
      if (!mounted) return;
      setState(() {
        _installed[voice.id] = true;
        _installing = null;
        _progress.remove(voice.id);
        _mode = Speech.modeNeural;
        _neuralVoice = voice.id;
      });
      _apply();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _installing = null;
        _progress.remove(voice.id);
        _error = humanizeError(e);
      });
    } finally {
      NeuralTts.instance.onProgress = null;
    }
  }

  Future<void> _remove(NeuralVoice voice) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这个音色？'),
        content: Text(
          '删除后能腾出约 ${voice.footprintLabel}，要重新下载 ${voice.sizeLabel} 才能再用。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (sure != true) return;
    try {
      await NeuralTts.instance.uninstall(voice);
      if (!mounted) return;
      setState(() {
        _installed[voice.id] = false;
        if (_neuralVoice == voice.id) _neuralVoice = null;
        if (_mode == Speech.modeNeural && !_anyNeuralInstalled()) {
          _mode = Speech.modeSystem;
        }
      });
      await _apply(preview: false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = humanizeError(e));
    }
  }

  Future<void> _pickEngine(String? name) async {
    if (_busy) return;
    setState(() {
      _engine = name;
      _voice = null;
      // 换引擎后音色支持情况是另一回事，重新试一次
      _voiceUnsupported = false;
      _busy = true;
    });
    try {
      await Speech.instance.applyConfig(
        mode: _mode,
        engine: name,
        voiceName: null,
        rate: _rate,
        // 换系统引擎跟已经下好的神经音色无关。少传这一项，
        // applyConfig 会把 neuralVoice 写成 null，用户挑的音色被静默抹掉。
        neuralVoice: _neuralVoice,
      );
      // 换引擎后音色列表是另一套，重新拉
      final voices = await Speech.instance.voices();
      if (!mounted) return;
      setState(() {
        _voices = voices;
        _error = Speech.instance.lastError;
      });
      await Speech.instance.speak(Speech.sample, allowFallback: false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = humanizeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final neural = _mode == Speech.modeNeural;
    final dict = _mode == Speech.modeDict;
    return Scaffold(
      appBar: AppBar(title: const Text('朗读语音')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _statusCard(),
                const SizedBox(height: 18),
                _sectionTitle('语音来源'),
                _pickTile(
                  title: '离线 · 神经语音',
                  subtitle: '把语音包下载到本机，模型自己发音，音色接近真人，不用联网',
                  selected: neural,
                  onTap: () => _pickMode(Speech.modeNeural),
                ),
                _pickTile(
                  title: '离线 · 系统语音',
                  subtitle: '不联网，音质由手机自带的语音引擎决定',
                  selected: !neural && !dict,
                  onTap: () => _pickMode(Speech.modeSystem),
                ),
                _pickTile(
                  title: '在线 · 词典真人发音',
                  subtitle: '免密钥、免下载，美音英音可切；只收录词条，长句按词逐个读',
                  selected: dict,
                  onTap: () => _pickMode(Speech.modeDict),
                ),
                const SizedBox(height: 18),
                if (neural)
                  ..._neuralSection()
                else if (dict)
                  ..._dictSection()
                else
                  ..._offlineSection(),
                const SizedBox(height: 18),
                _sectionTitle('语速'),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: _rate,
                        min: 0.3,
                        max: 1.0,
                        divisions: 14,
                        label: _rate.toStringAsFixed(2),
                        onChanged: (v) => setState(() => _rate = v),
                        onChangeEnd: (_) => _apply(),
                      ),
                    ),
                    SizedBox(
                      width: 44,
                      child: Text(
                        _rate.toStringAsFixed(2),
                        textAlign: TextAlign.right,
                        style: TextStyle(fontSize: 13, color: P.muted),
                      ),
                    ),
                  ],
                ),
                _hint('1.00 是常速。背单词和读文章 0.50–0.60 比较清楚，再慢反而容易失真。'),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _apply(),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: Text(_busy
                      ? (_mode == Speech.modeNeural
                          // 首次换音色要现场加载 60 多 MB 的模型，两三秒没反应会像卡死
                          ? '正在加载音色…'
                          : '正在试听…')
                      : (_mode == Speech.modeDict ? '试听这个词' : '试听这句')),
                ),
                const SizedBox(height: 8),
                Text(
                  _mode == Speech.modeDict ? Speech.dictSample : Speech.sample,
                  style: TextStyle(fontSize: 12.5, height: 1.6, color: P.muted),
                ),
              ],
            ),
    );
  }

  List<Widget> _offlineSection() {
    return [
      _sectionTitle('语音引擎'),
      if (_engines.isEmpty)
        _hint('这台设备只认系统默认引擎，没有别的可换。')
      else ...[
        _pickTile(
          title: '跟随系统',
          subtitle: '用系统当前默认的语音引擎',
          selected: _engine == null || _engine!.isEmpty,
          onTap: () => _pickEngine(null),
        ),
        for (final e in _engines)
          _pickTile(
            title: e.label,
            subtitle: e.name,
            selected: _engine == e.name,
            onTap: () => _pickEngine(e.name),
          ),
      ],
      const SizedBox(height: 18),
      _sectionTitle('音色'),
      if (_voiceUnsupported) ...[
        _hint('这个引擎里找不到刚才那个音色（名字或语言代码对不上），点哪个读出来都还是原来的声音，所以这里不再列。'),
        _hint('要真的换声音：切到上面「离线 · 神经语音」下载语音包（模型在本机发音，两个音色是两个模型），或切到「在线 · 词典真人发音」换美音/英音，也可以在手机系统设置里再装一个英文语音引擎。'),
      ] else
        _hint('点一下就会用这个音色读一句，觉得好听再留着。这台引擎一共提供 ${_voices.length} 个音色。'),
      _pickTile(
        title: '跟随系统',
        subtitle: '由引擎自己挑一个默认音色',
        selected: _voice == null || _voice!.isEmpty,
        onTap: () {
          setState(() => _voice = null);
          _apply();
        },
      ),
      if (!_voiceUnsupported)
        for (final v in _voices)
          _pickTile(
            title: v.label,
            subtitle: v.locale,
            selected: _voice == v.name,
            onTap: () {
              setState(() => _voice = v.name);
              _apply();
            },
          ),
    ];
  }

  List<Widget> _neuralSection() {
    final busy = _installing != null;
    return [
      _sectionTitle('离线语音包'),
      _hint('每个音色是一个压缩包（下载约 67MB），装好占 81MB 左右。下载后存在应用私有目录，卸载 App 会一起删掉。下载完点一下就会读一句。'),
      for (final v in neuralVoices) _neuralTile(v, busy: busy),
    ];
  }

  Widget _neuralTile(NeuralVoice voice, {required bool busy}) {
    final installed = _installed[voice.id] == true;
    final downloading = _installing == voice.id;
    final progress = _progress[voice.id] ?? 0;
    final selected = installed && _neuralVoice == voice.id;

    final status = downloading
        ? '下载中 ${(progress * 100).toStringAsFixed(0)}%'
        : installed
            ? '已下载 · 点一下试听'
            : '可下载 · 下载 ${voice.sizeLabel}，占 ${voice.footprintLabel}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: busy
            ? null
            : () {
                if (installed) {
                  setState(() => _neuralVoice = voice.id);
                  _apply();
                } else {
                  _download(voice);
                }
              },
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  installed
                      ? (selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked)
                      : Icons.cloud_download_outlined,
                  size: 17,
                  color: selected
                      ? P.primary
                      : installed
                          ? P.faint
                          : P.muted,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(voice.label,
                        style: TextStyle(fontSize: 13.5, color: P.title)),
                    const SizedBox(height: 1),
                    Text(
                      voice.note,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: P.muted),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      status,
                      style: TextStyle(
                        fontSize: 11,
                        color: downloading
                            ? P.primary
                            : installed
                                ? P.muted
                                : P.faint,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (downloading)
                Padding(
                  padding: const EdgeInsets.only(top: 6, right: 4),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      value: progress <= 0 ? null : progress,
                      strokeWidth: 2.5,
                    ),
                  ),
                )
              else if (installed)
                TextButton(
                  onPressed: busy ? null : () => _remove(voice),
                  child: const Text('删除', style: TextStyle(fontSize: 12)),
                )
              else
                TextButton(
                  onPressed: busy ? null : () => _download(voice),
                  child: const Text('下载', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _dictSection() {
    return [
      const SizedBox(height: 18),
      _sectionTitle('口音'),
      _hint('两个不同的录音，点一下立刻换，不用密钥也不用下载。'),
      _pickTile(
        title: '美式发音',
        subtitle: 'type=2',
        selected: _dictAccent == '2',
        onTap: () {
          setState(() => _dictAccent = '2');
          _apply();
        },
      ),
      _pickTile(
        title: '英式发音',
        subtitle: 'type=1',
        selected: _dictAccent == '1',
        onTap: () {
          setState(() => _dictAccent = '1');
          _apply();
        },
      ),
      const SizedBox(height: 18),
      _sectionTitle('这一路的说明'),
      _hint('直接用有道词典的词条真人发音，不需要填密钥、不需要下 67MB 语音包，也不受系统引擎能不能换音色影响。适合背单词和短语。'),
      _hint('这是词条录音，不是整句合成：单词和短语一声读完；句子和整段文章会拆成一个个词接着播，'
          '词与词之间必然有停顿，也没有连读和句调——要连贯的整句，得用「离线 · 神经语音」。'),
    ];
  }

  Widget _statusCard() {
    final s = Speech.instance;
    final err = _error ?? s.lastError;
    final neural = _mode == Speech.modeNeural;
    final dict = _mode == Speech.modeDict;
    String headline;
    if (neural) {
      if (_neuralVoice == null || _neuralVoice!.isEmpty) {
        headline = '离线神经语音 · 还没下载音色（现在仍是系统声音）';
      } else if (_installed[_neuralVoice] != true) {
        headline = '离线神经语音 · 音色还没下载好（现在仍是系统声音）';
      } else {
        final matches = neuralVoices.where((e) => e.id == _neuralVoice);
        final label = matches.isEmpty ? _neuralVoice! : matches.first.label;
        headline = '离线神经语音 · $label · 语速 ${_rate.toStringAsFixed(2)}';
      }
    } else if (dict) {
      headline =
          '在线 · 词典真人发音 · ${_dictAccent == '1' ? '英音' : '美音'}';
    } else {
      headline = s.activeLanguage == null
          ? '还没成功加载英文语音'
          : '${s.activeLanguage} · 语速 ${_rate.toStringAsFixed(2)}';
    }
    return Card(
      elevation: 0,
      color: err != null ? P.dangerBg : P.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: P.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('当前生效', style: TextStyle(fontSize: 12, color: P.muted)),
                const Spacer(),
                // 这是给"装了哪个包"用眼睛判断的：没有这一行就是旧版本
                Text(kBuildTag, style: TextStyle(fontSize: 11, color: P.muted)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              headline,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: P.title),
            ),
            if (!neural && !dict && _voice != null && _voice!.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(_voice!, style: TextStyle(fontSize: 11.5, color: P.muted)),
            ],
            if (err != null) ...[
              const SizedBox(height: 8),
              Text(err, style: TextStyle(fontSize: 12.5, height: 1.5, color: P.danger)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: P.title),
        ),
      );

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: TextStyle(fontSize: 12, height: 1.6, color: P.muted)),
      );

  Widget _pickTile({
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 17,
                color: selected ? P.primary : P.faint,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 13.5, color: P.title)),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: P.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
