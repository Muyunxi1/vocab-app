import '../errors.dart';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../speech.dart';
import 'add_words.dart';
import 'article_page.dart';
import 'rank.dart';
import 'review.dart';

import '../theme.dart';
class BookDetailPage extends StatefulWidget {
  const BookDetailPage({super.key, required this.book});

  final Book book;

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  /// 一次读多少条，滚动到底再接着读。
  static const int _pageSize = 200;

  final _search = TextEditingController();
  final _scroll = ScrollController();

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;
  List<Word> _words = [];
  String _sort = 'created';

  /// 多选筛选条件，见 Api.words 的 filters。
  final Set<String> _filters = {};

  /// 批量管理模式：列表变复选框，长按不再删除。
  bool _manage = false;
  final Set<String> _selected = {};

  /// 当前筛选条件下的全部词 id，用来判断「全选」状态。
  Set<String> _allIds = {};
  bool _busy = false;

  /// 清理「导入误加的遗忘次数」进行中。单独一个标志，
  /// 不复用 [_busy]，否则「补全释义」按钮会误显示成「补全中…」。
  bool _clearing = false;

  /// 请求序号，用来丢弃过期的返回（快速连点排序时防止旧结果盖掉新结果）。
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 240) {
      _loadMore();
    }
  }

  /// [keepScroll] 为 true 时不回到顶部。编辑释义、批量改掌握状态这类操作
  /// 只动了某几个词，整页跳回第一页会让用户在 1000 词的库里重新滚很久；
  /// 搜索、换排序、换筛选才需要从头看。
  Future<void> _load({bool keepScroll = false}) async {
    final seq = ++_seq;
    try {
      final words = await Api.instance.words(
        widget.book.id,
        q: _search.text.trim(),
        sort: _sort,
        limit: _pageSize,
        filters: _filters,
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        _words = words;
        _hasMore = words.length == _pageSize;
        _error = null;
        _loading = false;
        // 列表换了内容，旧的选择已经没有意义
        _selected.clear();
        _allIds = {};
      });
      if (!keepScroll && _scroll.hasClients) _scroll.jumpTo(0);
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = humanizeError(e);
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final seq = _seq;
    setState(() => _loadingMore = true);
    try {
      final more = await Api.instance.words(
        widget.book.id,
        q: _search.text.trim(),
        sort: _sort,
        limit: _pageSize,
        offset: _words.length,
        filters: _filters,
      );
      if (!mounted || seq != _seq) {
        if (mounted) setState(() => _loadingMore = false);
        return;
      }
      setState(() {
        _words = [..._words, ...more];
        _hasMore = more.length == _pageSize;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      _toast(humanizeError(e));
    }
  }

  Future<void> _editWord(Word word) async {
    final definition = TextEditingController(text: word.definition ?? '');
    final phonetic = TextEditingController(text: word.phonetic ?? '');
    final forms = TextEditingController(text: word.forms ?? '');
    var failCount = word.failCount;
    var mastered = word.mastered;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (innerCtx, setSheetState) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(innerCtx).viewInsets.bottom),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            // 键盘弹起后可用高度只剩一半，Column 又不会滚动，
            // 底部「保存」会被顶出屏幕点不到。整块限高并可滚动。
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(word.spelling,
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                    ),
                    IconButton(
                      tooltip: '朗读',
                      icon: const Icon(Icons.volume_up_outlined, size: 22),
                      onPressed: () => Speech.instance.speak(word.spelling),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: phonetic,
                  decoration: const InputDecoration(labelText: '音标', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: definition,
                  maxLines: 6,
                  minLines: 3,
                  decoration: const InputDecoration(
                    labelText: '释义',
                    hintText: '按词性分行，第一行是常用释义',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: forms,
                  maxLines: 3,
                  minLines: 1,
                  decoration: const InputDecoration(
                    labelText: '常用变形',
                    hintText: '例：过去式 went / 过去分词 gone / 现在分词 going',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: P.cardAlt,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Text('忘记次数', style: TextStyle(fontSize: 14)),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline, size: 20),
                        onPressed: failCount <= 0 ? null : () => setSheetState(() => failCount--),
                      ),
                      SizedBox(
                        width: 36,
                        child: Text(
                          '$failCount',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: P.danger,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline, size: 20),
                        onPressed: () => setSheetState(() => failCount++),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: mastered,
                  onChanged: (v) => setSheetState(() => mastered = v),
                  title: const Text('已掌握，不再进复习队列', style: TextStyle(fontSize: 14)),
                  subtitle: Text('遗忘次数仍然保留在排行榜里',
                      style: TextStyle(fontSize: 11, color: P.faint)),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('保存'),
                ),
              ],
              ),
            ),
          ),
        ),
      ),
    );

    try {
      if (saved != true || !mounted) return;
      final newDef = definition.text.trim();
      final newPh = phonetic.text.trim();
      final newForms = forms.text.trim();
      // 只有真的改过才写，避免没动释义也把它覆盖成空
      final defChanged = newDef != (word.definition ?? '').trim();
      final phChanged = newPh != (word.phonetic ?? '').trim();
      final formsChanged = newForms != (word.forms ?? '').trim();
      if (defChanged || phChanged || formsChanged) {
        await Api.instance.updateWord(
          widget.book.id,
          word.id,
          definition: defChanged ? newDef : null,
          phonetic: phChanged ? newPh : null,
          forms: formsChanged ? newForms : null,
        );
      }
      if (failCount != word.failCount) {
        await Api.instance.setFailCount(widget.book.id, word.id, failCount);
      }
      if (mastered != word.mastered) {
        await Api.instance.setMastered(widget.book.id, word.id, mastered);
      }
      if (!mounted) return;
      await _load(keepScroll: true);
    } catch (e) {
      _toast(humanizeError(e));
    } finally {
      definition.dispose();
      phonetic.dispose();
      forms.dispose();
    }
  }

  Future<void> _deleteWord(Word word) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${word.spelling}？'),
        content: const Text('会从这个词库移除；如果它不在任何其他词库，单词本身也会被删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await Api.instance.deleteWord(word.id, bookId: widget.book.id);
      if (!mounted) return;
      await _load();
    } catch (e) {
      _toast(humanizeError(e));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 清理历史上「导入时误加」的遗忘次数：先预览命中多少、是哪几个词，确认后才写库。
  /// 只清「只导入过一次、从没复习过」的，手动改过的和重复导入的都不动。
  Future<void> _clearDirtyFail() async {
    if (_busy || _clearing) return;
    setState(() => _clearing = true);
    try {
      final info = await Api.instance.previewDirtyFailCounts(widget.book.id);
      if (!mounted) return;
      final tail = info.repeatSuspects > 0
          ? '\n\n另有 ${info.repeatSuspects} 个重复导入过的词，用「更多」里另一项单独清理。'
          : '';
      if (info.count == 0) {
        _toast('没有「只导入过一次」误加的遗忘次数${tail.isEmpty ? '' : '；${info.repeatSuspects} 个重复导入过的去另一项处理'}');
        return;
      }
      final sample = info.samples.isEmpty ? '' : '\n\n例如：${info.samples.join('、')}';
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('清理导入误加的遗忘次数'),
          content: Text(
            '将清理 ${info.count} 个词的遗忘次数。$sample$tail\n\n'
            '只清遗忘次数，掌握状态和下次复习时间不变。清理后无法还原，建议先导出备份。',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清理')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      final n = await Api.instance.clearDirtyFailCounts(widget.book.id);
      if (!mounted) return;
      _toast('已清理 $n 个词的遗忘次数');
      await _load();
    } catch (e) {
      _toast(humanizeError(e));
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  /// 清理「重复导入」累加出来的遗忘次数。这批和历史手动调整在数据上无法区分，
  /// 所以把命中的词整条列出来，默认全选、可以逐条取消，勾错了能当场去掉。
  Future<void> _clearRepeatFail() async {
    if (_busy || _clearing) return;
    setState(() => _clearing = true);
    try {
      final items = await Api.instance.previewRepeatDirtyWords(widget.book.id);
      if (!mounted) return;
      if (items.isEmpty) {
        _toast('没有重复导入累加的遗忘次数');
        return;
      }
      final picked = <String>{for (final it in items) it.id};
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDlg) => AlertDialog(
            title: Text('清理重复导入的遗忘次数（${items.length} 个）'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '这些词的遗忘次数是重复导入累加出来的，不是真背错。'
                    '如果你手动改过某个词的次数，它也会出现在这里，不需要就去掉勾选。',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 300,
                    child: ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final it = items[i];
                        return CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: picked.contains(it.id),
                          title: Text(
                            '${it.spelling}　忘 ${it.failCount}',
                            style: const TextStyle(fontSize: 13),
                          ),
                          onChanged: (v) => setDlg(() {
                            if (v == true) {
                              picked.add(it.id);
                            } else {
                              picked.remove(it.id);
                            }
                          }),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
              FilledButton(
                onPressed: picked.isEmpty ? null : () => Navigator.pop(ctx, true),
                child: Text(picked.isEmpty ? '清理' : '清理 ${picked.length} 个'),
              ),
            ],
          ),
        ),
      );
      if (ok != true || !mounted) return;
      final n = await Api.instance.clearRepeatDirtyCounts(widget.book.id, picked.toList());
      if (!mounted) return;
      _toast('已清理 $n 个词的遗忘次数');
      await _load();
    } catch (e) {
      _toast(humanizeError(e));
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _manage ? '已选 ${_selected.length} 个' : widget.book.name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        leading: _manage
            ? IconButton(
                tooltip: '退出批量',
                icon: const Icon(Icons.close),
                onPressed: _exitManage,
              )
            : null,
        actions: _manage
            ? [
                TextButton(
                  onPressed: _busy ? null : _toggleAll,
                  child: Text(
                    _isAllSelected ? '取消全选' : '全选',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ]
            : [
                IconButton(
                  tooltip: '生成文章',
                  icon: const Icon(Icons.menu_book_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ArticlePage(bookId: widget.book.id, bookName: widget.book.name),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '遗忘排行',
                  icon: const Icon(Icons.leaderboard_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => RankPage(bookId: widget.book.id, bookName: widget.book.name)),
                  ),
                ),
                IconButton(
                  tooltip: '开始复习',
                  icon: const Icon(Icons.style_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => ReviewPage(bookId: widget.book.id, bookName: widget.book.name)),
                  ),
                ),
                IconButton(
                  tooltip: '批量管理',
                  icon: const Icon(Icons.checklist),
                  onPressed: _enterManage,
                ),
                PopupMenuButton<String>(
                  tooltip: '更多',
                  enabled: !_busy && !_clearing,
                  onSelected: (v) {
                    if (v == 'clearDirty') _clearDirtyFail();
                    if (v == 'clearRepeat') _clearRepeatFail();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'clearDirty',
                      child: Text('清理导入误加的遗忘次数'),
                    ),
                    PopupMenuItem(
                      value: 'clearRepeat',
                      child: Text('清理重复导入的遗忘次数'),
                    ),
                  ],
                ),
              ],
      ),
      floatingActionButton: _manage
          ? null
          : FloatingActionButton.extended(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => AddWordsPage(bookId: widget.book.id, bookName: widget.book.name)),
                );
                if (!mounted) return;
                await _load();
              },
              icon: const Icon(Icons.add),
              label: const Text('添加单词'),
            ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _load(),
              decoration: InputDecoration(
                hintText: '搜索拼写或释义',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _search.clear();
                    _load();
                  },
                ),
                filled: true,
                fillColor: P.card,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _sortChip('created', '最新'),
                const SizedBox(width: 8),
                _sortChip('fail', '忘记次数'),
                const SizedBox(width: 8),
                _sortChip('alpha', '字母'),
              ],
            ),
          ),
          _filterRow(),
          const SizedBox(height: 6),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!, textAlign: TextAlign.center),
                              const SizedBox(height: 12),
                              FilledButton(onPressed: _load, child: const Text('重试')),
                            ],
                          ),
                        ),
                      )
                    : _words.isEmpty
                        ? Center(
                            child: Text(
                              _search.text.trim().isEmpty ? '还没有单词' : '没有匹配的单词',
                              style: TextStyle(color: P.muted),
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.separated(
                              controller: _scroll,
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                              itemCount: _words.length + (_hasMore ? 1 : 0),
                              separatorBuilder: (_, __) => const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                if (index >= _words.length) {
                                  return const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 18),
                                    child: Center(
                                      child: SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      ),
                                    ),
                                  );
                                }
                                final word = _words[index];
                                return Card(
                                  elevation: 0,
                                  color: P.card,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  child: ListTile(
                                    contentPadding: EdgeInsets.symmetric(
                                        horizontal: _manage ? 4 : 14, vertical: 4),
                                    leading: _manage
                                        ? SizedBox(
                                            width: 40,
                                            child: Checkbox(
                                              value: _selected.contains(word.id),
                                              onChanged: (_) => _toggleSelect(word),
                                              materialTapTargetSize:
                                                  MaterialTapTargetSize.shrinkWrap,
                                              visualDensity: VisualDensity.compact,
                                            ),
                                          )
                                        : null,
                                    title: Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            word.spelling,
                                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                        if (word.phonetic != null && word.phonetic!.isNotEmpty) ...[
                                          const SizedBox(width: 8),
                                          Text(word.phonetic!, style: TextStyle(fontSize: 12, color: P.muted)),
                                        ],
                                        if (word.mastered) ...[
                                          const SizedBox(width: 6),
                                          Tooltip(
                                            message: '已掌握',
                                            child: Icon(Icons.check_circle,
                                                size: 15, color: P.primary),
                                          ),
                                        ],
                                      ],
                                    ),
                                    subtitle: Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: _definitionText(word),
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          tooltip: '朗读',
                                          padding: EdgeInsets.zero,
                                          visualDensity: VisualDensity.compact,
                                          constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                                          icon: Icon(Icons.volume_up_outlined,
                                              size: 18, color: P.muted),
                                          onPressed: () => Speech.instance.speak(word.spelling),
                                        ),
                                        if (word.failCount > 0)
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                                            decoration: BoxDecoration(
                                              color: P.dangerBg,
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            child: Text(
                                              '忘${word.failCount}',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: P.danger,
                                                  fontWeight: FontWeight.w600),
                                            ),
                                          ),
                                      ],
                                    ),
                                    onTap: () => _manage ? _toggleSelect(word) : _editWord(word),
                                    onLongPress: () =>
                                        _manage ? _toggleSelect(word) : _deleteWord(word),
                                  ),
                                );
                              },
                            ),
                          ),
          ),
          if (_manage) _batchBar(),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 筛选

  /// 变形词（minutes / responding）在词典里没有独立条目，添加时查不到就存了空释义。
  /// 这里按原形回查补上，只填空字段，手填过的内容和已有释义都不动。
  Future<void> _fillMissing() async {
    if (_busy) return;
    setState(() => _busy = true);
    var total = 0;
    var rounds = 0;
    var reachedCap = false;
    try {
      // 每轮最多补 500 条。原来写死「最多 5 轮」，词库超过 2500 个待补的词时
      // 后面的词会被静默放过，用户只看到「补上了 2500 个」，不知道还有剩。
      while (true) {
        if (rounds >= 20) {
          reachedCap = true;
          break;
        }
        rounds++;
        final n = await Api.instance.fillMissingDefinitions(bookId: widget.book.id);
        total += n;
        if (n < 500) break;
      }
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      final text = total == 0
          ? '这些词在词库里没有对应原形，补不了释义'
          : '补上了 $total 个词的释义${reachedCap ? '（单次上限已用完，再点一次继续补剩下的）' : ''}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('补全失败：${humanizeError(e)}')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _filterRow() {
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _filterChipTile('fail', '遗忘过'),
          const SizedBox(width: 8),
          _filterChipTile('mastered', '已掌握'),
          const SizedBox(width: 8),
          _filterChipTile('unmastered', '未掌握'),
          const SizedBox(width: 8),
          _filterChipTile('noDef', '暂无释义'),
          const SizedBox(width: 8),
          _filterChipTile('forms', '有变形'),
          if (_filters.contains('noDef'))
            TextButton(
              onPressed: _busy ? null : _fillMissing,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
              ),
              child: Text(
                _busy ? '补全中…' : '补全释义',
                style: TextStyle(fontSize: 11.5, color: P.primary),
              ),
            ),
          if (_filters.isNotEmpty)
            TextButton(
              onPressed: () {
                setState(() => _filters.clear());
                _load();
              },
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
              ),
              child: Text('清除', style: TextStyle(fontSize: 11.5, color: P.muted)),
            ),
        ],
      ),
    );
  }

  Widget _filterChipTile(String value, String label) {
    final active = _filters.contains(value);
    return GestureDetector(
      onTap: () {
        setState(() {
          if (active) {
            _filters.remove(value);
          } else {
            _filters.add(value);
            // 已掌握 / 未掌握 互斥，同时选等于没筛
            if (value == 'mastered') _filters.remove('unmastered');
            if (value == 'unmastered') _filters.remove('mastered');
          }
        });
        _load();
      },
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: active ? P.accentSoft : P.chip,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: active ? P.primary : P.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: active ? P.primaryDeep : P.muted,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 批量管理

  bool get _isAllSelected => _allIds.isNotEmpty && _selected.length >= _allIds.length;

  void _enterManage() {
    setState(() {
      _manage = true;
      _selected.clear();
      _allIds = {};
    });
  }

  void _exitManage() {
    setState(() {
      _manage = false;
      _selected.clear();
      _allIds = {};
    });
  }

  void _toggleSelect(Word word) {
    setState(() {
      if (!_selected.add(word.id)) _selected.remove(word.id);
    });
  }

  /// 全选拉的是「当前筛选结果」的全部 id，不只是已经滚出来的那些。
  Future<void> _toggleAll() async {
    if (_busy) return;
    if (_isAllSelected) {
      setState(() => _selected.clear());
      return;
    }
    setState(() => _busy = true);
    try {
      final all = await Api.instance.words(
        widget.book.id,
        q: _search.text.trim(),
        sort: _sort,
        filters: _filters,
        limit: 0,
      );
      if (!mounted) return;
      setState(() {
        _allIds = all.map((w) => w.id).toSet();
        _selected
          ..clear()
          ..addAll(_allIds);
      });
    } catch (e) {
      _toast('全选失败：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _batchDelete() async {
    if (_selected.isEmpty || _busy) return;
    final count = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 $count 个词？'),
        content: const Text('仍在其他词库里的词只解除本库关联，只在本库的词会连词条一起删。删除不能撤销，需要留底的话先导一份备份。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('删除 $count 个')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await Api.instance.deleteWords(widget.book.id, _selected.toList());
      if (!mounted) return;
      _exitManage();
      await _load();
      _toast('已删除 $count 个词');
    } catch (e) {
      _toast('删除失败：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _batchMastered(bool mastered) async {
    if (_selected.isEmpty || _busy) return;
    final count = _selected.length;
    setState(() => _busy = true);
    try {
      await Api.instance.setMasteredBatch(widget.book.id, _selected.toList(), mastered);
      if (!mounted) return;
      await _load(keepScroll: true);
      _toast(mastered ? '已标记 $count 个为已掌握' : '已取消 $count 个的掌握标记');
    } catch (e) {
      _toast('操作失败：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _batchResetFail() async {
    if (_selected.isEmpty || _busy) return;
    final count = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('重置 $count 个词的遗忘次数？'),
        content: const Text('遗忘次数和模糊次数一起清零，下次复习时间不受影响。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('重置')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await Api.instance.resetFailCountBatch(widget.book.id, _selected.toList());
      if (!mounted) return;
      await _load(keepScroll: true);
      _toast('已重置 $count 个词的遗忘次数');
    } catch (e) {
      _toast('操作失败：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 导出选中的词：按 id 从库里重新取一遍，选中的词不在当前页也能导全。
  Future<void> _exportSelected() async {
    if (_selected.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final all = await Api.instance.words(widget.book.id, sort: 'alpha', limit: 0);
      final picked = all.where((w) => _selected.contains(w.id)).toList();
      if (picked.isEmpty) {
        _toast('选中的词已经不在这个库里了');
        return;
      }
      final safeName = widget.book.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出选中的词',
        fileName: '$safeName-${picked.length}词.csv',
        bytes: utf8.encode('\ufeff${_toCsv(picked)}'),
      );
      if (!mounted) return;
      if (path == null) {
        _toast('已取消导出');
        return;
      }
      _toast('已导出 ${picked.length} 个词');
    } catch (e) {
      _toast('导出失败：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _toCsv(List<Word> words) {
    final buffer = StringBuffer('spelling,phonetic,definition,forms,failCount,fuzzyCount,mastered\r\n');
    for (final word in words) {
      buffer.write([
        _csvCell(word.spelling),
        _csvCell(word.phonetic ?? ''),
        _csvCell(word.definition ?? ''),
        _csvCell(word.forms ?? ''),
        '${word.failCount}',
        '${word.fuzzyCount}',
        word.mastered ? '1' : '0',
      ].join(','));
      buffer.write('\r\n');
    }
    return buffer.toString();
  }

  /// 逗号、引号、换行都要按 CSV 规矩转义，否则导入时列会串。
  String _csvCell(String value) {
    final needsQuote = value.contains(',') || value.contains('"') ||
        value.contains('\n') || value.contains('\r');
    final escaped = value.replaceAll('"', '""');
    return needsQuote ? '"$escaped"' : escaped;
  }

  Widget _definitionText(Word word) {
    final definition = (word.definition ?? '').trim();
    final isEmpty = definition.isEmpty;
    return Text(
      isEmpty ? '暂无释义' : definition,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 13, color: isEmpty ? P.warn : P.body),
    );
  }

  Widget _batchBar() {
    final count = _selected.length;
    final disabled = count == 0 || _busy;
    return Container(
      decoration: BoxDecoration(
        color: P.card,
        border: Border(top: BorderSide(color: P.border)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              _batchButton('删除', Icons.delete_outline,
                  disabled ? null : _batchDelete, danger: true),
              _batchButton('已掌握', Icons.check_circle_outline,
                  disabled ? null : () => _batchMastered(true)),
              _batchButton('取消掌握', Icons.remove_circle_outline,
                  disabled ? null : () => _batchMastered(false)),
              _batchButton('重置遗忘', Icons.restart_alt,
                  disabled ? null : _batchResetFail),
              _batchButton('导出 CSV', Icons.file_download_outlined,
                  disabled ? null : _exportSelected),
            ],
          ),
        ),
      ),
    );
  }

  Widget _batchButton(String label, IconData icon, VoidCallback? onPressed,
      {bool danger = false}) {
    final color = onPressed == null ? P.faint : (danger ? P.danger : P.title);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 17, color: color),
        label: Text(label, style: TextStyle(fontSize: 12.5, color: color)),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
        ),
      ),
    );
  }

  Widget _sortChip(String value, String label) {
    final active = _sort == value;
    return ChoiceChip(
      label: Text(label),
      selected: active,
      showCheckmark: false,
      onSelected: (_) {
        if (_sort == value) return;
        setState(() => _sort = value);
        _load();
      },
    );
  }
}
