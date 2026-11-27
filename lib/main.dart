import 'dart:ui' show PlatformDispatcher;

import 'errors.dart';
import 'package:flutter/material.dart';

import 'api.dart';
import 'pages/shell.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 未捕获的异常在 release 里会把进程直接带走，用户连错误页都看不到。
  // 同步错误交给 FlutterError，异步错误交给 PlatformDispatcher，统一进 logError。
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    logError('flutter', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    logError('async', error, stack);
    return true;
  };
  runApp(const VocabApp());
}

class VocabApp extends StatefulWidget {
  const VocabApp({super.key});

  @override
  State<VocabApp> createState() => _VocabAppState();
}

class _VocabAppState extends State<VocabApp> {
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  /// 初始化本地数据库与词典。失败时停在错误页，允许重试，
  /// 不让异常直接冒到 runApp 之外把整个 App 干掉。
  Future<void> _boot() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await Api.instance.load();
      // 库开好之后才能读 app_meta，所以主题放在这一步之后
      await ThemeController.instance.load();
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = humanizeError(e);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = !_loading && _error == null;
    // 主题换了就整棵重建：页面里读的都是 P.xxx，重建后即生效
    return ListenableBuilder(
      listenable: ThemeController.instance,
      builder: (context, _) => MaterialApp(
        title: '词学家',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: ready
            // 这里不能给 const：AppShell 没有 key 时，MaterialApp 重建会复用同一个
            // Element，AppShell 和页面里读 P.xxx 的 build 都不会重跑，切主题就只
            // 换了 Scaffold/AppBar 这些吃 Theme 的地方，卡片和文字还是旧色板。
            ? AppShell(key: ValueKey(ThemeController.instance.mode))
            : _BootPage(loading: _loading, error: _error, onRetry: _boot),
        // 平板和横屏时不要把所有东西拉满一整条，居中限宽读起来更舒服
        builder: (context, child) {
          if (child == null) return const SizedBox.shrink();
          final media = MediaQuery.of(context);
          final width = media.size.width;
          if (width <= 720) return child;
          // 一并把 MediaQuery 的宽度改成限宽后的值：里面页面按 constraints 排版，
          // 但也有地方会读 MediaQuery.size，不改会出现「以为自己是全屏」的错位。
          final narrow = media.copyWith(size: Size(720, media.size.height));
          return ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: MediaQuery(data: narrow, child: child),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _BootPage extends StatelessWidget {
  const _BootPage({required this.loading, required this.error, required this.onRetry});

  final bool loading;
  final String? error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 52, color: P.danger),
              const SizedBox(height: 16),
              const Text('启动失败', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text(
                '本地词典没能初始化，常见原因是存储空间不足或数据文件损坏。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: P.muted, height: 1.6),
              ),
              const SizedBox(height: 10),
              Text(
                '$error',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: P.faint, height: 1.5),
              ),
              const SizedBox(height: 22),
              FilledButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
      ),
    );
  }
}
