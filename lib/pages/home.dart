import '../errors.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import 'book_detail.dart';
import 'handwriting_page.dart';
import 'lookup.dart';
import 'voice_page.dart';
import '../widgets.dart';

import '../theme.dart';
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.refreshSignal = 0});

  /// 每次切回这个 tab 时父层把数字加一，页面据此重新拉一次数据。
  final int refreshSignal;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _loading = true;
  String? _error;
  List<Book> _books = [];
  Overview? _overview;

  String? _quickBookId;
  final _quickInput = TextEditingController();
  bool _quickBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // tab 常驻在 IndexedStack 里，从别的页面切回来时不会重建，
    // 概览数字（今日到期、累计忘记）要靠这个信号刷新。
    if (widget.refreshSignal != oldWidget.refreshSignal) _load();
  }

  @override
  void dispose() {
    _quickInput.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([Api.instance.books(), Api.instance.overview()]);
      if (!mounted) return;
      setState(() {
        _books = results[0] as List<Book>;
        _overview = results[1] as Overview;
        if (_quickBookId == null || !_books.any((b) => b.id == _quickBookId)) {
          _quickBookId = _books.isEmpty ? null : _books.first.id;
        }
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = humanizeError(e);
        _loading = false;
      });
    }
  }

  Future<void> _createBook() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建词库'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如：四级核心、阅读生词'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('创建')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    try {
      await Api.instance.createBook(name);
      await _load();
    } catch (e) {
      _toast(humanizeError(e));
    }
  }

  Future<void> _deleteBook(Book book) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${book.name}」？'),
        content: const Text('词库里的关联会一起删掉，单词本身如果还在别的词库里会保留。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.instance.deleteBook(book.id);
      await _load();
    } catch (e) {
      _toast(humanizeError(e));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 主界面直接加词：输完回车就进库，加一次记一次忘记。
  Future<void> _quickAdd(String text) async {
    // 回车能连发：上一次请求还没回来，第二次又进来，同一个词会被记两次忘记次数。
    if (_quickBusy) return;
    final value = text.trim();
    if (value.isEmpty) return;
    final bookId = _quickBookId;
    if (bookId == null) {
      _toast('先建一个词库');
      return;
    }
    setState(() => _quickBusy = true);
    try {
      final word = await Api.instance.addWord(bookId, value,
          autoLookup: true, countAsFail: true);
      if (!mounted) return;
      _quickInput.clear();
      _toast(word.failCount > 0
          ? '已加 ${word.spelling}，之前忘记过 ${word.failCount} 次'
          : '已加 ${word.spelling}');
      await _load();
    } catch (e) {
      _toast(humanizeError(e));
    } finally {
      if (mounted) setState(() => _quickBusy = false);
    }
  }

  Widget _buildQuickAdd() {
    return Card(
      elevation: 0,
      color: P.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.add_circle_outline, size: 18, color: P.primary),
                const SizedBox(width: 6),
                const Text('加生词', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                const Spacer(),
                IconButton(
                  onPressed: _openHandwriting,
                  tooltip: '手写录入',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 0, minHeight: 36),
                  visualDensity: VisualDensity.compact,
                  icon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.draw_outlined, size: 18, color: P.primary),
                      const SizedBox(width: 4),
                      Text('手写', style: TextStyle(fontSize: 13, color: P.primary)),
                    ],
                  ),
                ),
                if (_books.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _quickBookId,
                        isDense: true,
                        isExpanded: true,
                        style: TextStyle(fontSize: 13, color: P.primary),
                        items: [
                          for (final book in _books)
                            DropdownMenuItem(
                              value: book.id,
                              child: Center(
                                child: Text(book.name,
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => _quickBookId = v),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _quickInput,
                    textInputAction: TextInputAction.done,
                    onSubmitted: _quickAdd,
                    decoration: InputDecoration(
                      hintText: _books.isEmpty ? '先建词库' : '输入单词，回车添加',
                      isDense: true,
                      filled: true,
                      fillColor: P.cardAlt,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: _quickBusy ? null : () => _quickAdd(_quickInput.text),
                    child: _quickBusy
                        ? const SizedBox(
                            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('添加'),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('手动加词算一次忘记，重复添加会继续累加；导入的词不计',
                  style: TextStyle(fontSize: 11, color: P.faint)),
            ),
          ],
        ),
      ),
    );
  }

  /// 主页最上面的查词入口：只看释义，不进词库。
  Widget _buildLookupEntry() {
    return Card(
      elevation: 0,
      color: P.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const LookupPage()),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
          child: Row(
            children: [
              Icon(Icons.search, size: 20, color: P.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '查词：输一个单词，看音标和释义',
                  style: TextStyle(fontSize: 14, color: P.muted),
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: P.faint),
            ],
          ),
        ),
      ),
    );
  }

  /// 手写录入：进独立页面，选词库、画板识别后批量入库。
  void _openHandwriting() => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => HandwritingPage(initialBookId: _quickBookId),
        ),
      );

  /// 主题切换：三档一次选完，选完立刻生效并记住。
  Future<void> _pickTheme() async {
    final current = ThemeController.instance.mode;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('换个配色',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: P.title)),
            ),
            for (final m in AppThemeMode.values)
              ListTile(
                leading: Icon(themeIcon(m), color: current == m ? P.primary : P.muted),
                title: Text(themeLabel(m),
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: current == m ? FontWeight.w600 : FontWeight.w400,
                        color: P.title)),
                subtitle: Text(themeHint(m), style: TextStyle(fontSize: 12, color: P.muted)),
                trailing: current == m ? Icon(Icons.check, color: P.primary, size: 20) : null,
                onTap: () {
                  ThemeController.instance.setMode(m);
                  Navigator.pop(ctx);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('词学家', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: IconButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const VoicePage()),
              ),
              tooltip: '朗读语音',
              icon: Icon(Icons.record_voice_over_outlined, size: 19, color: P.muted),
              style: IconButton.styleFrom(
                backgroundColor: P.chip,
                padding: const EdgeInsets.all(7),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(color: P.border),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: TextButton.icon(
              onPressed: _pickTheme,
              icon: Icon(Icons.palette_outlined, size: 17, color: P.muted),
              label: Text(
                themeLabel(ThemeController.instance.mode),
                style: TextStyle(fontSize: 13, color: P.muted),
              ),
              style: TextButton.styleFrom(
                backgroundColor: P.chip,
                foregroundColor: P.muted,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(color: P.border),
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createBook,
        icon: const Icon(Icons.add),
        label: const Text('新建词库'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                children: [
                  if (_error != null)
                    ErrorCard(message: _error!, onRetry: _load, busy: _loading),
                  _buildLookupEntry(),
                  const SizedBox(height: 12),
                  if (_overview != null) _OverviewCard(overview: _overview!),
                  const SizedBox(height: 12),
                  _buildQuickAdd(),
                  const SizedBox(height: 16),
                  if (_books.isEmpty && _error == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 48),
                      child: Center(
                        child: Text('还没有词库，点右下角新建一个', style: TextStyle(color: P.muted)),
                      ),
                    ),
                  for (final book in _books)
                    Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      elevation: 0,
                      color: P.card,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        title: Text(book.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                        subtitle: Text('${book.wordCount} 个词'),
                        trailing: IconButton(
                          icon: Icon(Icons.delete_outline, size: 20, color: P.faint),
                          onPressed: () => _deleteBook(book),
                        ),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => BookDetailPage(book: book)),
                          );
                          if (!mounted) return;
                          await _load();
                        },
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({required this.overview});

  final Overview overview;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: P.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
        child: Row(
          children: [
            MetricCell(label: '总词数', value: '${overview.totalWords}'),
            const AppDivider(),
            MetricCell(label: '今日到期', value: '${overview.dueCount}'),
            const AppDivider(),
            MetricCell(label: '今日复习', value: '${overview.todayReviews}'),
            const AppDivider(),
            MetricCell(label: '累计忘记', value: '${overview.totalFailCount}'),
          ],
        ),
      ),
    );
  }
}
