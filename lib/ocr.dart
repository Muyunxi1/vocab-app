import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// 一条识别结果：单词 + 它所在的那一行原文，方便用户核对 OCR 有没有认错。
class OcrCandidate {
  const OcrCandidate(this.word, this.line);

  final String word;

  /// 识别到的整行，界面上作为灰字提示。
  final String line;
}

/// 一次识别拿到的全部结果：整段原文给翻译用，候选词给词表用。
class OcrScan {
  const OcrScan({required this.text, required this.candidates});

  final String text;
  final List<OcrCandidate> candidates;
}

/// 离线文字识别：模型随 APK 一起分发，不联网、不依赖 Google Play 服务。
class Ocr {
  Ocr._();

  static final Ocr instance = Ocr._();

  /// 一次最多取 5000 个，与批量添加的单次上限（Api.maxBatchWords）取同一个量级。
  ///
  /// 原来是 500：一份 3991 词的六级词表导进来，生词表只列得出前 500 个，
  /// 用户看到「共 500 个词」就以为导入上限没修、还是老包。实际上取词和入库是两道
  /// 独立的闸门，这次把取词闸门一起抬到 5000，两者才对得上。
  /// 列表本身是 ListView.builder，5000 行按需构建；释义查询走 lookupMany，
  /// 内部按 200 一批查词典，不会把 5000 个占位符塞进一条 SQL。
  static const int maxWords = 5000;

  /// 英文单词：字母开头，允许中间有连字符和撇号。
  ///
  /// 原来带 {1,44} 上限，超过 45 字符的词会被正则截成前半截当成一个"词"收进去；
  /// 长度交给后续 addWord 的 50 字符校验，这里不再截断。
  static final RegExp _token = RegExp(r"[A-Za-z][A-Za-z'\-]*");

  /// 书页上最常见的功能词。拍照取词的价值是挑生词，冠词、介词、代词、
  /// 助动词一堆挤进候选里，用户得逐个取消勾选，等于这个功能没做。
  /// 只收纯功能词，名词/动词/形容词一概不动，免得把该学的词挡掉。
  static const Set<String> _stopWords = {
    'a', 'an', 'the',
    'and', 'or', 'but', 'nor', 'so', 'yet',
    'of', 'to', 'in', 'on', 'at', 'by', 'for', 'with', 'from', 'into', 'onto',
    'about', 'as', 'than', 'then', 'that', 'this', 'these', 'those',
    'is', 'am', 'are', 'was', 'were', 'be', 'been', 'being',
    'do', 'does', 'did', 'done', 'doing',
    'has', 'have', 'had', 'having',
    'will', 'would', 'shall', 'should', 'can', 'could', 'may', 'might', 'must',
    'i', 'you', 'he', 'she', 'it', 'we', 'they',
    'me', 'him', 'her', 'us', 'them', 'my', 'your', 'his', 'its', 'our', 'their',
    'not', 'if', 'when', 'while', 'because', 'since', 'until',
    'there', 'here', 'where', 'what', 'which', 'who', 'whom', 'whose', 'how', 'why',
    'all', 'any', 'some', 'each', 'every', 'both', 'more', 'most', 'much', 'many',
    'other', 'another', 'such',
  };

  /// 书页上的栏目名、标题、指令行，不是生词。
  static const Set<String> _noiseWords = {
    'unit', 'units', 'lesson', 'lessons', 'module', 'modules',
    'chapter', 'chapters', 'page', 'pages', 'section', 'sections',
    'part', 'parts', 'vocabulary', 'vocab', 'exercise', 'exercises',
    'activity', 'activities', 'reading', 'writing', 'listening',
    'speaking', 'grammar', 'note', 'notes', 'review', 'test', 'quiz',
    'word', 'words', 'list', 'lists', 'name', 'class', 'grade',
    'date', 'book', 'books', 'student', 'students', 'teacher',
    'copyright', 'contents', 'appendix', 'index',
  };

  /// 识别图片，返回整段文字和候选单词。识别失败会抛异常，由调用方提示。
  ///
  /// [chinese] 为 true 时改用中文识别模型，能认中英混排的书页；
  /// 中文模型对英文的取词明显不如英文模型，词表用途还是走英文更准。
  Future<OcrScan> scan(String imagePath,
      {bool chinese = false, bool keepStopWords = false}) async {
    final recognizer = TextRecognizer(
      script: chinese ? TextRecognitionScript.chinese : TextRecognitionScript.latin,
    );
    try {
      final input = InputImage.fromFilePath(imagePath);
      final recognized = await recognizer.processImage(input);
      final candidates = <OcrCandidate>[];
      final seen = <String>{};
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          _collect(line.text, candidates, seen, keepStopWords: keepStopWords);
        }
      }
      return OcrScan(text: recognized.text, candidates: candidates);
    } finally {
      // 不释放会一直占着原生识别器
      await recognizer.close();
    }
  }

  /// 只要候选单词（添加单词页用）。
  Future<List<OcrCandidate>> recognize(String imagePath) async =>
      (await scan(imagePath)).candidates;

  /// 从一段纯文本（PDF、txt、粘贴内容）里挑单词。
  List<OcrCandidate> extractFromText(String text) {
    final candidates = <OcrCandidate>[];
    final seen = <String>{};
    for (final line in text.split('\n')) {
      _collect(line, candidates, seen);
      if (candidates.length >= maxWords) break;
    }
    return candidates;
  }

  void _collect(String raw, List<OcrCandidate> into, Set<String> seen,
      {bool keepStopWords = false}) {
    final line = raw.trim();
    if (line.isEmpty) return;
    // 一行里的每个词都是候选。原来只取 firstMatch，一行只出一个词，
    // 一页书最多出十来个候选，剩下的位置全是 The / Of 这种词。
    for (final m in _token.allMatches(line)) {
      if (into.length >= maxWords) return;
      var word = m.group(0)!;
      // 行尾断词留下的 "inter-"、所有格 "dogs'" 要把尾巴剥掉，
      // 否则入库的是半截词；词中间的连字符和撇号不动（well-known、don't）。
      word = word.replaceAll(RegExp(r"[-']+$"), '');
      // 手写页是用户主动书写，短词和功能词也保留；拍照取词仍按 ≥2 且滤停用词。
      if (word.length < (keepStopWords ? 1 : 2)) continue;
      final lc = word.toLowerCase();
      if (!keepStopWords) {
        if (_noiseWords.contains(lc)) continue;
        if (_stopWords.contains(lc)) continue;
      }
      if (!seen.add(lc)) continue;
      into.add(OcrCandidate(word, line));
    }
  }
}
