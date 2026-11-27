import '../errors.dart';
import 'dart:convert';
import 'dart:io';

import 'package:enough_convert/gbk.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../api.dart';
import '../models.dart';
import '../ocr.dart';
import '../translate.dart';

import '../theme.dart';
class TranslatePage extends StatefulWidget {
  const TranslatePage({
    super.key,
    required this.books,
    this.bookId,
    this.embedded = false,
  });

  final List<Book> books;
  final String? bookId;

  /// 放在底部导航里时不留返回箭头。
  final bool embedded;

  @override
  State<TranslatePage> createState() => _TranslatePageState();
}

class _VocabEntry {
  const _VocabEntry({
    required this.word,
    this.definition,
    this.phonetic,
    this.lemma,
  });

  final String word;
  final String? definition;
  final String? phonetic;

  /// 这个拼写是变形时，词典里实际命中的原形。
  final String? lemma;

  bool get known => definition != null;
}

/// 读文件失败时抛给用户的说明。humanizeError 认 `message` 字段，不会把堆栈丢到界面上。
class _ReadFailure implements Exception {
  const _ReadFailure(this.message);

  final String message;
}

class _TranslatePageState extends State<TranslatePage> {
  static const String _keyAppKey = 'youdao_app_key';
  static const String _keyAppSecret = 'youdao_app_secret';

  /// PDF 一次抽多少页。逐页抽文本不解码页内图片，所以能一次抽完整本书；
  /// 400 多页的词汇书一次读完，省得用户反复点「继续读」。
  static const int _maxPdfPages = 1000;

  /// 开读前先只看这几页：整本都是扫描图片时，别让用户白等几百页。
  static const int _pdfProbePages = 8;

  /// 文本文件上限，超过就不读了——再大读进内存只会把 App 顶崩
  static const int _maxTextBytes = 8 * 1024 * 1024;

  /// PDF 上限。syncfusion 只能把整份 PDF 读进内存再解析，所以这条线就是内存线：
  /// 200MB 的文件峰值大约 250MB，靠 AndroidManifest 里的 largeHeap 才站得住。
  static const int _maxPdfBytes = 200 * 1024 * 1024;

  /// 超过这个体积先提醒一句：解析要等一会儿，中途别切走。
  static const int _bigPdfBytes = 60 * 1024 * 1024;

  /// 能当纯文本直接读的扩展名
  static const Set<String> _textExtensions = {
    'txt', 'text', 'md', 'markdown', 'csv', 'tsv', 'json', 'log',
    'srt', 'vtt', 'html', 'htm', 'xml', 'ini', 'yaml', 'yml',
  };

  final _text = TextEditingController();
  final _picker = ImagePicker();
  final _selected = <int>{};

  String _sourceLabel = '';
  bool _extracting = false;
  bool _translating = false;
  bool _building = false;
  bool _importing = false;
  bool _keyReady = false;

  /// 拍照时用中文识别模型（中英混排的书页用得上）
  bool _ocrChinese = false;

  /// 译文输出中文；关掉就是输出英文
  bool _toChinese = true;

  String? _message;
  bool _messageIsError = false;
  String? _translation;
  List<_VocabEntry> _vocab = const [];
  String? _bookId;

  /// 当前正文来自哪个 PDF，以及已经读到第几页（`_pdfTo` 是"下一批从这里开始"）。
  /// 只用于"这份书太厚，分批往下读"，文本/拍照导入时为空。
  String? _pdfPath;
  int _pdfTo = 0;
  int _pdfTotal = 0;

  /// 上次读的时候前几页是不是一片空白（扫描图片版就是这个样子）
  bool _pdfLastBlank = false;

  @override
  void initState() {
    super.initState();
    _bookId = widget.bookId ?? (widget.books.isEmpty ? null : widget.books.first.id);
    _refreshKey();
  }

  @override
  void didUpdateWidget(TranslatePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 放在底部导航里时，词库列表是父层异步取的，第一次进来可能还是空的；
    // 这里跟着新列表补一次选中，不然导入目标会显示成「还没有词库」。
    if (_bookId != null && widget.books.any((b) => b.id == _bookId)) return;
    final target = widget.bookId;
    if (target != null && widget.books.any((b) => b.id == target)) {
      _bookId = target;
    } else if (widget.books.isNotEmpty) {
      _bookId = widget.books.first.id;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _refreshKey() async {
    final key = await Api.instance.secureMetaGet(_keyAppKey);
    final secret = await Api.instance.secureMetaGet(_keyAppSecret);
    if (!mounted) return;
    setState(() => _keyReady = key != null && secret != null);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _applyText(String text, String label, {String? pdfPath}) {
    setState(() {
      _text.text = text;
      _sourceLabel = label;
      _translation = null;
      _vocab = const [];
      _selected.clear();
      _message = null;
      _messageIsError = false;
      _pdfPath = pdfPath;
      if (pdfPath == null) {
        // 换成了文本或拍照，之前那份 PDF 的页码进度就没意义了
        _pdfTo = 0;
        _pdfTotal = 0;
      }
    });
    // 换了一篇新内容，上一份文档的段落缓存就没用了
    YoudaoTranslator.clearCache();
  }

  /// PDF 分页往下读时，把新一页的文字接到正文末尾，而不是覆盖已经翻译/提取过的部分。
  void _appendText(String text) {
    final merged = _text.text.isEmpty ? text : '${_text.text}\n\n$text';
    setState(() {
      _text.text = merged;
      // 来源行里的字数跟着涨
      _sourceLabel = _sourceLabel.replaceFirst(RegExp(r'（\d+ 字）'), '（${merged.runes.length} 字）');
      _translation = null;
      _vocab = const [];
      _selected.clear();
      _message = null;
      _messageIsError = false;
    });
    YoudaoTranslator.clearCache();
  }

  /// 输入框被改动后，旧的译文和词表就跟内容对不上了，直接作废。
  void _invalidateResults() {
    if (_translation == null && _vocab.isEmpty) return;
    setState(() {
      _translation = null;
      _vocab = const [];
      _selected.clear();
      _message = null;
      _messageIsError = false;
    });
  }

  /// 两种输出都要先有内容，重复的校验收在这里。
  String? _requireText() {
    final text = _text.text.trim();
    if (text.isEmpty) {
      _toast('先导入文件或拍照，或者在输入框里粘贴文字');
      return null;
    }
    return text;
  }

  // ---------------------------------------------------------------- 取内容

  Future<void> _pickFile() async {
    if (_extracting) return;
    try {
      final picked = await FilePicker.platform.pickFiles(type: FileType.any, withData: false);
      if (picked == null || picked.files.isEmpty) return;
      final file = picked.files.first;
      final path = file.path;
      if (path == null) {
        _toast('读不到这个文件，换一个再试');
        return;
      }
      final name = file.name;
      final lower = name.toLowerCase();
      final ext = lower.contains('.') ? lower.split('.').last : '';
      if (lower.endsWith('.doc') || lower.endsWith('.docx')) {
        _toast('暂不支持 Word，先在电脑上存成 PDF 或 TXT 再导入');
        return;
      }
      if (lower.endsWith('.epub') || lower.endsWith('.mobi') || lower.endsWith('.azw3')) {
        _toast('暂不支持电子书格式，先转成 PDF 或 TXT');
        return;
      }
      final isPdf = lower.endsWith('.pdf');
      if (!isPdf && !_textExtensions.contains(ext)) {
        _toast(ext.isEmpty
            ? '这个文件没有扩展名，认不出格式；改成 .txt 再试'
            : '不支持 .$ext 文件，只能读 PDF 和纯文本（TXT / MD / CSV 等）');
        return;
      }

      // 先看大小，别等读进内存才发现是几百兆
      final size = await File(path).length();
      final limit = isPdf ? _maxPdfBytes : _maxTextBytes;
      if (size > limit) {
        final readable = (limit / 1024 / 1024).round();
        final actual = (size / 1024 / 1024).toStringAsFixed(1);
        _toast('这个文件 $actual MB，超过 ${readable}MB 上限，先拆小一点再导入');
        return;
      }

      setState(() {
        _extracting = true;
        _message = null;
        _messageIsError = false;
      });
      final text = isPdf ? await _readPdf(path) : await _readTextFile(path);
      if (!mounted) return;
      if (text.trim().isEmpty) {
        if (isPdf) {
          // 空白也要把进度留住：前几页是封面、插图的情况很常见，
          // 用户点「继续读」就能试到后面真正有字的部分。
          _applyText(text, '$name（0 字）', pdfPath: path);
          _toast(_pdfLastBlank
              ? '前 $_pdfTo 页没有文字，这本 PDF 多半是扫描图片版；'
                  '点「继续读」还能往后试，整本都是图就得先在电脑上 OCR 转成 TXT'
              : '这几页没有文字，点「继续读」往后看看');
          return;
        }
        _toast('这个文件里没读到文字，可能是扫描版或图片型文件，用拍照导入更合适');
        return;
      }
      // 传了 pdfPath，`_readPdf` 记下的总页数与已读页数才会留着
      _applyText(text, '$name（${text.runes.length} 字）', pdfPath: isPdf ? path : null);
    } catch (e) {
      // _ReadFailure 的 message 本身就是给用户看的，别再套一层前缀
      if (mounted) {
        _toast(e is _ReadFailure ? e.message : '读文件失败：${humanizeError(e)}');
      }
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  Future<void> _takePhoto() async {
    if (_extracting) return;
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 2600,
        imageQuality: 92,
      );
      if (picked == null) return;
      setState(() {
        _extracting = true;
        _message = null;
      });
      final scan = await Ocr.instance.scan(picked.path, chinese: _ocrChinese);
      if (!mounted) return;
      _applyText(scan.text, '拍照识别（${scan.text.length} 字符）');
      if (scan.text.trim().isEmpty) {
        _toast('这张图没认出文字，换个角度或拍清楚一点');
      }
    } catch (e) {
      if (mounted) _toast('识别失败：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  /// 读 PDF：`from` 是起始页（0 起算），一批最多 `_maxPdfPages` 页。
  /// 厚书分几次读，每次把新页追加到正文，页码进度记在 `_pdfTo / _pdfTotal`。
  Future<String> _readPdf(String path, {int from = 0}) async {
    final size = await File(path).length();
    // 大文件先把等待预期说清楚，不然用户以为卡死了
    if (size > _bigPdfBytes) {
      _toast('这份 PDF 有 ${(size / 1024 / 1024).toStringAsFixed(0)} MB，'
          '页多时要等几分钟，期间别退出 App');
    }
    final args = <String, Object>{'path': path, 'from': from, 'maxPages': _maxPdfPages};
    Map<String, Object> result;
    try {
      // PDF 解析是纯 CPU 活，先丢到后台 isolate。PdfDocument 不能跨 isolate，
      // 所以在 isolate 内按路径重新打开，只把抽出来的文本传回来。
      result = await compute(_extractPdfSync, args);
    } catch (e) {
      // 大文件在主 isolate 再解析一次只会把界面一起拖垮，宁可直接报错
      if (size > _bigPdfBytes) {
        throw const _ReadFailure('这份 PDF 没能解析，多半是文件太大或里面全是图片。'
            '可以先在电脑上拆成小份，或者另存为 TXT / CSV 再导入');
      }
      // 个别机型在后台 isolate 里打不开 PDF，小文件退到当前 isolate 逐页抽：
      // 功能不丢，只是会慢一点。
      try {
        result = _extractPdfSync(args);
      } catch (_) {
        throw const _ReadFailure('这份 PDF 打不开，可能文件损坏或加了密码；'
            '换一份，或者另存为 TXT 再导入');
      }
      await Future<void>.delayed(Duration.zero);
    }
    final total = result['total']! as int;
    final to = result['to']! as int;
    _pdfTotal = total;
    _pdfTo = to;
    // 探测结果是"一片空白"时，提示交给上层统一说，这里不抢话
    _pdfLastBlank = (result['blank'] ?? false) as bool;
    if (!_pdfLastBlank && total > to) {
      // 这句只提示，不写进正文——正文是要送去翻译的内容，掺中文会污染译文
      _toast('这份 PDF 共 $total 页，这次读了第 ${from + 1}–$to 页；'
          '可以点「继续读」往下翻');
    }
    return result['text']! as String;
  }

  /// 厚书分批往下读：接着上次停下的页继续抽，追加到正文末尾。
  Future<void> _continuePdf() async {
    final path = _pdfPath;
    if (path == null || _extracting || _pdfTo >= _pdfTotal) return;
    final fromPage = _pdfTo;
    setState(() {
      _extracting = true;
      _message = null;
      _messageIsError = false;
    });
    try {
      final text = await _readPdf(path, from: fromPage);
      if (!mounted) return;
      if (text.trim().isEmpty) {
        _toast('第 ${fromPage + 1}–$_pdfTo 页没有文字；'
            '再往后点「继续读」，或者去电脑上把整本 OCR 成 TXT 再导入');
        return;
      }
      _appendText(text);
    } catch (e) {
      if (mounted) {
        _toast(e is _ReadFailure ? e.message : '读文件失败：${humanizeError(e)}');
      }
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  /// 「继续读」按钮上要显示的下一页范围。
  int get _nextPdfTo {
    final next = _pdfTo + _maxPdfPages;
    return next > _pdfTotal ? _pdfTotal : next;
  }

  /// compute 只接受顶层函数或静态方法；这里一批抽完，不碰 UI。
  static Map<String, Object> _extractPdfSync(Map<String, Object> args) {
    final path = args['path']! as String;
    final from = args['from']! as int;
    final maxPages = args['maxPages']! as int;
    final bytes = File(path).readAsBytesSync();
    final document = PdfDocument(inputBytes: bytes);
    try {
      final total = document.pages.count;
      final start = from < total ? from : total;
      var end = start + maxPages;
      if (end > total) end = total;
      final extractor = PdfTextExtractor(document);

      // 第一批先试读开头几页：整本是扫描图片的话，抽几百页纯属白等几分钟
      if (start == 0 && total > _pdfProbePages && end > _pdfProbePages) {
        final probe = _pdfRange(extractor, 0, _pdfProbePages);
        if (probe.isEmpty) {
          return <String, Object>{
            'text': '',
            'total': total,
            'from': 0,
            'to': _pdfProbePages,
            'blank': true,
          };
        }
        return <String, Object>{
          'text': _pdfRange(extractor, 0, end),
          'total': total,
          'from': 0,
          'to': end,
        };
      }

      return <String, Object>{
        'text': _pdfRange(extractor, start, end),
        'total': total,
        'from': start,
        'to': end,
      };
    } finally {
      document.dispose();
    }
  }

  /// 抽 [start, end) 页的文字，空页直接跳过。
  static String _pdfRange(PdfTextExtractor extractor, int start, int end) {
    final buffer = StringBuffer();
    for (var i = start; i < end; i++) {
      final pageText =
          extractor.extractText(startPageIndex: i, endPageIndex: i, layoutText: true).trim();
      if (pageText.isEmpty) continue;
      buffer.write(pageText);
      buffer.write('\n\n');
    }
    return buffer.toString();
  }

  Future<String> _readTextFile(String path) async {
    final bytes = await File(path).readAsBytes();
    // 8MB 的文本解码也是纯 CPU 活，放后台 isolate 跑，别卡住界面
    return compute(_decodeTextBytes, bytes);
  }

  /// 解码大文本。原来 utf8 失败就按 latin1 解，中文 GBK 文件会整段乱码；
  /// 项目里已经有 GBK 解码器（CSV 导入用的是同一个），直接兜到它。
  static String _decodeTextBytes(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      try {
        return const GbkCodec(allowInvalid: true).decode(bytes);
      } catch (_) {
        return latin1.decode(bytes);
      }
    }
  }

  // ---------------------------------------------------------------- 翻译

  Future<void> _translate() async {
    final text = _requireText();
    if (text == null) return;
    final key = await Api.instance.secureMetaGet(_keyAppKey);
    final secret = await Api.instance.secureMetaGet(_keyAppSecret);
    if (key == null || secret == null) {
      _toast('先填有道智云的应用 ID 和密钥');
      await _openSettings();
      return;
    }
    setState(() {
      _translating = true;
      _vocab = const [];
      _selected.clear();
      _message = null;
      _messageIsError = false;
    });
    try {
      final output = await YoudaoTranslator(appKey: key, appSecret: secret)
          .translate(text, to: _toChinese ? 'zh-CHS' : 'en');
      if (!mounted) return;
      setState(() {
        _translation = output;
        _message = '译文 ${output.runes.length} 字';
        _messageIsError = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _message = '翻译失败：${humanizeError(e)}';
        _messageIsError = true;
      });
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  // ---------------------------------------------------------------- 词表

  Future<void> _buildVocab() async {
    final text = _requireText();
    if (text == null) return;
    setState(() {
      _building = true;
      _message = null;
      _messageIsError = false;
    });
    try {
      final candidates = Ocr.instance.extractFromText(text);
      if (candidates.isEmpty) {
        _toast('这段内容里没找到英文单词');
        return;
      }
      final defs = await Api.instance.lookupMany(candidates.map((e) => e.word));
      final entries = <_VocabEntry>[];
      for (final candidate in candidates) {
        final hit = defs[candidate.word.toLowerCase()];
        entries.add(_VocabEntry(
          word: candidate.word,
          definition: hit?.definition,
          phonetic: hit?.phonetic,
          lemma: hit?.lemma,
        ));
      }
      if (!mounted) return;
      setState(() {
        _vocab = entries;
        // 只默认勾上查得到释义的；未收录的留给用户自己决定
        _selected
          ..clear()
          ..addAll([
            for (var i = 0; i < entries.length; i++)
              if (entries[i].known) i,
          ]);
        _translation = null;
        final known = entries.where((e) => e.known).length;
        final forms = entries.where((e) => e.lemma != null).length;
        // 取词有上限，超了要说明白，否则用户只会看到「一万多字的词表只给我 N 个」
        final capped = candidates.length >= Ocr.maxWords;
        _message = '共 ${entries.length} 个词，$known 个在词库里有释义'
            '${forms > 0 ? '，其中 $forms 个是变形、已对应到原形' : ''}'
            '，${entries.length - known} 个待补充'
            '${capped ? '；已达 ${Ocr.maxWords} 词取词上限，只取了前 ${Ocr.maxWords} 个' : ''}';
        _messageIsError = false;
      });
    } catch (e) {
      if (mounted) _toast(humanizeError(e));
    } finally {
      if (mounted) setState(() => _building = false);
    }
  }

  Future<void> _importVocab() async {
    final bookId = _bookId;
    if (bookId == null) {
      _toast('还没有词库，回主页建一个');
      return;
    }
    final words = <String>[];
    // 已查到的释义一起带过去，导入时不必再逐词查一遍词典
    final found = <String, String>{};
    for (final index in _selected) {
      if (index < 0 || index >= _vocab.length) continue;
      final entry = _vocab[index];
      words.add(entry.word);
      final def = entry.definition;
      if (def != null && def.trim().isNotEmpty) {
        found[entry.word.toLowerCase()] = def;
      }
    }
    if (words.isEmpty) {
      _toast('先勾选要导入的词');
      return;
    }
    setState(() => _importing = true);
    try {
      final result = await Api.instance.batchAdd(
        bookId,
        words.join('\n'),
        autoLookup: true,
        definitions: found,
      );
      if (!mounted) return;
      setState(() {
        _message = '导入结果：${result.summary}';
        _messageIsError = false;
      });
      _toast('已导入 ${result.added} 个词到「$_bookLabel」');
    } catch (e) {
      if (mounted) _toast(humanizeError(e));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  // ---------------------------------------------------------------- 密钥

  Future<void> _openSettings() async {
    final keyCtrl = TextEditingController(text: await Api.instance.secureMetaGet(_keyAppKey) ?? '');
    final secretCtrl =
        TextEditingController(text: await Api.instance.secureMetaGet(_keyAppSecret) ?? '');
    if (!mounted) return;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('有道智云密钥'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '去 ai.youdao.com 创建应用：平台类型必须选「API」（选 Android SDK 会报 205），并开通「文本翻译」，拿到应用 ID 和应用密钥填在这里。新账号有 50 元体验金。密钥只存在本机、不写进备份，翻译时随请求发给有道接口。',
                style: TextStyle(fontSize: 12, color: P.muted),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: keyCtrl,
                decoration: const InputDecoration(labelText: '应用 ID（appKey）'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: secretCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '应用密钥（appSecret）'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );

    if (saved == true) {
      await Api.instance.secureMetaSet(_keyAppKey, keyCtrl.text);
      await Api.instance.secureMetaSet(_keyAppSecret, secretCtrl.text);
      await _refreshKey();
      _toast(_keyReady ? '密钥已保存' : '应用 ID 和密钥都要填');
    }
    keyCtrl.dispose();
    secretCtrl.dispose();
  }

  // ---------------------------------------------------------------- 界面

  String get _bookLabel {
    final id = _bookId;
    if (id == null) return '还没有词库';
    for (final book in widget.books) {
      if (book.id == id) return book.name;
    }
    return '未知词库';
  }

  @override
  Widget build(BuildContext context) {
    final busy = _extracting || _translating || _building || _importing;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: const Text('翻译', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          PopupMenuButton<String>(
            tooltip: '更多设置',
            icon: const Icon(Icons.more_horiz, size: 20),
            onSelected: (value) => setState(() {
              if (value == 'ocr') _ocrChinese = !_ocrChinese;
              if (value == 'to') _toChinese = !_toChinese;
            }),
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                value: 'ocr',
                checked: _ocrChinese,
                child: const Text('拍照识别中文（中英混排）'),
              ),
              CheckedPopupMenuItem(
                value: 'to',
                checked: !_toChinese,
                child: const Text('译文输出英文'),
              ),
            ],
          ),
          IconButton(
            tooltip: '有道智云密钥',
            onPressed: _openSettings,
            icon: Icon(
              Icons.vpn_key_outlined,
              size: 20,
              color: _keyReady ? P.primary : P.faint,
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: _actionCard(
                    icon: Icons.folder_open_rounded,
                    title: '文件 / PDF',
                    hint: 'PDF · TXT · MD · CSV',
                    onTap: _extracting ? null : _pickFile,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _actionCard(
                    icon: Icons.photo_camera_outlined,
                    title: '拍照',
                    hint: '摄像头直接识别',
                    onTap: _extracting ? null : _takePhoto,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _sourceLabel.isEmpty
                  ? '支持 PDF、TXT、MD、CSV；拍照只认英文。Word 请先存成 PDF。'
                  : '来源：$_sourceLabel',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: P.muted),
            ),
            // 厚书没读完时，进度和「继续读」就挂在这一行，不额外占地方
            if (_pdfPath != null && _pdfTo < _pdfTotal)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '已读 1–$_pdfTo 页 / 共 $_pdfTotal 页',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: P.faint),
                    ),
                  ),
                  TextButton(
                    onPressed: busy ? null : _continuePdf,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      '继续读 ${_pdfTo + 1}–$_nextPdfTo 页',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 10),
            TextField(
              controller: _text,
              minLines: 3,
              maxLines: 6,
              style: TextStyle(fontSize: 14, height: 1.5, color: P.title),
              cursorColor: P.primary,
              onChanged: (_) => _invalidateResults(),
              decoration: InputDecoration(
                hintText: '文件或照片里的文字会出现在这里，也可以直接粘贴',
                hintStyle: TextStyle(fontSize: 13, color: P.faint),
                filled: true,
                fillColor: P.card,
                contentPadding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: P.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: P.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: P.primary, width: 1.4),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy ? null : _translate,
                    icon: _translating
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: P.onPrimary),
                          )
                        : const Icon(Icons.translate_rounded, size: 18),
                    label: Text(_translating ? '翻译中…' : '整段翻译'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : _buildVocab,
                    icon: _building
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: P.primary),
                          )
                        : const Icon(Icons.format_list_bulleted_rounded, size: 18),
                    label: Text(_building ? '提取中…' : '生词表'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      foregroundColor: P.primary,
                      side: BorderSide(color: P.border),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
              ],
            ),
            // 提示出现/消失时高度渐变，别让下面的内容整块跳一下
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _message == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _message!,
                        style: TextStyle(
                          fontSize: 12,
                          color: _messageIsError ? P.danger : P.primaryDeep,
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.03),
                      end: Offset.zero,
                    ).animate(anim),
                    child: child,
                  ),
                ),
                // 默认布局会把新旧两层各自居中，这里改成顶部对齐，切换时不抖
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.topCenter,
                  children: <Widget>[...previous, if (current != null) current],
                ),
                child: KeyedSubtree(
                  key: ValueKey<String>(_outputKey),
                  child: _buildOutput(),
                ),
              ),
            ),
            // 生词表的导入栏只在有词时出现，高度用动画过渡
            AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _vocab.isEmpty
                  ? const SizedBox(width: double.infinity)
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: widget.books.length > 1
                                  ? DropdownButtonHideUnderline(
                                      child: DropdownButton<String>(
                                        value: _bookId,
                                        isDense: true,
                                        isExpanded: true,
                                        style: TextStyle(fontSize: 13, color: P.primary),
                                        items: [
                                          for (final book in widget.books)
                                            DropdownMenuItem(
                                              value: book.id,
                                              child: Center(
                                                child: Text(book.name,
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis),
                                              ),
                                            ),
                                        ],
                                        onChanged: busy ? null : (v) => setState(() => _bookId = v),
                                      ),
                                    )
                                  : Text('导入到：$_bookLabel',
                                      style: TextStyle(fontSize: 13, color: P.primary),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: busy ? null : _selectAllKnown,
                              style: _miniButton,
                              child: const Text('全选', style: TextStyle(fontSize: 12)),
                            ),
                            TextButton(
                              onPressed: busy ? null : () => setState(_selected.clear),
                              style: _miniButton,
                              child: const Text('清空', style: TextStyle(fontSize: 12)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        FilledButton.icon(
                          onPressed: busy || _selected.isEmpty ? null : _importVocab,
                          icon: _importing
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: P.onPrimary),
                                )
                              : const Icon(Icons.playlist_add_check_rounded, size: 18),
                          label: Text(_importing ? '导入中…' : '导入选中的 ${_selected.length} 个词'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(46),
                            shape:
                                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                        ),
                        const SizedBox(height: 2),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// 文本按钮在小行里别撑高：默认 48 的最小点击区会把这一行顶成两块高。
  ButtonStyle get _miniButton => TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );

  /// 只勾收录到的词，未收录的留给用户自己判断
  void _selectAllKnown() {
    setState(() {
      _selected
        ..clear()
        ..addAll([
          for (var i = 0; i < _vocab.length; i++)
            if (_vocab[i].known) i,
        ]);
    });
  }

  /// 顶部两个导入入口。做成卡片而不是细长按钮，是为了让图标和用途一眼分得开。
  Widget _actionCard({
    required IconData icon,
    required String title,
    required String hint,
    required VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return Material(
      color: P.chip,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: P.border),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: enabled ? P.card : P.chipAlt,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, size: 19, color: enabled ? P.primary : P.faint),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: enabled ? P.title : P.faint,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: P.muted),
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

  /// 结果区换了内容就换 key，交给 AnimatedSwitcher 淡入淡出。
  String get _outputKey {
    if (_translation != null) return 'translation';
    if (_vocab.isNotEmpty) return 'vocab';
    return _extracting ? 'empty-busy' : 'empty';
  }

  Widget _buildOutput() {
    if (_translation != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: P.chip,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: P.border),
        ),
        child: SingleChildScrollView(
          primary: false,
          child: SelectableText(
            _translation!,
            style: TextStyle(fontSize: 14, height: 1.7, color: P.title),
          ),
        ),
      );
    }

    if (_vocab.isNotEmpty) {
      final knownIndexes = <int>[];
      final missingIndexes = <int>[];
      for (var i = 0; i < _vocab.length; i++) {
        (_vocab[i].known ? knownIndexes : missingIndexes).add(i);
      }
      return ListView.builder(
        padding: const EdgeInsets.only(bottom: 4),
        itemCount: knownIndexes.length +
            (missingIndexes.isEmpty ? 0 : missingIndexes.length + 1),
        itemBuilder: (context, position) {
          if (position < knownIndexes.length) {
            return _vocabTile(knownIndexes[position]);
          }
          final offset = position - knownIndexes.length;
          if (offset == 0) return _missingTitle(missingIndexes.length);
          return _vocabTile(missingIndexes[offset - 1]);
        },
      );
    }

    // 空着的时候别只留一句灰字，给个图标和两级说明，界面不至于太空
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: P.chip,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: P.border),
            ),
            child: Icon(
              _extracting ? Icons.hourglass_bottom_rounded : Icons.auto_awesome_outlined,
              size: 26,
              color: P.primary,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            _extracting ? '正在提取…' : '还没有内容',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: P.body),
          ),
          const SizedBox(height: 6),
          Text(
            _extracting ? '大文件会久一点，先别退出' : '导入文件或拍张照，再点「整段翻译」或「生词表」',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.5, color: P.faint),
          ),
        ],
      ),
    );
  }

  Widget _vocabTile(int index) {
    final item = _vocab[index];
    final checked = _selected.contains(index);
    // 整行都能点：手指不用非落在那个小方框上
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: checked ? P.chip : P.card,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: checked ? P.primary.withValues(alpha: 0.35) : P.border,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          onTap: _importing ? null : () => _toggle(index, !checked),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Checkbox(
                  value: checked,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: _importing ? null : (value) => _toggle(index, value),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              item.word,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: P.title,
                              ),
                            ),
                          ),
                          if (item.phonetic != null)
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Text(
                                item.phonetic!,
                                style: TextStyle(fontSize: 11, color: P.muted),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _vocabSubtitle(item),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: item.known ? P.body : P.warn,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 未收录词的副标题说清「为什么没查到」，不只是一句「没有这个词」。
  String _vocabSubtitle(_VocabEntry item) {
    final definition = item.definition;
    if (definition == null) return _missReason(item.word);
    final lemma = item.lemma;
    if (lemma == null) return definition;
    return '$lemma 的变形 · $definition';
  }

  String _missReason(String word) {
    final first = word.isEmpty ? '' : word[0];
    final looksProper = first.isNotEmpty &&
        first.toUpperCase() == first &&
        first.toLowerCase() != first;
    return looksProper ? '疑似专有名词或缩写，词典未收录' : '词典未收录，可手填释义';
  }

  Widget _missingTitle(int count) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 2),
      child: Row(
        children: [
          Text(
            '未收录 · $count 个',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: P.warn,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '默认不勾选，确认要背再手动勾上',
              style: TextStyle(fontSize: 11, color: P.faint),
            ),
          ),
        ],
      ),
    );
  }

  void _toggle(int index, bool? value) {
    setState(() {
      if (value == true) {
        _selected.add(index);
      } else {
        _selected.remove(index);
      }
    });
  }
}
