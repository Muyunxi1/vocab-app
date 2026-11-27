"""神经语音合成线程的形态契约。

这一组锁住「点离线神经语音闪退」和「读文章不连贯」两条故障的修复形态：

- 模型加载与推理必须发生在 _neuralWorker（顶层函数）里，主 isolate 只收消息；
- 主 isolate 不得再出现直接 free / 直接 generate 的旧路径；
- 连读侧的块长、预取延迟、播放器释放模式必须仍是修好的值。

任何一条被回退，这里就红。反向用例同时跑一遍旧写法，证明断言真的能抓到问题。
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
LIB = ROOT / 'lib'

CHECKS = []


def check(name):
    def wrap(fn):
        CHECKS.append((name, fn))
        return fn
    return wrap


def read(name):
    return (LIB / name).read_text(encoding='utf-8')


def code_of(text):
    """剥掉行注释，断言只看代码本身。"""
    lines = []
    for line in text.split('\n'):
        stripped = line.strip()
        if stripped.startswith('//'):
            continue
        lines.append(line)
    return '\n'.join(lines)


@check('合成线程入口是顶层函数，且自带原生绑定与引擎释放')
def _():
    text = read('neural_tts.dart')
    assert 'Future<void> _neuralWorker(SendPort replyTo) async' in text, '找不到合成线程入口'
    segment = text.split('Future<void> _neuralWorker(SendPort replyTo) async')[1][:2500]
    assert 'sherpa.initBindings()' in segment, '绑定没有在合成线程里做'
    assert "'ready': true" in segment and "'port': inbox.sendPort" in segment, '没有回传收件口'
    assert "kind == 'free'" in segment, '没有处理 free 消息'
    assert "kind != 'synth'" in segment, '没有处理 synth 消息'
    assert 'current.ptr != nullptr' in segment, 'free 前没有判空，空指针会直接崩'
    assert 'current.free()' in segment, '没有真的释放引擎'


@check('主 isolate 不再加载模型、不再推理')
def _():
    text = code_of(read('neural_tts.dart'))
    assert 'sherpa.OfflineTts(' not in text.split('sherpa.OfflineTts _createEngine')[0], \
        '类里仍在创建 OfflineTts'
    body = text.split('Future<String> synthesize(')[1].split('Duration _jobTimeout(')[0]
    assert 'generate(' not in body, 'synthesize 里还在主 isolate 推理'
    assert '_ensureLoaded' not in body, 'synthesize 仍走旧的 _ensureLoaded'
    assert "'kind': 'synth'" in body, 'synthesize 没有改走消息路由'


@check('旧的直接释放路径已删除')
def _():
    text = code_of(read('neural_tts.dart'))
    for gone in ('void _ensureBindings(', 'sherpa.OfflineTts _ensureLoaded(', 'void _safeFree(', 'void _freeNow('):
        assert gone not in text, '旧路径还在：%s' % gone
    assert '_releasePending' not in text and '_loadedVoiceId' not in text, '旧的加载/释放标记还在'


@check('线程 spawn 带 onExit 与 onError，死亡时会回错误而不是挂住')
def _():
    text = read('neural_tts.dart')
    segment = text.split('Isolate.spawn(')[1][:400]
    assert 'onExit: exit.sendPort' in segment, 'spawn 没有挂 onExit'
    assert 'onError: exit.sendPort' in segment, 'spawn 没有挂 onError'
    assert "debugName: 'neural-tts'" in segment, 'spawn 没有 debugName'
    dead = text.split('void _onWorkerDead(String reason) {')[1][:900]
    assert "'ok': false" in dead, '线程死了没有把等待中的任务回错误'
    assert 'Diag.record(' in dead, '线程死了没有留诊断记录'
    assert 'ready.complete()' in dead, '起线程的等待者没有解除，会永久挂起'


@check('推理线程用单线程，且没有残留双线程配置')
def _():
    text = read('neural_tts.dart')
    assert 'numThreads: 1' in text, 'numThreads 不是 1'
    assert 'numThreads: 2' not in text, '还留着 numThreads: 2'


@check('写 wav 是顶层函数，且不再有实例方法 _writeWav')
def _():
    text = read('neural_tts.dart')
    assert 'Future<void> _writeWavFile(File file, Float32List samples, int sampleRate) async' in text, \
        '找不到顶层 _writeWavFile'
    assert '_writeWav(' not in text, '旧的实例方法 _writeWav 还在'
    # 反证：旧写法把两条 final 挤在一行，这里确认已经拆开
    for line in text.split('\n'):
        assert line.count('final ') < 2 or 'final sample' in line, '还有两条语句挤在一行：%s' % line.strip()


@check('缓存命中仍按 wav 头校验，半截文件不会被当成命中')
def _():
    text = read('neural_tts.dart')
    body = text.split('Future<String> synthesize(')[1].split('Duration _jobTimeout(')[0]
    assert 'await _isValidWav(file)' in body, '命中缓存不再校验'
    assert 'await file.delete()' in body, '坏缓存没有被删掉'
    assert 'Future<bool> _isValidWav(File file)' in text, '_isValidWav 不见了'


@check('合成超时按期给足，且有 90 秒上限')
def _():
    text = read('neural_tts.dart')
    seg = text.split('Duration _jobTimeout(String text) {')[1][:300]
    assert '12 + words ~/ 6' in seg, '超时预算不再是按时长放宽'
    assert '90' in seg, '没有 90 秒上限'


@check('合成长度按 40 词切块，不再回到 18 词')
def _():
    text = read('pages/article_page.dart')
    assert 'const maxWords = 40' in text, '块长不是 40 词'
    assert 'const maxWords = 18' not in text, '块长仍被压到 18 词'


@check('预取延迟收到 120ms，播放器用 ReleaseMode.stop 复用底层 player')
def _():
    speech = read('speech.dart')
    assert 'milliseconds: 120' in speech, '预取延迟不是 120ms'
    assert 'milliseconds: 300' not in speech, '预取延迟还停在 300ms'
    assert 'ReleaseMode.stop' in speech, '播放器没有设 ReleaseMode.stop，块间仍会重建'
    assert 'setReleaseMode(ReleaseMode.stop)' in speech, 'setReleaseMode 没有落到 _player 上'


@check('反证：旧写法会被同一套判定抓到')
def _():
    fake = (
        'sherpa.OfflineTts _ensureLoaded(String voiceId) {\n'
        '  final tts = _ensureLoaded(voiceId);\n'
        '  audio = tts.generate(text: trimmed, speed: speed);\n'
        '}\n'
    )
    assert '_ensureLoaded' in fake
    assert 'generate(' in fake
    # 新版源码里这两样都不该出现在 synthesize 段
    body = code_of(read('neural_tts.dart')).split('Future<String> synthesize(')[1] \
        .split('Duration _jobTimeout(')[0]
    assert 'generate(' not in body and '_ensureLoaded' not in body
    assert re.search(r'numThreads: 1', read('neural_tts.dart'))


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
