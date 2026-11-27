import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import 'home.dart';
import 'mine_page.dart';
import 'stats_page.dart';
import 'translate_page.dart';

/// 底部导航：词库 / 翻译 / 统计 / 我的四个常驻页。
///
/// 翻译页以前挂在主页的一张入口卡上，每次进来都要先离开主页；放到导航栏后
/// 直接切过去，回来时填过的内容还在。「我的」同理，把散落的语音设置、存储、
/// 版本和诊断集中到一处。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  // 四个页面常驻在 IndexedStack 里，切回来不会重建，给个递增信号让它们各自刷新
  int _homeSignal = 0;
  int _statsSignal = 0;
  int _mineSignal = 0;

  // 没打开过的页面先不构建：统计页一进来就要跑概览和周统计两条查询，
  // 启动时白白占着主线程，放在这里按需建。
  final Set<int> _visited = {0};

  List<Book> _books = const [];
  String? _bookId;

  @override
  void initState() {
    super.initState();
    _refreshBooks();
  }

  /// 翻译页要拿到最新词库列表，不然新建的词库在导入目标里看不到。
  Future<void> _refreshBooks() async {
    try {
      final books = await Api.instance.books();
      if (!mounted) return;
      setState(() {
        _books = books;
        if (books.isEmpty) {
          _bookId = null;
          return;
        }
        final matched =
            _bookId == null ? <Book>[] : books.where((b) => b.id == _bookId).toList();
        _bookId = matched.isNotEmpty ? matched.first.id : books.first.id;
      });
    } catch (_) {
      // 词库读不到不影响翻译本身，用户可以在翻译页手动选
    }
  }

  void _select(int index) {
    if (index == _index) return;
    setState(() {
      _index = index;
      _visited.add(index);
      if (index == 0) _homeSignal++;
      if (index == 2) _statsSignal++;
      if (index == 3) _mineSignal++;
    });
    if (index == 1) _refreshBooks();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 停在其它页按返回键，先回词库，不要直接退出 App
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        setState(() {
          _index = 0;
          _homeSignal++;
        });
      },
      child: Scaffold(
        body: IndexedStack(
          index: _index,
          children: [
            HomePage(refreshSignal: _homeSignal),
            _visited.contains(1)
                ? TranslatePage(books: _books, bookId: _bookId, embedded: true)
                : const SizedBox.shrink(),
            _visited.contains(2)
                ? StatsPage(embedded: true, refreshSignal: _statsSignal)
                : const SizedBox.shrink(),
            _visited.contains(3)
                ? MinePage(embedded: true, refreshSignal: _mineSignal)
                : const SizedBox.shrink(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _select,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.menu_book_outlined),
              selectedIcon: Icon(Icons.menu_book),
              label: '词库',
            ),
            NavigationDestination(
              icon: Icon(Icons.translate_outlined),
              selectedIcon: Icon(Icons.translate),
              label: '翻译',
            ),
            NavigationDestination(
              icon: Icon(Icons.insights_outlined),
              selectedIcon: Icon(Icons.insights),
              label: '统计',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: '我的',
            ),
          ],
        ),
      ),
    );
  }
}
