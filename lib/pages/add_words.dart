import '../errors.dart';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../models.dart';
import '../ocr.dart';

import '../theme.dart';
class AddWordsPage extends StatelessWidget {
  const AddWordsPage({super.key, required this.bookId, required this.bookName});

  final String bookId;
  final String bookName;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('添加单词', style: TextStyle(fontWeight: FontWeight.w700)),
          bottom: const TabBar(
            tabs: [
              Tab(text: '单个'),
              Tab(text: '批量'),
              Tab(text: '文件'),
              Tab(text: '拍照'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _SingleTab(bookId: bookId),
            _BatchTab(bookId: bookId),
            _FileTab(bookId: bookId),
            _PhotoTab(bookId: bookId),
          ],
        ),
      ),
    );
  }
}

class _SingleTab extends StatefulWidget {
  const _SingleTab({required this.bookId});

  final String bookId;

  @override
  State<_SingleTab> createState() => _SingleTabState();
}

class _SingleTabState extends State<_SingleTab> with AutomaticKeepAliveClientMixin {
  /// TabBarView 默认会销毁不可见的 Tab，用户填到一半滑去看别的再回来就空了。
  @override
  bool get wantKeepAlive => true;

  final _spelling = TextEditingController();
  final _phonetic = TextEditingController();
  final _definition = TextEditingController();
  /// 查词时顺手拿到的变形，保存时一起带过去
  String _forms = '';
  bool _busy = false;

  @override
  void dispose() {
    _spelling.dispose();
    _phonetic.dispose();
    _definition.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
    final spelling = _spelling.text.trim();
    if (spelling.isEmpty) return;
    setState(() => _busy = true);
    try {
      final result = await Api.instance.lookup(spelling);
      if (!mounted) return;
      setState(() {
        if (result.found) {
          _phonetic.text = result.phonetic ?? '';
          _definition.text = result.definition ?? '';
          _forms = result.forms ?? '';
        } else {
          // 换了一个词却没清掉上一个词查到的释义，保存时会把 A 的释义
          // 记到 B 头上，是最难发现的那种数据污染。
          _phonetic.clear();
          _definition.clear();
          _forms = '';
        }
      });
      if (!result.found) _toast('词库里没有这个词，可以手填释义');
    } catch (e) {
      _toast(humanizeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final spelling = _spelling.text.trim();
    if (spelling.isEmpty) {
      _toast('先填单词');
      return;
    }
    setState(() => _busy = true);
    try {
      final def = _definition.text.trim();
      final word = await Api.instance.addWord(
        widget.bookId,
        spelling,
        definition: def.isEmpty ? null : def,
        phonetic: _phonetic.text.trim().isEmpty ? null : _phonetic.text.trim(),
        forms: _forms.isEmpty ? null : _forms,
        autoLookup: def.isEmpty && _forms.isEmpty,
        countAsFail: true,
      );
      if (!mounted) return;
      _toast(word.failCount > 0
          ? '已加入 ${word.spelling}，累计忘记 ${word.failCount} 次'
          : '已加入 ${word.spelling}');
      setState(() {
        _spelling.clear();
        _phonetic.clear();
        _definition.clear();
        _forms = '';
      });
    } catch (e) {
      _toast(humanizeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _spelling,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: '单词',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: '自动查词',
                icon: const Icon(Icons.search),
                onPressed: _busy ? null : _lookup,
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phonetic,
            decoration: const InputDecoration(labelText: '音标（可选）', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _definition,
            maxLines: 4,
            minLines: 3,
            decoration: const InputDecoration(
              labelText: '释义（留空则自动查询）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}

class _BatchTab extends StatefulWidget {
  const _BatchTab({required this.bookId});

  final String bookId;

  @override
  State<_BatchTab> createState() => _BatchTabState();
}

class _BatchTabState extends State<_BatchTab> with AutomaticKeepAliveClientMixin {
  /// 批量粘贴的一大段文本切走再回来不能丢。
  @override
  bool get wantKeepAlive => true;

  final _text = TextEditingController();
  bool _autoLookup = false;
  bool _busy = false;
  ImportResult? _result;

  /// 粘贴上千词要跑几十秒，给一个能看见的进度。
  int _done = 0;
  int _total = 0;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _busy = true;
      _done = 0;
      _total = 0;
    });
    try {
      final result = await Api.instance.batchAdd(widget.bookId, text,
          autoLookup: _autoLookup, onProgress: (int done, int total) {
        if (!mounted) return;
        setState(() {
          _done = done;
          _total = total;
        });
      });
      if (!mounted) return;
      setState(() => _result = result);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(humanizeError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _text,
            maxLines: 10,
            minLines: 8,
            decoration: const InputDecoration(
              hintText: '粘贴一段文本，空格、换行、逗号、标点都会拆成一个个单词',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('同时自动查词', style: TextStyle(fontSize: 14)),
            subtitle: const Text('一次最多 ${Api.maxBatchWords} 个词，开了查词会慢一些',
                style: TextStyle(fontSize: 12)),
            value: _autoLookup,
            onChanged: (v) => setState(() => _autoLookup = v),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _submit,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: _busy
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                          height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 10),
                      Text(_total > 0 ? '导入中… 已处理 $_done/共 $_total 个词' : '导入中…'),
                    ],
                  )
                : const Text('导入'),
          ),
          if (_result != null) ...[
            const SizedBox(height: 20),
            _ResultCard(result: _result!),
          ],
        ],
      ),
    );
  }
}

class _FileTab extends StatefulWidget {
  const _FileTab({required this.bookId});

  final String bookId;

  @override
  State<_FileTab> createState() => _FileTabState();
}

class _FileTabState extends State<_FileTab> with AutomaticKeepAliveClientMixin {
  /// 导入结果和选中的文件名要留在页面上，切 Tab 回来还能看到导了多少条。
  @override
  bool get wantKeepAlive => true;

  bool _busy = false;
  String? _fileName;
  ImportResult? _result;
  int _rows = 0;

  Future<void> _pick() async {
    try {
      // 只收词表格式。原来 FileType.any 允许选中 JSON 备份，整份备份会被
      // 当成 CSV 按行灌进词库，多出一堆 "version": 7 这样的垃圾词。
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['csv', 'tsv', 'txt', 'docx'],
        withData: false,
      );
      if (picked == null || picked.files.isEmpty) return;
      final file = picked.files.first;
      final path = file.path;
      if (path == null) {
        // 云盘 provider 常常只给内容不给路径；静默 return 会让用户以为按钮坏了
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('这个来源读不到文件路径，先把文件存到手机「下载」目录再选一次')),
        );
        return;
      }
      setState(() {
        _fileName = file.name;
        _result = null;
        _busy = true;
        _rows = 0;
      });
      final result = await Api.instance.importFile(
        widget.bookId,
        path,
        onRows: (n) {
          if (mounted) setState(() => _rows = n);
        },
      );
      if (!mounted) return;
      setState(() => _result = result);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(humanizeError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '支持 CSV / TSV / TXT 和 Word（.docx）：第一列单词、第二列释义（可选）。'
            'Word 里不管是表格，还是「abandon v. 放弃」这种一行一词，都能认出来。'
            '一次最多 ${Api.maxImportRows} 行，大文件边读边存，不会占满内存。'
            '备份文件请到「统计 → 恢复」导入。',
            style: TextStyle(fontSize: 13, color: P.muted),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pick,
            icon: const Icon(Icons.folder_open),
            label: Text(_busy
                ? (_rows > 0 ? '导入中… 已读 $_rows 行' : '导入中…')
                : '选择文件'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          ),
          if (_fileName != null) ...[
            const SizedBox(height: 12),
            Text('已选：$_fileName', style: TextStyle(fontSize: 13, color: P.body)),
          ],
          if (_result != null) ...[
            const SizedBox(height: 20),
            _ResultCard(result: _result!),
          ],
        ],
      ),
    );
  }
}

class _PhotoTab extends StatefulWidget {
  const _PhotoTab({required this.bookId});

  final String bookId;

  @override
  State<_PhotoTab> createState() => _PhotoTabState();
}

class _PhotoTabState extends State<_PhotoTab> with AutomaticKeepAliveClientMixin {
  /// 识别出来的候选和用户的勾选要保住，切走一次就得重新拍照。
  @override
  bool get wantKeepAlive => true;

  final _picker = ImagePicker();
  final _selected = <int>{};
  List<OcrCandidate> _candidates = const [];
  String? _imagePath;
  bool _recognizing = false;
  bool _importing = false;
  bool _autoLookup = false;
  ImportResult? _result;
  String _hint = '';

  @override
  void initState() {
    super.initState();
    _recoverLost();
  }

  /// 安卓在内存紧张时会回收拍照页，拍的图要从这里捞回来，否则用户会觉得白拍了
  Future<void> _recoverLost() async {
    try {
      final lost = await _picker.retrieveLostData();
      if (lost.isEmpty) return;
      final file = lost.file;
      if (file != null) await _runOcr(file.path);
    } catch (_) {
      // 没有待恢复的图就是正常情况，不用提示
    }
  }

  Future<void> _pick(ImageSource source) async {
    if (_recognizing) return;
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 2600,
        imageQuality: 92,
      );
      if (picked == null) return;
      await _runOcr(picked.path);
    } catch (e) {
      _toast('打不开相机或相册：${humanizeError(e)}');
    }
  }

  Future<void> _runOcr(String path) async {
    // 拍照回来或恢复丢失数据时页面可能已经关掉了
    if (!mounted) return;
    setState(() {
      _imagePath = path;
      _candidates = const [];
      _selected.clear();
      _result = null;
      _hint = '';
      _recognizing = true;
    });
    try {
      final found = await Ocr.instance.recognize(path);
      if (!mounted) return;
      setState(() {
        _candidates = found;
        _selected.addAll(List.generate(found.length, (i) => i));
        _hint = found.isEmpty
            ? '这张图里没认出英文单词，换个角度或拍清楚一点再试'
            : '共 ${found.length} 个词，默认全选，去掉认错的再导入';
      });
    } catch (e) {
      if (mounted) setState(() => _hint = '识别失败：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _recognizing = false);
    }
  }

  Future<void> _submit() async {
    final words = <String>[];
    for (final i in _selected) {
      if (i >= 0 && i < _candidates.length) words.add(_candidates[i].word);
    }
    if (words.isEmpty) {
      _toast('先勾选要导入的词');
      return;
    }
    setState(() => _importing = true);
    try {
      final result = await Api.instance.batchAdd(
        widget.bookId,
        words.join('\n'),
        autoLookup: _autoLookup,
      );
      if (!mounted) return;
      setState(() => _result = result);
      _toast(result.summary);
    } catch (e) {
      _toast(humanizeError(e));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _toggleAll(bool select) {
    setState(() {
      if (select) {
        _selected.addAll(List.generate(_candidates.length, (i) => i));
      } else {
        _selected.clear();
      }
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final busy = _recognizing || _importing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '对着书页或词表拍一张，自动认出发音旁边的英文单词。识别在本机完成，不需要联网。',
            style: TextStyle(fontSize: 13, color: P.muted),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : () => _pick(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('拍照'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : () => _pick(ImageSource.gallery),
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('相册选'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                ),
              ),
            ],
          ),
          if (_imagePath != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(
                File(_imagePath!),
                height: 120,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ],
          if (busy) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(minHeight: 3),
          ],
          if (_hint.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_hint, style: TextStyle(fontSize: 12, color: P.warnDeep2)),
          ],
          if (_candidates.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  '已选 ${_selected.length} / ${_candidates.length}',
                  style: TextStyle(fontSize: 12, color: P.body),
                ),
                const Spacer(),
                TextButton(
                  onPressed: busy ? null : () => _toggleAll(true),
                  child: const Text('全选', style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  onPressed: busy ? null : () => _toggleAll(false),
                  child: const Text('清空', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            Expanded(
              child: ListView.builder(
                itemCount: _candidates.length,
                itemBuilder: (context, index) {
                  final item = _candidates[index];
                  final checked = _selected.contains(index);
                  return CheckboxListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: checked,
                    onChanged: busy
                        ? null
                        : (v) {
                            setState(() {
                              if (v == true) {
                                _selected.add(index);
                              } else {
                                _selected.remove(index);
                              }
                            });
                          },
                    title: Text(item.word, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      item.line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: P.faint),
                    ),
                  );
                },
              ),
            ),
          ] else
            const Spacer(),
          if (_candidates.isNotEmpty)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('同时自动查词', style: TextStyle(fontSize: 13)),
              subtitle: const Text('补上音标和释义，词多时会慢一些', style: TextStyle(fontSize: 11)),
              value: _autoLookup,
              onChanged: busy ? null : (v) => setState(() => _autoLookup = v),
            ),
          FilledButton(
            onPressed: (busy || _candidates.isEmpty) ? null : _submit,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
            child: _importing
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text('导入选中的 ${_selected.length} 个词'),
          ),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                // 只显示 added/skipped 会把「本来就在库里」和「超出上限被截断」
                // 都算成跳过，用户看不出到底哪一步少了词。
                _result!.summary,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: P.primaryDeep),
              ),
            ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final ImportResult result;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: P.chip,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(result.summary,
                style: TextStyle(fontWeight: FontWeight.w600, color: P.primaryDeep)),
            for (final item in result.failed.take(5))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(item, style: TextStyle(fontSize: 12, color: P.warnDeep)),
              ),
            if (result.failed.length > 5)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('还有 ${result.failed.length - 5} 个失败，这里只列前 5 条',
                    style: TextStyle(fontSize: 12, color: P.warnDeep)),
              ),
          ],
        ),
      ),
    );
  }
}
