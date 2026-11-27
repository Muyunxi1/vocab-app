#!/usr/bin/env python
"""P0 / P1 / P2 修复的回归契约。

第三方报告 P1-10 指出：已有 6 个脚本全绿，但 CSV 往返和备份文章仍是坏的，
因为它们只测了切分函数，没测字段映射和恢复范围。这里补两类断言：

  1. 语义层：按表头映射列，释义落在 definition 而不是第 2 列；
  2. 源码层：锁住本轮修复的关键形态，防止改回去。

用法：python tool/verify_p0_contract.py
退出码：0 全通过；1 有断言失败
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.path.join(ROOT, "lib", "api.dart")
BOOK_DETAIL = os.path.join(ROOT, "lib", "pages", "book_detail.dart")
ADD_WORDS = os.path.join(ROOT, "lib", "pages", "add_words.dart")
HOME = os.path.join(ROOT, "lib", "pages", "home.dart")
REVIEW = os.path.join(ROOT, "lib", "pages", "review.dart")
OCR = os.path.join(ROOT, "lib", "ocr.dart")
ARTICLE_PAGE = os.path.join(ROOT, "lib", "pages", "article_page.dart")
SPEECH = os.path.join(ROOT, "lib", "speech.dart")


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def split_line(line, delim=","):
    cells, buf, in_quote, i = [], [], False, 0
    while i < len(line):
        ch = line[i]
        if in_quote:
            if ch == '"':
                if i + 1 < len(line) and line[i + 1] == '"':
                    buf.append('"')
                    i += 1
                else:
                    in_quote = False
            else:
                buf.append(ch)
        elif ch == '"':
            in_quote = True
        elif ch == delim:
            cells.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
        i += 1
    cells.append("".join(buf))
    return cells


def split_records(text):
    out, buf, in_quote, i = [], [], False, 0
    while i < len(text):
        ch = text[i]
        if ch == '"':
            if in_quote and i + 1 < len(text) and text[i + 1] == '"':
                buf.append('""')
                i += 2
                continue
            in_quote = not in_quote
            buf.append(ch)
        elif not in_quote and ch in "\r\n":
            if ch == "\r" and i + 1 < len(text) and text[i + 1] == "\n":
                i += 1
            out.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
        i += 1
    if buf:
        out.append("".join(buf))
    return out, in_quote


EXPORT_SAMPLE = (
    'spelling,phonetic,definition,forms,failCount,fuzzyCount,mastered\r\n'
    'abandon,/əˈbændən/,"v. 放弃\nn. 放纵",abandoned,3,1,0\r\n'
    'ability,/əˈbɪləti/,n. 能力,,1,0,0\r\n'
)


def normalize_header(name):
    return "spelling" if name == "word" else name.lower()


def map_row_by_header(cells, header):
    row = {}
    for i, key in enumerate(header):
        if i < len(cells):
            row[normalize_header(key)] = cells[i]
    return row


def main():
    failed = []
    ok = []

    def check(name, cond, detail=""):
        if cond:
            ok.append(name)
        else:
            failed.append(name + ("：" + detail if detail else ""))

    # ---------- 1. 语义：按表头取释义，而不是固定第 2 列 ----------
    records, still_open = split_records(EXPORT_SAMPLE)
    if len(records) != 3:
        check("导出样本可切回 3 条记录", False, "实际 %d 条" % len(records))
    else:
        header = split_line(records[0])
        row = map_row_by_header(split_line(records[1].replace("\n", "\\n")), header)
        # 真实实现里引号内换行会保留，这里把换行还原成 \n 只为打印
        raw_cells = split_line(records[1])
        row_raw = map_row_by_header(raw_cells, header)
        check("表头首列是 spelling", header[0] == "spelling", header[:3])
        check("按表头取到 definition", (row_raw.get("definition") or "").startswith("v. 放弃"), repr(row_raw.get("definition")))
        check("按表头取到 phonetic", row_raw.get("phonetic") == "/əˈbændən/", repr(row_raw.get("phonetic")))
        # 对照：旧的 cells[1] 当释义就是错的
        check("旧写法 cells[1] 确实不是释义", raw_cells[1] != "v. 放弃", repr(raw_cells[1]))

    api = read(API)
    check("importCsv 有表头映射", "header['spelling']" in api or "header['word']" in api)
    check("importCsv 不再写死 cells[1] 当释义", "cells[1]" not in api.split("Future<ImportResult> importCsv")[-1][:6000])

    # ---------- 2. 备份：导出与恢复都要覆盖文章 ----------
    # exportJson 是流式写法，函数体里有一层层嵌套的 }，用非贪婪正则抓会被第一个
    # 缩进两格的 } 提前截断，把 articles 和 version 拦在命中范围外。改成按
    # 「下一个顶层方法」定位，取完整函数体。
    start = api.find('Future<String> exportJson')
    end = api.find('\n  Future<', start + 1) if start >= 0 else -1
    seg = api[start:end] if start >= 0 and end > start else ""
    check("exportJson 存在", bool(seg))
    # 流式实现里各表是通过 writeRows('表名', ...) 逐个写出的，不是拼一个 Map 字面，
    # 所以按 writeRows 的调用断言；version 也是直接写的 "version":8。
    check("exportJson 导出 articles", re.search(r"writeRows\(\s*'articles'", seg) is not None)
    check("exportJson 导出 article_sentences",
          re.search(r"writeRows\(\s*'article_sentences'", seg) is not None)
    check("exportJson 版本升到 8", re.search(r'"version":\s*8', seg) is not None, seg[:120])
    check("importJson 恢复 articles", "rowsOf('articles'" in api)
    check("importJson 恢复 article_sentences", "rowsOf('article_sentences'" in api)
    check("importJson 有坏行计数", "badRows" in api)
    check("importJson 按列白名单重建", "columns = <String, List<String>>{" in api)
    check("大备份解析走后台 isolate", "_decodeBackupText" in api)

    # ---------- 3. 删除要清孤儿 ----------
    m = re.search(r"Future<void> deleteBook\(.*?\n  \}", api, re.S)
    seg = m.group(0) if m else ""
    check("deleteBook 清 article_sentences", "article_sentences" in seg)
    check("deleteBook 清 articles", "'articles'" in seg or "articles " in seg)
    check("deleteBook 清 reviews", "'reviews'" in seg)

    # ---------- 4. 掌握语义 ----------
    m = re.search(r"Future<int> setMasteredBatch\(.*?\n  \}", api, re.S)
    seg = m.group(0) if m else ""
    check("setMasteredBatch 置空 next_review_at", "next_review_at = NULL" in seg)

    # ---------- 5. 加词与计数 ----------
    check("addWord 支持 countAsFail", "countAsFail" in api)
    check("is_edited 按释义是否为空", re.search(r"is_edited.*isEmpty", api, re.S) is not None)
    home = read(HOME)
    check("首页加词传 countAsFail: true", "countAsFail: true" in home)
    check("首页加词防重入", re.search(r"if \(_quickBusy\) return", home) is not None)

    # ---------- 6. 语音 ----------
    # 有道在线合成（要用户自己申请私钥并开通服务）已下线，实现与音色表一并删除，
    # 所以这里改锁剩下那一路在线语音——词典词条真人发音——的缓存与拆词形态。
    speech = read(SPEECH)
    check("词典真人发音有本地缓存", "_dictCacheFile" in speech)
    check("词典发音缓存校验文件长度", "1024" in speech)
    check("长句按词拆开再逐个播", "_dictWords" in speech and "_dictPath" in speech)
    check("已下线的在线合成不留入口", "modeOnline" not in speech)

    # 听全文：系统语音从不碰 AudioPlayer，用 _player.state 当等待条件等于整段跳过，
    # 默认语音来源下就只剩最后一块有声音。这里锁住「按模式分支 + 令牌 + 超时」三条。
    m = re.search(r"Future<bool> speakAndWait\(.*?\n  \}", speech, re.S)
    seg = m.group(0) if m else ""
    check("听全文等待按语音模式分支", "modeDict" in seg and "done.isCompleted" in seg, seg[:80])
    check("听全文不再拿播放器状态当等待条件", "_player.state" not in seg)
    check("听全文等待有超时预算", "_waitBudget" in seg and "timeout(" in seg)
    check("听全文等待带取消令牌", "_waitSeq" in speech and "token != _waitSeq" in seg)

    # ---------- 7. 界面与稳定性 ----------
    check("复习队列有批量上限", "_reviewBatch" in read(REVIEW))
    check("拍照结果用 summary", "result.summary" in read(ADD_WORDS) or "_result!.summary" in read(ADD_WORDS))
    check("编辑弹窗可滚动", "SingleChildScrollView" in read(BOOK_DETAIL))
    check("文章页 dispose 停朗读", "dispose" in read(ARTICLE_PAGE))
    check("OCR 有停用词表", "_stopWords" in read(OCR))

    if ok:
        for name in ok:
            print("PASS: " + name)
    if failed:
        for name in failed:
            print("FAIL: " + name)
        print("\n%d 项通过，%d 项失败" % (len(ok), len(failed)))
        return 1
    print("\n全部 %d 项通过" % len(ok))
    return 0


if __name__ == "__main__":
    sys.exit(main())
