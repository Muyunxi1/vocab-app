import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../diag.dart';
import '../errors.dart';
import '../models.dart';
import '../neural_tts.dart';
import '../speech.dart';
import '../theme.dart';
import '../version_tag.dart';
import '../widgets.dart';
import 'voice_page.dart';

/// 「我的」：学习档案 + 朗读入口 + 存储与诊断。
///
/// 之前这些都散在别处：语音设置是词库页右上角一个小喇叭，备份在统计页底部，
/// 改配色是标题栏一个文字按钮。设置类的东西集中一处，找起来才不用记位置。
class MinePage extends StatefulWidget {
  const MinePage({super.key, this.embedded = false, this.refreshSignal = 0});

  final bool embedded;

  /// 切回本页时递增，用来重新拉一遍统计。
  final int refreshSignal;

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  static const String _keyName = 'mine_name';
  static const String _keyAvatar = 'mine_avatar';

  bool _loading = true;
  bool _busy = false;
  String? _error;

  Overview? _overview;
  int _mastered = 0;
  int _streak = 0;
  int _articles = 0;

  int _dbBytes = 0;
  int _modelBytes = 0;
  int _synthBytes = 0;
  int _dictBytes = 0;

  String _name = '词友';
  int _avatar = 0;

  /// 头像底色，跟护眼主题的绿系保持一致。
  static const List<Color> _avatarColors = [
    Color(0xFF3A9D6E),
    Color(0xFF4C8FB8),
    Color(0xFFC0803A),
    Color(0xFF8B6BB1),
    Color(0xFFB0566A),
    Color(0xFF5C8A4A),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MinePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshSignal != oldWidget.refreshSignal) _load();
  }

  /// 每次 _load 递增。快速切 tab 会有两次请求叠在一起，
  /// 只认最后一次的结果，避免慢的那次回来把新数据盖回旧的。
  int _loadSeq = 0;

  Future<void> _load() async {
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ov = await Api.instance.overview();
      final mastered = await Api.instance.masteredCount();
      final articles = await Api.instance.articleCount();
      // 180 天覆盖一学期的连续打卡；再长的查询对「连续天数」没有意义，
      // 而 60 天会让坚持了两个月的用户在第七十天看到数字停在 60。
      final days = await Api.instance.weeklyStats(days: 180);
      final name = await Api.instance.metaGet(_keyName);
      final avatar = await Api.instance.metaGet(_keyAvatar);
      final usage = await _usage();
      await Speech.instance.ensureLoaded();
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _overview = ov;
        _mastered = mastered;
        _articles = articles;
        _streak = _streakOf(days);
        _name = (name == null || name.trim().isEmpty) ? '词友' : name.trim();
        _avatar = (int.tryParse(avatar ?? '') ?? 0) % _avatarColors.length;
        _dbBytes = usage[0];
        _modelBytes = usage[1];
        _synthBytes = usage[2];
        _dictBytes = usage[3];
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() => _error = humanizeError(e));
    } finally {
      if (mounted && seq == _loadSeq) setState(() => _loading = false);
    }
  }

  /// 数据库 / 模型 / 合成缓存 / 发音缓存，四份分别算。
  Future<List<int>> _usage() async {
    var db = 0;
    try {
      // WAL 模式下数据实际在 -wal 里，只看 .db 会少算一大截
      final path = await Api.instance.databasePath();
      for (final suffix in const ['', '-wal', '-shm']) {
        final file = File('$path$suffix');
        if (await file.exists()) db += await file.length();
      }
      // 内置词典副本也在数据库目录里，同样是 App 占的空间
      db += await Api.instance.dictDbBytes();
    } on FileSystemException {
      db = 0;
    }
    var models = 0;
    var synth = 0;
    var dict = 0;
    try {
      await NeuralTts.instance.refresh();
      models = await NeuralTts.instance.modelsBytes();
      // 下载中断留下的 .tmp 与半装目录也算模型占用，否则这部分空间看不见、清不掉
      models += await NeuralTts.instance.pendingBytes();
      synth = await NeuralTts.instance.cacheBytes();
    } catch (_) {
      // 语音目录读不到不影响别的数字
    }
    try {
      dict = await Speech.instance.dictCacheBytes();
    } catch (_) {
      dict = 0;
    }
    return [db, models, synth, dict];
  }

  /// 连续打卡：从今天往前数，每天有复习或加词就算学了。
  ///
  /// 今天还没学不算断，从昨天开始数——否则每天早上打开都显示归零。
  int _streakOf(List<DayStat> days) {
    var streak = 0;
    for (var i = days.length - 1; i >= 0; i--) {
      final d = days[i];
      final active = d.reviewed > 0 || d.added > 0;
      if (active) {
        streak++;
        continue;
      }
      if (i == days.length - 1) continue;
      break;
    }
    return streak;
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    _toast('$what 已复制：$text');
  }

  // ---------------- 档案卡 ----------------

  Future<void> _editName() async {
    final controller = TextEditingController(text: _name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('换个称呼'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 12,
          decoration: const InputDecoration(hintText: '比如：小周、阿 May'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) {
      controller.dispose();
      return;
    }
    try {
      await Api.instance.metaSet(_keyName, name);
    } catch (e) {
      // 存不进去就别改界面：否则用户看到新名字，重启又变回去，还以为是 bug
      controller.dispose();
      if (mounted) _toast('保存失败：${humanizeError(e)}');
      return;
    }
    controller.dispose();
    if (!mounted) return;
    setState(() => _name = name);
  }

  Future<void> _pickAvatar() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选个头像颜色'),
        content: Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            for (var i = 0; i < _avatarColors.length; i++)
              GestureDetector(
                onTap: () => Navigator.pop(ctx, i),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _avatarColors[i],
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: i == _avatar ? P.title : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    try {
      await Api.instance.metaSet(_keyAvatar, '$picked');
    } catch (e) {
      if (mounted) _toast('保存失败：${humanizeError(e)}');
      return;
    }
    if (!mounted) return;
    setState(() => _avatar = picked);
  }

  Widget _profileCard() {
    final ov = _overview;
    final total = ov?.totalWords ?? 0;
    final rate = total == 0 ? 0.0 : (_mastered / total).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: P.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: P.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: _pickAvatar,
                child: Container(
                  width: 54,
                  height: 54,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _avatarColors[_avatar].withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _avatarColors[_avatar].withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    _name.isEmpty ? '词' : _name.substring(0, 1),
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: _avatarColors[_avatar],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: _editName,
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              _name,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: P.title,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(Icons.edit_outlined, size: 14, color: P.faint),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _streak > 0
                          ? '已连续学习 $_streak 天 · 今天复习 ${ov?.todayReviews ?? 0} 次'
                          : '今天还没开始，复习 ${ov?.dueCount ?? 0} 个就到期的词',
                      style: TextStyle(fontSize: 12, color: P.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _statCell('$_streak', '连续天数'),
              _divider(),
              _statCell('$total', '总词数'),
              _divider(),
              _statCell('$_mastered', '已掌握'),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: rate,
                    minHeight: 6,
                    backgroundColor: P.chip,
                    valueColor: AlwaysStoppedAnimation<Color>(P.primary),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '掌握 ${(rate * 100).toStringAsFixed(0)}%',
                style: TextStyle(fontSize: 11.5, color: P.muted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _divider() => Container(
        width: 1,
        height: 26,
        color: P.border,
      );

  Widget _statCell(String value, String label) => Expanded(
        child: Column(
          children: [
            // 系统字体放大到 1.3 倍以上时，五位数会撑破这一格并溢出黄条，
            // 这里按可用宽度等比缩，读得清也不会挤坏布局
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  color: P.title,
                ),
              ),
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label,
                  maxLines: 1,
                  style: TextStyle(fontSize: 11.5, color: P.faint)),
            ),
          ],
        ),
      );

  // ---------------- 设置项 ----------------

  Widget _sectionTitle(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 20, 2, 8),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: P.muted,
          ),
        ),
      );

  Widget _card(List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: P.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: P.border),
        ),
        child: Column(children: children),
      );

  Widget _row({
    required IconData icon,
    required String title,
    String? subtitle,
    String? trailing,
    Widget? trailingWidget,
    VoidCallback? onTap,
  }) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: P.chip,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 17, color: P.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: P.title,
                      ),
                    ),
                    if (subtitle != null && subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(fontSize: 11.5, color: P.muted),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null)
                Text(
                  trailing,
                  style: TextStyle(fontSize: 12, color: P.faint),
                ),
              if (trailingWidget != null) trailingWidget,
              if (onTap != null) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 18, color: P.faint),
              ],
            ],
          ),
        ),
      );

  /// 当前朗读来源的一行描述。
  String _speechSummary() {
    final s = Speech.instance;
    switch (s.mode) {
      case Speech.modeNeural:
        final id = s.neuralVoice;
        final voice = neuralVoices.where((v) => v.id == id).toList();
        final label = voice.isEmpty ? '未选音色' : voice.first.label;
        return '离线神经语音 · $label · 语速 ${s.rate.toStringAsFixed(2)}';
      case Speech.modeDict:
        return '词典真人发音 · ${s.dictAccent == '1' ? '英音' : '美音'} · 语速 ${s.rate.toStringAsFixed(2)}';
      default:
        return '系统语音 · ${s.voiceName ?? '跟随系统'} · 语速 ${s.rate.toStringAsFixed(2)}';
    }
  }

  Future<void> _showStorage() async {
    final total = _dbBytes + _modelBytes + _synthBytes + _dictBytes;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('存储占用'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _storageLine('数据库（词库、文章、内置词典）', _dbBytes),
              _storageLine('离线语音模型（含未装完的下载）', _modelBytes),
              _storageLine('合成音频缓存', _synthBytes),
              _storageLine('真人发音缓存', _dictBytes),
              const Divider(height: 20),
              _storageLine('合计', total, bold: true),
              const SizedBox(height: 10),
              Text(
                '模型是下载来的语音包，每个约 80MB；删掉音色才会回收。两份缓存可以清，清了不影响词库。',
                style: TextStyle(fontSize: 11.5, height: 1.5, color: P.muted),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  Widget _storageLine(String label, int bytes, {bool bold = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  color: bold ? P.title : P.body,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            Text(
              _fmtBytes(bytes),
              style: TextStyle(
                fontSize: 12.5,
                color: bold ? P.title : P.muted,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
        ),
      );

  Future<void> _clearCache() async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清掉语音缓存？'),
        content: const Text(
          '只删已经合成好的音频和下载过的真人发音，语音模型和词库都不动。'
          '清完第一次朗读会重新合成、重新下载。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清理')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      var freed = 0;
      try {
        freed += await NeuralTts.instance.clearCache();
      } catch (_) {
        // 合成缓存清不动就继续清下一个
      }
      try {
        freed += await Speech.instance.clearDictCache();
      } catch (_) {
        // 同上
      }
      if (!mounted) return;
      _toast(freed <= 0 ? '缓存本来就是空的' : '已释放 ${_fmtBytes(freed)}');
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 一键诊断报告：把能定位问题的环境事实写成 txt，存到手机上发给开发者。
  Future<void> _exportDiagnostics() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final report = await _buildReport();
      final bytes = Uint8List.fromList(utf8.encode(report));
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '保存诊断报告',
        fileName: '词学家诊断-$_stamp.txt',
        type: FileType.any,
        bytes: bytes,
      );
      if (path == null) return;
      if (!mounted) return;
      _toast('已保存诊断报告（${_fmtBytes(bytes.length)}），发我即可');
    } catch (e) {
      if (mounted) _toast('导出失败：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _stamp {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}';
  }

  Future<String> _buildReport() async {
    final buf = StringBuffer();
    final now = DateTime.now();
    void section(String title) {
      buf.write('\n---- $title ----\n');
    }

    buf.write('词学家 诊断报告\n');
    buf.write('生成时间: ${now.toString().substring(0, 19)}\n');
    buf.write('构建标识: $kBuildTag\n');
    buf.write('应用版本: $kAppVersion\n');
    buf.write('系统: ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}\n');
    buf.write('机型架构: ${Platform.numberOfProcessors} 核\n');

    section('数据');
    buf.write('单词 ${_overview?.totalWords ?? 0} 个，其中已掌握 $_mastered 个\n');
    buf.write('今日复习 ${_overview?.todayReviews ?? 0} 次，'
        '到期 ${_overview?.dueCount ?? 0} 个\n');
    buf.write('累计遗忘次数 ${_overview?.totalFailCount ?? 0}\n');
    buf.write('文章 $_articles 篇，连续打卡 $_streak 天\n');

    section('存储');
    buf.write('数据库 ${_fmtBytes(_dbBytes)}\n');
    buf.write('语音模型 ${_fmtBytes(_modelBytes)}\n');
    buf.write('合成缓存 ${_fmtBytes(_synthBytes)}\n');
    buf.write('真人发音缓存 ${_fmtBytes(_dictBytes)}\n');

    section('语音');
    final s = Speech.instance;
    buf.write('模式 ${s.mode}\n');
    buf.write('系统引擎 ${s.engine ?? '跟随系统'}\n');
    buf.write('系统音色 ${s.voiceName ?? '跟随系统'}\n');
    buf.write('离线音色 ${s.neuralVoice ?? '未选'}\n');
    buf.write('语速 ${s.rate.toStringAsFixed(2)}，'
        '词典口音 ${s.dictAccent == '1' ? '英音' : '美音'}\n');
    buf.write('实际生效语言 ${s.activeLanguage ?? '未知'}\n');
    buf.write('当前错误 ${s.lastError ?? '无'}\n');
    // 神经语音的失败原因单独记一份：模型下载/加载失败时 Speech 那边只看到降级，
    // 真正的错误在 NeuralTts 里，不写出来这份报告就定位不到
    buf.write('神经语音错误 ${NeuralTts.instance.lastError ?? '无'}\n');
    try {
      await NeuralTts.instance.refresh();
    } catch (_) {
      // 装了什么读不到就跳过
    }
    for (final voice in neuralVoices) {
      final installed = NeuralTts.instance.isInstalled(voice.id);
      buf.write('音色 ${voice.id}（${voice.label}）'
          '${installed ? ' 已安装' : ' 未安装'}\n');
    }

    section('最近错误（最多 ${Diag.maxLines} 条）');
    final lines = Diag.snapshot();
    if (lines.isEmpty) {
      buf.write('（无）\n');
    } else {
      for (final line in lines) {
        buf.write('$line\n');
      }
    }
    return buf.toString();
  }

  /// 备份真正的入口在「统计」页，这里只负责说清楚去哪找、规则是什么。
  /// 之前这一行没有 onTap，点了没反应，用户以为功能坏了。
  Future<void> _showBackupHint() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('备份与恢复'),
        content: const Text(
          '导出：在「统计」页最下面点「备份」，生成一个 json 文件，存到手机或发给自己。\n'
          '恢复：换手机后在同一位置选「从备份恢复」。只会补上现在没有的词库、单词和文章，'
          '已有的一律跳过，不会覆盖你现在的内容。',
          style: TextStyle(fontSize: 12.5, height: 1.65),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  Future<void> _showContact() async {    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('找设计者'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('使用中遇到问题、想加功能，直接发消息，'
                  '附上「诊断报告」定位最快。',
                  style: TextStyle(fontSize: 12.5, height: 1.6, color: P.body)),
              const SizedBox(height: 12),
              SelectableText('QQ：3250184963',
                  style: TextStyle(fontSize: 13, color: P.title)),
              const SizedBox(height: 6),
              SelectableText('微信：q13248769',
                  style: TextStyle(fontSize: 13, color: P.title)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(
                const ClipboardData(text: 'QQ 3250184963 / 微信 q13248769'),
              );
              if (ctx.mounted) Navigator.pop(ctx);
              _toast('联系方式已复制');
            },
            child: const Text('复制'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: const Text('我的', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: _loading && _overview == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
              children: [
                if (_error != null)
                  ErrorCard(message: _error!, onRetry: _load, busy: _loading),
                if (_overview != null) _profileCard(),
                _sectionTitle('朗读'),
                _card([
                  _row(
                    icon: Icons.record_voice_over_outlined,
                    title: '朗读语音',
                    subtitle: _speechSummary(),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const VoicePage()),
                      );
                      // 回来时配置可能变了，重读一遍
                      await _load();
                    },
                  ),
                ]),
                _sectionTitle('数据与存储'),
                _card([
                  _row(
                    icon: Icons.pie_chart_outline,
                    title: '存储占用',
                    subtitle: '数据库、语音模型、两份缓存分开算',
                    trailing: _fmtBytes(_dbBytes + _modelBytes + _synthBytes + _dictBytes),
                    onTap: _showStorage,
                  ),
                  Divider(height: 1, color: P.border),
                  _row(
                    icon: Icons.cleaning_services_outlined,
                    title: '清理语音缓存',
                    subtitle: _busy ? '正在清理…' : '合成音频与真人发音，不影响词库',
                    onTap: _busy ? null : _clearCache,
                  ),
                  Divider(height: 1, color: P.border),
                  _row(
                    icon: Icons.backup_outlined,
                    title: '备份与恢复',
                    subtitle: '在「统计」页底部导出与恢复，换手机用',
                    onTap: _showBackupHint,
                  ),
                ]),
                _sectionTitle('关于'),
                _card([
                  _row(
                    icon: Icons.verified_outlined,
                    title: '当前版本',
                    subtitle: kBuildTag,
                    trailing: kAppVersion,
                  ),
                  Divider(height: 1, color: P.border),
                  _row(
                    icon: Icons.bug_report_outlined,
                    title: '导出诊断报告',
                    subtitle: _busy ? '正在整理…' : '设备、存储、语音状态和最近错误，导成 txt',
                    onTap: _busy ? null : _exportDiagnostics,
                  ),
                  Divider(height: 1, color: P.border),
                  _row(
                    icon: Icons.chat_bubble_outline,
                    title: '设计者 QQ',
                    subtitle: '3250184963',
                    trailingWidget: Icon(Icons.copy_rounded, size: 15, color: P.faint),
                    onTap: () => _copy('3250184963', 'QQ'),
                  ),
                  Divider(height: 1, color: P.border),
                  _row(
                    icon: Icons.chat_bubble_outline,
                    title: '设计者微信',
                    subtitle: 'q13248769',
                    trailingWidget: Icon(Icons.copy_rounded, size: 15, color: P.faint),
                    onTap: () => _copy('q13248769', '微信'),
                  ),
                  Divider(height: 1, color: P.border),
                  _row(
                    icon: Icons.support_agent_outlined,
                    title: '遇到问题？',
                    subtitle: '把诊断报告和现象一起发过来',
                    onTap: _showContact,
                  ),
                ]),
                const SizedBox(height: 18),
                Center(
                  child: Text(
                    '词库、复习记录只存在这台手机里；词典真人发音与在线翻译会联网请求第三方',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: P.faint),
                  ),
                ),
              ],
            ),
    );
  }
}
