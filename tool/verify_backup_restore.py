#!/python
"""备份恢复契约测试：恢复不能把手动调过的次数标记弄丢。

manual_adjust 是「这条次数由人产生」的唯一凭证，清理判据靠它把手动数据
排除在外。导出是全表导出所以文件里带着这一列，恢复时漏写就等于把它洗成
导入脏数据。

用法：python tool/verify_backup_restore.py
退出码：0 通过；1 恢复漏字段
"""
import os
import re
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.path.join(ROOT, "lib", "api.dart")


def extract_constant(src, name):
    m = re.search(r"%s\s*=(.*?);" % name, src, re.S)
    if not m:
        return None
    parts = re.findall(r"'([^']*)'", m.group(1))
    return re.sub(r"\s+", " ", "".join(parts)).strip() if parts else None


def main():
    failed = False
    with open(API, encoding="utf-8", errors="replace") as f:
        src = f.read()

    # --- 1. 恢复 book_words 时字段必须带 manual_adjust ---
    m = re.search(r"Future<BackupResult> importJson\(.*?\n  \}", src, re.S)
    body = m.group(0) if m else ""
    if not body:
        print("FAIL: 找不到 importJson")
        return 1

    # 恢复现在走 putSafe 逐行兜底（坏行只丢一行，不回滚整份），两种写法都认
    insert = re.search(
        r"(?:txn\.insert\('book_words'|putSafe\(txn, 'book_words')"
        r"\s*,\s*\{(.*?)\}",
        body,
        re.S,
    )
    if not insert:
        print("FAIL: 定位不到 book_words 的恢复插入块")
        return 1
    fields = insert.group(1)
    if "'manual_adjust'" not in fields:
        print("FAIL: 恢复 book_words 时没写 manual_adjust，手动次数会退化成导入脏数据")
        failed = True
    else:
        print("PASS: 恢复时会带回 manual_adjust")

    # 老备份（v5 及以前）没有这一列，必须能用默认值兜底
    if "manual_adjust': row['manual_adjust'] ?? 0" not in fields.replace(" ", ""):
        alt = "manual_adjust" in fields and "??0" in fields.replace(" ", "")
        if not alt:
            print("FAIL: manual_adjust 缺默认值，老备份会插空值")
            failed = True
        else:
            print("PASS: 老备份用默认 0 兜底")
    else:
        print("PASS: 老备份用默认 0 兜底")

    # --- 2. 恢复后的数据不能被清理判据命中 ---
    dirty = extract_constant(src, "_dirtyFailWhere")
    if not dirty:
        print("FAIL: 抽不到 _dirtyFailWhere")
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
    c.execute("INSERT INTO words VALUES('w1','abandon','2026-11-10T09:00:00.000')")
    # 模拟「恢复回来的手动加词」：fail_count=1、last_fail_at 等于 created_at、manual_adjust=1
    c.execute(
        "INSERT INTO book_words VALUES('b1','w1','2026-11-10T09:00:00.000',0,1,0,0,"
        "NULL,'2026-11-10T09:00:00.000',NULL,1)"
    )
    hits = c.execute(
        "SELECT COUNT(*) FROM book_words bw JOIN words w ON w.id = bw.word_id "
        "WHERE bw.book_id = 'b1' AND (" + dirty + ")"
    ).fetchone()[0]
    if hits != 0:
        print("FAIL: 恢复回来的手动次数被清理判据命中")
        failed = True
    else:
        print("PASS: 恢复回来的手动次数不会被清理")

    # 反证：同一形状但标记丢了（=漏写该列的后果），就会被清
    c.execute("UPDATE book_words SET manual_adjust = 0 WHERE book_id='b1'")
    hits0 = c.execute(
        "SELECT COUNT(*) FROM book_words bw JOIN words w ON w.id = bw.word_id "
        "WHERE bw.book_id = 'b1' AND (" + dirty + ")"
    ).fetchone()[0]
    if hits0 != 1:
        print("FAIL: 反证样本没命中，说明判据已失效")
        failed = True
    else:
        print("PASS: 反证成立——漏写该列就会误清")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
