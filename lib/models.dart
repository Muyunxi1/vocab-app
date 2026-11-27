class Book {
  final String id;
  final String name;
  final String? description;
  final int wordCount;

  Book({required this.id, required this.name, this.description, required this.wordCount});
}

/// 由一组单词生成的阅读文章。
class Article {
  final String id;
  final String bookId;
  final String? title;

  /// 英文正文，段落之间用换行分隔。
  final String body;

  /// 本次要求的单词列表。
  final List<String> words;

  /// 生成时没能用上的词。
  final List<String> missing;
  final String? model;
  final String createdAt;

  Article({
    required this.id,
    required this.bookId,
    this.title,
    required this.body,
    required this.words,
    this.missing = const [],
    this.model,
    required this.createdAt,
  });

  /// 重点词也就是要求生成的全部词。
  int get keyWordCount => words.length;
}

/// 文章里的一句话，翻译和解析结果随读随存。
class ArticleSentence {
  final String articleId;
  final int idx;
  final String en;
  final String? zh;

  /// 解析结果，存 JSON 字符串；没解析过就是 null。
  final String? parseJson;

  ArticleSentence({
    required this.articleId,
    required this.idx,
    required this.en,
    this.zh,
    this.parseJson,
  });
}

class Word {
  final String id;
  final String spelling;
  final String? phonetic;
  final String? definition;

  /// 常用变形，一行一条，例如「复数 sets」「过去式 set」。
  final String? forms;
  final int failCount;
  final int fuzzyCount;

  /// 已掌握：不再进复习队列，遗忘次数照样留在排行榜里。
  final bool mastered;
  final DateTime? nextReviewAt;

  Word({
    required this.id,
    required this.spelling,
    this.phonetic,
    this.definition,
    this.forms,
    this.failCount = 0,
    this.fuzzyCount = 0,
    this.mastered = false,
    this.nextReviewAt,
  });
}

class RankItem {
  final String wordId;
  final String spelling;
  final String? definition;
  final int failCount;
  final int fuzzyCount;
  final DateTime? lastFailAt;

  RankItem({
    required this.wordId,
    required this.spelling,
    this.definition,
    required this.failCount,
    required this.fuzzyCount,
    this.lastFailAt,
  });
}

class Overview {
  final int totalWords;
  final int todayReviews;
  final int totalFailCount;

  /// 今天到期、该复习的词数
  final int dueCount;

  Overview({
    required this.totalWords,
    required this.todayReviews,
    required this.totalFailCount,
    this.dueCount = 0,
  });
}

/// 「导入误加遗忘次数」的预览结果：命中多少、前几个示例词，
/// 以及重复导入过（last_fail_at 被刷新过）因而这次不处理的疑似数量。
class DirtyFailCounts {  final int count;
  final List<String> samples;
  final int repeatSuspects;

  DirtyFailCounts({
    required this.count,
    required this.samples,
    required this.repeatSuspects,
  });
}

/// 清理清单里的一条词：id 用于回传，spelling 和次数给用户核对。
class DirtyWordItem {
  final String id;
  final String spelling;
  final int failCount;

  DirtyWordItem({
    required this.id,
    required this.spelling,
    required this.failCount,
  });
}

/// 某一天的学习量，用于趋势图。
class DayStat {  final DateTime day;
  final int added;
  final int reviewed;
  final int failed;

  DayStat({
    required this.day,
    required this.added,
    required this.reviewed,
    required this.failed,
  });
}

/// 恢复备份的结果。
class BackupResult {
  final int books;
  final int words;
  final int skippedWords;
  final int reviews;
  // v8 起备份含文章与分句，这两项是新增的恢复计数；老调用点不传按 0 处理。
  final int articles;
  final int sentences;

  /// 备份里类型不认识、或一个已知列都没有而跳过的行数。恢复完成后提示用户，
  /// 让「少恢复了几条」是可见的，而不是安静地丢掉。
  final int badRows;

  BackupResult({
    required this.books,
    required this.words,
    required this.skippedWords,
    required this.reviews,
    this.articles = 0,
    this.sentences = 0,
    this.badRows = 0,
  });
}

class ImportResult {
  final int added;
  final int skipped;
  final List<String> failed;

  /// 这些词本来就在目标词库里，本次只是补了缺失字段，没有新增记录。
  /// 与 added 分开统计，避免把「重复导入」说成「新增了 N 个」。
  final int existed;

  /// 因为超出单次导入上限而整批没处理的词数。
  /// 单独统计，不再混进 skipped（skipped 只表示格式不合格被跳过）。
  final int truncated;

  /// 被未闭合引号吞掉的物理行数。这些行不参与切词，否则会切出一个假单词、
  /// 用户只看到「新增 1」，完全不知道后面几十行没了。
  final int broken;

  /// 本次实际读到的物理行数（只对文件导入有意义）。
  ///
  /// 「我导了上千词，词库只多了 500 个」这种反馈，靠计数分不开是文件本身只写了
  /// 500 行、还是被上限截断、还是后面的行没被识别成词。把行数摆到结果里，
  /// 用户和检验方都能当场对上。
  final int rows;

  /// 本地词典命中、补上音标/释义/变形的条数（仅开启自动查词时有意义）。
  final int dictHits;

  /// 本地词典没查到的词（未带手填释义、自动查词时收集），供提示手动补。
  final List<String> unfoundWords;

  ImportResult({
    required this.added,
    required this.skipped,
    required this.failed,
    this.existed = 0,
    this.truncated = 0,
    this.broken = 0,
    this.rows = 0,
    this.dictHits = 0,
    this.unfoundWords = const [],
  });

  /// 面向用户的一行结果文案，各类计数各有名字。
  String get summary {
    final parts = <String>[];
    if (rows > 0) parts.add('读到 $rows 行');
    parts.add('新增 $added');
    if (existed > 0) parts.add('已在词库 $existed');
    if (skipped > 0) parts.add('格式不合格 $skipped');
    if (truncated > 0) parts.add('超出上限未处理 $truncated');
    if (broken > 0) parts.add('引号未闭合跳过 $broken 行');
    if (dictHits > 0) parts.add('已配释义 $dictHits');
    if (unfoundWords.isNotEmpty) parts.add('未查到 ${unfoundWords.length}');
    if (failed.isNotEmpty) parts.add('失败 ${failed.length}');
    return parts.join('，');
  }
}

class LookupResult {
  final String spelling;
  final bool found;
  final String? phonetic;
  final String? definition;
  final String? forms;

  /// 这个拼写是某个原形的变形时，这里给出还原出的原形。
  /// 只有原形确实在词典里命中才会填写，否则为 null。
  final String? lemma;

  LookupResult({
    required this.spelling,
    required this.found,
    this.phonetic,
    this.definition,
    this.forms,
    this.lemma,
  });
}
