import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../api.dart';
import '../digital_ink.dart';
import '../errors.dart';
import '../models.dart';
import '../ocr.dart';
import '../theme.dart';

/// 手写录入：在画板上手写英文单词，识别后勾选或手动修改再入库。
///
/// 识别优先走数字墨水引擎——吃笔画矢量坐标，本来就是为手写设计的；
/// 模型未就绪、识别为空或引擎报错时，回退到现有截图 OCR 兜底。
/// 结果一定经过勾选或手动修改，不会把识别结果直接写进词库。
class HandwritingPage extends StatefulWidget {
  const HandwritingPage({super.key, this.initialBookId});

  /// 主页传过来的当前词库；词库列表里找不到时回退第一个。
  final String? initialBookId;

  @override
  State<HandwritingPage> createState() => _HandwritingPageState();
}

class _HandwritingPageState extends State<HandwritingPage> {
  List<Book> _books = [];
  String? _bookId;
  bool _loadingBooks = true;

  /// 当前正在书写的指针，避免双指轨迹串到同一笔里画成墨块。
  int? _activePointer;
  Size? _boardSize;

  /// 全部笔迹；每一笔带自己的点序列、颜色和粗细。
  List<_Stroke> _strokes = [];

  /// 橡皮模式：开启后触点经过的笔迹按范围擦除，整笔会被切成多段。
  bool _eraser = false;

  /// 橡皮擦除半径；随下方三档大小调整，默认中档。
  double _eraseRadius = 20;
  static const List<MapEntry<double, String>> _eraseSizes = [
    MapEntry(14, '细'),
    MapEntry(20, '中'),
    MapEntry(28, '粗'),
  ];

  /// 画笔当前粗细与颜色；新笔画沿用这一套，旧笔画保留各自当时的设置。
  double _penWidth = 5;
  Color _penColor = const Color(0xFF111111);

  static const List<MapEntry<double, String>> _penSizes = [
    MapEntry(3, '细'),
    MapEntry(5, '中'),
    MapEntry(8, '粗'),
  ];
  static const List<MapEntry<Color, String>> _penColors = [
    MapEntry(Color(0xFF111111), '黑'),
    MapEntry(Color(0xFF1E73E8), '蓝'),
    MapEntry(Color(0xFFD83A3A), '红'),
  ];

  /// 工具条配色（对齐参考笔记软件）：选中项浅蓝圆底 + 蓝色图标，
  /// 未选中近黑线性图标；不再用绿底白图标，避免浅底上白色看不清。
  static const Color _toolBlue = Color(0xFF2E7CF6);
  static const Color _toolBlueSoft = Color(0xFFE3EEFF);
  static const Color _toolIdle = Color(0xFF333A45);

  /// 识别结果与核对。
  final _manual = TextEditingController();
  List<OcrCandidate> _candidates = const [];
  final _selected = <int>{};

  /// 候选的本地词典预览：key 为小写拼写，识别后批量查一次，只读辅助勾选；
  /// 不联网，查不到的候选在面板上标「未收录」。
  Map<String, LookupResult> _lookupPreview = {};

  bool _recognizing = false;
  bool _importing = false;
  bool _autoLookup = false;

  /// 工具条是否展开：收起时画板上只留一个可拖动的悬浮触发按钮；点按钮后
  /// 工具条从左侧水平滑出，主工具全部用图标表达。分屏矮窗口下优先保证画板面积。
  bool _toolsOpen = false;

  /// 悬浮球当前位置（相对画板左上）；null 表示默认左上。拖动后停在原地，
  /// 关闭工具条回到悬浮球时位置保留。
  Offset? _triggerPos;
  static const double _triggerSize = 44;
  ImportResult? _result;
  String _hint = '';
  String? _shotPath;

  @override
  void initState() {
    super.initState();
    _loadBooks();
  }

  @override
  void dispose() {
    _manual.dispose();
    DigitalInk.instance.close();
    super.dispose();
    _cleanShot();
  }

  Future<void> _loadBooks() async {
    try {
      final books = await Api.instance.books();
      if (!mounted) return;
      setState(() {
        _books = books;
        _bookId = widget.initialBookId != null &&
                books.any((b) => b.id == widget.initialBookId)
            ? widget.initialBookId
            : (books.isEmpty ? null : books.first.id);
        _loadingBooks = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingBooks = false;
        _hint = humanizeError(e);
      });
    }
  }

  // ---------- 画板 ----------

  Offset _clamp(Offset p) {
    final s = _boardSize;
    if (s == null) return p;
    return Offset(
      p.dx.clamp(0.0, s.width).toDouble(),
      p.dy.clamp(0.0, s.height).toDouble(),
    );
  }

  /// 悬浮球拖动位置夹紧在画板内，留足按钮自身边长，不贴出边界外。
  Offset _clampTrigger(Offset p) {
    final s = _boardSize;
    if (s == null) return p;
    final maxX = (s.width - _triggerSize).clamp(0.0, double.infinity);
    final maxY = (s.height - _triggerSize).clamp(0.0, double.infinity);
    return Offset(
      p.dx.clamp(0.0, maxX).toDouble(),
      p.dy.clamp(0.0, maxY).toDouble(),
    );
  }

  /// 触点是否落在悬浮球上：Listener 不走手势竞技场，拖球 / 点球收回时仍会
  /// 收到指针事件，这里把球范围内的触点挡掉，避免在画板上同步画线。
  bool _onTrigger(Offset p) {
    final pos = _triggerPos;
    if (pos == null) return false;
    final r = Rect.fromLTWH(pos.dx, pos.dy, _triggerSize, _triggerSize);
    return r.contains(p);
  }

  /// 范围橡皮：把触点半径内的点逐点剔除，被穿过的一笔按保留段切成多段，
  /// 不再整笔移除。
  void _eraseAt(Offset p) {
    final next = <_Stroke>[];
    for (final stroke in _strokes) {
      List<InkPoint>? cur;
      for (final pt in stroke.points) {
        if ((pt.offset - p).distance <= _eraseRadius) {
          if (cur != null && cur.isNotEmpty) {
            next.add(_Stroke(color: stroke.color, width: stroke.width)
              ..points.addAll(cur));
          }
          cur = null;
        } else {
          (cur ??= []).add(pt);
        }
      }
      if (cur != null && cur.isNotEmpty) {
        next.add(_Stroke(color: stroke.color, width: stroke.width)
          ..points.addAll(cur));
      }
    }
    _strokes = next;
  }

  void _onDown(PointerDownEvent e) {
    if (_activePointer != null) return;
    final p = _clamp(e.localPosition);
    if (!p.dx.isFinite || !p.dy.isFinite) return;
    if (_onTrigger(p)) return;
    _activePointer = e.pointer;
    if (_eraser) {
      _eraseAt(p);
      setState(() {});
      return;
    }
    final stroke = _Stroke(color: _penColor, width: _penWidth)
      ..points.add(InkPoint(p, DateTime.now().millisecondsSinceEpoch));
    setState(() => _strokes.add(stroke));
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _activePointer) return;
    final p = _clamp(e.localPosition);
    if (!p.dx.isFinite || !p.dy.isFinite) return;
    if (_eraser) {
      _eraseAt(p);
      setState(() {});
      return;
    }
    if (_strokes.isEmpty) return;
    final last = _strokes.last.points.last.offset;
    // 距离太近的重复点不收，避免抖动堆成粗块。
    if ((p - last).distance < 1.2) return;
    setState(() => _strokes.last.points.add(
          InkPoint(p, DateTime.now().millisecondsSinceEpoch)));
  }

  void _onUp(PointerUpEvent e) {
    if (e.pointer == _activePointer) _activePointer = null;
    setState(() {});
  }

  void _onCancel(PointerCancelEvent e) {
    if (e.pointer == _activePointer) _activePointer = null;
    setState(() {});
  }

  void _clearBoard() => setState(() => _strokes.clear());

  /// 点按悬浮球在工具条展开 / 收起之间切换；动画由工具条浮层的
  /// AnimatedSwitcher 播放左侧水平滑入滑出。
  void _toggleTools() => setState(() => _toolsOpen = !_toolsOpen);

  Future<void> _cleanShot() async {
    final path = _shotPath;
    if (path == null) return;
    _shotPath = null;
    try {
      await File(path).delete();
    } catch (_) {
      // 临时文件删不掉不影响识别，下次启动系统会清
    }
  }

  /// 自绘一张白底黑字的识别图：按笔迹包围盒裁掉四周空白，等比放大到统一尺寸，
  /// 再落临时目录走现有 OCR 管线（仅在数字墨水没认出时兜底用）。
  Future<String?> _renderRecognizePng() async {
    double minX = double.infinity, minY = double.infinity;
    double maxX = -double.infinity, maxY = -double.infinity;
    var hasPoint = false;
    for (final stroke in _strokes) {
      for (final pt in stroke.points) {
        final p = pt.offset;
        if (!p.dx.isFinite || !p.dy.isFinite) continue;
        hasPoint = true;
        if (p.dx < minX) minX = p.dx;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dy > maxY) maxY = p.dy;
      }
    }
    if (!hasPoint) return null;

    const pad = 40.0;
    const targetH = 480.0;
    final bw = (maxX - minX).abs() < 1 ? 1.0 : maxX - minX;
    final bh = (maxY - minY).abs() < 1 ? 1.0 : maxY - minY;
    final scale = targetH / bh;
    final canvasW = (bw * scale + pad * 2).ceil();
    final canvasH = (targetH + pad * 2).ceil();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, canvasW.toDouble(), canvasH.toDouble()),
    );
    canvas.drawColor(const ui.Color(0xFFFFFFFF), ui.BlendMode.srcOver);

    const ink = ui.Color(0xFF111111);
    final line = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final dot = Paint()..color = ink..style = PaintingStyle.fill;

    Offset mapPoint(Offset p) =>
        Offset((p.dx - minX) * scale + pad, (p.dy - minY) * scale + pad);

    for (final stroke in _strokes) {
      final pts = [
        for (final pt in stroke.points)
          if (pt.offset.dx.isFinite && pt.offset.dy.isFinite)
            mapPoint(pt.offset),
      ];
      if (pts.isEmpty) continue;
      for (var i = 0; i < pts.length; i++) {
        canvas.drawCircle(pts[i], 3, dot);
        if (i > 0) canvas.drawLine(pts[i - 1], pts[i], line);
      }
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(canvasW, canvasH);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return null;
    final dir = Directory.systemTemp;
    final path = p.join(
      dir.path, 'handwriting-${DateTime.now().millisecondsSinceEpoch}.png');
    await File(path).writeAsBytes(data.buffer.asUint8List());
    return path;
  }

  // ---------- 识别与入库 ----------

  Future<void> _recognize() async {
    if (_recognizing) return;
    if (_strokes.isEmpty) {
      _toast('先在画板上写单词');
      return;
    }
    setState(() {
      _recognizing = true;
      _result = null;
      _hint = '';
    });
    try {
      final words = <String>[];
      final sources = <String>[];
      final seen = <String>{};
      void push(String word, String source) {
        final lc = word.toLowerCase();
        if (seen.add(lc)) {
          words.add(word);
          sources.add(source);
        }
      }

      // 第一路：数字墨水，笔画矢量端侧推理。
      var inkOk = false;
      String? inkError;
      try {
        await DigitalInk.instance.ensureModel();
        final inkWords = await DigitalInk.instance.recognize(
          [for (final s in _strokes) s.points],
          _boardSize ?? const Size(300, 400),
        );
        for (final w in inkWords) {
          push(w, '手写识别');
        }
        inkOk = inkWords.isNotEmpty;
      } catch (e) {
        inkOk = false;
        inkError = humanizeError(e);
      }

      // 第二路：截图 OCR 兜底，墨水没认出或引擎不可用时才走。
      if (words.isEmpty) {
        await _cleanShot();
        final path = await _renderRecognizePng();
        if (path != null) {
          _shotPath = path;
          final scan = await Ocr.instance.scan(path, keepStopWords: true);
          for (final c in scan.candidates) {
            push(c.word, '截图识别');
          }
        }
      }

      // 批量查一次本地词典做预览（只读，不联网）；词典故障不阻断识别流程。
      Map<String, LookupResult> preview = const {};
      if (words.isNotEmpty) {
        try {
          preview = await Api.instance.lookupMany(words);
        } catch (_) {
          preview = const {};
        }
      }

      if (!mounted) return;
      setState(() {
        _lookupPreview = preview;
        _candidates = [
          for (var i = 0; i < words.length; i++)
            OcrCandidate(words[i], sources[i]),
        ];
        // 默认只勾置信度最高的首选；其余候选要加再点，避免只想导一个时逐个取消。
        _selected
          ..clear()
          ..addAll(_candidates.isEmpty ? const <int>[] : [0]);
        // 手动框留空，只作额外补词；未勾选的候选不会从文本框被再次导入。
        _manual.text = '';
        if (words.isEmpty) {
          _hint = inkError != null
              ? '手写模型暂不可用：$inkError；截图也没认出，请在下方手动补'
              : '没认出英文单词，写工整一点，或在下面手动补';
        } else if (inkOk) {
          _hint = '已默认勾选最可能的一个，其余点选要的再导入';
        } else if (inkError != null) {
          _hint = '手写模型暂不可用：$inkError；已用截图识别兜底，点选要的再导入';
        } else {
          _hint = '手写模型没认出来，已用截图识别兜底；点选要的再导入';
        }
      });
    } catch (e) {
      if (mounted) setState(() => _hint = '识别失败：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _recognizing = false);
    }
    // 识别结束（含没认出/报错）都展开结果核对面板，候选或手动补词后再入库。
    if (mounted) {
      _openResultSheet();
    }
  }

  Future<void> _submit() async {
    if (_importing) return;
    final bookId = _bookId;
    if (bookId == null) {
      _toast('先建一个词库');
      return;
    }
    final words = <String>{};
    for (final i in _selected) {
      if (i >= 0 && i < _candidates.length) words.add(_candidates[i].word);
    }
    // 手动框里兜底补的词也收进来，按空白、逗号、分号拆开。
    for (final line in _manual.text.split('\n')) {
      for (final w in line.split(RegExp(r'[\s,，;；、]+'))) {
        final t = w.trim();
        if (t.isNotEmpty) words.add(t);
      }
    }
    if (words.isEmpty) {
      _toast('先勾选或写出要加的词');
      return;
    }
    setState(() => _importing = true);
    try {
      final result = await Api.instance.batchAdd(
        bookId,
        words.join('\n'),
        autoLookup: _autoLookup,
      );
      if (!mounted) return;
      setState(() => _result = result);
      _toast(result.summary);
    } catch (e) {
      if (mounted) _toast(humanizeError(e));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _toggleAll(bool select) => setState(() {
    if (select) {
      _selected.addAll(List.generate(_candidates.length, (i) => i));
    } else {
      _selected.clear();
    }
  });

  LookupResult? _previewOf(int i) =>
      _lookupPreview[_candidates[i].word.toLowerCase()];

  bool _previewFound(int i) {
    final hit = _previewOf(i);
    return hit != null && hit.found;
  }

  /// 候选下方的本地词典预览：命中显示音标 + 释义首段，查不到标「未收录」。
  String _previewText(int i) {
    final hit = _previewOf(i);
    if (hit == null || !hit.found) return '未收录';
    final ph = (hit.phonetic ?? '').trim();
    final def = (hit.definition ?? '').trim().split('\n').first.trim();
    final buf = StringBuffer();
    if (ph.isNotEmpty) buf.write('/$ph/ ');
    buf.write(def.isEmpty ? '—' : def);
    return buf.toString();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 展开态工具条：单行横排胶囊，主工具 / 粗细 / 颜色 / 识别一条排开；窗口
  /// 偏窄时整条可左右滑动。浮层叠在画板顶部，收回由常驻悬浮球点按承担。
  Widget _buildToolbar(bool busy) {
    final sizes = _eraser ? _eraseSizes : _penSizes;
    return Container(
      decoration: BoxDecoration(
        color: P.card.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // 首钮与胶囊边缘留一点内边距；球在工具条侧方，不占行内空间。
            const SizedBox(width: 6),
            _iconTool(
              icon: Icons.edit_outlined,
              tooltip: '画笔',
              selected: !_eraser,
              onTap: busy ? null : () => setState(() => _eraser = false),
            ),
            _iconTool(
              icon: Icons.cleaning_services_outlined,
              tooltip: '橡皮',
              selected: _eraser,
              onTap: busy ? null : () => setState(() => _eraser = !_eraser),
            ),
            _iconTool(
              icon: Icons.delete_outline,
              tooltip: '清空',
              onTap: busy ? null : _clearBoard,
            ),
            for (final s in sizes)
              _sizeButton(
                s.key,
                s.value,
                _eraser ? _eraseRadius == s.key : _penWidth == s.key,
                _eraser
                    ? () => setState(() => _eraseRadius = s.key)
                    : () => setState(() => _penWidth = s.key),
              ),
            if (!_eraser)
              for (final c in _penColors)
                _colorButton(c.key, c.value, _penColor == c.key),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: busy ? null : _recognize,
              icon: _recognizing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.draw_outlined, size: 18),
              label: Text(_recognizing ? '识别中…' : '识别'),
              style: FilledButton.styleFrom(
                backgroundColor: _toolBlue,
                foregroundColor: Colors.white,
                minimumSize: const Size(88, 38),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 工具条浮层：跟随常驻悬浮球的位置出现在球的侧方（球在左半向右展、
  /// 右半向左展），垂直对齐球中线并夹紧在画板内。Positioned 直接挂在
  /// 画板 Stack 下，定位才生效；点按球 toggle 展开 / 收起，不放关闭按钮。
  Widget _buildToolbarOverlay(bool busy) {
    final s = _boardSize ?? const Size(300, 400);
    final pos = _triggerPos ?? const Offset(12, 12);
    const toolbarH = 56.0;
    final top = ((pos.dy + _triggerSize / 2) - toolbarH / 2)
        .clamp(0.0, (s.height - toolbarH).clamp(0.0, double.infinity))
        .toDouble();
    const gap = 8.0;
    final rightSide = pos.dx + _triggerSize / 2 <= s.width / 2;
    double? left, right, width;
    if (rightSide) {
      left = pos.dx + _triggerSize + gap;
      width = (s.width - left - gap).clamp(120.0, s.width);
    } else {
      right = s.width - pos.dx + gap;
      width = (pos.dx - gap * 2).clamp(120.0, s.width);
    }
    return Positioned(
      top: top,
      left: left,
      right: right,
      width: width,
      height: toolbarH,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (current, previous) => Stack(
          fit: StackFit.loose,
          alignment: Alignment.topLeft,
          children: [...previous, if (current != null) current],
        ),
        transitionBuilder: (child, animation) {
          return FadeTransition(
            opacity: CurvedAnimation(
                parent: animation, curve: Curves.easeOutCubic),
            child: child,
          );
        },
        child: _toolsOpen
            ? KeyedSubtree(
                key: const ValueKey('toolbar'),
                child: _buildToolbar(busy),
              )
            : const SizedBox.shrink(key: ValueKey('off')),
      ),
    );
  }

  /// 悬浮触发按钮：常驻在画板上，点按在工具条展开 / 收起之间切换；按住拖动
  /// 可把球挪到画板任意位置，位置保留。tap 与 drag 由手势竞技场自动区分。
  Widget _buildTrigger() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleTools,
      onPanUpdate: (d) => setState(() {
        final cur = _triggerPos ?? const Offset(12, 12);
        _triggerPos = _clampTrigger(cur + d.delta);
      }),
      child: Tooltip(
        message: _toolsOpen ? '收起工具条' : '工具 · 可拖动',
        child: Material(
          color: P.isDark ? P.accentSoft : _toolBlueSoft,
          shape: const CircleBorder(),
          elevation: 2,
          shadowColor: Colors.black.withValues(alpha: 0.08),
          child: const SizedBox(
            width: _triggerSize,
            height: _triggerSize,
            child: Center(
              child: Icon(Icons.edit_outlined, size: 22, color: _toolBlue),
            ),
          ),
        ),
      ),
    );
  }

  /// 图标工具按钮：选中态浅蓝底 + 蓝色图标，未选中近黑线性描边；
  /// 文字含义走 tooltip，不占横向空间。
  Widget _iconTool({
    required IconData icon,
    required String tooltip,
    bool selected = false,
    VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    final foreground = selected
        ? _toolBlue
        : enabled
            ? (P.isDark ? P.title : _toolIdle)
            : P.faint;
    final background = selected
        ? (P.isDark ? P.accentSoft : _toolBlueSoft)
        : null;
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        foregroundColor: foreground,
        backgroundColor: background,
        minimumSize: const Size(44, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      icon: Icon(icon, size: 20),
    );
  }

  /// 识别结果核对面板：候选勾选、手动补词、自动查词、加入词库，从底部弹层展开，
  /// 不占用书写态的画板空间；面板内部自行滚动。
  Future<void> _openResultSheet() async {
    final busy = _recognizing || _importing;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_hint.isNotEmpty) ...[
                    Text(_hint,
                        style: TextStyle(fontSize: 12, color: P.warnDeep2)),
                    const SizedBox(height: 10),
                  ],
                  if (_candidates.isNotEmpty) ...[
                    Row(
                      children: [
                        Text('已选 ${_selected.length} / ${_candidates.length}',
                            style: TextStyle(fontSize: 12, color: P.body)),
                        const Spacer(),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () {
                                  _toggleAll(true);
                                  setSheet(() {});
                                },
                          child: const Text('全选', style: TextStyle(fontSize: 12)),
                        ),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () {
                                  _toggleAll(false);
                                  setSheet(() {});
                                },
                          child: const Text('清空', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var i = 0; i < _candidates.length; i++)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ChoiceChip(
                                label: Text(_candidates[i].word,
                                    style: const TextStyle(fontSize: 13)),
                                selected: _selected.contains(i),
                                onSelected: busy
                                    ? null
                                    : (v) {
                                        if (v) {
                                          _selected.add(i);
                                        } else {
                                          _selected.remove(i);
                                        }
                                        setSheet(() {});
                                      },
                              ),
                              const SizedBox(height: 3),
                              SizedBox(
                                width: 150,
                                child: Text(
                                  _previewText(i),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: _previewFound(i)
                                        ? P.body
                                        : P.faint,
                                  ),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                  TextField(
                    controller: _manual,
                    minLines: 2,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: '没认出来的词，在这里打字补一行一个',
                      isDense: true,
                      filled: true,
                      fillColor: P.cardAlt,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title:
                        const Text('入库时自动补本地词典释义', style: TextStyle(fontSize: 14)),
                    value: _autoLookup,
                    onChanged: busy
                        ? null
                        : (v) {
                            _autoLookup = v;
                            setSheet(() {});
                          },
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () async {
                            await _submit();
                            setSheet(() {});
                          },
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48)),
                    child: _importing
                        ? const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2)),
                              SizedBox(width: 10),
                              Text('导入中…'),
                            ],
                          )
                        : const Text('加入词库'),
                  ),
                  if (_result != null) ...[
                    const SizedBox(height: 10),
                    Text(_result!.summary,
                        style: TextStyle(fontSize: 13, color: P.body)),
                    if (_result!.unfoundWords.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text('未收录：${_result!.unfoundWords.join('、')}',
                          style: TextStyle(fontSize: 11, color: P.faint)),
                    ],
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 粗细档位：圆点大小表达档位，文字含义走 tooltip，不显示文字标签。
  Widget _sizeButton(double value, String label, bool selected, VoidCallback onPressed) {
    return IconButton(
      onPressed: onPressed,
      tooltip: label,
      style: IconButton.styleFrom(
        foregroundColor: selected ? _toolBlue : P.faint,
        minimumSize: const Size(40, 36),
      ),
      icon: Icon(Icons.circle, size: value + 3,
          color: selected ? _toolBlue : P.faint),
    );
  }

  Widget _colorButton(Color color, String label, bool selected) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Tooltip(
        message: label,
        child: GestureDetector(
          onTap: () => setState(() => _penColor = color),
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? _toolBlue : P.border,
                width: selected ? 2.5 : 1,
              ),
            ),
            child: selected
                ? const Icon(Icons.check, size: 14, color: Colors.white)
                : null,
          ),
        ),
      ),
    );
  }

  /// 手写画板：铺满父级剩余空间，保底 150px；笔迹坐标按画板实际尺寸夹紧。
  Widget _buildBoard() {
    return Positioned.fill(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 150),
        child: Card(
          elevation: 0,
          color: P.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: P.border),
          ),
          child: ClipRect(
            child: RepaintBoundary(
              child: LayoutBuilder(builder: (context, constraints) {
                _boardSize =
                    Size(constraints.maxWidth, constraints.maxHeight);
                return Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onDown,
                  onPointerMove: _onMove,
                  onPointerUp: _onUp,
                  onPointerCancel: _onCancel,
                  child: CustomPaint(
                    painter: _BoardPainter(strokes: _strokes),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingBooks) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final busy = _recognizing || _importing;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 46,
        title: const Text('手写录入', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        top: false,
        child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.book_outlined, size: 18, color: P.primary),
                const SizedBox(width: 6),
                const Text('录入到', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                const Spacer(),
                if (_books.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 150),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _bookId,
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
                        onChanged: (v) => setState(() => _bookId = v),
                      ),
                    ),
                  )
                else
                  Text('还没有词库', style: TextStyle(fontSize: 13, color: P.muted)),
              ],
            ),
            const SizedBox(height: 6),
            // 画板铺满剩余空间；悬浮球可拖到画板任意位置，点按后工具条从
            // 左侧水平滑出，不再从纵向空间里单独扣一整列。
            Expanded(
              child: Stack(
                children: [
                  _buildBoard(),
                  _buildToolbarOverlay(busy),
                  // 悬浮球常驻在画板上，点按 toggle 展开 / 收起；最后绘制，
                  // 叠在工具条左缘，位置可拖动并保留。
                  Positioned(
                    left: _triggerPos?.dx ?? 12,
                    top: _triggerPos?.dy ?? 12,
                    child: _buildTrigger(),
                  ),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// 一笔笔迹：点序列 + 当时的颜色和粗细。
class _Stroke {
  _Stroke({required this.color, required this.width});

  final List<InkPoint> points = [];
  Color color;
  double width;
}

/// 画板描边：每一笔按各自的颜色和粗细连成折线，起笔单点画个小圆圈。
class _BoardPainter extends CustomPainter {
  const _BoardPainter({required this.strokes});

  final List<_Stroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    bool ok(Offset p) =>
        p.dx.isFinite &&
        p.dy.isFinite &&
        p.dx >= 0 &&
        p.dx <= size.width &&
        p.dy >= 0 &&
        p.dy <= size.height;

    for (final stroke in strokes) {
      final pts = [
        for (final pt in stroke.points)
          if (ok(pt.offset)) pt.offset,
      ];
      if (pts.isEmpty) continue;
      final line = Paint()
        ..color = stroke.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final dot = Paint()..color = stroke.color..style = PaintingStyle.fill;
      for (var i = 0; i < pts.length; i++) {
        canvas.drawCircle(pts[i], stroke.width / 2, dot);
        if (i > 0) canvas.drawLine(pts[i - 1], pts[i], line);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BoardPainter oldDelegate) => true;
}
