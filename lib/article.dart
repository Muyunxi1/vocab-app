import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'wordform.dart';

/// 文章生成相关错误，界面直接显示 message。
/// [retryable] 表示重发一次有意义（网络抖动、模型偶发空回复）。
class ArticleException implements Exception {
  const ArticleException(this.message, {this.retryable = false});

  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

/// 生成结果：正文、切好的句子、没用上的词。
class GeneratedArticle {
  final String body;
  final List<String> sentences;
  final List<String> missing;

  GeneratedArticle({
    required this.body,
    required this.sentences,
    required this.missing,
  });

  int get wordCount => countWords(body);
}

/// 数正文里的英文词数。列表页的「N 词」和生成结果共用这一份正则。
int countWords(String body) => RegExp(r"[A-Za-z][A-Za-z'\-]*").allMatches(body).length;

/// 句子结构里的一段。
class ParsePart {
  final String part;
  final String role;

  ParsePart({required this.part, required this.role});
}

/// 一句话里的重点词。
class ParseWord {
  final String word;
  final String pos;
  final String zh;
  final String example;

  ParseWord({
    required this.word,
    required this.pos,
    required this.zh,
    required this.example,
  });
}

/// 单句解析结果：整句中文 + 结构拆解 + 重点词。
class SentenceParse {
  final String zh;
  final List<ParsePart> structure;
  final List<ParseWord> words;

  SentenceParse({
    required this.zh,
    required this.structure,
    required this.words,
  });

  /// 从模型返回的 JSON 构造；字段缺失时按空处理，不抛异常。
  static SentenceParse fromJson(Map<String, dynamic> json) {
    final structure = <ParsePart>[];
    final rawStructure = json['structure'];
    if (rawStructure is List) {
      for (final item in rawStructure) {
        if (item is! Map) continue;
        final part = (item['part'] ?? '').toString().trim();
        final role = (item['role'] ?? '').toString().trim();
        if (part.isEmpty && role.isEmpty) continue;
        structure.add(ParsePart(part: part, role: role));
      }
    }

    final words = <ParseWord>[];
    final rawWords = json['words'];
    if (rawWords is List) {
      for (final item in rawWords) {
        if (item is! Map) continue;
        final word = (item['word'] ?? '').toString().trim();
        if (word.isEmpty) continue;
        words.add(ParseWord(
          word: word,
          pos: (item['pos'] ?? '').toString().trim(),
          zh: (item['zh'] ?? '').toString().trim(),
          example: (item['example'] ?? '').toString().trim(),
        ));
      }
    }

    return SentenceParse(
      zh: (json['zh'] ?? '').toString().trim(),
      structure: structure,
      words: words,
    );
  }

  Map<String, dynamic> toJson() => {
        'zh': zh,
        'structure': [
          for (final p in structure) {'part': p.part, 'role': p.role},
        ],
        'words': [
          for (final w in words)
            {'word': w.word, 'pos': w.pos, 'zh': w.zh, 'example': w.example},
        ],
      };
}

/// DeepSeek 文章生成客户端。密钥由用户自己填，只存本机。
class ArticleGenerator {
  const ArticleGenerator({required this.apiKey, this.model = 'deepseek-chat'});

  final String apiKey;
  final String model;

  static const String _endpoint = 'https://api.deepseek.com/v1/chat/completions';
  static const Duration _requestTimeout = Duration(seconds: 60);

  /// 生成一篇文章。漏词会整篇重写一轮，仍漏就在结果里如实标出。
  Future<GeneratedArticle> generate(List<String> words) async {
    var body = await _requestArticle(words);
    var missing = missingWords(body, words);
    if (missing.isNotEmpty) {
      body = await _requestArticle(words, emphasize: missing);
      missing = missingWords(body, words);
    }
    return GeneratedArticle(
      body: body,
      sentences: splitSentences(body),
      missing: missing,
    );
  }

  /// 解析一句话。返回 JSON 解析后的结构，失败抛 [ArticleException]。
  Future<SentenceParse> parseSentence(String sentence, {List<String> words = const []}) async {
    final messages = <Map<String, String>>[
      {
        'role': 'system',
        'content': '你是英语精读老师，回答只输出 JSON，不要 markdown 代码块，不要任何解释。',
      },
      {'role': 'user', 'content': _buildParsePrompt(sentence, words)},
    ];
    final raw = await _chat(messages, maxTokens: 1000, temperature: 0.2);
    final json = extractJsonObject(raw);
    if (json == null) {
      throw const ArticleException('解析结果格式不对，稍后再试');
    }
    return SentenceParse.fromJson(json);
  }

  Future<String> _requestArticle(List<String> words, {List<String> emphasize = const []}) {
    final messages = <Map<String, String>>[
      {
        'role': 'system',
        'content': '你是英语分级读物作者，写具体的叙事，不堆形容词，不用生僻表达。',
      },
      {'role': 'user', 'content': _buildPrompt(words, emphasize: emphasize)},
    ];
    return _chat(messages, maxTokens: 900, temperature: 0.8);
  }

  String _buildPrompt(List<String> words, {List<String> emphasize = const []}) {
    final buffer = StringBuffer()
      ..writeln('请用下面给定的单词写一篇英文短文，要求：')
      ..writeln('1. 难度控制在 CEFR B1，单句不超过 18 个词；')
      ..writeln('2. 正文 180–260 词，分 3–4 段，段落之间空一行；')
      ..writeln('3. 给定的每个词都要在正文中出现至少一次，允许按语法变形（时态、单复数、比较级等）；')
      ..writeln('4. 讲一件具体的事，语境自然连贯，不要写成单词表造句；')
      ..writeln('5. 只输出英文正文，不要标题、不要中文、不要任何标注或解释。');
    if (emphasize.isNotEmpty) {
      buffer.writeln('上一版漏用了这些词，这次务必自然地把它们都用进去：${emphasize.join(', ')}。');
    }
    buffer.writeln('必须用到的单词：${words.join(', ')}');
    return buffer.toString();
  }

  String _buildParsePrompt(String sentence, List<String> words) {
    final hint = words.isEmpty ? '' : '\n本句可能涉及的词：${words.join(', ')}';
    return '请解析下面这句英文，只输出一个 JSON 对象，不要代码块、不要多余说明：\n'
        '{\n'
        '  "zh": "整句中文翻译",\n'
        '  "structure": [{"part": "原句中的片段", "role": "主语/谓语/宾语/时间状语从句/插入语 等"}],\n'
        '  "words": [{"word": "本句值得记的词", "pos": "n./v./adj. 等", "zh": "中文释义", "example": "一个简短的英文例句"}]\n'
        '}\n'
        '要求：structure 要覆盖整句、按原句顺序排列；words 只挑 2–4 个词。$hint\n'
        '句子：$sentence';
  }

  /// 带一次退避重试的外壳。
  Future<String> _chat(List<Map<String, String>> messages,
      {int maxTokens = 800, double temperature = 0.8}) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _chatOnce(messages, maxTokens: maxTokens, temperature: temperature);
      } on ArticleException catch (e) {
        // 429 / 503 / 断网 / 超时都标了 retryable，但原来这个字段没人用，
        // 用户只能自己再点一次。这里补一次 800ms 退避重试。
        if (!e.retryable || attempt == 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
    }
    throw const ArticleException('生成失败，稍后再试');
  }

  Future<String> _chatOnce(List<Map<String, String>> messages,
      {int maxTokens = 800, double temperature = 0.8}) async {
    final payload = jsonEncode({
      'model': model,
      'messages': messages,
      'max_tokens': maxTokens,
      'temperature': temperature,
      'stream': false,
    });

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.postUrl(Uri.parse(_endpoint)).timeout(_requestTimeout);
      request.headers.contentType = ContentType.json;
      request.headers.set('Authorization', 'Bearer $apiKey');
      request.write(payload);
      final response = await request.close().timeout(_requestTimeout);
      final raw = await response.transform(utf8.decoder).join().timeout(_requestTimeout);

      switch (response.statusCode) {
        case 200:
          break;
        case 401:
          throw const ArticleException('DeepSeek 密钥无效，检查填的 key 是否正确');
        case 402:
          throw const ArticleException('DeepSeek 账户余额不足，充值后再试');
        case 429:
          throw const ArticleException('请求太频繁，等几秒再试', retryable: true);
        case 500:
        case 502:
        case 503:
          throw const ArticleException('生成服务暂时不可用，稍后再试', retryable: true);
        default:
          throw ArticleException('生成服务返回 HTTP ${response.statusCode}');
      }

      final decoded = jsonDecode(raw);
      final choices = decoded is Map ? decoded['choices'] : null;
      if (choices is! List || choices.isEmpty) {
        throw const ArticleException('模型没有返回内容', retryable: true);
      }
      final first = choices.first;
      final message = first is Map ? first['message'] : null;
      final content = message is Map ? message['content'] : null;
      final text = content is String ? content.trim() : '';
      if (text.isEmpty) {
        throw const ArticleException('模型返回了空内容', retryable: true);
      }
      return cleanBody(text);
    } on ArticleException {
      // 状态码分支抛的是已经写好中文的可读异常，不能被下面的兜底吞掉
      rethrow;
    } on SocketException catch (e) {
      throw ArticleException('连不上 DeepSeek，检查网络：${e.message}', retryable: true);
    } on HandshakeException {
      throw const ArticleException('和 DeepSeek 建立安全连接失败，换网络再试', retryable: true);
    } on TimeoutException {
      throw const ArticleException('生成超时（60 秒），网络慢时再试一次', retryable: true);
    } on FormatException {
      // 200 但 body 不是 JSON：多半被网络中间设备或代理改写过
      throw const ArticleException('返回内容不是预期格式，稍后再试', retryable: true);
    } on HttpException catch (e) {
      throw ArticleException('连接被中断，换网络再试：${e.message}', retryable: true);
    } on Object catch (e) {
      throw ArticleException('生成失败：$e', retryable: true);
    } finally {
      client.close(force: true);
    }
  }
}

/// 去掉代码块围栏、标题行和多余空行，只留正文。
String cleanBody(String raw) {
  var text = raw.trim();
  if (text.startsWith('```')) {
    final firstBreak = text.indexOf('\n');
    if (firstBreak > 0) text = text.substring(firstBreak + 1);
    final lastFence = text.lastIndexOf('```');
    if (lastFence >= 0) text = text.substring(0, lastFence);
  }
  final lines = text.split('\n');
  final kept = <String>[];
  for (final line in lines) {
    final trimmed = line.trim();
    // 模型偶尔会加「Title:」这类行，整行丢掉
    if (RegExp(r'^(title|标题)\s*[:：]', caseSensitive: false).hasMatch(trimmed)) continue;
    kept.add(trimmed);
  }
  var result = kept.join('\n');
  result = result.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return result.trim();
}

/// 句号后面跟这些缩写时不算句子边界，否则 Dr. / U.S. 会被切成半句。
const List<String> _abbreviations = <String>[
  'Mr', 'Mrs', 'Ms', 'Dr', 'Prof', 'St', 'Jr', 'Sr', 'vs', 'etc',
  'e.g', 'i.e', 'a.m', 'p.m', 'U.S', 'U.K',
  // 文章里常见的另一半缩写，漏掉时会在缩写处切成半句
  'No', 'Nos', 'Fig', 'Figs', 'Inc', 'Ltd', 'Co', 'Corp', 'Vol', 'Ch', 'Sec',
  'pp', 'Ph.D', 'M.D', 'B.A', 'M.A', 'Rev', 'Hon', 'Gov', 'Sen', 'Rep',
  'Capt', 'Col', 'Gen', 'Lt', 'Maj', 'Sgt', 'Mt', 'Ave', 'Blvd', 'Dept', 'Est',
];

/// 缩写句号的临时占位符，取正文里不可能出现的控制字符。
const String _abbrMark = '\u0001';

String _guardAbbreviations(String text) {
  var result = text;
  // 小数点不是句号。"He was 3.5 years old." 原来会被切成
  // "He was 3." 和 "5 years old." 两句，逐句译文和解析全建在半句上。
  result = result.replaceAllMapped(
    RegExp(r'(\d)\.(\d)'),
    (m) => '${m[1]}$_abbrMark${m[2]}',
  );
  for (final abbr in _abbreviations) {
    final pattern = RegExp(
      r'\b' + RegExp.escape(abbr) + r'\.(?=\s|$)',
      caseSensitive: false,
    );
    // 缩写内部的点也要一起换掉：只换末尾点时，p.m. 会在中间的「.」处被切开
    final safe = abbr.replaceAll('.', _abbrMark);
    result = result.replaceAll(pattern, '$safe$_abbrMark');
  }
  return result;
}

String _restoreAbbreviations(String text) => text.replaceAll(_abbrMark, '.');

/// 按句末标点切句，保留标点；段落边界也切。
List<String> splitSentences(String body) {
  final out = <String>[];
  for (final para in body.split('\n')) {
    final p = para.trim();
    if (p.isEmpty) continue;
    final guarded = _guardAbbreviations(p);
    for (final match in RegExp(r'''[^.!?]+[.!?]+["')\]]*|[^.!?]+$''').allMatches(guarded)) {
      final sentence = _restoreAbbreviations((match.group(0) ?? '').trim());
      if (sentence.isEmpty) continue;
      // 只有标点的碎片跳过
      if (!RegExp('[A-Za-z]').hasMatch(sentence)) continue;
      out.add(sentence);
    }
  }
  return out;
}

/// 词组里相邻两个词之间允许隔开的最大字符数，超过就不算同一个词组。
const int _phraseMaxGap = 32;

/// 正文里没出现过的词。词形按 [wordVariants] 展开后匹配，不会把 went 当成没用上 go。
List<String> missingWords(String body, List<String> words) {
  final lowerBody = body.toLowerCase();
  final tokens = RegExp(r"[a-z']+")
      .allMatches(lowerBody)
      .map((m) => m.group(0) ?? '')
      .toSet();
  final missing = <String>[];
  for (final raw in words) {
    final word = raw.trim().toLowerCase();
    if (word.isEmpty) continue;
    if (word.contains(' ')) {
      // 词组逐词按变形展开，并要求相邻两词挨得够近：
      // 只判断"每个词都在正文里"会把 take ...（隔两句）... off 也算用上了。
      final parts = word.split(' ').where((p) => p.isNotEmpty).toList();
      var cursor = 0;
      var allFound = true;
      for (final part in parts) {
        var best = -1;
        var bestLen = 0;
        for (final v in wordVariants(part)) {
          var from = cursor;
          // 同一个词可能出现多次，最多往前找 8 处，避免长文里空转
          for (var tries = 0; tries < 8; tries++) {
            final at = lowerBody.indexOf(v, from);
            if (at < 0) break;
            if (at - cursor <= _phraseMaxGap) {
              if (best < 0 || at < best) {
                best = at;
                bestLen = v.length;
              }
              break;
            }
            from = at + 1;
          }
        }
        if (best < 0) {
          allFound = false;
          break;
        }
        cursor = best + bestLen;
      }
      if (!allFound) missing.add(raw);
      continue;
    }
    final variants = wordVariants(word);
    var hit = false;
    for (final v in variants) {
      if (tokens.contains(v)) {
        hit = true;
        break;
      }
    }
    if (!hit) missing.add(raw);
  }
  return missing;
}

/// 从模型回复里抠出第一个完整 JSON 对象；抠不出来返回 null。
Map<String, dynamic>? extractJsonObject(String raw) {
  var text = raw.trim();
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
  if (fence != null) text = fence.group(1)?.trim() ?? text;
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final decoded = jsonDecode(text.substring(start, end + 1));
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}
