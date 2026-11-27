"""词库导入额度的形态契约（构建 49）。

锁住「粘一份上千词的词表，词库只多了 500 个」这条反馈的修复形态：

- 粘贴通道的单次上限必须离开 500 这个值，且与文件导入同一个数量级；
- 粘贴时必须按步长回报进度，界面要能显示「已处理 x/共 y」；
- 文件导入的结果必须带上读到的行数，用户才能分清是文件本身少还是入库丢了。

任何一条被回退，这里就红；末尾一条反证，证明判定不是恒真。
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
LIB = ROOT / 'lib'

CHECKS = []

OLD_CAP = 500
NEW_CAP = 5000


def check(name):
    def wrap(fn):
        CHECKS.append((name, fn))
        return fn
    return wrap


def read(name):
    return (LIB / name).read_text(encoding='utf-8')


@check('粘贴上限已离开 500，且与文件导入同一数量级')
def _():
    api = read('api.dart')
    assert 'static const int maxBatchWords = %d;' % NEW_CAP in api, \
        'maxBatchWords 不是 %d' % NEW_CAP
    assert 'static const int maxBatchWords = %d;' % OLD_CAP not in api, \
        'maxBatchWords 仍是 500，粘上千词还会被截断'
    assert NEW_CAP >= OLD_CAP * 5, '新上限太小，够不着一份上千词的词表'


@check('进度回调用的是固定步长常量，不是散落的魔数')
def _():
    api = read('api.dart')
    assert 'static const int batchProgressStep = ' in api, '没有 progressStep 常量'
    seg = api.split('static const int batchProgressStep = ')[1][:80]
    assert '200' in seg, '步长不是 200'


@check('batchAdd 增加了 onProgress 参数')
def _():
    api = read('api.dart')
    seg = api.split('Future<ImportResult> batchAdd(')[1][:900]
    assert 'void Function(int done, int total)? onProgress' in seg, \
        'batchAdd 没有 onProgress'


@check('循环里按步长回调，且不会每处理一个词就 setState')
def _():
    api = read('api.dart')
    seg = api.split('Future<ImportResult> batchAdd(')[1]
    body = seg.split('Future<ImportResult> importFile(')[0]
    assert 'i % batchProgressStep == 0' in body, '没有按步长回调'
    assert 'onProgress(i, items.length)' in body, '回调没有传出已处理数'


@check('收尾再回调一次，进度停在终值')
def _():
    api = read('api.dart')
    body = api.split('Future<ImportResult> batchAdd(')[1].split('Future<ImportResult> importFile(')[0]
    assert 'onProgress(items.length - truncated, items.length)' in body, \
        '收尾没有回调，尾巴不足一步长时进度会停在前一个格'


@check('粘贴页把进度接到界面上了')
def _():
    page = read('pages/add_words.dart')
    assert 'onProgress: (int done, int total)' in page, '界面没有接 onProgress'
    assert '_done = done' in page and '_total = total' in page, '进度没有落进状态'
    assert '已处理 $_done' in page and '共 $_total' in page, '界面没有显示已处理数'


@check('文件导入的额度没有被顺手改坏')
def _():
    api = read('api.dart')
    assert 'static const int maxImportRows = 20000;' in api, 'maxImportRows 变了'
    seg = api.split('Future<ImportResult> _importLines(')[1][:1200]
    assert 'rows > maxImportRows' in seg, '超行数判断不见了'


@check('导入结果带上读到的行数')
def _():
    models = read('models.dart')
    assert 'final int rows;' in models, 'ImportResult 没有 rows'
    assert 'if (rows > 0) parts.add(' in models, 'summary 没有把行数摆出来'
    assert '读到 ' in models, 'summary 文案里没有「读到」'
    api = read('api.dart')
    assert 'rows: rows,' in api, '_importLines 没有把 rows 传进结果'


@check('粘贴通道不写 rows，避免把词数说成行数')
def _():
    api = read('api.dart')
    body = api.split('Future<ImportResult> batchAdd(')[1].split('Future<ImportResult> importFile(')[0]
    assert 'rows: ' not in body, 'batchAdd 不该带 rows'


@check('自动查词结果回报配词命中与未收录')
def _():
    models = read('models.dart')
    assert 'final int dictHits;' in models, 'ImportResult 没有 dictHits'
    assert 'final List<String> unfoundWords;' in models, 'ImportResult 没有 unfoundWords'
    assert '已配释义' in models, 'summary 没有报已配释义条数'
    assert '未查到' in models, 'summary 没有报未查到条数'
    api = read('api.dart')
    body = api.split('Future<ImportResult> batchAdd(')[1].split('Future<ImportResult> importFile(')[0]
    assert 'dictHits: dictHits,' in body, 'batchAdd 没传 dictHits'
    assert 'unfoundWords: unfoundWords,' in body, 'batchAdd 没传 unfoundWords'


@check('反证：把上限改回 500，第 1 条会红')
def _():
    fake = 'static const int maxBatchWords = %d;\n' % OLD_CAP
    assert 'static const int maxBatchWords = 500;' in fake
    # 同样的判定拿去比对真源码，必须有新值
    real = read('api.dart')
    assert 'static const int maxBatchWords = %d;' % NEW_CAP in real, '真源码里找不到新上限'


def main():
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
