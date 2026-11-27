import '../errors.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../speech.dart';

import '../theme.dart';
/// 复习页：先进设置选范围（全部 / 随机 / 手选），再逐张卡片复习。
/// 卡片右上角有一个很小的删除按钮，看到不想背的词可以直接删掉。
class ReviewPage extends StatefulWidget {
  const ReviewPage({super.key, required this.bookId, required this.bookName});

  final String bookId;
  final String bookName;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  // 0 = 选范围，1 = 复习中，2 = 本轮结束
  int _stage = 0;

  /// 一次最多取多少个词。几万词的库全量加载会查出所有 Word 对象，界面会卡住。
  static const int _reviewBatch = 300;

  int _mode = 0; // 0 全部 / 1 随机 / 2 手选
  int _randomCount = 20;
  String _filter = 'recent';
  List<Word> _selected = [];
  int _total = 0;

  List<Word> _words = [];
  int _index = 0;
  bool _flipped = false;
  bool _busy = false;
  bool _loadingQueue = false;

  int _forgot = 0;
  int _fuzzy = 0;
  int _remembered = 0;

  /// 词库里没存音标时的显示兜底：从内嵌词典现查一份。
  /// 只用来显示，不回写数据库 —— 复习页不该顺手改用户数据。
  String? _dictPhonetic;
  String? _dictPhoneticFor;

  @override
  void initState() {
    super.initState();
    _loadTotal();
  }

  @override
  void dispose() {
    // 离开复习页时把还在念的词停掉，否则会跟着念到别的界面
    Speech.instance.stop();
    super.dispose();
  }

  Future<void> _loadTotal() async {
    try {
      final count = await Api.instance.countWords(widget.bookId);
      if (!mounted) return;
      setState(() => _total = count);
    } catch (_) {
      // 数量取不到不影响复习，忽略
    }
  }

  /// 当前词没音标就去词典查一份。查不到不显示，不影响复习。
  Future<void> _ensurePhonetic() async {
    if (_words.isEmpty || _index >= _words.length) return;
    final word = _words[_index];
    if ((word.phonetic ?? '').trim().isNotEmpty) return;
    if (_dictPhoneticFor == word.id) return;
    _dictPhoneticFor = word.id;
    if (_dictPhonetic != null) setState(() => _dictPhonetic = null);
    try {
      final r = await Api.instance.lookup(word.spelling);
      if (!mounted || _dictPhoneticFor != word.id) return;
      final ph = (r.phonetic ?? '').trim();
      setState(() => _dictPhonetic = ph.isEmpty ? null : ph);
    } catch (_) {
      // 词典查不到或库没装好：卡片照旧，不弹提示
    }
  }

  Future<void> _pickWords() async {
    final all = await Api.instance.words(widget.bookId);
    if (!mounted) return;
    if (all.isEmpty) {
      _toast('这个词库还没有单词');
      return;
    }
    final picked = await Navigator.of(context).push<List<Word>>(
      MaterialPageRoute(builder: (_) => _WordPickerPage(words: all, initial: _selected)),
    );
    if (picked == null || !mounted) return;
    setState(() => _selected = picked);
  }

  Future<void> _start({bool ignoreDue = false}) async {
    if (_mode == 2 && _selected.isEmpty) {
      _toast('先选要复习的单词');
      return;
    }
    setState(() => _loadingQueue = true);
    try {
      List<Word> queue;
      if (_mode == 2) {
        // 不能直接引用 _selected：复习过程中删词会改动「已选」状态，
        // 退回设置页时勾选数量跟着变。拷一份再开始。
        queue = List<Word>.from(_selected);
      } else if (_mode == 1) {
        queue = await Api.instance.reviewQueue(widget.bookId, limit: _randomCount, order: _filter);
      } else {
        // 默认只出已到期的词；今天刷完了给一次「继续加练」的机会。
        // 一次最多取 _reviewBatch 个，免得几万词全量查出来卡在「准备中」。
        queue = await Api.instance
            .reviewQueue(widget.bookId, limit: _reviewBatch, dueOnly: !ignoreDue);
      }
      if (!mounted) return;
      if (queue.isEmpty) {
        setState(() => _loadingQueue = false);
        if (!ignoreDue) {
          final go = await _confirmExtra();
          if (go && mounted) await _start(ignoreDue: true);
          return;
        }
        _toast('没有可复习的单词');
        return;
      }
      setState(() {
        _words = queue;
        _index = 0;
        _flipped = false;
        _forgot = 0;
        _fuzzy = 0;
        _remembered = 0;
        _stage = 1;
        _loadingQueue = false;
      });
      _ensurePhonetic();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingQueue = false);
      _toast(humanizeError(e));
    }
  }

  Future<bool> _confirmExtra() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('今天没有到期的单词'),
        content: const Text('可以继续复习还没到期的词。提前复习会让这些词的下次到期时间重新排，间隔可能变短。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('今天就这样'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('继续加练'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _grade(int result) async {
    if (_busy) return;
    // 队列越界保护：删除最后一个词或队列重建时下标可能已经失效
    if (_index < 0 || _index >= _words.length) return;
    final word = _words[_index];
    // 换下一个词之前先把还在读的那句停掉，不然会出现两个词抢着念
    Speech.instance.stop();
    setState(() => _busy = true);
    try {
      await Api.instance.submitReview(word.id, result, bookId: widget.bookId);
      if (!mounted) return;
      setState(() {
        if (result == 0) {
          _forgot++;
        } else if (result == 1) {
          _fuzzy++;
        } else {
          _remembered++;
        }
        _index++;
        _flipped = false;
        if (_index >= _words.length) _stage = 2;
      });
      if (_stage == 1) _ensurePhonetic();
    } catch (e) {
      _toast(humanizeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteCurrent() async {
    // 评分请求还在路上时不能删，否则界面已经翻到下一张，删掉的会是新词
    if (_busy || _words.isEmpty || _index >= _words.length) return;
    final word = _words[_index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${word.spelling}？'),
        content: const Text('会从这个词库移除，之后再复习也不会出现。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.instance.deleteWord(word.id, bookId: widget.bookId);
      if (!mounted) return;
      setState(() {
        _words.removeAt(_index);
        _flipped = false;
        if (_words.isEmpty || _index >= _words.length) _stage = 2;
      });
      if (_stage == 1) _ensurePhonetic();
      _toast('已删除 ${word.spelling}');
    } catch (e) {
      _toast(humanizeError(e));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('复习 · ${widget.bookName}', style: const TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          if (_stage == 1 && _words.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '$_index/${_words.length}',
                  style: TextStyle(fontSize: 14, color: P.muted),
                ),
              ),
            ),
        ],
      ),
      body: switch (_stage) {
        1 => _buildReview(),
        2 => _buildSummary(),
        _ => _buildSetup(),
      },
    );
  }

  // ---------------- 选范围 --------------

  Widget _buildSetup() {
    final randomMax = _total == 0 ? 20 : (_total < _randomCount ? _total : _randomCount);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            children: [
              Card(
                elevation: 0,
                color: P.card,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('这个词库共 $_total 个词', style: TextStyle(fontSize: 13, color: P.muted)),
                      const SizedBox(height: 12),
                      SegmentedButton<int>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: 0, label: Text('全部'), icon: Icon(Icons.list_alt)),
                          ButtonSegment(value: 1, label: Text('随机'), icon: Icon(Icons.shuffle)),
                          ButtonSegment(value: 2, label: Text('手选'), icon: Icon(Icons.checklist)),
                        ],
                        selected: {_mode},
                        onSelectionChanged: (s) => setState(() => _mode = s.first),
                      ),
                      if (_mode == 0) ...[
                        const SizedBox(height: 12),
                        Text(
                          '只出今天到期的词，按「最久没背过的」顺序排。今天刷完了会问要不要加练。',
                          style: TextStyle(fontSize: 12, color: P.muted),
                        ),
                      ],
                      if (_mode == 1) ...[
                        const SizedBox(height: 18),
                        const Text('抽多少个', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final n in const [10, 20, 30, 50])
                              ChoiceChip(
                                label: Text('$n'),
                                selected: _randomCount == n,
                                onSelected: (_) => setState(() => _randomCount = n),
                              ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        const Text('优先抽哪些', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _filterChip('recent', '最近没背过'),
                            _filterChip('fail', '忘得最多'),
                            _filterChip('random', '随便抽'),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _filter == 'recent'
                              ? '从未背过或最久没背的排在前面'
                              : _filter == 'fail'
                                  ? '忘记次数多的优先抽出来'
                                  : '完全随机，可能抽到刚背过的',
                          style: TextStyle(fontSize: 12, color: P.muted),
                        ),
                        if (_total > 0 && _total < _randomCount)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text('词库共 $_total 个词（已掌握的进不了队列），本轮最多 $randomMax 个',
                                style: TextStyle(fontSize: 12, color: P.faint)),
                          ),
                      ],
                      if (_mode == 2) ...[
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          onPressed: _pickWords,
                          icon: const Icon(Icons.playlist_add_check, size: 18),
                          label: Text(_selected.isEmpty ? '选择单词' : '已选 ${_selected.length} 个，重新选'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: FilledButton(
            onPressed: _loadingQueue ? null : _start,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: _loadingQueue
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('开始复习'),
          ),
        ),
      ],
    );
  }

  Widget _filterChip(String value, String label) {
    return ChoiceChip(
      label: Text(label),
      selected: _filter == value,
      onSelected: (_) => setState(() => _filter = value),
    );
  }

  // ---------------- 复习中 --------------

  Widget _buildReview() {
    if (_words.isEmpty || _index >= _words.length) {
      return Center(child: Text('没有可复习的单词', style: TextStyle(color: P.muted)));
    }
    final word = _words[_index];
    final own = (word.phonetic ?? '').trim();
    // 词库没存音标就用词典现查的那份（只在当前词匹配时生效）
    final phonetic = own.isNotEmpty
        ? own
        : (_dictPhoneticFor == word.id ? _dictPhonetic : null);
    final progress = _words.isEmpty ? 0.0 : _index / _words.length;
    return Column(
      children: [
        // 细进度条：只看数字不直观，走一段更好判断还剩多少
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 2),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: progress),
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              builder: (_, value, __) => LinearProgressIndicator(
                value: value,
                minHeight: 4,
                backgroundColor: P.chip,
                valueColor: AlwaysStoppedAnimation<Color>(P.primary),
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            // 换词整卡上滑淡入：一眼能看出"已经是下一个词"
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              layoutBuilder: (current, previous) => Stack(
                fit: StackFit.expand,
                alignment: Alignment.center,
                children: [...previous, if (current != null) current],
              ),
              transitionBuilder: (child, animation) {
                final curved =
                    CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
                return FadeTransition(
                  opacity: curved,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.06),
                      end: Offset.zero,
                    ).animate(curved),
                    child: child,
                  ),
                );
              },
              child: KeyedSubtree(
                key: ValueKey<String>(word.id),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned.fill(child: _cardBody(word, phonetic)),
                    Positioned(top: 4, right: 4, child: _cardDeleteButton()),
                  ],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Row(
            children: [
              _gradeButton('忘记', Icons.close_rounded, P.danger, 0),
              const SizedBox(width: 10),
              _gradeButton('模糊', Icons.blur_on_rounded, P.warn, 1),
              const SizedBox(width: 10),
              _gradeButton('记得', Icons.check_rounded, P.primaryDeep, 2),
            ],
          ),
        ),
      ],
    );
  }

  Widget _cardDeleteButton() {
    return SizedBox(
      width: 36,
      height: 36,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 17,
        tooltip: '删除这个词',
        icon: Icon(Icons.close, color: P.faint),
        onPressed: _busy ? null : _deleteCurrent,
      ),
    );
  }

  Widget _cardBody(Word word, String? phonetic) {
    return GestureDetector(
      onTap: () => setState(() => _flipped = !_flipped),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: P.card,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: P.border),
          // 很淡的一层落影，白卡浮在护眼底色上才有层次；深色档用纯黑
          boxShadow: [
            BoxShadow(
              color: (P.isDark ? Colors.black : P.primary).withValues(alpha: 0.12),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
        // 高度按卡片实际尺寸算：不写死，横屏和不同屏幕比例都不会把单词压到边角
        child: LayoutBuilder(
          builder: (context, box) {
            // 未翻面：留出上方约四分之一，单词落在卡片中偏上
            // 翻面后：留白收到最小，把剩下的高度全让给释义
            final topGap = _flipped
                ? 8.0
                : (box.maxHeight * 0.24).clamp(24.0, 220.0);
            return Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  height: topGap,
                ),
                Text(
                  word.spelling,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                    color: P.title,
                  ),
                ),
                // 音标可能晚一步才查到，用高度动画接上，别让卡片整体跳一下
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: phonetic == null || phonetic.isEmpty
                      ? const SizedBox(height: 8, width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            phonetic,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 16,
                              letterSpacing: 0.3,
                              color: P.muted,
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: 12),
                IconButton(
                  tooltip: '朗读',
                  style: IconButton.styleFrom(
                    backgroundColor: P.chip,
                    foregroundColor: P.primary,
                    shape: const CircleBorder(),
                  ),
                  icon: const Icon(Icons.volume_up_rounded, size: 20),
                  onPressed: () => Speech.instance.speak(word.spelling),
                ),
                const SizedBox(height: 16),
                // 翻面只换下半张：淡入 + 高度展开，卡片本身不重绘
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.topCenter,
                      children: [...previous, if (current != null) current],
                    ),
                    child: _flipped
                        ? KeyedSubtree(
                            key: const ValueKey<String>('answer'),
                            child: _answer(word))
                        : KeyedSubtree(
                            key: const ValueKey<String>('hint'), child: _hint()),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _answer(Word word) {
    // 释义可能很长，包一层滚动：高度受限时能滚，内容不多时按内容占高
    return SingleChildScrollView(
      primary: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(height: 1, color: P.border),
          const SizedBox(height: 14),
          Text(
            word.definition ?? '暂无释义',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 17, height: 1.6, color: P.body),
          ),
          if ((word.forms ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: P.chipAlt,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                word.forms!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: P.body, height: 1.6),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Text(
            '忘记 ${word.failCount} 次 · 模糊 ${word.fuzzyCount} 次',
            style: TextStyle(fontSize: 12, color: P.faint),
          ),
        ],
      ),
    );
  }

  Widget _hint() {
    // 贴着喇叭下方出现，跟释义块同一个起点，翻面时文字不会上下乱跳
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text(
          '点击看释义',
          style: TextStyle(fontSize: 13, color: P.faint, letterSpacing: 1.2),
        ),
      ),
    );
  }

  Widget _gradeButton(String label, IconData icon, Color color, int result) {
    // 深色档里红/橙/绿是提亮过的，直接做实心底会晃眼，改成深底 + 亮色字和描边
    return Expanded(
      child: FilledButton(
        onPressed: _busy ? null : () => _grade(result),
        style: FilledButton.styleFrom(
          backgroundColor: P.isDark ? P.cardAlt : color,
          foregroundColor: P.isDark ? color : P.onPrimary,
          side: P.isDark ? BorderSide(color: color.withValues(alpha: 0.5)) : BorderSide.none,
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 5),
            Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  // ---------------- 本轮结束 --------------

  Widget _buildSummary() {
    final total = _forgot + _fuzzy + _remembered;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 56, color: P.primary),
            const SizedBox(height: 16),
            const Text('这一轮复习完了', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('共 $total 个 · 忘记 $_forgot · 模糊 $_fuzzy · 记得 $_remembered',
                style: TextStyle(fontSize: 14, color: P.muted)),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () {
                setState(() {
                  _stage = 0;
                  _words = [];
                  _index = 0;
                  _flipped = false;
                });
                _loadTotal();
              },
              child: const Text('换个范围再来'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('返回词库'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 手选单词页：勾选要复习的词，返回选中的列表。
class _WordPickerPage extends StatefulWidget {
  const _WordPickerPage({required this.words, required this.initial});

  final List<Word> words;
  final List<Word> initial;

  @override
  State<_WordPickerPage> createState() => _WordPickerPageState();
}

class _WordPickerPageState extends State<_WordPickerPage> {
  late final Set<String> _checked = widget.initial.map((e) => e.id).toSet();
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Word> get _filtered {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return widget.words;
    return widget.words.where((w) {
      final def = (w.definition ?? '').toLowerCase();
      return w.spelling.toLowerCase().contains(q) || def.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    // 过滤只算一次，否则列表里每一行都会把整份词表重新过滤一遍
    final visible = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: Text('已选 ${_checked.length} 个', style: const TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          TextButton(
            onPressed: () {
              // 只作用于当前搜索出来的这一批，避免选到没看见的词
              if (visible.isEmpty) return;
              setState(() {
                final allChecked = visible.every((w) => _checked.contains(w.id));
                if (allChecked) {
                  _checked.removeAll(visible.map((e) => e.id));
                } else {
                  _checked.addAll(visible.map((e) => e.id));
                }
              });
            },
            child: Text(
              visible.isNotEmpty && visible.every((w) => _checked.contains(w.id)) ? '取消全选' : '全选',
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '搜索拼写或释义',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: P.card,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              itemCount: visible.length,
              itemBuilder: (context, i) {
                final word = visible[i];
                final on = _checked.contains(word.id);
                return Card(
                  elevation: 0,
                  color: P.card,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: CheckboxListTile(
                    value: on,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(word.spelling, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      word.definition ?? '暂无释义',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    secondary: word.failCount > 0
                        ? Text('忘${word.failCount}',
                            style: TextStyle(fontSize: 12, color: P.danger))
                        : null,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _checked.add(word.id);
                        } else {
                          _checked.remove(word.id);
                        }
                      });
                    },
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: FilledButton(
              onPressed: () {
                final picked =
                    widget.words.where((w) => _checked.contains(w.id)).toList();
                Navigator.of(context).pop(picked);
              },
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: Text('确定（${_checked.length} 个）'),
            ),
          ),
        ],
      ),
    );
  }
}
