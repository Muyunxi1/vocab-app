import '../errors.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../widgets.dart';

import '../theme.dart';
import '../version_tag.dart';
/// 统计与数据管理：近 7 天的学习量、备份导出、从备份恢复。
class StatsPage extends StatefulWidget {
  const StatsPage({super.key, this.embedded = false, this.refreshSignal = 0});

  /// 放在底部导航里时不留返回箭头。
  final bool embedded;

  /// 切回这个 tab 时父层把数字加一，页面据此重新统计。
  final int refreshSignal;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  bool _loading = true;
  String? _error;
  Overview? _overview;
  List<DayStat> _stats = const [];
  bool _busy = false;

  /// 备份导出 / 恢复进行到哪一步。没有它，大备份处理时页面只有死寂的界面，
  /// 用户会以为卡死直接强杀，而那时正好在写库。
  String? _progress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(StatsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 常驻在 IndexedStack 里，切回来不会重建，靠信号重新统计一次
    if (widget.refreshSignal != oldWidget.refreshSignal) _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([Api.instance.overview(), Api.instance.weeklyStats()]);
      if (!mounted) return;
      setState(() {
        _overview = results[0] as Overview;
        _stats = results[1] as List<DayStat>;
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

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String get _stamp {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}';
  }

  Future<void> _export() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _progress = '正在打包备份数据';
    });
    try {
      final json = await Api.instance.exportJson();
      if (mounted) setState(() => _progress = '正在写入文件');
      final bytes = Uint8List.fromList(utf8.encode(json));
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '保存备份',
        fileName: '词学家备份-$_stamp.json',
        type: FileType.any,
        bytes: bytes,
      );
      if (!mounted) return;
      if (path == null) return; // 用户取消
      _toast('已导出 ${(bytes.length / 1024).toStringAsFixed(0)} KB 备份');
    } catch (e) {
      if (mounted) _toast('导出失败：${humanizeError(e)}');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    final picked = await FilePicker.platform.pickFiles(type: FileType.any, withData: false);
    if (!mounted) return; // 选文件期间页面可能已经被关掉
    if (picked == null || picked.files.isEmpty) return;
    final path = picked.files.first.path;
    if (path == null) {
      _toast('读不到这个文件');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从备份恢复'),
        content: const Text('只会补上现在没有的词库和单词，已有的一律跳过，不会覆盖你现在的内容。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('恢复')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _busy = true;
      _progress = '正在读取备份文件';
    });
    try {
      final text = await _readBackupFile(path);
      if (!mounted) return;
      final result = await Api.instance.importJson(
        text,
        onProgress: (stage) {
          if (!mounted) return;
          setState(() => _progress = stage);
        },
      );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      _toast('恢复完成：新增 ${result.books} 个词库、${result.words} 个单词，'
          '跳过 ${result.skippedWords} 个已存在的词'
          '${result.badRows > 0 ? '，${result.badRows} 行格式不对已跳过' : ''}');
    } catch (e) {
      if (mounted) _toast('恢复失败：${humanizeError(e)}');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  /// 备份文件按 UTF-8 读，老设备导出成 GBK 时由公共解码兜底。
  ///
  /// 先 stat 再读：整份 json 要解成字符串、再解成对象树，内存是文件的两三倍。
  /// 设上限后选错一个大文件只会得到一句提示，不会直接把 App 撑爆。
  Future<String> _readBackupFile(String path) async {
    final file = File(path);
    final size = await file.length();
    if (size > Api.maxBackupBytes) {
      throw ApiException(
          '这个文件 ${size ~/ (1024 * 1024)}MB，超过备份文件上限 '
          '${Api.maxBackupBytes ~/ (1024 * 1024)}MB，大概率选错了文件');
    }
    final bytes = await file.readAsBytes();
    return Api.decodeTextBytes(bytes);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: const Text('统计', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                if (_busy && _progress != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_progress!,
                              style: TextStyle(fontSize: 12, color: P.muted)),
                        ),
                      ],
                    ),
                  ),
                if (_error != null) ErrorCard(message: _error!, onRetry: _load, busy: _loading),
                if (_overview != null) _overviewCard(_overview!),
                const SizedBox(height: 14),
                _chartCard(),
                const SizedBox(height: 14),
                _backupCard(),
                const SizedBox(height: 18),
                // 用来确认手机上装的是哪一个包：这行不变说明没装上，变了才是新版本
                Center(
                  child: Text(
                    kBuildTag,
                    style: TextStyle(fontSize: 11, color: P.faint),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _overviewCard(Overview o) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
        child: Row(
          children: [
            MetricCell(label: '总词数', value: '${o.totalWords}'),
            const AppDivider(),
            MetricCell(label: '今日到期', value: '${o.dueCount}'),
            const AppDivider(),
            MetricCell(label: '今日复习', value: '${o.todayReviews}'),
            const AppDivider(),
            MetricCell(label: '累计忘记', value: '${o.totalFailCount}'),
          ],
        ),
      ),
    );
  }

  Widget _chartCard() {
    int maxV = 1;
    for (final s in _stats) {
      if (s.added > maxV) maxV = s.added;
      if (s.reviewed > maxV) maxV = s.reviewed;
    }
    final totalAdded = _stats.fold<int>(0, (sum, s) => sum + s.added);
    final totalReviewed = _stats.fold<int>(0, (sum, s) => sum + s.reviewed);
    final totalFailed = _stats.fold<int>(0, (sum, s) => sum + s.failed);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('近 7 天', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('新增 $totalAdded · 复习 $totalReviewed 次 · 忘记 $totalFailed 次',
                style: TextStyle(fontSize: 12, color: P.muted)),
            const SizedBox(height: 16),
            SizedBox(
              height: 108,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final s in _stats)
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _bar(s.added, maxV, P.accentSoft),
                              const SizedBox(width: 2),
                              _bar(s.reviewed, maxV, P.primary),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text('${s.day.month}/${s.day.day}',
                              style: TextStyle(fontSize: 10, color: P.faint)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _legend(P.accentSoft, '新增词'),
                const SizedBox(width: 14),
                _legend(P.primary, '复习次数'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _bar(int value, int maxValue, Color color) {
    const maxHeight = 78.0;
    final height = value == 0 ? 2.0 : (value / maxValue) * maxHeight;
    return Container(
      width: 7,
      height: height < 2 ? 2 : height,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
    );
  }

  Widget _legend(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(fontSize: 11, color: P.muted)),
      ],
    );
  }

  Widget _backupCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('数据备份', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              '词库和复习记录只存在这台手机里，卸载或清除数据就没了。导出成文件存到网盘或电脑，换手机时再恢复。'
              '备份不含有道密钥。',
              style: TextStyle(fontSize: 12, color: P.muted, height: 1.6),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _export,
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: const Text('导出备份'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _restore,
                    icon: _busy
                        ? const SizedBox(
                            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.restore, size: 18),
                    label: const Text('恢复'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
