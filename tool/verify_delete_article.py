#!/usr/bin/env python
"""「删除文章」契约测试。

两个要点：
  1. 删文章必须连带删它的逐句记录，否则 article_sentences 会留孤儿行；
  2. api.dart 的 deleteArticle 里两条 DELETE 必须都在，不能只删父表。

这里用同构 sqlite 验证「同事务删父表 + 子表」的结果，再用正则确认 Dart 实现
里确实写了这两条 DELETE，防止只改了 UI 却没删子表。

用法：python tool/verify_delete_article.py
退出码：0 通过；1 缺方法 / 只删了父表 / 留下孤儿
"""
import os
import re
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.path.join(ROOT, "lib", "api.dart")


def build_db():
    c = sqlite3.connect(":memory:")
    # 关掉 python 的隐式事务，下面才能显式 BEGIN
    c.isolation_level = None
    c.executescript(
        """
        CREATE TABLE articles(id TEXT PRIMARY KEY, book_id TEXT, title TEXT,
          body TEXT, created_at TEXT);
        CREATE TABLE article_sentences(article_id TEXT NOT NULL, idx INTEGER NOT NULL,
          en TEXT NOT NULL, zh TEXT, parse_json TEXT, PRIMARY KEY(article_id, idx));
        """
    )
    for aid in ("a1", "a2"):
        c.execute(
            "INSERT INTO articles VALUES(?,?,?,?,?)",
            (aid, "b1", "11 月 15 日 · 5 词", "body of " + aid, "2026-11-15"),
        )
        for i in range(3):
            c.execute(
                "INSERT INTO article_sentences VALUES(?,?,?,?,?)",
                (aid, i, "sentence %d of %s" % (i, aid), None, None),
            )
    return c


def simulate(c, victim):
    """同事务删掉 victim：先子表，后父表。"""
    try:
        c.execute("BEGIN")
        c.execute("DELETE FROM article_sentences WHERE article_id = ?", (victim,))
        c.execute("DELETE FROM articles WHERE id = ?", (victim,))
        c.commit()
    except Exception:
        c.rollback()
        raise


def main():
    failed = False

    # --- 数据结果 ---
    c = build_db()
    simulate(c, "a1")
    arts = [r[0] for r in c.execute("SELECT id FROM articles").fetchall()]
    orphan = c.execute(
        "SELECT COUNT(*) FROM article_sentences s "
        "LEFT JOIN articles a ON a.id = s.article_id WHERE a.id IS NULL"
    ).fetchone()[0]
    kept = c.execute(
        "SELECT COUNT(*) FROM article_sentences WHERE article_id = 'a2'"
    ).fetchone()[0]
    gone = c.execute(
        "SELECT COUNT(*) FROM article_sentences WHERE article_id = 'a1'"
    ).fetchone()[0]

    if arts != ["a2"]:
        print("FAIL: 删除后文章列表应为 ['a2']，实际 %s" % arts)
        failed = True
    elif gone != 0:
        print("FAIL: 被删文章的逐句没清干净，剩 %d 条" % gone)
        failed = True
    elif orphan != 0:
        print("FAIL: 留有 %d 条无归属的句子行" % orphan)
        failed = True
    elif kept != 3:
        print("FAIL: 另一篇文章的逐句被误删，只剩 %d 条" % kept)
        failed = True
    else:
        print("PASS: 删 a1 后剩 a2 的 3 句，无孤儿行")

    # --- Dart 实现形态 ---
    if not os.path.exists(API):
        print("FAIL: 找不到 lib/api.dart")
        return 1
    with open(API, encoding="utf-8", errors="replace") as f:
        text = f.read()

    m = re.search(r"deleteArticle\s*\((.*?)\n  \}", text, re.S)
    if not m:
        print("FAIL: api.dart 里没有 deleteArticle 方法")
        return 1
    body = m.group(1)
    if not re.search(r"delete\(\s*'article_sentences'", body):
        print("FAIL: deleteArticle 没有删 article_sentences，会留孤儿行")
        failed = True
    elif not re.search(r"delete\(\s*'articles'", body):
        print("FAIL: deleteArticle 没有删 articles 本身")
        failed = True
    elif "transaction" not in body:
        print("FAIL: deleteArticle 的两条 DELETE 没有放在同一事务里")
        failed = True
    else:
        print("PASS: deleteArticle 在事务里删了父表和子表")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
