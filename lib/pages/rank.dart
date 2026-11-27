import '../errors.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';

import '../theme.dart';
class RankPage extends StatefulWidget {
  const RankPage({super.key, required this.bookId, required this.bookName});

  final String bookId;
  final String bookName;

  @override
  State<RankPage> createState() => _RankPageState();
}

class _RankPageState extends State<RankPage> {
  bool _loading = true;
  String? _error;
  List<RankItem> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await Api.instance.rank(widget.bookId, limit: 100);
      if (!mounted) return;
      setState(() {
        _items = items;
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

  String _formatTime(DateTime? time) {
    if (time == null) return '';
    final local = time.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('遗忘排行 · ${widget.bookName}', style: const TextStyle(fontWeight: FontWeight.w700)),
        // 排行固定取前 100，超出时说明一句，免得用户以为词库里只有这些词
        bottom: _items.length >= 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(24),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('只显示遗忘次数最多的 100 个',
                      style: TextStyle(fontSize: 11, color: P.muted)),
                ),
              )
            : null,
      ),
      body: _loading
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
              : _items.isEmpty
                  ? Center(
                      child: Text('还没有忘记记录\n复习时点「忘记」才会进榜', textAlign: TextAlign.center, style: TextStyle(color: P.muted, height: 1.6)),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        itemCount: _items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final item = _items[index];
                          final rank = index + 1;
                          final top = rank <= 3;
                          return Card(
                            elevation: 0,
                            color: P.card,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                              leading: Container(
                                width: 34,
                                height: 34,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: top ? P.primary : P.chipAlt,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '$rank',
                                  style: TextStyle(
                                    color: top ? P.onPrimary : P.muted,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              title: Row(
                                children: [
                                  Flexible(
                                    child: Text(item.spelling,
                                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: P.dangerBg,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text('忘 ${item.failCount}',
                                        style: TextStyle(fontSize: 12, color: P.danger, fontWeight: FontWeight.w600)),
                                  ),
                                ],
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.definition ?? '暂无释义',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 13, color: P.body),
                                    ),
                                    if (item.lastFailAt != null)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 3),
                                        child: Text('最近忘记 ${_formatTime(item.lastFailAt)}',
                                            style: TextStyle(fontSize: 11, color: P.faint)),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}
