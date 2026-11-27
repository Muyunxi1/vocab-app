import '../errors.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';

/// 生成文章前挑词。可以只挑 3 个，也可以全选，不强制 30 个。
class PickWordsPage extends StatefulWidget {
  const PickWordsPage({super.key, required this.bookId, required this.bookName});

  final String bookId;
  final String bookName;

  @override
  State<PickWordsPage> createState() => _PickWordsPageState();
}

class _PickWordsPageState extends State<PickWordsPage> {
  final Set<String> _selected = {};
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;

  List<Word> _words = const [];
  bool _loading = true;

  /// 读库失败时留在这里，用来区分「词库是空的」和「读不出来」
  String? _error;

  /// 请求序号。连续切排序或搜索时，只有最后一次发起的请求能落盘。
  int _loadSeq = 0;

  /// fail = 遗忘次数，alpha = 字母
  String _sort = 'fail';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    const page = 500;
    final all = <Word>[];
    var offset = 0;
    try {
      while (true) {
        final batch = await Api.instance.words(
          widget.bookId,
          q: _search.text.trim(),
          sort: _sort,
          limit: page,
          offset: offset,
        );
        // 循环内也要挡：新请求已经发出就别再继续翻页了
        if (!mounted || seq != _loadSeq) return;
        all.addAll(batch);
        if (batch.length < page) break;
        offset += page;
        // 词库再大也不至于要读完才让人挑，到 5000 就停
        if (all.length >= 5000) break;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = humanizeError(e);
        _words = const [];
        _loading = false;
      });
      return;
    }
    if (!mounted || seq != _loadSeq) return;
    setState(() {
      _words = all;
      _loading = false;
    });
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _load);
  }

  void _toggle(Word word) {
    setState(() {
      if (_selected.contains(word.spelling)) {
        _selected.remove(word.spelling);
      } else {
        _selected.add(word.spelling);
      }
    });
  }

  void _toggleAll() {
    // 搜索态下 _words 只是可见集合，_selected 里可能还有看不见的已选词。
    // 用「已选总数 >= 当前列表总数」判断，会把这些看不见的选择一起清掉。
    final visible = _words.map((w) => w.spelling).toSet();
    final allVisibleSelected = visible.isNotEmpty && visible.every(_selected.contains);
    setState(() {
      if (allVisibleSelected) {
        _selected.removeAll(visible);
      } else {
        _selected.addAll(visible);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final count = _selected.length;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.bookName} · 选词'),
        actions: [
          TextButton(
            onPressed: _words.isEmpty ? null : _toggleAll,
            child: Text(
              count >= _words.length && _words.isNotEmpty ? '取消全选' : '全选',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _filterBar(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('读取词库失败',
                                  style: TextStyle(color: P.muted, fontSize: 14)),
                              const SizedBox(height: 6),
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: P.faint, fontSize: 11.5),
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton(onPressed: _load, child: const Text('重试')),
                            ],
                          ),
                        ),
                      )
                    : _words.isEmpty
                        ? Center(
                            child: Text(
                              _search.text.trim().isEmpty ? '词库里还没有单词' : '没有匹配的词',
                              style: TextStyle(color: P.muted, fontSize: 13),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 90),
                            itemCount: _words.length,
                            itemBuilder: (context, index) => _wordRow(_words[index]),
                          ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          decoration: BoxDecoration(
            color: P.card,
            border: Border(top: BorderSide(color: P.border)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (count > 40)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '词太多，文章会又长又生硬，一把 15–40 个比较合适',
                    style: TextStyle(fontSize: 11.5, color: P.warn),
                  ),
                ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed:
                      count == 0 ? null : () => Navigator.of(context).pop(_selected.toList()),
                  child: Text(count == 0 ? '选几个词再生成' : '用这 $count 个词生成'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(
        color: P.card,
        border: Border(bottom: BorderSide(color: P.border)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 38,
            child: TextField(
              controller: _search,
              onChanged: _onSearchChanged,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: '搜单词',
                hintStyle: TextStyle(fontSize: 12.5, color: P.faint),
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18, color: P.faint),
                prefixIconConstraints: const BoxConstraints(minWidth: 34),
                contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: BorderSide(color: P.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: BorderSide(color: P.border),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _sortChip('遗忘次数', 'fail'),
              const SizedBox(width: 8),
              _sortChip('字母', 'alpha'),
              const Spacer(),
              Text('共 ${_words.length} 个', style: TextStyle(fontSize: 11, color: P.faint)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sortChip(String label, String value) {
    final active = _sort == value;
    return GestureDetector(
      onTap: () {
        if (_sort == value) return;
        setState(() => _sort = value);
        _load();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: active ? P.accentSoft : P.chip,
          borderRadius: BorderRadius.circular(7),
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

  Widget _wordRow(Word word) {
    final checked = _selected.contains(word.spelling);
    final definition = word.definition?.split('\n').first.trim() ?? '';
    return InkWell(
      onTap: () => _toggle(word),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 9, 14, 9),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: P.border))),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              height: 30,
              child: Checkbox(
                value: checked,
                onChanged: (_) => _toggle(word),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          word.spelling,
                          style: TextStyle(
                            fontSize: 14,
                            color: P.title,
                            fontWeight: checked ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (word.failCount > 0)
                        Text(
                          '忘 ${word.failCount}',
                          style: TextStyle(fontSize: 10.5, color: P.danger),
                        ),
                    ],
                  ),
                  if (definition.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        definition,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: P.muted),
                      ),
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
