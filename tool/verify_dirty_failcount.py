#!/usr/bin/env python
"""「清理导入误加遗忘次数」的两个判据契约测试。

为什么不用 dart test：lib/api.dart 依赖 sqflite（Flutter 插件），桌面上跑不起来。
这里用同源 sqlite 引擎验证 SQL 判据本身，并断言 api.dart 里的常量与这里逐字一致，
防止预览与执行的过滤条件漂移。

两个判据各有分工，谁都不能越界：
  _dirtyFailWhere  —— 只导入过一次：fail_count=1，且 last_fail_at 与首次入库时间相同
  _repeatFailWhere —— 重复导入过：fail_count>1，未复习、无评分记录、没被手动改过

用法：python tool/verify_dirty_failcount.py
退出码：0 通过；1 常量缺失/不一致/误伤样本
"""
import os
import re
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.path.join(ROOT, "lib", "api.dart")

# 与 api.dart 的常量必须逐字一致（空白归一化后比较）。
# manual_adjust = 0 不能省：首次手动加词同样是 fail_count=1 且
# last_fail_at 与 created_at 相等，只有这个标记能把它和导入脏数据分开。
DIRTY_REF = (
    "bw.fail_count = 1 AND bw.fuzzy_count = 0 AND bw.ok_count = 0 "
    "AND bw.last_reviewed_at IS NULL AND bw.last_fail_at IS NOT NULL "
    "AND bw.last_fail_at = w.created_at AND bw.manual_adjust = 0 "
    "AND NOT EXISTS (SELECT 1 FROM reviews r WHERE r.word_id = bw.word_id)"
)

# 重复导入过的词 last_fail_at 会被后一次添加刷新，所以这里不看时间，
# 改用手动调整标记 manual_adjust 把「手动改过的」挡在外面。
REPEAT_REF = (
    "bw.fail_count > 1 AND bw.fuzzy_count = 0 AND bw.ok_count = 0 "
    "AND bw.last_reviewed_at IS NULL AND bw.manual_adjust = 0 "
    "AND NOT EXISTS (SELECT 1 FROM reviews r WHERE r.word_id = bw.word_id)"
)

EXPECTED_DIRTY = ["w1"]
EXPECTED_REPEAT = ["w4"]


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


def extract_constant(name):
    """从 api.dart 抓出某个字符串常量的拼接结果。"""
    if not os.path.exists(API):
        return None, "找不到 lib/api.dart"
    with open(API, encoding="utf-8", errors="replace") as f:
        text = f.read()
    m = re.search(r"%s\s*=(.*?);" % name, text, re.S)
    if not m:
        return None, "api.dart 里没有 %s 常量" % name
    parts = re.findall(r"'([^']*)'", m.group(1))
    if not parts:
        return None, "%s 里没有单引号字符串片段" % name
    return norm("".join(parts)), None


def build_db():
    """:memory: 库，造 6 类样本。"""
    c = sqlite3.connect(":memory:")
    c.executescript(
        """
        CREATE TABLE words(id TEXT PRIMARY KEY, spelling TEXT, created_at TEXT NOT NULL);
        CREATE TABLE book_words(
          book_id TEXT, word_id TEXT, created_at TEXT,
          mastered INTEGER DEFAULT 0, fail_count INTEGER DEFAULT 0,
          fuzzy_count INTEGER DEFAULT 0, ok_count INTEGER DEFAULT 0,
          last_reviewed_at TEXT, last_fail_at TEXT, next_review_at TEXT,
          manual_adjust INTEGER DEFAULT 0);
        CREATE TABLE reviews(word_id TEXT, book_id TEXT, result INTEGER, reviewed_at TEXT);
        """
    )
    # 1 单次导入：last_fail_at 与 words.created_at 同一时刻 —— 只该被 _dirty 命中
    c.execute("INSERT INTO words VALUES('w1','using','2026-11-01T10:00:00.000')")
    c.execute(
        "INSERT INTO book_words VALUES('b1','w1','2026-11-01T10:00:00.010',0,1,0,0,"
        "NULL,'2026-11-01T10:00:00.000',NULL,0)"
    )
    # 2 真背错过：有 reviews 记录 + 复习过 + 遗忘时间晚于入库
    c.execute("INSERT INTO words VALUES('w2','apple','2026-10-01T10:00:00.000')")
    c.execute(
        "INSERT INTO book_words VALUES('b1','w2','2026-10-01T10:00:00.010',0,1,0,0,"
        "'2026-10-05T09:00:00.000','2026-10-05T09:00:00.000','2026-10-06T00:00:00.000',0)"
    )
    c.execute("INSERT INTO reviews VALUES('w2','b1',0,'2026-10-05T09:00:00.000')")
    # 3 手动调过（旧数据没标记）：fail_count=1，遗忘时间是之后补写
    c.execute("INSERT INTO words VALUES('w3','book','2026-10-02T10:00:00.000')")
    c.execute(
        "INSERT INTO book_words VALUES('b1','w3','2026-10-02T10:00:00.010',0,1,0,0,"
        "NULL,'2026-10-20T08:00:00.000',NULL,0)"
    )
    # 4 重复导入：次数大于 1，遗忘时间被后一次添加刷新 —— 只该被 _repeat 命中
    c.execute("INSERT INTO words VALUES('w4','cover','2026-10-03T10:00:00.000')")
    c.execute(
        "INSERT INTO book_words VALUES('b1','w4','2026-10-03T10:00:00.010',0,3,0,0,"
        "NULL,'2026-10-07T10:00:00.000',NULL,0)"
    )
    # 5 手动调过且已打标记：次数同样大于 1，但必须被 _repeat 排除
    c.execute("INSERT INTO words VALUES('w5','remain','2026-10-04T10:00:00.000')")
    c.execute(
        "INSERT INTO book_words VALUES('b1','w5','2026-10-04T10:00:00.010',0,4,0,0,"
        "NULL,'2026-10-09T10:00:00.000',NULL,1)"
    )
    # 6 另一个词库里的同一条脏词 —— 验证 book_id 过滤
    c.execute(
        "INSERT INTO book_words VALUES('b2','w1','2026-11-01T10:00:00.020',0,1,0,0,"
        "NULL,'2026-11-01T10:00:00.000',NULL,0)"
    )
    return c


def hit_ids(c, where):
    rows = c.execute(
        "SELECT bw.word_id FROM book_words bw JOIN words w ON w.id = bw.word_id "
        "WHERE bw.book_id = 'b1' AND (" + where + ") ORDER BY bw.word_id"
    ).fetchall()
    return [r[0] for r in rows]


def main():
    failed = False

    for name, ref, expected in (
        ("_dirtyFailWhere", DIRTY_REF, EXPECTED_DIRTY),
        ("_repeatFailWhere", REPEAT_REF, EXPECTED_REPEAT),
    ):
        where, err = extract_constant(name)
        if err:
            print("FAIL: %s" % err)
            print("  期望内容：" + ref)
            failed = True
            continue
        if where != ref:
            print("FAIL: %s 与契约判据不一致" % name)
            print("  实际：" + where)
            print("  期望：" + ref)
            failed = True
            continue
        got = hit_ids(build_db(), where)
        if got != expected:
            print("FAIL: %s 命中集合不对，期望 %s，实际 %s" % (name, expected, got))
            failed = True
            continue
        print("PASS: %s 只命中 %s" % (name, got))

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
