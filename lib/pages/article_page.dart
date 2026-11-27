import '../errors.dart';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart';
import '../article.dart';
import '../models.dart';
import '../speech.dart';
import '../theme.dart';
import '../translate.dart';
import '../wordform.dart';
import 'pick_words_page.dart';

/// DeepSeek 密钥存在 app_meta 里的键名，和翻译密钥一样只存本机。
const String _keyDeepSeek = 'deepseek_api_key';
const String _keyYoudaoApp = 'youdao_app_key';
const String _keyYoudaoSecret = 'youdao_app_secret';

/// 建议的选词数量，只用于空态文案，不再限制实际能选几个。
const int _suggestedWordCount = 30;

/// 文章列表 + 生成入口。
class ArticlePage extends StatefulWidget {
  const ArticlePage({super.key, required this.bookId, required this.bookName});

  final String bookId;
  final String bookName;

  @override
  State<ArticlePage> createState() => _ArticlePageState();
}

class _ArticlePageState extends State<ArticlePage> {
  List<Article> _articles = const [];
  bool _loading = true;
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // 生成中的请求没法中断，但页面已经走了，回调里全靠 mounted 拦住 setState。
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final articles = await Api.instance.articlesOf(widget.bookId);
      if (!mounted) return;
      setState(() {
        _articles = articles;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast(humanizeError(e));
    }
  }

  Future<void> _generate() async {
    if (_generating) return;

    // 先挑词：不限制个数，挑几个都行
    final picked = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => PickWordsPage(bookId: widget.bookId, bookName: widget.bookName),
      ),
    );
    if (!mounted || picked == null || picked.isEmpty) return;

    var apiKey = (await Api.instance.secureMetaGet(_keyDeepSeek))?.trim() ?? '';
    if (apiKey.isEmpty) {
      await _openKeyDialog();
      apiKey = (await Api.instance.secureMetaGet(_keyDeepSeek))?.trim() ?? '';
      if (apiKey.isEmpty || !mounted) return;
    }
    await _runGenerate(picked, apiKey);
  }

  Future<void> _runGenerate(List<String> spellings, String apiKey) async {
    setState(() => _generating = true);
    try {
      final generator = ArticleGenerator(apiKey: apiKey);
      final result = await generator.generate(spellings);
      final now = DateTime.now();
      final title = '${now.month} 月 ${now.day} 日 · ${spellings.length} 词';
      final id = await Api.instance.saveArticle(
        bookId: widget.bookId,
        title: title,
        body: result.body,
        words: spellings,
        missing: result.missing,
        model: generator.model,
        sentences: result.sentences,
      );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      if (result.missing.isNotEmpty) {
        _toast('生成了，但有 ${result.missing.length} 个词没用上：${result.missing.join('、')}');
      }
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ArticleReaderPage(articleId: id)),
      );
    } on ArticleException catch (e) {
      _toast(humanizeError(e));
    } catch (e) {
      _toast('生成失败：${humanizeError(e)}');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _openKeyDialog() async {
    final controller = TextEditingController(
      text: await Api.instance.secureMetaGet(_keyDeepSeek) ?? '',
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('填 DeepSeek 密钥'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: 'sk-...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '去 platform.deepseek.com 创建，形如 sk- 开头。密钥只存在本机、不写进备份，请求时随请求发给官方接口。'
              '生成文章按次计费，一篇约几厘钱。',
              style: TextStyle(fontSize: 12, height: 1.6, color: P.muted),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              await Api.instance.secureMetaSet(_keyDeepSeek, controller.text);
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 删一篇文章：二次确认后连它的逐句记录一起清，再刷新列表。
  Future<void> _deleteArticle(Article article) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这篇文章？'),
        content: Text(
          '「${article.title ?? '未命名文章'}」的逐句译文和句子解析会一起清掉，删除后无法恢复。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await Api.instance.deleteArticle(article.id);
      if (!mounted) return;
      _toast('已删除');
      await _load();
    } catch (e) {
      _toast(humanizeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.bookName} · 文章'),
        actions: [
          IconButton(
            tooltip: '密钥设置',
            icon: const Icon(Icons.key_outlined),
            onPressed: _openKeyDialog,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _articles.isEmpty
              ? _emptyView()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 90),
                  itemCount: _articles.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final article = _articles[index];
                    return _articleCard(article);
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _generating ? null : _generate,
        icon: _generating
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.auto_awesome),
        label: Text(_generating ? '生成中…' : '生成文章'),
      ),
    );
  }

  Widget _emptyView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_outlined, size: 46, color: P.faint),
            const SizedBox(height: 14),
            Text('还没有文章', style: TextStyle(fontSize: 16, color: P.title)),
            const SizedBox(height: 8),
            Text(
              '从词库里挑词，生成一篇把挑中的词都用上的短文。挑 $_suggestedWordCount 个左右读起来最顺，少几个也行。一次生成通常消耗一次模型调用，漏词时会自动补写一轮，最多两次。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, height: 1.7, color: P.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _articleCard(Article article) {
    final missing = article.missing;
    return Material(
      color: P.card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ArticleReaderPage(articleId: article.id)),
          );
          _load();
        },
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: P.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      article.title ?? '未命名文章',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: P.title),
                    ),
                  ),
                  Text(
                    '${article.keyWordCount} 个重点词',
                    style: TextStyle(fontSize: 11, color: P.faint),
                  ),
                  SizedBox(
                    width: 30,
                    height: 30,
                    child: PopupMenuButton<String>(
                      padding: EdgeInsets.zero,
                      tooltip: '更多',
                      icon: Icon(Icons.more_horiz, size: 18, color: P.faint),
                      color: P.card,
                      onSelected: (value) {
                        if (value == 'delete') _deleteArticle(article);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'delete',
                          child: Text('删除文章'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                article.body.replaceAll('\n', ' '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, height: 1.6, color: P.muted),
              ),
              if (missing.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '缺 ${missing.length} 个词：${missing.join('、')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: P.warn),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 阅读页：按句展示，逐句可翻译、可解析。
class ArticleReaderPage extends StatefulWidget {
  const ArticleReaderPage({super.key, required this.articleId});

  final String articleId;

  @override
  State<ArticleReaderPage> createState() => _ArticleReaderPageState();
}

class _ArticleReaderPageState extends State<ArticleReaderPage> {
  Article? _article;
  List<ArticleSentence> _sentences = const [];
  final Map<int, String> _zh = {};
  final Map<int, SentenceParse> _parses = {};
  final Set<int> _busy = {};

  /// 重点词及其所有变形的索引，_load 时算一次，逐句渲染只查表。
  Map<String, String> _variantIndex = {};
  bool _loading = true;

  /// 是否正在整篇朗读，「听全文」按钮据此切成「停止」。
  bool _listening = false;

  /// 读取失败时留在这里，页面要能说出失败而不是一直转圈
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // 离开页面就把朗读停掉：整篇连读是循环等待，不停会跟着用户换页面继续念。
    // _listening 也要复位：只靠 mounted 判断的话，循环里的 await 已经把这一块
    // 播起来，stop 完成唤醒后还要等下一轮才退出，那一块的声音会漏出来。
    _listening = false;
    Speech.instance.stop();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final article = await Api.instance.articleById(widget.articleId);
      final sentences = await Api.instance.sentencesOf(widget.articleId);
      if (!mounted) return;
      setState(() {
        _article = article;
        _sentences = sentences;
        _variantIndex = _buildVariantIndex(article?.words ?? const <String>[]);
        _loadError = null;
        _loading = false;
        for (final s in sentences) {
          final zh = s.zh;
          if (zh != null && zh.isNotEmpty) _zh[s.idx] = zh;
          final raw = s.parseJson;
          if (raw != null && raw.isNotEmpty) {
            final json = extractJsonObject(raw);
            if (json != null) _parses[s.idx] = SentenceParse.fromJson(json);
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = humanizeError(e);
      });
    }
  }

  void _retryLoad() {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    _load();
  }

  /// 把重点词的所有变形展开成一张表，同一变形只留第一个命中的原词。
  static Map<String, String> _buildVariantIndex(List<String> keyWords) {
    final map = <String, String>{};
    for (final word in keyWords) {
      for (final variant in wordVariants(word)) {
        map.putIfAbsent(variant, () => word);
      }
    }
    return map;
  }

  /// 返回译文；没配置密钥、请求失败或本来就没这句时返回 null。
  Future<String?> _translateSentence(ArticleSentence sentence) async {
    final idx = sentence.idx;
    if (_busy.contains(idx)) return _zh[idx];
    if (_zh.containsKey(idx)) return _zh[idx];
    setState(() => _busy.add(idx));
    try {
      final appKey = (await Api.instance.secureMetaGet(_keyYoudaoApp))?.trim() ?? '';
      final appSecret = (await Api.instance.secureMetaGet(_keyYoudaoSecret))?.trim() ?? '';
      if (appKey.isEmpty || appSecret.isEmpty) {
        _toast('逐句翻译用的是有道，先去「翻译」页填有道 key');
        return null;
      }
      final zh = await YoudaoTranslator(appKey: appKey, appSecret: appSecret)
          .translate(sentence.en, from: 'en', to: 'zh-CHS');
      await Api.instance.setSentenceZh(widget.articleId, idx, zh);
      if (mounted) setState(() => _zh[idx] = zh);
      return zh;
    } catch (e) {
      _toast('翻译失败：${humanizeError(e)}');
      return null;
    } finally {
      if (mounted) setState(() => _busy.remove(idx));
    }
  }

  Future<void> _openParse(ArticleSentence sentence) async {
    final idx = sentence.idx;
    if (_busy.contains(idx)) return;
    if (_parses.containsKey(idx)) {
      _showParseSheet(sentence, _parses[idx]!);
      return;
    }

    final apiKey = (await Api.instance.secureMetaGet(_keyDeepSeek))?.trim() ?? '';
    if (apiKey.isEmpty) {
      _toast('解析要用 DeepSeek 密钥，先在右上角设置里填');
      return;
    }

    setState(() => _busy.add(idx));
    try {
      final words = _article?.words ?? const <String>[];
      final parse = await ArticleGenerator(apiKey: apiKey)
          .parseSentence(sentence.en, words: words);
      final raw = jsonEncode(parse.toJson());
      await Api.instance.setSentenceParse(widget.articleId, idx, raw);
      if (!mounted) return;
      setState(() => _parses[idx] = parse);
      _showParseSheet(sentence, parse);
    } on ArticleException catch (e) {
      // 结构化失败时退到只显示翻译；连翻译都拿不到也要把这一句弹出来，
      // 否则用户点了解析什么也看不到。
      // 先把 busy 放开：_translateSentence 拿 busy 当去重标记，不放开就
      // 直接返回缓存里的 null，弹窗里只剩一句错误、没有译文。
      if (mounted) setState(() => _busy.remove(idx));
      final zh = await _translateSentence(sentence);
      if (!mounted) return;
      _showFallbackSheet(sentence, zh ?? _zh[idx], e.message);
    } catch (e) {
      // 同上：回退翻译前必须放开 busy，否则这一句永远拿不到译文
      if (mounted) setState(() => _busy.remove(idx));
      final zh = await _translateSentence(sentence);
      if (!mounted) return;
      _showFallbackSheet(sentence, zh ?? _zh[idx], humanizeError(e));
    } finally {
      if (mounted) setState(() => _busy.remove(idx));
    }
  }

  void _showParseSheet(ArticleSentence sentence, SentenceParse parse) {
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: P.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 30),
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: P.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text('句子解析',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: P.title)),
            const SizedBox(height: 12),
            Text(sentence.en,
                style: TextStyle(fontSize: 15, height: 1.7, color: P.title, fontWeight: FontWeight.w600)),
            if (parse.zh.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(parse.zh, style: TextStyle(fontSize: 13, height: 1.7, color: P.muted)),
            ],
            if (parse.structure.isNotEmpty) ...[
              const SizedBox(height: 18),
              _sectionTitle('句子结构'),
              const SizedBox(height: 8),
              for (final part in parse.structure) _structureRow(part),
            ],
            if (parse.words.isNotEmpty) ...[
              const SizedBox(height: 18),
              _sectionTitle('重点词语'),
              const SizedBox(height: 8),
              for (final word in parse.words) _wordRow(word),
            ],
          ],
        ),
      ),
    );
  }

  /// zh 为 null 表示翻译也没拿到，这时弹层只放原句、失败原因和重试入口。
  void _showFallbackSheet(ArticleSentence sentence, String? zh, String? failReason) {
    if (!mounted) return;
    final hasZh = zh != null && zh.trim().isNotEmpty;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: P.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('句子解析',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: P.title)),
            const SizedBox(height: 12),
            Text(sentence.en,
                style: TextStyle(fontSize: 15, height: 1.7, color: P.title, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (hasZh) ...[
              Text(zh, style: TextStyle(fontSize: 13, height: 1.7, color: P.muted)),
              const SizedBox(height: 14),
              Text('结构拆解这次没生成成功，只保留了翻译。稍后再点一次解析可以重试。',
                  style: TextStyle(fontSize: 12, height: 1.6, color: P.warn)),
            ] else ...[
              Text(
                failReason == null || failReason.isEmpty ? '结构和翻译这次都没成功。' : '解析失败：$failReason',
                style: TextStyle(fontSize: 12.5, height: 1.6, color: P.warn),
              ),
              const SizedBox(height: 6),
              Text('逐句翻译要用有道密钥，去「翻译」页填好后再点一次；也可以先只看原句。',
                  style: TextStyle(fontSize: 11.5, height: 1.6, color: P.faint)),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _openParse(sentence);
                },
                child: const Text('再解析一次'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            color: P.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Text(text, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: P.title)),
      ],
    );
  }

  Widget _structureRow(ParsePart part) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(top: 7, right: 8),
            decoration: BoxDecoration(color: P.primary, shape: BoxShape.circle),
          ),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: TextStyle(fontSize: 13, height: 1.65, color: P.body),
                children: [
                  TextSpan(
                    text: part.part,
                    style: TextStyle(fontWeight: FontWeight.w600, color: P.title),
                  ),
                  TextSpan(text: '：${part.role}'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _wordRow(ParseWord word) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              style: TextStyle(fontSize: 13.5, height: 1.6, color: P.title),
              children: [
                TextSpan(
                  text: word.word,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (word.pos.isNotEmpty)
                  TextSpan(text: '  ${word.pos}', style: TextStyle(color: P.muted, fontSize: 12)),
                if (word.zh.isNotEmpty) TextSpan(text: '  ${word.zh}'),
              ],
            ),
          ),
          if (word.example.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(word.example,
                  style: TextStyle(fontSize: 12, height: 1.5, color: P.faint)),
            ),
        ],
      ),
    );
  }

  /// 正文按句渲染，重点词加下划线。变形表在 _load 时算好，滚动时不再重算。
  Widget _sentenceText(String text) {
    final spans = <TextSpan>[];
    var last = 0;
    for (final match in RegExp(r"[A-Za-z][A-Za-z'\-]*").allMatches(text)) {
      final token = match.group(0) ?? '';
      if (match.start > last) {
        spans.add(TextSpan(text: text.substring(last, match.start)));
      }
      final hit = _variantIndex.containsKey(token.toLowerCase());
      spans.add(TextSpan(
        text: token,
        style: hit
            ? TextStyle(
                decoration: TextDecoration.underline,
                decorationColor: P.warnDeep,
                decorationThickness: 2,
              )
            : null,
      ));
      last = match.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return RichText(
      text: TextSpan(
        style: TextStyle(fontSize: 16, height: 1.8, color: P.title),
        children: spans,
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final article = _article;
    return Scaffold(
      appBar: AppBar(
        title: Text(article?.title ?? '文章'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('文章打不开', style: TextStyle(color: P.muted, fontSize: 14)),
                        const SizedBox(height: 6),
                        Text(
                          _loadError!,
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: P.faint, fontSize: 11.5),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(onPressed: _retryLoad, child: const Text('重试')),
                      ],
                    ),
                  ),
                )
              : article == null
                  ? Center(child: Text('文章不存在', style: TextStyle(color: P.muted)))
                  : Column(
                  children: [
                    _metaBar(article),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 30),
                        itemCount: _sentences.length,
                        itemBuilder: (context, index) => _sentenceCard(_sentences[index]),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _metaBar(Article article) {
    final missing = article.missing;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 10, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: P.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_sentences.length} 句 · ${countWords(article.body)} 词 · '
                  '${article.keyWordCount - missing.length} 个重点词',
                  style: TextStyle(fontSize: 12, color: P.muted),
                ),
                if (missing.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      '没用到：${missing.join('、')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: P.warn),
                    ),
                  ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: _speakAll,
            icon: Icon(
              _listening ? Icons.stop_circle_outlined : Icons.headphones_outlined,
              size: 18,
            ),
            label: Text(
              _listening ? '停止' : '听全文',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// 整篇朗读：按句子聚成小块逐块读，再点一次就停。
  ///
  /// 原来是把整篇 440 词一次丢给引擎。神经语音的合成是在主 isolate 里同步算的，
  /// 一整篇会把界面卡住好几秒，也没有任何中途停下的办法。
  Future<void> _speakAll() async {
    if (_listening) {
      setState(() => _listening = false);
      await Speech.instance.stop();
      return;
    }
    final chunks = _speechChunks();
    if (chunks.isEmpty) {
      _toast('这篇文章还没有可朗读的内容');
      return;
    }
    setState(() => _listening = true);
    try {
      for (var i = 0; i < chunks.length; i++) {
        if (!mounted || !_listening) break;
        // 等这一块播完再读下一块，否则引擎被后面的句子打断，只听到最后一句。
        // 顺带把下一块交给它预合成：神经语音现场推理要一两秒，不提前算就会一段一静默。
        final next = i + 1 < chunks.length ? chunks[i + 1] : null;
        final ok = await Speech.instance.speakAndWait(chunks[i], prefetchNext: next);
        if (!ok) {
          if (mounted) _toast('这台手机的英文语音包可能没装');
          break;
        }
      }
    } finally {
      if (mounted) setState(() => _listening = false);
    }
  }

  /// 每块控制在 40 词左右。
  ///
  /// 推理已经搬到合成线程，不再占 UI 线程，所以块可以放大：块越小，块与块之间
  /// 那次播放器重新起播的间隙就越密，长文连锁听下来反而更顿。40 词一块时
  /// 单块约二十秒，间隙数量降到原来的四成左右。
  /// 「停止」按钮不依赖推理返回，随时能打断。
  List<String> _speechChunks() {
    const maxWords = 40;
    final chunks = <String>[];
    final buffer = StringBuffer();
    var words = 0;
    for (final sentence in _sentences) {
      final text = sentence.en.trim();
      if (text.isEmpty) continue;
      buffer.write(text);
      buffer.write(' ');
      words += text.split(RegExp(r'\s+')).length;
      if (words >= maxWords) {
        chunks.add(buffer.toString().trim());
        buffer.clear();
        words = 0;
      }
    }
    final tail = buffer.toString().trim();
    if (tail.isNotEmpty) chunks.add(tail);
    return chunks;
  }

  Widget _sentenceCard(ArticleSentence sentence) {
    final idx = sentence.idx;
    final zh = _zh[idx];
    final busy = _busy.contains(idx);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: P.border.withValues(alpha: 0.6))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => Speech.instance.speak(sentence.en),
            child: _sentenceText(sentence.en),
          ),
          if (zh != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(zh, style: TextStyle(fontSize: 13, height: 1.7, color: P.muted)),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _smallButton(
                label: '解析',
                busy: busy,
                onPressed: () => _openParse(sentence),
              ),
              const SizedBox(width: 8),
              _smallButton(
                label: zh == null ? '译' : '已译',
                busy: busy,
                onPressed: zh == null ? () => _translateSentence(sentence) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _smallButton({required String label, required bool busy, VoidCallback? onPressed}) {
    return SizedBox(
      height: 28,
      child: OutlinedButton(
        onPressed: busy ? null : onPressed,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          side: BorderSide(color: P.border),
          foregroundColor: P.muted,
          textStyle: const TextStyle(fontSize: 11.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
        child: busy
            ? const SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              )
            : Text(label),
      ),
    );
  }
}
