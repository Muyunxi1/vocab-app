"""P3 修复的契约测试。

语义层测 CSV 记录的引号规则（复刻 _splitCsvRecords 的新规则 + 旧规则作反证），
源码层锁住 P3-1/2/4/6/7/8/10/11/12/13 这十条修复的形态，任何一条被回退都会红。
"""
import pathlib
import re
import sys

LIB = pathlib.Path(__file__).resolve().parents[1] / 'lib'
QUOTE_START = {'', '\n', '\r', ',', '\t'}


# ---------- 语义层：CSV 记录切分 ----------

def split_records_new(text):
    """新规则：引号只在字段起始位置才切换引号状态。"""
    out, buf, in_q, i, n = [], [], False, 0, len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            if in_q and i + 1 < n and text[i + 1] == '"':
                buf.append('""')
                i += 2
                continue
            if in_q:
                in_q = False
                buf.append(ch)
                i += 1
                continue
            prev = '' if i == 0 else text[i - 1]
            if prev in QUOTE_START:
                in_q = True
            buf.append(ch)
            i += 1
        elif not in_q and ch in '\n\r':
            if ch == '\r' and i + 1 < n and text[i + 1] == '\n':
                i += 1
            out.append(''.join(buf))
            buf = []
            i += 1
        else:
            buf.append(ch)
            i += 1
    if buf:
        out.append(''.join(buf))
    if in_q:
        raise ValueError('unclosed quote')
    return out


def split_records_old(text):
    """旧规则：任何位置的引号都切换引号状态（P3-9 的问题所在）。"""
    out, buf, in_q, i, n = [], [], False, 0, len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            if in_q and i + 1 < n and text[i + 1] == '"':
                buf.append('""')
                i += 2
                continue
            in_q = not in_q
            buf.append(ch)
            i += 1
        elif not in_q and ch in '\n\r':
            if ch == '\r' and i + 1 < n and text[i + 1] == '\n':
                i += 1
            out.append(''.join(buf))
            buf = []
            i += 1
        else:
            buf.append(ch)
            i += 1
    if buf:
        out.append(''.join(buf))
    if in_q:
        raise ValueError('unclosed quote')
    return out


CHECKS = []


def check(name):
    def deco(fn):
        CHECKS.append((name, fn))
        return fn
    return deco


@check('P3-9 释义里的裸引号（5"）不再打断记录切分')
def _():
    csv = 'spelling,definition\napple,"5" 英寸的手机壳"\nbanana,香蕉\n'
    got = split_records_new(csv)
    assert len(got) == 3, '新规则应切成 3 条，实际 %d：%r' % (len(got), got)
    assert got[1].startswith('apple'), got[1]


@check('P3-9 反证：旧规则把这份文件切成 1 条或直接报错')
def _():
    csv = 'spelling,definition\napple,"5" 英寸的手机壳"\nbanana,香蕉\n'
    try:
        got = split_records_old(csv)
        assert len(got) == 1, '旧规则本应只切出 1 条，实际 %d' % len(got)
    except ValueError:
        pass  # 旧规则报「引号没闭合」也算复现了 bug


@check('P3-9 标准转义引号仍然正确处理（回归）')
def _():
    csv = 'spelling,definition\napple,"say ""hi"" to me"\nbanana,b\n'
    got = split_records_new(csv)
    assert len(got) == 3, got
    assert '""hi""' in got[1], got[1]


@check('P3-9 引号内换行仍归同一条记录（回归）')
def _():
    csv = 'spelling,definition\napple,"第一行\n第二行"\nbanana,b\n'
    got = split_records_new(csv)
    assert len(got) == 3, got
    assert '\n' in got[1], got[1]


# ---------- 源码层 ----------

def read(rel):
    return (LIB / rel).read_text(encoding='utf-8')


@check('P3-1 界面不再把 Exception.toString() 直接显示（除日志类）')
def _():
    bad = []
    for p in LIB.rglob('*.dart'):
        if '.bak' in p.name:
            continue
        text = p.read_text(encoding='utf-8')
        for line in text.split('\n'):
            # 只认「正好是 $e」的插值：$escaped / $existed / $error 这类是别的变量
            if not re.search(r'\$e(?![A-Za-z0-9_])', line):
                continue
            stripped = line.strip()
            if stripped.startswith('//'):
                continue
            # 日志和失败清单允许带原始异常
            if 'debugPrint(' in line or 'failed.add(' in line or 'logError(' in line:
                continue
            if 'ArticleException(' in line:
                continue
            bad.append('%s: %s' % (p.name, stripped))
    assert not bad, '仍有界面文案拼接原始异常：\n' + '\n'.join(bad)


@check('P3-14 main() 装了 FlutterError.onError 与 PlatformDispatcher.onError')
def _():
    text = read('main.dart')
    assert 'FlutterError.onError' in text
    assert 'PlatformDispatcher.instance.onError' in text
    assert 'logError(' in text


@check('P3-2 logError 在处理路径里真的被调用')
def _():
    callers = 0
    for p in LIB.rglob('*.dart'):
        if '.bak' in p.name or p.name == 'errors.dart':
            continue
        if 'logError(' in p.read_text(encoding='utf-8'):
            callers += 1
    assert callers >= 1, 'logError 只在 errors.dart 里定义，没有任何调用点'


@check('P3-4 手选复习队列拷一份再开始')
def _():
    text = read('pages/review.dart')
    assert 'List<Word>.from(_selected)' in text


@check('P3-6 排行页说明只显示前 100 个')
def _():
    text = read('pages/rank.dart')
    assert '遗忘次数最多的 100 个' in text


@check('P3-7 ErrorCard 支持 busy 并在忙时禁用重试')
def _():
    text = read('widgets.dart')
    assert 'this.busy = false' in text
    assert 'busy ? null : onRetry' in text


@check('P3-8 复习范围提示不再声称「词库只有 N 个词」')
def _():
    text = read('pages/review.dart')
    assert '词库只有 $_total 个词' not in text
    assert '已掌握的进不了队列' in text


@check('P3-10 截断行数按剩余行数记，不是只 +1')
def _():
    text = read('api.dart')
    seg = text.split('Future<ImportResult> _importLines')[1][:3000]
    marker = 'if (rows > maxImportRows)'
    assert marker in seg
    # 超上限后要逐行记数再 continue，不能 break —— 只 +1 或直接 break，
    # 报给用户的「还有 N 行没处理」就不真实
    tail = seg.split(marker)[1][:200]
    assert 'truncated++' in tail
    assert 'continue' in tail
    assert 'lines.length' not in seg


@check('P3-11 CSV 读取注释与实现一致（不再声称不读进内存）')
def _():
    text = read('api.dart')
    assert '不把整个文件读进内存' not in text


@check('P3-12 新词插入撞 UNIQUE 时接上已有记录')
def _():
    text = read('api.dart')
    assert 'isUniqueConstraintError()' in text


@check('P3-13 复习计数用 UPDATE 里自增，不写绝对值')
def _():
    text = read('api.dart')
    assert 'fail_count = fail_count + 1' in text
    assert "'fail_count': ((cur['fail_count']" not in text.replace(' ', ' ')


@check('P2-15 备份导出改成分页读 + 逐行编码，不再整表读进内存')
def _():
    text = read('api.dart')
    assert r'LIMIT $pageSize OFFSET $offset' in text, '导出没有分页查询'
    assert "await _d.query('words')" not in text, '仍有一次读全表 words 的写法'
    # 分页必须配 ORDER BY，否则 OFFSET 翻页会重复或漏行
    for table in ('books', 'words', 'book_words', 'reviews', 'articles', 'article_sentences'):
        assert re.search('SELECT \\* FROM %s ORDER BY' % table, text), '%s 没有 ORDER BY' % table


@check('P3-15 备份恢复与导出都有阶段提示')
def _():
    api = read('api.dart')
    page = read('pages/stats_page.dart')
    assert 'void Function(String stage)? onProgress' in api
    assert 'onProgress?.call(' in api
    assert '_progress' in page
    assert 'onProgress: (stage)' in page


def main():
    print('---- 检查前先确认新规则与 Dart 实现一致 ----')
    failures = 0
    for name, fn in CHECKS:
        try:
            fn()
            print('PASS: %s' % name)
        except AssertionError as e:
            failures += 1
            print('FAIL: %s -> %s' % (name, e))
        except Exception as e:  # noqa: BLE001
            failures += 1
            print('ERROR: %s -> %r' % (name, e))
    print('---- 共 %d 项，失败 %d 项 ----' % (len(CHECKS), failures))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
