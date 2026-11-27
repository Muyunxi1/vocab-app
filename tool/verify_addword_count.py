#!/usr/bin/env python
"""「手动加词算一次忘记」契约测试。

设计意图：
  - 主页 / 添加单词页手动加词 -> 计 1 次忘记，重复加会继续累加；
  - 导入（CSV / 批量粘贴）-> 不计，避免再次污染；
  - 手动累加出来的次数必须打 manual_adjust 标记，否则会被
    「清理重复导入」判据当成导入脏数据清掉。

前两条查源码调用点，后一条用同构 sqlite 跑两个判据验证。

用法：python tool/verify_addword_count.py
退出码：0 通过；1 签名缺失 / 调用点传错 / 手动次数被清理判据命中
"""
import os
import re
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.path.join(ROOT, "lib", "api.dart")
HOME = os.path.join(ROOT, "lib", "pages", "home.dart")
ADD_PAGE = os.path.join(ROOT, "lib", "pages", "add_words.dart")


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def extract_constant(src, name):
    m = re.search(r"%s\s*=(.*?);" % name, src, re.S)
    if not m:
        return None
    parts = re.findall(r"'([^']*)'", m.group(1))
    return re.sub(r"\s+", " ", "".join(parts)).strip() if parts else None


def main():
    failed = False
    api = read(API)

    # --- 1. 签名必须带 countAsFail，默认 false ---
    m = re.search(r"Future<Word> addWord\((.*?)\)\s*async", api, re.S)
    if not m:
        print("FAIL: 找不到 addWord 签名")
        return 1
    sig = re.sub(r"\s+", " ", m.group(1))
    if "bool countAsFail = false" not in sig:
        print("FAIL: addWord 签名没有 `bool countAsFail = false`，实际：%s" % sig)
        failed = True
    else:
        print("PASS: addWord 有 countAsFail 参数，默认 false")

    # --- 2. 方法体必须自增并打标记 ---
    body = re.search(r"Future<Word> addWord\(.*?\n  \}", api, re.S)
    body_text = body.group(0) if body else ""
    if "fail_count = fail_count + 1" not in body_text:
        print("FAIL: addWord 没有对 fail_count 自增")
        failed = True
    elif "manual_adjust = 1" not in body_text:
        print("FAIL: 手动加词累加时没打 manual_adjust 标记，会被清理判据误清")
        failed = True
    else:
        print("PASS: addWord 自增 fail_count 并打 manual_adjust 标记")

    # --- 3. 调用点：手动页传 true，导入不传 ---
    for path, label in ((HOME, "主页"), (ADD_PAGE, "添加单词页")):
        if not os.path.exists(path):
            print("FAIL: 找不到 %s" % path)
            failed = True
            continue
        src = read(path)
        calls = re.findall(r"addWord\((.*?)\);", src, re.S)
        ok = any("countAsFail: true" in c for c in calls)
        if not ok:
            print("FAIL: %s 的 addWord 调用没有 countAsFail: true" % label)
            failed = True
        else:
            print("PASS: %s 手动加词计次数" % label)

    # 只看代码，不看注释：注释里提到 countAsFail: true 是在解释语义，不算调用
    code_lines = [
        ln for ln in api.splitlines()
        if not ln.lstrip().startswith("//")
    ]
    if any("countAsFail: true" in ln for ln in code_lines):
        print("FAIL: api.dart 内部（导入路径）出现了 countAsFail: true，导入不该计数")
        failed = True
    else:
        print("PASS: 导入路径不计数")

    # --- 4. 手动累加的次数不能被两个清理判据命中 ---
    dirty = extract_constant(api, "_dirtyFailWhere")
    repeat = extract_constant(api, "_repeatFailWhere")
    if not dirty or not repeat:
        print("FAIL: 抽不到清理判据常量")
        return 1

    c = sqlite3.connect(":memory:")
    c.executescript(
        """
        CREATE TABLE words(id TEXT PRIMARY KEY, spelling TEXT, created_at TEXT NOT NULL);
        CREATE TABLE book_words(book_id TEXT, word_id TEXT, created_at TEXT,
          mastered INTEGER DEFAULT 0, fail_count INTEGER DEFAULT 0,
          fuzzy_count INTEGER DEFAULT 0, ok_count INTEGER DEFAULT 0,
          last_reviewed_at TEXT, last_fail_at TEXT, next_review_at TEXT,
          manual_adjust INTEGER DEFAULT 0);
        CREATE TABLE reviews(word_id TEXT, book_id TEXT, result INTEGER, reviewed_at TEXT);
        """
    )
    c.execute("INSERT INTO words VALUES('w9','money','2026-11-15T10:00:00.000')")
    c.execute(
        "INSERT INTO book_words VALUES('b1','w9','2026-11-15T10:00:00.010',0,0,0,0,NULL,NULL,NULL,0)"
    )
    # 手动加 3 次（模拟 addWord 的自增 SQL）
    for i in range(3):
        c.execute(
            "UPDATE book_words SET fail_count = fail_count + 1, "
            "last_fail_at = '2026-11-15T10:0%d:00.000', manual_adjust = 1 "
            "WHERE book_id = 'b1' AND word_id = 'w9'" % i
        )

    row = c.execute(
        "SELECT fail_count, manual_adjust FROM book_words WHERE book_id='b1' AND word_id='w9'"
    ).fetchone()
    if row != (3, 1):
        print("FAIL: 手动加 3 次后应为 (3, 1)，实际 %s" % (row,))
        failed = True
    else:
        print("PASS: 手动加 3 次后 fail_count=3 且已标记")

    for name, where in (("_dirtyFailWhere", dirty), ("_repeatFailWhere", repeat)):
        hits = c.execute(
            "SELECT COUNT(*) FROM book_words bw JOIN words w ON w.id = bw.word_id "
            "WHERE bw.book_id = 'b1' AND (" + where + ")"
        ).fetchone()[0]
        if hits != 0:
            print("FAIL: 手动累加 3 次的词被 %s 命中，会被误清" % name)
            failed = True
        else:
            print("PASS: 手动累加 3 次的词不被 %s 命中" % name)

    # 首次手动加词：fail_count=1 且 last_fail_at 与首次入库同一时刻，
    # 这正是「单次导入误加」的形状，必须靠 manual_adjust 才能区分开。
    c.execute(
        "INSERT INTO words VALUES('w10','coin','2026-11-15T11:00:00.000')"
    )
    c.execute(
        "INSERT INTO book_words VALUES('b1','w10','2026-11-15T11:00:00.010',0,1,0,0,"
        "NULL,'2026-11-15T11:00:00.000',NULL,1)"
    )
    for name, where in (("_dirtyFailWhere", dirty), ("_repeatFailWhere", repeat)):
        hits = c.execute(
            "SELECT COUNT(*) FROM book_words bw JOIN words w ON w.id = bw.word_id "
            "WHERE bw.book_id = 'b1' AND bw.word_id = 'w10' AND (" + where + ")"
        ).fetchone()[0]
        if hits != 0:
            print("FAIL: 首次手动加词（fail_count=1）被 %s 命中，会被误清" % name)
            failed = True
        else:
            print("PASS: 首次手动加词不被 %s 命中" % name)

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
