import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:enough_convert/gbk.dart';
import 'package:flutter/foundation.dart' show compute, debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'csv_stream.dart';
import 'diag.dart';
import 'models.dart';
import 'secrets.dart';
import 'wordbook.dart';
import 'wordform.dart';

class ApiException implements Exception {
  final String message;

  const ApiException(this.message);

  @override
  String toString() => message;
}

/// 纯本地数据层：不连服务器，所有数据存在手机自己的 SQLite 里。
class Api {
  Api._();

  static final Api instance = Api._();

  /// assets/dict.db 的字节数，用来判断本地副本有没有写坏。
  /// 换词库后同步改这里；对不上只会重写一次副本，不会出错。
  static const int _dictBytes = 8056832;

  /// 批量粘贴一次最多处理的词数。
  ///
  /// 原来是 500，用户粘一份上千词的词表时后面几千个被静默截断，只在结果里写
  /// 「超出上限未处理 N」，很难注意到。文件导入的额度是 20000 行，粘贴没理由更小，
  /// 这里按同一个数量级给到 5000；再多就让用户走文件导入，那条路是流式读的。
  static const int maxBatchWords = 5000;

  /// 批量粘贴时每处理多少个词回调一次进度。
  static const int batchProgressStep = 200;

  /// 文件导入一次最多处理的行数。
  static const int maxImportRows = 20000;

  /// 单个导入文件的上限。读取是流式的，内存占用与文件大小无关，
  /// 这个值只是防呆：200MB 的纯词表已经是几十万词，真遇到大概率是选错了文件。
  static const int maxImportBytes = 200 * 1024 * 1024;

  /// 单个备份文件的上限。
  ///
  /// 恢复是把整份 json 解成一个字符串、再解成对象树，内存大约是文件的两到三倍。
  /// 没有上限时，选错一个大文件就是一次 OOM 闪退，用户还会以为「备份坏了」。
  static const int maxBackupBytes = 80 * 1024 * 1024;

  Database? _db;
  Database? _dict;
  bool _ready = false;

  /// 初始化过程本身。多个页面会同时调 load()（主页就是 books() 和 overview() 并发），
  /// 用同一个 Future 兜住，避免把 6.5MB 词典复制两遍、二次 ATTACH 词典库。
  Future<void>? _loading;

  Future<void> load() async {
    if (_ready) return;
    final pending = _loading;
    if (pending != null) {
      await pending;
      return;
    }
    final future = _open();
    _loading = future;
    try {
      await future;
      _ready = true;
    } finally {
      // 失败也不留死值，下次启动或重试还能再来一次
      _loading = null;
    }
  }

  Future<void> _open() async {
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'vocab_offline.db');

    _db = await openDatabase(
      dbPath,
      version: 7,
      onCreate: (db, version) async => _createSchema(db),
      onUpgrade: (db, oldVersion, newVersion) async {
        // 旧库补索引，新库在 onCreate 里已建好
        if (oldVersion < 2) {
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_words_fail ON words(fail_count)');
        }
        if (oldVersion < 3) {
          // 3：加「常用变形」列 + 词典版本记录表
          await db.execute('ALTER TABLE words ADD COLUMN forms TEXT');
          await db.execute(
            'CREATE TABLE IF NOT EXISTS app_meta(key TEXT PRIMARY KEY, value TEXT)',
          );
        }
        if (oldVersion < 4) {
          // 4：已掌握标记 + 下次复习时间
          await db.execute(
              'ALTER TABLE words ADD COLUMN mastered INTEGER NOT NULL DEFAULT 0');
          await db.execute('ALTER TABLE words ADD COLUMN next_review_at TEXT');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_bw_book_created ON book_words(book_id, created_at)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_words_due ON words(mastered, next_review_at)',
          );
        }
        if (oldVersion < 5) {
          // 5：生成的文章 + 按句拆开的正文
          await _createArticleSchema(db);
        }
        if (oldVersion < 6) {
          // 6：复习状态从 words 搬到 book_words。
          // 原来 mastered / fail_count / next_review_at 挂在全局词条表上（words 的
          // spelling_lc 唯一），同一个词加进两个词库时，在 A 库标「已掌握」，B 库也
          // 跟着变成已掌握，遗忘次数也串在一起。改成按 (book_id, word_id) 存。
          for (final sql in const [
            'ALTER TABLE book_words ADD COLUMN mastered INTEGER NOT NULL DEFAULT 0',
            'ALTER TABLE book_words ADD COLUMN fail_count INTEGER NOT NULL DEFAULT 0',
            'ALTER TABLE book_words ADD COLUMN fuzzy_count INTEGER NOT NULL DEFAULT 0',
            'ALTER TABLE book_words ADD COLUMN ok_count INTEGER NOT NULL DEFAULT 0',
            'ALTER TABLE book_words ADD COLUMN last_reviewed_at TEXT',
            'ALTER TABLE book_words ADD COLUMN last_fail_at TEXT',
            'ALTER TABLE book_words ADD COLUMN next_review_at TEXT',
          ]) {
            try {
              await db.execute(sql);
            } catch (e) {
              // 列已存在（装过中途版本）就跳过，不影响下面把数据搬过去
              debugPrint('[migrate] 加列跳过：$e');
            }
          }
          // 老库的状态一次性复制到每条关联上。原表列留着不动，万一要回滚还有底。
          await db.execute(
            'UPDATE book_words SET '
            'mastered = (SELECT w.mastered FROM words w WHERE w.id = book_words.word_id), '
            'fail_count = (SELECT w.fail_count FROM words w WHERE w.id = book_words.word_id), '
            'fuzzy_count = (SELECT w.fuzzy_count FROM words w WHERE w.id = book_words.word_id), '
            'ok_count = (SELECT w.ok_count FROM words w WHERE w.id = book_words.word_id), '
            'last_reviewed_at = (SELECT w.last_reviewed_at FROM words w WHERE w.id = book_words.word_id), '
            'last_fail_at = (SELECT w.last_fail_at FROM words w WHERE w.id = book_words.word_id), '
            'next_review_at = (SELECT w.next_review_at FROM words w WHERE w.id = book_words.word_id)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_bw_book_due '
            'ON book_words(book_id, mastered, next_review_at)',
          );
        }
        if (oldVersion < 7) {
          // 7：记一下「遗忘次数被人手动改过」。原版「已存在词」分支重复导入会把
          // fail_count 累加，那种脏数据没有任何痕迹能和手动调整区分；从这版起
          // 手动改过的词打个标记，之后的清理入口就能把它排除掉。
          // 老数据全按 0 处理——历史的手动改动无法回溯识别，只能靠清理前的清单核对。
          try {
            await db.execute(
              'ALTER TABLE book_words ADD COLUMN manual_adjust INTEGER NOT NULL DEFAULT 0',
            );
          } catch (e) {
            // 列已存在就跳过
            debugPrint('[migrate] 加列跳过：$e');
          }
        }
      },
    );

    // 索引统一在这里保底建一遍。迁移里虽然也建了，但如果某个库已经停在 v4
    // 却漏了索引（比如装过中途版本），版本号相同就不会再走迁移，排序会变慢。
    await _db!.execute(
      'CREATE INDEX IF NOT EXISTS idx_bw_book_created ON book_words(book_id, created_at)',
    );
    await _db!.execute(
      'CREATE INDEX IF NOT EXISTS idx_words_due ON words(mastered, next_review_at)',
    );
    await _db!.execute(
      'CREATE INDEX IF NOT EXISTS idx_bw_book_due '
      'ON book_words(book_id, mastered, next_review_at)',
    );

    await _ensureDict(dir);
    _dict = await openDatabase(p.join(dir, 'dict.db'), readOnly: true);
    // 词典刷新失败不该让整个 App 起不来，下次启动会再试一次
    try {
      await _syncDict(p.join(dir, 'dict.db'));
    } catch (e) {
      // 忽略：旧的释义和变形照样能用。但记一条日志，词典 ATTACH 失败是有价值的现场信息
      debugPrint('[dict] 同步词条失败：$e');
    }
  }

  Future<void> _createSchema(Database db) async {
    await db.execute(
      'CREATE TABLE books('
      'id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT, created_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE words('
      'id TEXT PRIMARY KEY, spelling TEXT NOT NULL, spelling_lc TEXT NOT NULL UNIQUE, '
      'phonetic TEXT, definition TEXT, forms TEXT, example TEXT, source TEXT, '
      'is_edited INTEGER NOT NULL DEFAULT 0, '
      'fail_count INTEGER NOT NULL DEFAULT 0, fuzzy_count INTEGER NOT NULL DEFAULT 0, '
      'ok_count INTEGER NOT NULL DEFAULT 0, mastered INTEGER NOT NULL DEFAULT 0, '
      'last_reviewed_at TEXT, last_fail_at TEXT, next_review_at TEXT, created_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE app_meta(key TEXT PRIMARY KEY, value TEXT)',
    );
    await db.execute(
      'CREATE TABLE book_words('
      'book_id TEXT NOT NULL, word_id TEXT NOT NULL, created_at TEXT NOT NULL, '
      'mastered INTEGER NOT NULL DEFAULT 0, '
      'fail_count INTEGER NOT NULL DEFAULT 0, fuzzy_count INTEGER NOT NULL DEFAULT 0, '
      'ok_count INTEGER NOT NULL DEFAULT 0, '
      'last_reviewed_at TEXT, last_fail_at TEXT, next_review_at TEXT, '
      'manual_adjust INTEGER NOT NULL DEFAULT 0, '
      'PRIMARY KEY(book_id, word_id))',
    );
    await db.execute(
      'CREATE TABLE reviews('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, word_id TEXT NOT NULL, book_id TEXT, '
      'result INTEGER NOT NULL, reviewed_at TEXT NOT NULL)',
    );
    await db.execute('CREATE INDEX idx_bw_book ON book_words(book_id)');
    await db.execute(
        'CREATE INDEX idx_bw_book_created ON book_words(book_id, created_at)');
    await db.execute(
      'CREATE INDEX idx_bw_book_due ON book_words(book_id, mastered, next_review_at)',
    );
    await db.execute(
        'CREATE INDEX idx_words_due ON words(mastered, next_review_at)');
    await db.execute('CREATE INDEX idx_reviews_at ON reviews(reviewed_at)');
    await db.execute('CREATE INDEX idx_words_fail ON words(fail_count)');
    await _createArticleSchema(db);
  }

  /// 文章相关的两张表。新库在 onCreate 建，老库在 onUpgrade 升到 v5 时建，
  /// 两处共用这一个定义，避免两边写岔。
  Future<void> _createArticleSchema(Database db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS articles('
      'id TEXT PRIMARY KEY, book_id TEXT NOT NULL, title TEXT, body TEXT NOT NULL, '
      'words TEXT NOT NULL, missing TEXT, model TEXT, created_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS article_sentences('
      'article_id TEXT NOT NULL, idx INTEGER NOT NULL, en TEXT NOT NULL, '
      'zh TEXT, parse_json TEXT, PRIMARY KEY(article_id, idx))',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_articles_book ON articles(book_id, created_at)',
    );
  }

  /// 把内置词典复制成可读副本。
  /// 文件大小对不上就当作上次没写完，删掉重来；写入走临时文件再改名，
  /// 避免中途断电留下一个半截文件导致每次启动都打不开数据库。
  Future<void> _ensureDict(String dir) async {
    final dictPath = p.join(dir, 'dict.db');
    final target = File(dictPath);
    if (await target.exists()) {
      if (await target.length() == _dictBytes) return;
      await target.delete();
    }
    final tmp = File('$dictPath.tmp');
    if (await tmp.exists()) await tmp.delete();
    final data = await rootBundle.load('assets/dict.db');
    await tmp.writeAsBytes(data.buffer.asUint8List(), flush: true);
    await tmp.rename(dictPath);
  }

  /// 词典数据版本。改了词库内容（重新生成 dict.db）就把这个字符串一起改。
  /// 只有版本不一致才做一次刷新，不会每次启动都跑。
  static const String _dictStamp = '2026-11-dict6';

  /// 用内置词典刷新「没被手改过」的词条：释义按词性分行、补上常用变形。
  /// 手改过的（is_edited = 1）一律不动，避免覆盖用户自己的整理。
  Future<void> _syncDict(String dictPath) async {
    final rows = await _d
        .rawQuery("SELECT value FROM app_meta WHERE key = 'dict_stamp'");
    if (rows.isNotEmpty && rows.first['value'] == _dictStamp) return;

    final escaped = dictPath.replaceAll("'", "''");
    await _d.execute("ATTACH DATABASE '$escaped' AS dz");
    try {
      await _d.rawUpdate(
        'UPDATE words SET '
        'definition = IFNULL((SELECT d.translation FROM dz.dict d WHERE d.word = words.spelling_lc), definition), '
        'forms = IFNULL((SELECT d.forms FROM dz.dict d WHERE d.word = words.spelling_lc), forms) '
        'WHERE is_edited = 0 '
        'AND EXISTS (SELECT 1 FROM dz.dict d WHERE d.word = words.spelling_lc)',
      );
    } finally {
      await _d.execute('DETACH DATABASE dz');
    }
    await _d.insert(
      'app_meta',
      {'key': 'dict_stamp', 'value': _dictStamp},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Database get _d {
    final db = _db;
    if (db == null) throw const ApiException('本地数据库还没准备好');
    return db;
  }

  String _newId(String prefix) {
    final rand = Random().nextInt(0x7fffffff).toRadixString(16);
    return '$prefix${DateTime.now().microsecondsSinceEpoch}$rand';
  }

  String _now() => DateTime.now().toIso8601String();

  // ---------------- 词库 ----------------

  Future<List<Book>> books() async {
    await load();
    final rows = await _d.rawQuery(
      'SELECT b.id, b.name, b.description, '
      '(SELECT COUNT(*) FROM book_words bw WHERE bw.book_id = b.id) AS word_count '
      'FROM books b ORDER BY b.created_at DESC',
    );
    return rows.map(_bookFromMap).toList();
  }

  Book _bookFromMap(Map<String, Object?> m) => Book(
        id: m['id'] as String,
        name: m['name'] as String? ?? '',
        description: m['description'] as String?,
        wordCount: (m['word_count'] as int?) ?? 0,
      );

  Future<Book> createBook(String name, {String? description}) async {
    await load();
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const ApiException('词库名不能为空');
    final book = Book(
        id: _newId('b'), name: trimmed, description: description, wordCount: 0);
    await _d.insert('books', {
      'id': book.id,
      'name': book.name,
      'description': description,
      'created_at': _now(),
    });
    return book;
  }

  Future<void> deleteBook(String bookId) async {
    await load();
    await _d.transaction((txn) async {
      // 复习记录和文章都带 book_id，删库时一并清掉：留着会让今日复习数和
      // 近七天曲线把已删除的库算进去，文章也会变成打不开的孤儿数据。
      await txn.rawDelete(
        'DELETE FROM article_sentences WHERE article_id IN '
        '(SELECT id FROM articles WHERE book_id = ?)',
        [bookId],
      );
      await txn.delete('articles', where: 'book_id = ?', whereArgs: [bookId]);
      await txn.delete('reviews', where: 'book_id = ?', whereArgs: [bookId]);
      await txn.delete('book_words', where: 'book_id = ?', whereArgs: [bookId]);
      await txn.delete('books', where: 'id = ?', whereArgs: [bookId]);
      // 不在任何词库里的孤立词条一并清掉
      await txn.rawDelete(
          'DELETE FROM words WHERE id NOT IN (SELECT word_id FROM book_words)');
    });
  }

  // ---------------- 单词 ----------------

  /// 拼 LIKE 用的模式串：引号会破坏 SQL 字面量，反斜杠是 ESCAPE 字符，
  /// % 和 _ 是 LIKE 的通配符，这四类都要转义。
  String _likePattern(String keyword) => keyword
      .replaceAll(r'\', r'\\')
      .replaceAll("'", "''")
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// 复习状态（mastered、各类计数、复习时间）存在 book_words 上，按词库各算各的。
  /// 列表类查询统一用这段列清单：词条字段从 words 取，状态从 bw 取，避免两边同名打架。
  static const String _wordColumns =
      'w.id, w.spelling, w.spelling_lc, w.phonetic, w.definition, w.forms, '
      'w.example, w.source, w.is_edited, w.created_at, '
      'bw.mastered, bw.fail_count, bw.fuzzy_count, bw.ok_count, '
      'bw.last_reviewed_at, bw.last_fail_at, bw.next_review_at';

  /// 取词库里的词。limit <= 0 表示不分页、全取。
  /// [filters] 为空表示不筛；多个条件之间是 AND：
  /// fail（遗忘过）、mastered（已掌握）、unmastered（未掌握）、
  /// noDef（暂无释义）、forms（有变形记录）。
  Future<List<Word>> words(String bookId,
      {String? q,
      String sort = 'created',
      int limit = 0,
      int offset = 0,
      Set<String> filters = const {}}) async {
    await load();
    final orderBy = switch (sort) {
      'fail' => 'bw.fail_count DESC, bw.last_fail_at DESC',
      'alpha' => 'w.spelling_lc ASC',
      _ => 'bw.created_at DESC',
    };
    final keyword = (q ?? '').trim().toLowerCase();
    final escaped = _likePattern(keyword);
    final whereLike = keyword.isEmpty
        ? ''
        : " AND (w.spelling_lc LIKE '%$escaped%' ESCAPE '\\' OR IFNULL(w.definition, '') LIKE '%$escaped%' ESCAPE '\\')";
    final whereFilter = _filterSql(filters);
    final paged = limit > 0 ? ' LIMIT $limit OFFSET $offset' : '';
    final rows = await _d.rawQuery(
      'SELECT $_wordColumns FROM book_words bw JOIN words w ON w.id = bw.word_id '
      'WHERE bw.book_id = ?$whereLike$whereFilter ORDER BY $orderBy$paged',
      [bookId],
    );
    return rows.map(_wordFromMap).toList();
  }

  /// 把筛选条件翻成 SQL 片段。条件都来自代码里的固定字符串，不接用户输入。
  String _filterSql(Set<String> filters) {
    final parts = <String>[];
    if (filters.contains('fail')) parts.add('bw.fail_count > 0');
    if (filters.contains('mastered')) parts.add('bw.mastered = 1');
    if (filters.contains('unmastered')) parts.add('bw.mastered = 0');
    if (filters.contains('noDef')) {
      parts.add("TRIM(IFNULL(w.definition, '')) = ''");
    }
    if (filters.contains('forms')) parts.add("TRIM(IFNULL(w.forms, '')) <> ''");
    if (parts.isEmpty) return '';
    return ' AND ${parts.join(' AND ')}';
  }

  /// 只数个数，不把每个词的释义都读出来。
  Future<int> countWords(String bookId, {String? q}) async {
    await load();
    final keyword = (q ?? '').trim().toLowerCase();
    if (keyword.isEmpty) {
      final rows = await _d.rawQuery(
        'SELECT COUNT(*) AS c FROM book_words WHERE book_id = ?',
        [bookId],
      );
      return (rows.first['c'] as int?) ?? 0;
    }
    final escaped = _likePattern(keyword);
    final rows = await _d.rawQuery(
      'SELECT COUNT(*) AS c FROM book_words bw JOIN words w ON w.id = bw.word_id '
      "WHERE bw.book_id = ? AND (w.spelling_lc LIKE '%$escaped%' ESCAPE '\\' OR IFNULL(w.definition, '') LIKE '%$escaped%' ESCAPE '\\')",
      [bookId],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  Word _wordFromMap(Map<String, Object?> m) => Word(
        id: m['id'] as String,
        spelling: m['spelling'] as String? ?? '',
        phonetic: m['phonetic'] as String?,
        definition: m['definition'] as String?,
        forms: m['forms'] as String?,
        failCount: (m['fail_count'] as int?) ?? 0,
        fuzzyCount: (m['fuzzy_count'] as int?) ?? 0,
        mastered: ((m['mastered'] as int?) ?? 0) != 0,
        nextReviewAt: m['next_review_at'] == null
            ? null
            : DateTime.tryParse(m['next_review_at'] as String),
      );

  /// 添加单词。
  ///
  /// [forms] 是调用方已经查到的常用变形；不传时按 [autoLookup] 去词典里补。
  ///
  /// [countAsFail] 只在「人手动加词」时传 true，表示这次添加算一次忘记：
  /// 主页和添加单词页手动输入既算，导入 / 翻译批量带入不算，否则又会把导入
  /// 误加的次数灌回来。手动累加的次数会打 manual_adjust 标记，避免被清理入口误清。
  Future<Word> addWord(String bookId, String spelling,
      {String? definition,
      String? phonetic,
      String? forms,
      bool autoLookup = true,
      bool countAsFail = false}) async {
    await load();
    final typed = spelling.trim();
    if (typed.isEmpty) throw const ApiException('单词不能为空');
    if (typed.length > 50) throw const ApiException('单词太长，最多 50 个字符');
    final key = typed.toLowerCase();

    final existing = await _d.query('words',
        where: 'spelling_lc = ?', whereArgs: [key], limit: 1);

    if (existing.isNotEmpty) {
      final cur = existing.first;
      final wordId = cur['id'] as String;
      // 次数只在调用方明确要求时累加（手动加词传 countAsFail: true）；
      // 导入 / 翻译带入的不等于忘记，累加会让排行榜和复习排序失真。
      final patch = <String, Object?>{};

      // 老词有缺的字段就这次一起补上：手填的优先，其次查词典，已有内容不动
      final defIn = (definition ?? '').trim();
      final phIn = (phonetic ?? '').trim();
      final fmIn = (forms ?? '').trim();
      final oldDef = ((cur['definition'] as String?) ?? '').trim();
      final oldPh = ((cur['phonetic'] as String?) ?? '').trim();
      final oldFm = ((cur['forms'] as String?) ?? '').trim();
      final wasEdited = ((cur['is_edited'] as int?) ?? 0) == 1;

      var fillDef = defIn;
      var fillPh = phIn;
      var fillFm = fmIn;
      if (autoLookup && (fillDef.isEmpty || fillPh.isEmpty || fillFm.isEmpty)) {
        final hit = await lookup(typed);
        if (fillDef.isEmpty) fillDef = (hit.definition ?? '').trim();
        if (fillPh.isEmpty) fillPh = (hit.phonetic ?? '').trim();
        if (fillFm.isEmpty) fillFm = (hit.forms ?? '').trim();
      }
      if (oldDef.isEmpty && fillDef.isNotEmpty) {
        patch['definition'] = fillDef;
        if (defIn.isNotEmpty && !wasEdited) patch['is_edited'] = 1;
      }
      if (oldPh.isEmpty && fillPh.isNotEmpty) patch['phonetic'] = fillPh;
      if (oldFm.isEmpty && fillFm.isNotEmpty) patch['forms'] = fillFm;

      await _d.transaction((txn) async {
        if (patch.isNotEmpty) {
          await txn
              .update('words', patch, where: 'id = ?', whereArgs: [wordId]);
        }
        await _link(txn, bookId, wordId);
        if (countAsFail) {
          // 手动加词算一次忘记，只累加当前词库这条关联；打 manual_adjust
          // 标记，免得被「清理重复导入」的判据当成导入脏数据清掉。
          await txn.rawUpdate(
            'UPDATE book_words SET fail_count = fail_count + 1, '
            'last_fail_at = ?, manual_adjust = 1 '
            'WHERE book_id = ? AND word_id = ?',
            [_now(), bookId, wordId],
          );
        }
      });

      // 复习状态现在挂在 book_words 上，words 表里那几列是迁移前的旧值，
      // 直接拿 cur 拼结果会把「已掌握」这类状态读错，所以回读一次。
      final reread = await _d.rawQuery(
        'SELECT $_wordColumns FROM book_words bw JOIN words w ON w.id = bw.word_id '
        'WHERE bw.book_id = ? AND bw.word_id = ?',
        [bookId, wordId],
      );
      if (reread.isNotEmpty) return _wordFromMap(reread.first);
      final updated = Map<String, Object?>.from(cur);
      updated.addAll(patch);
      return _wordFromMap(updated);
    }

    var ph = (phonetic ?? '').trim();
    var def = (definition ?? '').trim();
    var fm = (forms ?? '').trim();
    var fromDict = false;
    // 本地词典是点查，开销很小：缺哪个字段就补哪个，手填的内容一律不覆盖
    if (autoLookup) {
      final hit = await lookup(typed);
      if (hit.found) {
        fromDict = def.isEmpty;
        if (ph.isEmpty) ph = (hit.phonetic ?? '').trim();
        if (def.isEmpty) def = (hit.definition ?? '').trim();
        if (fm.isEmpty) fm = (hit.forms ?? '').trim();
      }
    }
    final id = _newId('w');
    final now = _now();
    try {
      await _d.transaction((txn) async {
        await txn.insert('words', {
          'id': id,
          'spelling': typed,
          'spelling_lc': key,
          'phonetic': ph.isEmpty ? null : ph,
          'definition': def.isEmpty ? null : def,
          'forms': fm.isEmpty ? null : fm,
          'source': fromDict ? 'dict' : 'manual',
          // 带了人给的释义（手填、CSV 导入、批量带入）才算「整理过」，词典同步时
          // 不再覆盖。词典自动查出来的释义不能标 1，否则以后换了更好的词典也刷不动，
          // 用户看到的永远是第一次自动查到的那条。
          'is_edited': (def.isEmpty || fromDict) ? 0 : 1,
          'fail_count': countAsFail ? 1 : 0,
          'fuzzy_count': 0,
          'ok_count': 0,
          'last_fail_at': null,
          'created_at': now,
        });
        await _link(txn, bookId, id);
        if (countAsFail) {
          await txn.rawUpdate(
            'UPDATE book_words SET fail_count = 1, last_fail_at = ?, manual_adjust = 1 '
            'WHERE book_id = ? AND word_id = ?',
            [now, bookId, id],
          );
        }
      });
    } on DatabaseException catch (e) {
      // 先查后插之间有窗口：另一个入口同时加同一个新词时会撞 UNIQUE(spelling_lc)。
      // 这不是用户的错，把库里已经存在的那条接上即可。
      if (!e.isUniqueConstraintError()) rethrow;
      return addWord(bookId, spelling,
          definition: definition,
          phonetic: phonetic,
          forms: forms,
          autoLookup: autoLookup,
          countAsFail: countAsFail);
    }

    return Word(
      id: id,
      spelling: typed,
      phonetic: ph.isEmpty ? null : ph,
      definition: def.isEmpty ? null : def,
      forms: fm.isEmpty ? null : fm,
      failCount: countAsFail ? 1 : 0,
    );
  }

  /// 把词挂到词库上，已经挂过就跳过。
  Future<void> _link(
      DatabaseExecutor exec, String bookId, String wordId) async {
    final exists = await exec.query(
      'book_words',
      where: 'book_id = ? AND word_id = ?',
      whereArgs: [bookId, wordId],
      limit: 1,
    );
    if (exists.isEmpty) {
      await exec.insert('book_words', {
        'book_id': bookId,
        'word_id': wordId,
        'created_at': _now(),
      });
    }
  }

  /// 手动调整某个词的忘记次数（负数按 0 处理）。
  Future<Word> setFailCount(String bookId, String wordId, int count) async {
    await load();
    final safe = count < 0 ? 0 : count;
    // 遗忘次数按词库各算各的，读写的都是当前词库这条关联
    final rows = await _d.query(
      'book_words',
      where: 'book_id = ? AND word_id = ?',
      whereArgs: [bookId, wordId],
      limit: 1,
    );
    if (rows.isEmpty) throw const ApiException('这个单词不在当前词库里');
    final cur = rows.first;
    // manual_adjust 打上标记：这条次数是人手动改的，不是导入累加的，
    // 之后的清理入口靠它把这种词排除掉，别跟着脏数据一起被清。
    final values = <String, Object?>{'fail_count': safe, 'manual_adjust': 1};
    // 排行要看最近一次忘记时间，原来是 0 次就没有时间，补一个当前时间免得永远排在最后
    if (safe > 0 && cur['last_fail_at'] == null) {
      values['last_fail_at'] = _now();
    }
    await _d.update(
      'book_words',
      values,
      where: 'book_id = ? AND word_id = ?',
      whereArgs: [bookId, wordId],
    );
    final wordRows = await _d.rawQuery(
      'SELECT $_wordColumns FROM book_words bw JOIN words w ON w.id = bw.word_id '
      'WHERE bw.book_id = ? AND bw.word_id = ?',
      [bookId, wordId],
    );
    if (wordRows.isEmpty) throw const ApiException('这个单词不在当前词库里');
    return _wordFromMap(wordRows.first);
  }

  /// 空格、换行、逗号、顿号这类都当分隔符；撇号和连字符留在词里（don't、well-known）。
  static final RegExp _batchSeparator =
      RegExp(r"""[\s\u3000,;，；、。！!？?：:|/\\()（）\[\]【】“”‘’"]+""");

  /// [definitions] 是调用方已经查到的释义（键为小写词形）。已经带释义的词不再查词典，
  /// 否则翻译页先 lookupMany 一遍、batchAdd 又逐词查一遍，同一批词被查两次。
  Future<ImportResult> batchAdd(
    String bookId,
    String text, {
    bool autoLookup = false,
    Map<String, String>? definitions,
    void Function(int done, int total)? onProgress,
  }) async {
    await load();
    final items = text
        .split(_batchSeparator)
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (items.isEmpty) throw const ApiException('没有可添加的单词');

    var added = 0;
    var skipped = 0;
    var existed = 0;
    var truncated = 0;
    var dictHits = 0;
    final unfoundWords = <String>[];
    final failed = <String>[];

    // 自动查词时批量预查一次本地词典，用来回报「配上释义 / 没查到」各多少；
    // addWord 内部仍会按字段缺啥补啥，这里只做统计，不改变入库内容。
    final dict = autoLookup ? await lookupMany(items) : const <String, LookupResult>{};

    // 目标词库里已有的词，用来区分「新增」与「本来就有」
    final before = <String>{};
    final known = await _d.rawQuery(
      'SELECT w.spelling_lc AS k FROM words w '
      'JOIN book_words bw ON bw.word_id = w.id WHERE bw.book_id = ?',
      [bookId],
    );
    for (final row in known) {
      final k = row['k'];
      if (k is String && k.isNotEmpty) before.add(k);
    }

    for (var i = 0; i < items.length; i++) {
      // 上千词的粘贴要跑几十秒，按固定步长回报进度，否则界面只有一个转圈，
      // 用户分不清是在干活还是死了。
      if (onProgress != null && i > 0 && i % batchProgressStep == 0) {
        onProgress(i, items.length);
      }
      // 到上限就停，剩下的单独计为「未处理」，不与格式跳过混在一起
      if (added + existed + skipped >= maxBatchWords) {
        truncated += items.length - i;
        break;
      }
      final item = items[i];
      // 一个词太长多半是粘错内容，跳过
      if (item.length > 50) {
        skipped++;
        continue;
      }
      final key = item.toLowerCase();
      try {
        final known0 = definitions?[key];
        final hasDef = known0 != null && known0.trim().isNotEmpty;
        await addWord(
          bookId,
          item,
          definition: hasDef ? known0 : null,
          autoLookup: !hasDef && autoLookup,
        );
        // 只有自动查词且没带手填释义时才统计词典命中；手填释义的词不算未查到。
        if (autoLookup && !hasDef) {
          final hit = dict[key];
          if (hit != null && hit.found) {
            dictHits++;
          } else {
            unfoundWords.add(item);
          }
        }
        if (before.contains(key)) {
          existed++;
        } else {
          added++;
          before.add(key);
        }
      } catch (e) {
        failed.add('$item：$e');
      }
    }
    // 收尾再报一次：最后不足一个步长的尾巴也要让进度停在终值
    if (onProgress != null) onProgress(items.length - truncated, items.length);
    return ImportResult(
      added: added,
      skipped: skipped,
      failed: failed,
      existed: existed,
      truncated: truncated,
      dictHits: dictHits,
      unfoundWords: unfoundWords,
    );
  }

  /// 词书导入的统一入口：按扩展名分派到 CSV/TSV/TXT 或 Word（.docx）。
  Future<ImportResult> importFile(String bookId, String filePath,
      {bool autoLookup = false, void Function(int rows)? onRows}) async {
    final lower = filePath.toLowerCase();
    if (lower.endsWith('.docx')) {
      return importDocx(bookId, filePath,
          autoLookup: autoLookup, onRows: onRows);
    }
    if (lower.endsWith('.doc')) {
      throw const ApiException('老式 .doc 读不了，请在 Word 里另存为 .docx 再导入');
    }
    return importCsv(bookId, filePath, autoLookup: autoLookup, onRows: onRows);
  }

  /// 文本词表导入：逗号或 Tab 分隔，第一列单词、第二列释义（可选），带引号的字段能正确处理。
  /// 逐块流式读，不把整份文件读进内存，上万的词书也能吃下。
  Future<ImportResult> importCsv(String bookId, String filePath,
      {bool autoLookup = false, void Function(int rows)? onRows}) async {
    await load();
    final file = File(filePath);
    if (!await file.exists()) throw const ApiException('文件读不到');
    // 未闭合引号会把后面若干物理行吞成一条坏记录：不当普通行切词，只累计行数，
    // 最后如实告诉用户「有 N 行因为引号没闭合被跳过」。
    var broken = 0;
    return _importLines(
        bookId,
        CsvStreamReader.read(file,
            maxBytes: maxImportBytes,
            onBrokenRecord: (int lines) {
          broken += lines;
        }),
        autoLookup: autoLookup,
        loose: false,
        onRows: onRows,
        brokenRowsOf: () => broken);
  }

  /// Word 文档导入：正文抽成行（表格按行、段落按段），再按「英文部分 + 中文部分」切词。
  /// docx 是 zip+xml，解析放到后台 isolate，避免大文件把界面卡住。
  Future<ImportResult> importDocx(String bookId, String filePath,
      {bool autoLookup = false, void Function(int rows)? onRows}) async {
    await load();
    final file = File(filePath);
    if (!await file.exists()) throw const ApiException('文件读不到');
    // 先 stat 再读。docx 是压缩包，几十 MB 的包解压后能翻好几倍；
    // 不分大小直接 readAsBytes，等于先把内存占满再去解压，中端机会被系统杀掉。
    final size = await file.length();
    if (size > WordbookReader.maxBytes) {
      throw ApiException(
          '这个 Word 文档 ${size ~/ (1024 * 1024)}MB，超过导入上限 '
          '${WordbookReader.maxBytes ~/ (1024 * 1024)}MB。'
          '先把文档里的图片删掉，或另存为 TXT / CSV 再导入');
    }
    final bytes = await file.readAsBytes();
    final text = bytes.length < 256 * 1024
        ? WordbookReader.docxToText(bytes)
        : await compute(WordbookReader.docxToText, bytes);
    return _importLines(bookId, Stream.fromIterable(text.split('\n')),
        autoLookup: autoLookup, loose: true, onRows: onRows);
  }

  /// CSV 与 docx 共用的入库循环。
  ///
  /// [brokenRowsOf] 读的是「被未闭合引号吞掉的物理行数」计数：坏记录不参与切词，
  /// 只记账，最后由 [ImportResult.broken] 报给用户。
  Future<ImportResult> _importLines(String bookId, Stream<String> lines,
      {required bool autoLookup,
      required bool loose,
      void Function(int rows)? onRows,
      int Function()? brokenRowsOf}) async {
    var added = 0;
    var skipped = 0;
    var rows = 0;
    final failed = <String>[];
    var existed = 0;
    var truncated = 0;

    // 与 batchAdd 一致：先取目标词库已有词，区分「新增」与「本来就有」
    final before = <String>{};
    final known = await _d.rawQuery(
      'SELECT w.spelling_lc AS k FROM words w '
      'JOIN book_words bw ON bw.word_id = w.id WHERE bw.book_id = ?',
      [bookId],
    );
    for (final row in known) {
      final k = row['k'];
      if (k is String && k.isNotEmpty) before.add(k);
    }

    // 表头映射：自己导出的 CSV 第二列是音标，按列位置取释义会串列（导出的文件
    // 自己导不回来）。有表头就按列名找，没表头才退回「第一列词、第二列释义」，
    // 这样历史导出文件、手写的纯词表文件都还能按原来的用法导入。
    Map<String, int>? header = loose ? const <String, int>{} : null;
    // 读到过一行真表头：此后一律按列名取，不再按位置兜底
    var hasHeader = false;
    await for (final line in lines) {
      rows++;
      if (onRows != null && rows % 200 == 0) onRows(rows);
      // 到上限就停：剩下的行数照常数完，才能如实报「还有 N 行没处理」
      if (rows > maxImportRows) {
        truncated++;
        continue;
      }
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final List<String> plain;
      if (loose) {
        // Word 段落：`abandon /əˈbændən/ v. 放弃` 这类，按中英文切
        plain = WordbookReader.splitLoose(trimmed);
        if (plain.isEmpty) continue;
      } else if (trimmed.contains('\t') || trimmed.contains(',')) {
        final delimiter = trimmed.contains('\t') ? '\t' : ',';
        // _splitCsvLine 已经把 "" 还原成 "，也把字段外层的包裹引号去掉了。
        // 这里绝不能再 replaceAll('"','')：那会把释义里的合法引号（5" tall、
        // say "hi"）一起删掉，自己导出的文件回导就永久丢字符。
        plain = [
          for (final c in _splitCsvLine(trimmed, delimiter)) c.trim()
        ];
      } else {
        // 只有一列，或词和释义用空格隔开：也按中英文切，比把整行当单词强
        plain = WordbookReader.splitLoose(trimmed);
        if (plain.isEmpty) continue;
      }

      if (!loose && header == null) {
        final lower = [for (final c in plain) c.toLowerCase()];
        if (lower.contains('spelling') || lower.contains('word')) {
          header = <String, int>{};
          for (var i = 0; i < lower.length; i++) {
            // 同名列只认第一个，后面的忽略
            header.putIfAbsent(lower[i], () => i);
          }
          // 「word」和「spelling」是同一列的两个叫法
          if (!header.containsKey('spelling') && header.containsKey('word')) {
            header['spelling'] = header['word']!;
          }
          hasHeader = true;
          continue;
        }
        header = const <String, int>{};
      }

      /// 有表头时必须严格按列名取：列名对不上就返回空，不能退回「第二列就是释义」。
      /// 否则表头里没有 definition 的短行会把音标写成释义，还会被标成「已整理」，
      /// 词典以后再也刷不掉。没表头的老文件才允许按位置兜底。
      String col(String name, int fallback) {
        final i = header![name];
        if (i != null && i < plain.length) return plain[i];
        if (!hasHeader && fallback >= 0 && fallback < plain.length) {
          return plain[fallback];
        }
        return '';
      }

      final word = col('spelling', 0);
      if (word.isEmpty) continue;
      if (word.length > 50) {
        skipped++;
        continue;
      }

      final definition = col('definition', 1);
      // Word 里第三列是音标；CSV 只在表头写了 phonetic 时才取
      final phonetic = col('phonetic', loose ? 2 : -1);
      final forms = col('forms', -1);

      try {
        final w = await addWord(bookId, word,
            definition: definition.isEmpty ? null : definition,
            phonetic: phonetic.isEmpty ? null : phonetic,
            forms: forms.isEmpty ? null : forms,
            autoLookup: definition.isEmpty && autoLookup);
        final key2 = word.toLowerCase();
        if (before.contains(key2)) {
          existed++;
        } else {
          added++;
          before.add(key2);
          // 文件里带了自己导出的进度列（failCount/fuzzyCount/mastered）时，只在新词
          // 上恢复进度，且打 manual_adjust：这批次数是人从旧设备带过来的，不是导入
          // 误加的，不能让清理入口把它当脏数据清掉。已存在的词一律不动，不覆盖当前进度。
          final failRaw = col('failcount', -1);
          final fuzzyRaw = col('fuzzycount', -1);
          final masteredRaw = col('mastered', -1);
          if (failRaw.isNotEmpty ||
              fuzzyRaw.isNotEmpty ||
              masteredRaw.isNotEmpty) {
            final fail = int.tryParse(failRaw) ?? 0;
            final fuzzy = int.tryParse(fuzzyRaw) ?? 0;
            final mastered = (int.tryParse(masteredRaw) ?? 0) != 0;
            if (fail > 0 || fuzzy > 0 || mastered) {
              final now = _now();
              await _d.rawUpdate(
                'UPDATE book_words SET fail_count = ?, fuzzy_count = ?, mastered = ?, '
                'last_fail_at = ?, next_review_at = ?, manual_adjust = 1 '
                'WHERE book_id = ? AND word_id = ?',
                [
                  fail,
                  fuzzy,
                  mastered ? 1 : 0,
                  fail > 0 ? now : null,
                  mastered ? null : now,
                  bookId,
                  w.id,
                ],
              );
            }
          }
        }
      } catch (e) {
        failed.add('$word：$e');
      }
    }
    return ImportResult(
      added: added,
      skipped: skipped,
      failed: failed,
      existed: existed,
      truncated: truncated,
      broken: brokenRowsOf?.call() ?? 0,
      rows: rows,
    );
  }

  /// 把一段字节按「UTF-8 优先、GBK 兜底」解成文本，并去掉 BOM。
  /// 导入 CSV 和恢复备份共用这一套，避免两处各写一份、以后改漏一处。
  static String decodeTextBytes(List<int> bytes) {
    String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      text = const GbkCodec(allowInvalid: true).decode(bytes);
    }
    // 记事本另存时可能带 BOM，留着会让第一个单词前面多一个不可见字符
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
      text = text.substring(1);
    }
    return text;
  }

  /// 按分隔符切一行，引号里的分隔符不算切点，"" 表示一个引号本身。
  List<String> _splitCsvLine(String line, String delimiter) {
    final cells = <String>[];
    final buf = StringBuffer();
    var inQuote = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (inQuote) {
        if (ch == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            buf.write('"');
            i++;
          } else {
            inQuote = false;
          }
        } else {
          buf.write(ch);
        }
      } else if (ch == '"') {
        inQuote = true;
      } else if (ch == delimiter) {
        cells.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    cells.add(buf.toString());
    return cells;
  }

  Future<LookupResult> lookup(String spelling) async {
    await load();
    final raw = spelling.trim();
    final key = raw.toLowerCase();
    if (key.isEmpty) return LookupResult(spelling: spelling, found: false);
    final rows = await _dict!
        .query('dict', where: 'word = ?', whereArgs: [key], limit: 1);
    if (rows.isNotEmpty) {
      return LookupResult(
        spelling: spelling,
        found: true,
        phonetic: _clean(rows.first['phonetic']),
        definition: _clean(rows.first['translation']),
        forms: _clean(rows.first['forms']),
      );
    }
    // 词典里只有原形：minutes / responding 这类变形要猜回 minute / respond 再查。
    // 候选常常不止一个且互相冲突（using 既能猜成 us，也能猜成 use），
    // 这里优先采信「词典自己的 forms 字段里写明包含该变形」的候选，避免给出另一个词的释义。
    final candidates = lemmaCandidates(key);
    if (candidates.isNotEmpty) {
      final candidateRows = await _dictRows(candidates);
      LookupResult? confirmed;
      LookupResult? fallback;
      for (final candidate in candidates) {
        final row = candidateRows[candidate];
        if (row == null) continue;
        final hit = LookupResult(
          spelling: spelling,
          found: true,
          phonetic: _clean(row['phonetic']),
          definition: _clean(row['translation']),
          forms: _clean(row['forms']),
          lemma: candidate,
        );
        fallback ??= hit;
        if (_formsHas(hit.forms, key)) {
          confirmed = hit;
          break;
        }
      }
      if (confirmed != null) return confirmed;
      if (fallback != null) return fallback;
    }
    return LookupResult(spelling: spelling, found: false);
  }

  /// 一次查多个词的释义，给文档 / PDF / 拍照生成的生词表用。
  /// 返回的 key 是小写拼写，调用方按此取。
  ///
  /// 精确查不到的拼写，会按词形规则还原出可能的原形再查一轮：
  /// 命中时 [LookupResult.lemma] 是还原出的原形，释义取原形的释义；
  /// 确实查不到的回 [LookupResult.found] = false。
  Future<Map<String, LookupResult>> lookupMany(
      Iterable<String> spellings) async {
    await load();
    final wanted = <String, String>{};
    for (final raw in spellings) {
      final value = raw.trim();
      if (value.isEmpty) continue;
      wanted.putIfAbsent(value.toLowerCase(), () => value);
    }
    if (wanted.isEmpty) return const {};

    final result = <String, LookupResult>{};

    // 第一轮：精确查
    final rows = await _dictRows(wanted.keys.toList());
    for (final entry in rows.entries) {
      final key = entry.key;
      result[key] = LookupResult(
        spelling: wanted[key] ?? key,
        found: true,
        phonetic: _clean(entry.value['phonetic']),
        definition: _clean(entry.value['translation']),
        forms: _clean(entry.value['forms']),
      );
    }

    // 第二轮：猜原形再查，命中的才算还原成功
    final missing = wanted.keys.where((k) => !result.containsKey(k)).toList();
    if (missing.isNotEmpty) {
      final candidates = <String, List<String>>{};
      final all = <String>{};
      for (final word in missing) {
        final list = lemmaCandidates(word);
        if (list.isEmpty) continue;
        candidates[word] = list;
        all.addAll(list);
      }
      if (all.isNotEmpty) {
        final formRows = await _dictRows(all.toList());
        for (final word in candidates.keys) {
          // 与 lookup 一致：先采信 forms 里写明包含该变形词的候选，再退回首个命中
          LookupResult? confirmed;
          LookupResult? fallback;
          for (final candidate in candidates[word]!) {
            final row = formRows[candidate];
            if (row == null) continue;
            final hit = LookupResult(
              spelling: wanted[word] ?? word,
              found: true,
              phonetic: _clean(row['phonetic']),
              definition: _clean(row['translation']),
              forms: _clean(row['forms']),
              lemma: candidate,
            );
            fallback ??= hit;
            if (_formsHas(hit.forms, word)) {
              confirmed = hit;
              break;
            }
          }
          final picked = confirmed ?? fallback;
          if (picked != null) result[word] = picked;
        }
      }
    }

    // 剩下的是词库里确实没有的
    for (final word in wanted.keys) {
      result.putIfAbsent(
        word,
        () => LookupResult(spelling: wanted[word] ?? word, found: false),
      );
    }

    return result;
  }

  /// 给词库里释义为空的词补释义：按原形回查词典，只填空字段，手填过的一律不动。
  ///
  /// 用来处理历史数据——变形词（minutes / responding）在添加的当时查不到，
  /// 存进来就是空的，此后不会再自动补。返回本次补上的条数。
  Future<int> fillMissingDefinitions({String? bookId, int limit = 500}) async {
    await load();
    final where = bookId == null
        ? "(definition IS NULL OR trim(definition) = '')"
        : "(definition IS NULL OR trim(definition) = '') "
            "AND id IN (SELECT word_id FROM book_words WHERE book_id = ?)";
    final rows = await _d.rawQuery(
      'SELECT id, spelling FROM words WHERE $where LIMIT $limit',
      bookId == null ? const [] : [bookId],
    );
    if (rows.isEmpty) return 0;

    final spellings =
        rows.map((m) => (m['spelling'] as String?) ?? '').toList();
    final looked = await lookupMany(spellings);

    var filled = 0;
    for (final row in rows) {
      final id = row['id'] as String?;
      final spelling = ((row['spelling'] as String?) ?? '').trim();
      if (id == null || spelling.isEmpty) continue;
      final hit = looked[spelling.toLowerCase()];
      if (hit == null || !hit.found) continue;

      final payload = <String, Object?>{};
      final def = (hit.definition ?? '').trim();
      if (def.isNotEmpty) payload['definition'] = def;
      final ph = (hit.phonetic ?? '').trim();
      if (ph.isNotEmpty) payload['phonetic'] = ph;
      final fm = (hit.forms ?? '').trim();
      if (fm.isNotEmpty) payload['forms'] = fm;
      if (payload.isEmpty) continue;

      await _d.update('words', payload, where: 'id = ?', whereArgs: [id]);
      filled++;
    }
    return filled;
  }

  /// 批量查词典表，返回 word -> 行；分批查，避免一条 SQL 里塞几百个占位符。
  Future<Map<String, Map<String, Object?>>> _dictRows(List<String> keys) async {
    final rows = <String, Map<String, Object?>>{};
    const chunk = 200;
    for (var start = 0; start < keys.length; start += chunk) {
      final part = keys.sublist(start, min(start + chunk, keys.length));
      final placeholders = List.filled(part.length, '?').join(',');
      final found = await _dict!.query(
        'dict',
        where: 'word IN ($placeholders)',
        whereArgs: part,
      );
      for (final row in found) {
        rows[row['word'] as String] = row;
      }
    }
    return rows;
  }

  // ------------------------------------------------------------ 文章

  /// 保存一篇生成的文章，句子按下标一起落库。
  /// 返回文章 id；句子翻译和解析后续用 setSentenceZh / setSentenceParse 回填。
  Future<String> saveArticle({
    required String bookId,
    String? title,
    required String body,
    required List<String> words,
    List<String> missing = const [],
    String? model,
    required List<String> sentences,
  }) async {
    await load();
    final id = _newId('a');
    final now = DateTime.now().toIso8601String();
    await _d.transaction((txn) async {
      await txn.insert('articles', {
        'id': id,
        'book_id': bookId,
        'title': title,
        'body': body,
        'words': words.join('\n'),
        'missing': missing.join('\n'),
        'model': model,
        'created_at': now,
      });
      for (var i = 0; i < sentences.length; i++) {
        await txn.insert('article_sentences', {
          'article_id': id,
          'idx': i,
          'en': sentences[i],
        });
      }
    });
    return id;
  }

  Future<List<Article>> articlesOf(String bookId) async {
    await load();
    final rows = await _d.query(
      'articles',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'created_at DESC',
    );
    return rows.map(_articleFromMap).toList();
  }

  Future<Article?> articleById(String id) async {
    await load();
    final rows =
        await _d.query('articles', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _articleFromMap(rows.first);
  }

  Future<List<ArticleSentence>> sentencesOf(String articleId) async {
    await load();
    final rows = await _d.query(
      'article_sentences',
      where: 'article_id = ?',
      whereArgs: [articleId],
      orderBy: 'idx ASC',
    );
    return rows
        .map((row) => ArticleSentence(
              articleId: articleId,
              idx: (row['idx'] as int?) ?? 0,
              en: (row['en'] as String?) ?? '',
              zh: _clean(row['zh']),
              parseJson: row['parse_json'] as String?,
            ))
        .toList();
  }

  /// 回填某一句的中文翻译。
  Future<void> setSentenceZh(String articleId, int idx, String zh) async {
    await load();
    await _d.update(
      'article_sentences',
      {'zh': zh.trim()},
      where: 'article_id = ? AND idx = ?',
      whereArgs: [articleId, idx],
    );
  }

  /// 回填某一句的解析结果（JSON 字符串）。
  Future<void> setSentenceParse(
      String articleId, int idx, String parseJson) async {
    await load();
    await _d.update(
      'article_sentences',
      {'parse_json': parseJson},
      where: 'article_id = ? AND idx = ?',
      whereArgs: [articleId, idx],
    );
  }

  /// 删掉一篇文章，连同它的逐句记录一起清。两条 DELETE 放同一个事务里，
  /// 免得中途失败时留下没有归属的句子行。
  Future<void> deleteArticle(String articleId) async {
    await load();
    await _d.transaction((txn) async {
      await txn.delete(
        'article_sentences',
        where: 'article_id = ?',
        whereArgs: [articleId],
      );
      await txn.delete('articles', where: 'id = ?', whereArgs: [articleId]);
    });
  }

  Article _articleFromMap(Map<String, Object?> map) {
    return Article(
      id: (map['id'] as String?) ?? '',
      bookId: (map['book_id'] as String?) ?? '',
      title: _clean(map['title']),
      body: (map['body'] as String?) ?? '',
      words: _splitLines(map['words']),
      missing: _splitLines(map['missing']),
      model: _clean(map['model']),
      createdAt: (map['created_at'] as String?) ?? '',
    );
  }

  List<String> _splitLines(Object? raw) {
    final text = (raw as String?)?.trim();
    if (text == null || text.isEmpty) return const [];
    return text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// 读 app_meta 里的配置（翻译密钥等）。
  Future<String?> metaGet(String key) async {
    await load();
    final rows = await _d.query('app_meta',
        where: 'key = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    return _clean(rows.first['value']);
  }

  /// 写 app_meta 配置；传空值等于删掉这一项。
  Future<void> metaSet(String key, String? value) async {
    await load();
    final text = value?.trim();
    if (text == null || text.isEmpty) {
      await _d.delete('app_meta', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await _d.insert(
      'app_meta',
      {'key': key, 'value': text},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  String? _clean(Object? v) {
    final s = (v as String?)?.trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  /// 判断词典条目的 forms 字段里是否明确列出了 [token]（某个变形词）。
  ///
  /// forms 的格式是每行一个标签加变形词，例如：
  ///   现在分词 having
  ///   过去式/过去分词 had
  ///   第三人称单数 has
  /// 因此取每行最后一个空白分隔的片段来比对。命中说明这个词确实是该原形的变形，
  /// 而不是靠规则猜出来的另一个词（例如 using 猜成 us 时必须靠这里否掉）。
  bool _formsHas(String? forms, String token) {
    if (forms == null || forms.isEmpty) return false;
    final target = token.trim().toLowerCase();
    if (target.isEmpty) return false;
    for (final line in forms.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.isEmpty) continue;
      final last = parts.last.toLowerCase().replaceAll(RegExp(r"^[^a-z']"), '');
      if (last == target) return true;
    }
    return false;
  }

  /// 读敏感配置（目前只有有道密钥），读出时自动解混淆。
  Future<String?> secureMetaGet(String key) async {
    final raw = await metaGet(key);
    if (raw == null) return null;
    try {
      return SecretVault.unpack(raw);
    } catch (_) {
      // 解不出来就当老明文处理，不让密钥设置页直接崩
      return raw;
    }
  }

  /// 写敏感配置，落库前先混淆。
  Future<void> secureMetaSet(String key, String? value) async {
    final text = value?.trim();
    if (text == null || text.isEmpty) {
      await metaSet(key, null);
      return;
    }
    await metaSet(key, SecretVault.pack(text));
  }

  Future<Word> updateWord(String bookId, String wordId,
      {String? definition, String? phonetic, String? forms}) async {
    await load();
    final values = <String, Object?>{'is_edited': 1};
    if (definition != null) {
      final v = definition.trim();
      values['definition'] = v.isEmpty ? null : v;
    }
    if (phonetic != null) {
      final v = phonetic.trim();
      values['phonetic'] = v.isEmpty ? null : v;
    }
    if (forms != null) {
      final v = forms.trim();
      values['forms'] = v.isEmpty ? null : v;
    }
    await _d.update('words', values, where: 'id = ?', whereArgs: [wordId]);
    // 复习状态挂在 book_words 上，回读时按词库取，否则 mastered / 计数会读成旧值
    final rows = await _d.rawQuery(
      'SELECT $_wordColumns FROM book_words bw JOIN words w ON w.id = bw.word_id '
      'WHERE bw.book_id = ? AND bw.word_id = ?',
      [bookId, wordId],
    );
    if (rows.isEmpty) throw const ApiException('这个单词不在当前词库里');
    return _wordFromMap(rows.first);
  }

  /// 单条删除。给了 bookId 时直接复用 [deleteWords]，保证单条和批量规则永远一致。
  Future<void> deleteWord(String wordId, {String? bookId}) async {
    if (bookId != null) {
      await deleteWords(bookId, [wordId]);
      return;
    }
    // 没给词库时按"全库删除"处理：解除所有关联后删词条
    await load();
    await _d.transaction((txn) async {
      await txn.delete('book_words', where: 'word_id = ?', whereArgs: [wordId]);
      // 词条要删，指向它的复习记录会变成悬空行，统计和曲线都会读错
      await txn.delete('reviews', where: 'word_id = ?', whereArgs: [wordId]);
      await txn.delete('words', where: 'id = ?', whereArgs: [wordId]);
    });
  }

  /// 批量删除。仍挂在别的词库上的词只解除本库关联，孤立的词连词条一起删，
  /// 规则和 [deleteWord] 保持一致，整批放在一个事务里。
  Future<int> deleteWords(String bookId, List<String> wordIds) async {
    await load();
    if (wordIds.isEmpty) return 0;
    await _d.transaction((txn) async {
      for (final id in wordIds) {
        await txn.delete('book_words',
            where: 'book_id = ? AND word_id = ?', whereArgs: [bookId, id]);
        // 本库这条词的复习记录跟着删：留着会让今日复习数虚高，
        // 统计里出现已经不存在的词。
        await txn.delete('reviews',
            where: 'book_id = ? AND word_id = ?', whereArgs: [bookId, id]);
        final left = await txn.query('book_words',
            where: 'word_id = ?', whereArgs: [id], limit: 1);
        if (left.isEmpty) {
          // 词条本身要删了，别的库残留的同词复习记录也没有主语，一并清掉
          await txn.delete('reviews', where: 'word_id = ?', whereArgs: [id]);
          await txn.delete('words', where: 'id = ?', whereArgs: [id]);
        }
      }
    });
    return wordIds.length;
  }

  /// 单条 SQL 里能带的参数个数有上限，大词库全选时按批切，别一次塞几千个 ?。
  static const int _batchChunk = 500;

  /// 按 [_batchChunk] 切片，最后一片可能不满。
  Iterable<List<String>> _chunks(List<String> ids) sync* {
    for (var i = 0; i < ids.length; i += _batchChunk) {
      final end = i + _batchChunk > ids.length ? ids.length : i + _batchChunk;
      yield ids.sublist(i, end);
    }
  }

  /// 批量标记已掌握 / 取消掌握。返回实际影响的行数。
  Future<int> setMasteredBatch(
      String bookId, List<String> wordIds, bool mastered) async {
    await load();
    if (wordIds.isEmpty) return 0;
    var affected = 0;
    for (final chunk in _chunks(wordIds)) {
      final placeholders = List.filled(chunk.length, '?').join(', ');
      affected += await _d.rawUpdate(
        // next_review_at 跟单条 setMastered 一样清空：取消掌握后按「没复习过」
        // 立刻回到复习队列，两个入口的语义必须一致，否则批量取消的词会一直不出现。
        'UPDATE book_words SET mastered = ?, next_review_at = NULL '
        'WHERE book_id = ? AND word_id IN ($placeholders)',
        [mastered ? 1 : 0, bookId, ...chunk],
      );
    }
    return affected;
  }

  /// 批量重置遗忘次数：遗忘、模糊次数一起清零，下次复习时间不动。
  Future<int> resetFailCountBatch(String bookId, List<String> wordIds) async {
    await load();
    if (wordIds.isEmpty) return 0;
    var affected = 0;
    for (final chunk in _chunks(wordIds)) {
      final placeholders = List.filled(chunk.length, '?').join(', ');
      affected += await _d.rawUpdate(
        'UPDATE book_words SET fail_count = 0, fuzzy_count = 0, last_fail_at = NULL '
        'WHERE book_id = ? AND word_id IN ($placeholders)',
        [bookId, ...chunk],
      );
    }
    return affected;
  }

  /// 「导入误加遗忘次数」的判据。原版导入在新词入库那一次写入里，
  /// 把 fail_count 记成 1，而且 last_fail_at 和 created_at 用的是同一个 now，
  /// 两个时间戳逐字相等；手动调遗忘次数用的是另一次 _now()，不会相等。
  /// 注意 manual_adjust 这一条不能省：首次手动加词同样会形成
  /// 「fail_count=1 且 last_fail_at = created_at」的形状，只能靠标记区分开。
  /// 重复导入过的词 last_fail_at 会被后一次添加刷新，这里认不出来，故意不处理。
  /// 预览和执行必须共用这一个字符串，否则两边数量会对不上。
  static const String _dirtyFailWhere =
      'bw.fail_count = 1 AND bw.fuzzy_count = 0 AND bw.ok_count = 0'
      ' AND bw.last_reviewed_at IS NULL AND bw.last_fail_at IS NOT NULL'
      ' AND bw.last_fail_at = w.created_at AND bw.manual_adjust = 0'
      ' AND NOT EXISTS (SELECT 1 FROM reviews r WHERE r.word_id = bw.word_id)';

  /// 清理前的预览：命中数量、前几个示例词，以及这次不处理的重复导入疑似量。
  Future<DirtyFailCounts> previewDirtyFailCounts(String bookId) async {
    await load();
    final rows = await _d.rawQuery(
      'SELECT w.spelling FROM book_words bw JOIN words w ON w.id = bw.word_id '
      'WHERE bw.book_id = ? AND ($_dirtyFailWhere) ORDER BY w.spelling_lc ASC',
      [bookId],
    );
    final repeat = await _d.rawQuery(
      'SELECT COUNT(*) AS c FROM book_words bw JOIN words w ON w.id = bw.word_id '
      'WHERE bw.book_id = ? AND ($_repeatFailWhere)',
      [bookId],
    );
    return DirtyFailCounts(
      count: rows.length,
      samples: rows.take(5).map((m) => m['spelling'] as String? ?? '').toList(),
      repeatSuspects: (repeat.first['c'] as int?) ?? 0,
    );
  }

  /// 清掉「导入误加」的遗忘次数：只动 fail_count / fuzzy_count / last_fail_at，
  /// 掌握状态和下次复习时间不动。返回实际清理的词数。
  /// 清零动作直接复用 [resetFailCountBatch]，不再写第二份 UPDATE。
  Future<int> clearDirtyFailCounts(String bookId) async {
    await load();
    final rows = await _d.rawQuery(
      'SELECT bw.word_id FROM book_words bw JOIN words w ON w.id = bw.word_id '
      'WHERE bw.book_id = ? AND ($_dirtyFailWhere)',
      [bookId],
    );
    final ids = rows.map((m) => m['word_id'] as String).toList();
    if (ids.isEmpty) return 0;
    return resetFailCountBatch(bookId, ids);
  }

  /// 「重复导入过」的判据。原版「已存在词」分支每重复导入一次就把 fail_count 加 1，
  /// 并把 last_fail_at 刷成当时时间，所以时间戳和 created_at 对不上，单次导入那条判据
  /// 认不出来。这里改用「次数大于 1」+ 从未复习 + 没被手动改过（manual_adjust）。
  /// 注意：历史数据里手动改过的词 manual_adjust 都是 0，无法与重复导入区分，
  /// 所以清理前必须把命中清单整条列出来让人核对，不能静默清。
  static const String _repeatFailWhere =
      'bw.fail_count > 1 AND bw.fuzzy_count = 0 AND bw.ok_count = 0'
      ' AND bw.last_reviewed_at IS NULL AND bw.manual_adjust = 0'
      ' AND NOT EXISTS (SELECT 1 FROM reviews r WHERE r.word_id = bw.word_id)';

  /// 列出全部「重复导入疑似」的词，给清理清单用。不截断，数量可能上百。
  Future<List<DirtyWordItem>> previewRepeatDirtyWords(String bookId) async {
    await load();
    final rows = await _d.rawQuery(
      'SELECT bw.word_id, w.spelling, bw.fail_count '
      'FROM book_words bw JOIN words w ON w.id = bw.word_id '
      'WHERE bw.book_id = ? AND ($_repeatFailWhere) ORDER BY w.spelling_lc ASC',
      [bookId],
    );
    return rows
        .map((m) => DirtyWordItem(
              id: m['word_id'] as String,
              spelling: (m['spelling'] as String?) ?? '',
              failCount: (m['fail_count'] as int?) ?? 0,
            ))
        .toList();
  }

  /// 清掉勾选的那几条「重复导入」的遗忘次数。id 只能来自预览清单，
  /// 避免用户看着预览、清掉的却是别的词。清零动作同样复用 [resetFailCountBatch]。
  Future<int> clearRepeatDirtyCounts(
      String bookId, List<String> wordIds) async {
    await load();
    if (wordIds.isEmpty) return 0;
    return resetFailCountBatch(bookId, wordIds);
  }

  // ---------------- 复习与统计 ----------------

  /// 取复习队列。
  /// order: due=到期优先（默认）, recent=最久没背过的优先, fail=忘得最多的优先, random=随机打乱
  /// limit 传 0 或负数表示不限数量、全取。
  Future<List<Word>> reviewQueue(
    String bookId, {
    int limit = 20,
    String order = 'due',
    bool includeMastered = false,
    bool dueOnly = false,
  }) async {
    await load();
    final orderBy = switch (order) {
      'fail' =>
        "ORDER BY bw.fail_count DESC, IFNULL(bw.last_reviewed_at, '') ASC",
      'random' => 'ORDER BY RANDOM()',
      'recent' =>
        "ORDER BY IFNULL(bw.last_reviewed_at, '') ASC, bw.fail_count DESC",
      // 从没复习过的（next_review_at 为空）排最前，其余按到期时间从早到晚
      _ => "ORDER BY IFNULL(bw.next_review_at, '') ASC, "
          "IFNULL(bw.last_reviewed_at, '') ASC, bw.fail_count DESC",
    };
    final limitSql = limit > 0 ? ' LIMIT $limit' : '';
    final masteredSql = includeMastered ? '' : ' AND bw.mastered = 0';
    // dueOnly：只出已经到期的词。next_review_at 为空表示从没复习过，也算到期。
    // 到期日按天算（与 submitReview 写入的零点格式一致），所以直接按字符串比较。
    final args = <Object?>[bookId];
    var dueSql = '';
    if (dueOnly) {
      final now = DateTime.now();
      final todayStart =
          DateTime(now.year, now.month, now.day).toIso8601String();
      dueSql =
          " AND (bw.next_review_at IS NULL OR trim(bw.next_review_at) = '' "
          'OR bw.next_review_at <= ?)';
      args.add(todayStart);
    }
    final rows = await _d.rawQuery(
      'SELECT $_wordColumns FROM book_words bw JOIN words w ON w.id = bw.word_id '
      'WHERE bw.book_id = ?$masteredSql$dueSql $orderBy$limitSql',
      args,
    );
    return rows.map(_wordFromMap).toList();
  }

  /// 下次复习间隔（天）：忘记 1 天、模糊 3 天、记得 7 天。固定间隔，不做时间加权。
  static const List<int> _reviewIntervals = [1, 3, 7];

  Future<void> submitReview(String wordId, int result,
      {required String bookId}) async {
    await load();
    final now = _now();
    // 复习状态按词库存，所以要落在当前词库的这条关联上，而不是全局词条上
    final rows = await _d.query(
      'book_words',
      where: 'book_id = ? AND word_id = ?',
      whereArgs: [bookId, wordId],
      limit: 1,
    );
    if (rows.isEmpty) throw const ApiException('这个单词不在当前词库里');
    final interval = _reviewIntervals[result.clamp(0, 2)];
    // 到期日按「天」算，不按精确时刻：今天早上复习过的词，明天一早就是到期的，
    // 而不是要等到明天同一时刻才排进队列。
    final today = DateTime.now();
    final nextAt = DateTime(today.year, today.month, today.day)
        .add(Duration(days: interval))
        .toIso8601String();

    // 计数在 UPDATE 里直接 +1，而不是事务外读出来加一再写绝对值：
    // 两次复习挨得很近时，后写的那次会把前一次的自增覆盖掉，次数少记一次。
    await _d.transaction((txn) async {
      if (result == 0) {
        await txn.rawUpdate(
          'UPDATE book_words SET fail_count = fail_count + 1, last_fail_at = ?, '
          'last_reviewed_at = ?, next_review_at = ? '
          'WHERE book_id = ? AND word_id = ?',
          [now, now, nextAt, bookId, wordId],
        );
      } else {
        final col = result == 1 ? 'fuzzy_count' : 'ok_count';
        await txn.rawUpdate(
          'UPDATE book_words SET $col = $col + 1, last_reviewed_at = ?, next_review_at = ? '
          'WHERE book_id = ? AND word_id = ?',
          [now, nextAt, bookId, wordId],
        );
      }
      await txn.insert('reviews', {
        'word_id': wordId,
        'book_id': bookId,
        'result': result,
        'reviewed_at': now,
      });
    });
  }

  /// 已掌握：从复习队列里拿掉，但历史忘记次数照样保留在排行榜里。
  Future<void> setMastered(String bookId, String wordId, bool mastered) async {
    await load();
    await _d.update(
      'book_words',
      {'mastered': mastered ? 1 : 0, 'next_review_at': null},
      where: 'book_id = ? AND word_id = ?',
      whereArgs: [bookId, wordId],
    );
  }

  Future<List<RankItem>> rank(String bookId, {int limit = 100}) async {
    await load();
    final rows = await _d.rawQuery(
      'SELECT w.id, w.spelling, w.definition, bw.fail_count, bw.fuzzy_count, bw.last_fail_at '
      'FROM book_words bw JOIN words w ON w.id = bw.word_id '
      'WHERE bw.book_id = ? AND bw.fail_count > 0 '
      'ORDER BY bw.fail_count DESC, bw.last_fail_at DESC LIMIT ?',
      [bookId, limit],
    );
    return rows
        .map((m) => RankItem(
              wordId: m['id'] as String,
              spelling: m['spelling'] as String? ?? '',
              definition: m['definition'] as String?,
              failCount: (m['fail_count'] as int?) ?? 0,
              fuzzyCount: (m['fuzzy_count'] as int?) ?? 0,
              lastFailAt: m['last_fail_at'] == null
                  ? null
                  : DateTime.tryParse(m['last_fail_at'] as String),
            ))
        .toList();
  }

  Future<Overview> overview() async {
    await load();
    final words = (await _d.rawQuery('SELECT COUNT(*) AS c FROM words'))
            .first['c'] as int? ??
        0;
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day).toIso8601String();
    final today = (await _d.rawQuery(
          'SELECT COUNT(*) AS c FROM reviews WHERE reviewed_at >= ?',
          [todayStart],
        ))
            .first['c'] as int? ??
        0;
    final fails = (await _d.rawQuery(
          'SELECT IFNULL(SUM(fail_count), 0) AS c FROM book_words',
        ))
            .first['c'] as int? ??
        0;
    // 到期该复习的：没标已掌握，且下次复习时间已到（从未复习过的新词也算）
    final due = (await _d.rawQuery(
          'SELECT COUNT(*) AS c FROM book_words WHERE mastered = 0 '
          'AND (next_review_at IS NULL OR next_review_at <= ?)',
          [_now()],
        ))
            .first['c'] as int? ??
        0;

    return Overview(
      totalWords: words,
      todayReviews: today,
      totalFailCount: fails,
      dueCount: due,
    );
  }

  /// 已掌握的去重词数，和 [overview] 的总词数同一口径。
  ///
  /// 不能用 `COUNT(*)`：同一拼写进了两个词库就有两条 book_words，
  /// 那样掌握数会大于总词数，掌握率算出 120% 这种自相矛盾的数。
  Future<int> masteredCount() async {
    await load();
    final rows = await _d.rawQuery(
      'SELECT COUNT(DISTINCT word_id) AS c FROM book_words WHERE mastered = 1',
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  /// 数据库文件的完整路径，用于统计占用。
  Future<String> databasePath() async {
    final dir = await getDatabasesPath();
    return p.join(dir, 'vocab_offline.db');
  }

  /// 内置词典副本（databases/dict.db）占多少字节。
  ///
  /// 它是首次启动从 assets 复制过来的常驻文件，「存储占用」里漏掉它，
  /// 用户会奇怪「词库才几 MB，怎么总占用凭空多出一截」。
  Future<int> dictDbBytes() async {
    try {
      final file = File(p.join(p.dirname(await databasePath()), 'dict.db'));
      return await file.exists() ? await file.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  /// 文章总数（诊断报告用）。
  Future<int> articleCount() async {
    await load();
    final rows = await _d.rawQuery('SELECT COUNT(*) AS c FROM articles');
    return (rows.first['c'] as int?) ?? 0;
  }

  /// 近 N 天（含今天）每天的新增词数、复习次数、忘记次数。
  Future<List<DayStat>> weeklyStats({int days = 7}) async {
    await load();
    final now = DateTime.now();
    final firstDay = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: days - 1));
    final since = firstDay.toIso8601String();

    final added = _groupByDay(await _d.rawQuery(
      'SELECT date(created_at) AS d, COUNT(*) AS c FROM book_words '
      'WHERE created_at >= ? GROUP BY d',
      [since],
    ));
    final reviewed = _groupByDay(await _d.rawQuery(
      'SELECT date(reviewed_at) AS d, COUNT(*) AS c FROM reviews '
      'WHERE reviewed_at >= ? GROUP BY d',
      [since],
    ));
    final failed = _groupByDay(await _d.rawQuery(
      'SELECT date(reviewed_at) AS d, COUNT(*) AS c FROM reviews '
      'WHERE reviewed_at >= ? AND result = 0 GROUP BY d',
      [since],
    ));

    return List.generate(days, (i) {
      final day = firstDay.add(Duration(days: i));
      final key = _dayKey(day);
      return DayStat(
        day: day,
        added: added[key] ?? 0,
        reviewed: reviewed[key] ?? 0,
        failed: failed[key] ?? 0,
      );
    });
  }

  String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Map<String, int> _groupByDay(List<Map<String, Object?>> rows) {
    final map = <String, int>{};
    for (final row in rows) {
      final key = row['d'] as String?;
      if (key == null || key.isEmpty) continue;
      map[key] = (row['c'] as int?) ?? 0;
    }
    return map;
  }

  // ---------------- 备份与恢复 ----------------

  /// 密钥不进备份：备份文件常被转发到别的设备，把 appSecret 一起带走不合适。
  static const List<String> _secretMetaKeys = [
    'youdao_app_key',
    'youdao_app_secret',
    'deepseek_api_key',
  ];

  Future<String> exportJson() async {
    await load();
    // 不再「七张表一次性读进内存再 jsonEncode」：几万词的库会把行对象、
    // 中间 Map、最终字符串三份同时压在堆上。改成逐表分页读、读一页编码一页，
    // 峰值降到「当前页 + 已生成的文本」。
    const pageSize = 2000;
    final buf = StringBuffer();
    buf.write('{"app":"vocab_offline",');
    // 备份内容直接是各表的行，随库结构一起演进，所以跟 _db version 对齐。
    // 恢复不校验这个字段（老备份照样能导），它只用于人工排障。
    // v8 起包含 articles 与 article_sentences。
    buf.write('"version":8,"exported_at":');
    buf.write(jsonEncode(_now()));

    Future<void> writeRows(
        String key, String sql, List<Object?> args) async {
      buf.write(',');
      buf.write(jsonEncode(key));
      buf.write(':[');
      var offset = 0;
      var first = true;
      while (true) {
        final rows = await _d
            .rawQuery('$sql LIMIT $pageSize OFFSET $offset', args);
        if (rows.isEmpty) break;
        for (final row in rows) {
          if (!first) buf.write(',');
          first = false;
          buf.write(jsonEncode(row));
        }
        if (rows.length < pageSize) break;
        offset += pageSize;
      }
      buf.write(']');
    }

    // 每个查询都要带 ORDER BY：没有稳定顺序时 OFFSET 翻页会重复或漏行。
    await writeRows('books', 'SELECT * FROM books ORDER BY id', const []);
    await writeRows('words', 'SELECT * FROM words ORDER BY id', const []);
    await writeRows(
        'book_words',
        'SELECT * FROM book_words ORDER BY book_id, word_id',
        const []);
    await writeRows('reviews', 'SELECT * FROM reviews ORDER BY id', const []);
    // 文章正文与逐句译文是用户花额度生成的内容，无法从词库反推，必须进备份。
    await writeRows('articles', 'SELECT * FROM articles ORDER BY id', const []);
    await writeRows(
        'article_sentences',
        'SELECT * FROM article_sentences ORDER BY article_id, idx',
        const []);
    final secretFilter = _secretMetaKeys.map((_) => '?').join(', ');
    await writeRows(
      'meta',
      'SELECT * FROM app_meta WHERE key NOT IN ($secretFilter) ORDER BY key',
      _secretMetaKeys,
    );
    buf.write('}');
    return buf.toString();
  }

  /// compute 只接受顶层函数或静态方法；整份备份的 JSON 解析放到后台 isolate。
  static Map<String, dynamic> _decodeBackupText(String text) =>
      jsonDecode(text) as Map<String, dynamic>;

  /// 恢复备份。只补缺失的记录，已存在的按主键跳过，绝不覆盖现在的数据。
  Future<BackupResult> importJson(String text,
      {void Function(String stage)? onProgress}) async {
    await load();
    onProgress?.call('正在解析备份文件');
    Map<String, dynamic> root;
    try {
      // 几万词的备份几十 MB，jsonDecode 压在 UI isolate 上会让界面僵住十几秒，
      // 用户以为卡死就强杀了。大文件搬到后台 isolate，小文件直解省一次拷贝。
      root = text.length > 1000000
          ? await compute(_decodeBackupText, text)
          : jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      throw const ApiException('这个文件不是有效的备份文件');
    }
    if (root['app'] != 'vocab_offline') {
      throw const ApiException('这不是词学家的备份文件');
    }

    // 各表只收这些列。备份可能来自别的版本：多一列 sqflite 会直接抛错、
    // 少一列靠表默认值补、计数被写成字符串也会抛，三种都会让整批回滚。
    // 这里按白名单和类型重建 Map，坏行计数跳过，好行照常恢复。
    const columns = <String, List<String>>{
      'books': ['id', 'name', 'description', 'created_at'],
      'words': [
        'id',
        'spelling',
        'spelling_lc',
        'phonetic',
        'definition',
        'forms',
        'example',
        'source',
        'is_edited',
        'fail_count',
        'fuzzy_count',
        'ok_count',
        'mastered',
        'last_reviewed_at',
        'last_fail_at',
        'next_review_at',
        'created_at',
      ],
      'book_words': [
        'book_id',
        'word_id',
        'created_at',
        'mastered',
        'fail_count',
        'fuzzy_count',
        'ok_count',
        'last_reviewed_at',
        'last_fail_at',
        'next_review_at',
        'manual_adjust',
      ],
      'reviews': ['id', 'word_id', 'book_id', 'result', 'reviewed_at'],
      'articles': [
        'id',
        'book_id',
        'title',
        'body',
        'words',
        'missing',
        'model',
        'created_at'
      ],
      'article_sentences': ['article_id', 'idx', 'en', 'zh', 'parse_json'],
      'app_meta': ['key', 'value'],
    };
    // 这几列在库里是 INT，备份里被写成 "3" / "true" 时按整数收下
    const intColumns = <String, Set<String>>{
      'words': {
        'is_edited',
        'fail_count',
        'fuzzy_count',
        'ok_count',
        'mastered'
      },
      'book_words': {
        'mastered',
        'fail_count',
        'fuzzy_count',
        'ok_count',
        'manual_adjust'
      },
      'reviews': {'id', 'result'},
      'article_sentences': {'idx'},
    };

    var badRows = 0;

    /// 单行写入的兜底：缺 NOT NULL 列、类型不符这类坏行只丢这一行。
    ///
    /// 直接让异常抛出去会把整个事务回滚，用户几千个词全白导，还只看到一句
    /// 「恢复失败」。缺一行不影响其余数据的恢复，记进坏行计数更合理。
    Future<bool> putSafe(Transaction txn, String table,
        Map<String, Object?> row,
        {bool ignore = false}) async {
      try {
        await txn.insert(table, row,
            conflictAlgorithm:
                ignore ? ConflictAlgorithm.ignore : ConflictAlgorithm.abort);
        return true;
      } on DatabaseException catch (e) {
        badRows++;
        Diag.record(
            '恢复', '$table 有一行写不进去：${e.toString().split('\n').first}');
        return false;
      }
    }

    List<Map<String, Object?>> rowsOf(String table, Object? value) {
      if (value is! List) return const [];
      final cols = columns[table]!;
      final ints = intColumns[table] ?? const <String>{};
      final out = <Map<String, Object?>>[];
      for (final e in value) {
        if (e is! Map) {
          badRows++;
          continue;
        }
        final row = <String, Object?>{};
        try {
          for (final col in cols) {
            if (!e.containsKey(col)) continue;
            final v = e[col];
            if (v == null) continue;
            row[col] = _backupValue(col, v, ints.contains(col));
          }
        } on FormatException {
          badRows++;
          continue;
        }
        // 一个认识的列都没有的行，插进去只会是垃圾记录
        if (row.isEmpty) {
          badRows++;
          continue;
        }
        out.add(row);
      }
      return out;
    }

    onProgress?.call('正在整理备份内容');
    final books = rowsOf('books', root['books']);
    final words = rowsOf('words', root['words']);
    final links = rowsOf('book_words', root['book_words']);
    final reviews = rowsOf('reviews', root['reviews']);
    // 老备份没有这两项，rowsOf 会返回空列表，后面按空处理即可，不报错。
    final articles = rowsOf('articles', root['articles']);
    final sentences = rowsOf('article_sentences', root['article_sentences']);
    final metas = rowsOf('app_meta', root['meta']);

    // v5 及以前的备份把复习状态（mastered、各类计数、复习时间）写在 words 行里，
    // v6 之后写在 book_words 行里。恢复链接时新备份优先，取不到再回退到 words 行，
    // 否则用老备份恢复出来的词全是「没背过、没掌握」。
    final wordRowById = <String, Map<String, Object?>>{};
    for (final row in words) {
      final id = row['id'] as String?;
      if (id != null) wordRowById[id] = row;
    }

    var newBooks = 0;
    var newWords = 0;
    var skippedWords = 0;
    var newReviews = 0;
    var newArticles = 0;
    var newSentences = 0;

    // 先把现有的关键字段读进内存。逐个查库的话，五万个词就是五万次 SQL，
    // 恢复一份大备份会卡上好几秒。
    final bookIds = <String>{};
    for (final row in await _d.query('books', columns: ['id'])) {
      final id = row['id'] as String?;
      if (id != null) bookIds.add(id);
    }
    final wordIds = <String>{};
    final spellings = <String>{};
    final wordIdBySpelling = <String, String>{};
    for (final row in await _d.query('words', columns: ['id', 'spelling_lc'])) {
      final id = row['id'] as String?;
      final lc = row['spelling_lc'] as String?;
      if (id != null) wordIds.add(id);
      if (lc != null) {
        spellings.add(lc);
        if (id != null) wordIdBySpelling[lc] = id;
      }
    }
    final linkKeys = <String>{};
    for (final row
        in await _d.query('book_words', columns: ['book_id', 'word_id'])) {
      linkKeys.add('${row['book_id']}|${row['word_id']}');
    }
    // 复习记录没有业务主键，用「词 + 时间 + 结果」当去重键
    final reviewKeys = <String>{};
    for (final row in await _d
        .query('reviews', columns: ['word_id', 'reviewed_at', 'result'])) {
      reviewKeys
          .add('${row['word_id']}|${row['reviewed_at']}|${row['result']}');
    }
    final metaKeys = <String>{};
    for (final row in await _d.query('app_meta', columns: ['key'])) {
      final key = row['key'] as String?;
      if (key != null) metaKeys.add(key);
    }
    // 文章按 id 去重：库里已经有这篇就只补缺的分句；分句再按 (article_id, idx)
    // 主键冲突忽略，同一份备份导入两次不会翻倍。
    final articleIds = <String>{};
    for (final row in await _d.query('articles', columns: ['id'])) {
      final id = row['id'] as String?;
      if (id != null) articleIds.add(id);
    }

    // 备份里的单词 id 对应到恢复后的真实 id。拼写已经在库里时不新增，
    // 直接把这个旧 id 指向现有词，否则词库链接会挂到不存在的词上。
    final remap = <String, String>{};

    await _d.transaction((txn) async {
      onProgress?.call('正在恢复词库');
      for (final row in books) {
        final id = row['id'] as String?;
        if (id == null || !bookIds.add(id)) continue;
        if (!await putSafe(txn, 'books', row)) {
          // 这一行没写进去，就别让后面的词库关联把它当存在的词库
          bookIds.remove(id);
          continue;
        }
        newBooks++;
      }
      onProgress?.call('正在恢复单词');
      for (final row in words) {
        final oldId = row['id'] as String?;
        final lc = row['spelling_lc'] as String?;
        if (oldId == null || lc == null) continue;
        if (!wordIds.add(oldId)) {
          remap[oldId] = oldId;
          skippedWords++;
          continue;
        }
        if (spellings.contains(lc)) {
          final live = wordIdBySpelling[lc];
          if (live != null) remap[oldId] = live;
          skippedWords++;
          continue;
        }
        if (!await putSafe(txn, 'words', row)) {
          // 单词没落库：把这个旧 id 从已存在集合里摘掉，免得后面按它挂词库关联
          wordIds.remove(oldId);
          continue;
        }
        spellings.add(lc);
        wordIdBySpelling[lc] = oldId;
        remap[oldId] = oldId;
        newWords++;
      }
      onProgress?.call('正在恢复词库关联');
      for (final row in links) {
        final bookId = row['book_id'] as String?;
        final oldWordId = row['word_id'] as String?;
        if (bookId == null || oldWordId == null) continue;
        // 词库没恢复进来、或这个词既没恢复也没对上现有词，就别插一条孤儿链接
        if (!bookIds.contains(bookId)) continue;
        final wordId = remap[oldWordId];
        if (wordId == null) continue;
        final key = '$bookId|$wordId';
        if (!linkKeys.contains(key)) {
          // 链接行本身带着这条词库里的复习状态，一并搬过去
          final src = wordRowById[oldWordId];
          final savedLink = await putSafe(txn, 'book_words', {
            'book_id': bookId,
            'word_id': wordId,
            'created_at': row['created_at'] ?? _now(),
            'mastered': row['mastered'] ?? src?['mastered'] ?? 0,
            'fail_count': row['fail_count'] ?? src?['fail_count'] ?? 0,
            'fuzzy_count': row['fuzzy_count'] ?? src?['fuzzy_count'] ?? 0,
            'ok_count': row['ok_count'] ?? src?['ok_count'] ?? 0,
            'last_reviewed_at':
                row['last_reviewed_at'] ?? src?['last_reviewed_at'],
            'last_fail_at': row['last_fail_at'] ?? src?['last_fail_at'],
            'next_review_at': row['next_review_at'] ?? src?['next_review_at'],
            // 这一列是「次数由人产生」的凭证，清理判据靠它排除手动数据。
            // 漏写就等于把手动调过的次数洗成导入脏数据，下次清理会被清掉。
            'manual_adjust': row['manual_adjust'] ?? 0,
          });
          if (!savedLink) {
            // 这一行没写进去：不记这个键，留着下次同样的行还能补
            continue;
          }
        }
        linkKeys.add(key);
      }
      onProgress?.call('正在恢复复习记录');
      for (final row in reviews) {
        final oldWordId = row['word_id'] as String?;
        if (oldWordId == null) continue;
        final wordId = remap[oldWordId];
        if (wordId == null) continue; // 词不在库里，这条复习记录没有意义
        final reviewedAt = row['reviewed_at'] as String? ?? '';
        final result = row['result'];
        final key = '$wordId|$reviewedAt|$result';
        if (!reviewKeys.add(key)) continue;
        // 不带备份里的自增 id：目标库里那个号可能已经被占用，
        // INSERT OR IGNORE 会让整段复习历史安静地丢掉。
        final savedReview = await putSafe(txn, 'reviews', {
          'word_id': wordId,
          'book_id': row['book_id'],
          'result': result,
          'reviewed_at': reviewedAt,
        });
        if (savedReview) newReviews++;
      }
      // 文章与分句：book_id 不在恢复范围内的跳过，避免挂到不存在的词库上。
      onProgress?.call('正在恢复文章');
      for (final row in articles) {
        final id = row['id'] as String?;
        final bookId = row['book_id'] as String?;
        final body = row['body'];
        final wordsJson = row['words'];
        if (id == null || bookId == null) continue;
        if (!bookIds.contains(bookId)) continue;
        if (body == null || wordsJson == null) continue;
        if (!articleIds.add(id)) continue;
        final savedArticle = await putSafe(
          txn,
          'articles',
          {
            'id': id,
            'book_id': bookId,
            'title': row['title'],
            'body': body,
            'words': wordsJson,
            'missing': row['missing'],
            'model': row['model'],
            'created_at': row['created_at'] ?? _now(),
          },
          ignore: true,
        );
        if (!savedArticle) {
          // 文章没写进去，它的分句就不该再挂上去
          articleIds.remove(id);
          continue;
        }
        newArticles++;
      }
      for (final row in sentences) {
        final articleId = row['article_id'] as String?;
        final idx = row['idx'];
        final en = row['en'];
        if (articleId == null || idx == null || en == null) continue;
        if (!articleIds.contains(articleId)) continue;
        final savedSentence = await putSafe(
          txn,
          'article_sentences',
          {
            'article_id': articleId,
            'idx': idx,
            'en': en,
            'zh': row['zh'],
            'parse_json': row['parse_json'],
          },
          ignore: true,
        );
        if (savedSentence) newSentences++;
      }
      for (final row in metas) {
        final key = row['key'] as String?;
        if (key == null || _secretMetaKeys.contains(key)) continue;
        if (!metaKeys.add(key)) continue;
        await putSafe(txn, 'app_meta', row);
      }
    });

    return BackupResult(
      books: newBooks,
      words: newWords,
      skippedWords: skippedWords,
      reviews: newReviews,
      articles: newArticles,
      sentences: newSentences,
      badRows: badRows,
    );
  }

  /// 把备份里的一列值规整成 sqflite 能写进去的类型。
  /// 常见的是「计数被写成字符串」和「布尔被写成 0/1」，两种都容下来；
  /// 实在认不出类型的抛 [FormatException]，由调用方把整行当坏行跳过。
  static Object _backupValue(String column, Object value, bool asInt) {
    if (asInt) {
      if (value is int) return value;
      if (value is bool) return value ? 1 : 0;
      if (value is num) return value.toInt();
      if (value is String) {
        final t = value.trim().toLowerCase();
        if (t == 'true') return 1;
        if (t == 'false') return 0;
        final n = int.tryParse(t);
        if (n != null) return n;
      }
      throw FormatException('$column 不是整数');
    }
    if (value is String) return value;
    if (value is num || value is bool) return '$value';
    throw FormatException('$column 的类型不认识');
  }
}
