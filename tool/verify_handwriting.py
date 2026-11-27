"""手写录入板的契约测试。

锁住这条功能的形态：主页入口可达、页面自带词库选择、笔画矢量先走数字墨水引擎，
没认出再回退现有截图 OCR；结果经勾选/手动核对后才入库。
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
LIB = ROOT / 'lib'
PAGE = LIB / 'pages' / 'handwriting_page.dart'
HOME = LIB / 'pages' / 'home.dart'
OCR = LIB / 'ocr.dart'
INK = LIB / 'digital_ink.dart'
PUBSPEC = ROOT / 'pubspec.yaml'
# 手写板允许出现的 import：Flutter 自带、dart 核心、项目内模块、已有的 path。
ALLOWED_IMPORTS = {
    'dart:io',
    'dart:ui',
    'package:flutter/material.dart',
    'package:path/path.dart',
    '../api.dart',
    '../digital_ink.dart',
    '../errors.dart',
    '../models.dart',
    '../ocr.dart',
    '../theme.dart',
}

# 当前 pubspec dependencies 的基线包名；手写板功能不再另加未登记的包。
BASELINE_DEPS = {
    'flutter',
    'sqflite', 'path', 'file_picker', 'image_picker',
    'google_mlkit_text_recognition',
    'google_mlkit_digital_ink_recognition',
    'crypto', 'syncfusion_flutter_pdf',
    'flutter_tts', 'enough_convert', 'audioplayers', 'sherpa_onnx',
    'archive', 'path_provider',
}

CHECKS = []


def check(name):
    def deco(fn):
        CHECKS.append((name, fn))
        return fn
    return deco


def read(path):
    return path.read_text(encoding='utf-8')


@check('页面文件存在且能作为独立页面挂载')
def _():
    assert PAGE.exists(), 'handwriting_page.dart 不存在'
    text = read(PAGE)
    assert 'class HandwritingPage extends StatefulWidget' in text
    assert 'Scaffold(' in text


@check('主页加生词卡内有入口，独立卡片已移除')
def _():
    home = read(HOME)
    assert "import 'handwriting_page.dart';" in home, '主页没引入手写板页面'
    assert 'HandwritingPage(' in home, '主页没有跳转到 HandwritingPage'
    assert 'Navigator.of(context).push' in home
    assert '_buildHandEntry' not in home, '旧的独立卡片方法残留'
    assert '_openHandwriting' in home
    assert 'Icons.draw_outlined' in home
    assert "Text('手写'" in home, '入口图标旁缺中文提示'


@check('页面内自带目标词库下拉')
def _():
    text = read(PAGE)
    assert 'DropdownButton<String>' in text
    assert 'Api.instance.books()' in text
    assert '_bookId' in text


@check('画板用 Listener 采集笔画、CustomPaint 描边')
def _():
    text = read(PAGE)
    assert 'Listener(' in text
    assert 'onPointerDown' in text
    assert 'onPointerMove' in text
    assert 'onPointerCancel' in text
    assert 'CustomPaint(' in text
    assert '_BoardPainter' in text


@check('画板锁定单指针、裁剪越界并钳制坐标，避免墨块与串线')
def _():
    text = read(PAGE)
    assert '_activePointer' in text
    assert 'e.pointer' in text
    assert 'ClipRect' in text
    assert 'LayoutBuilder' in text
    assert '_clamp' in text


@check('画笔逐段描边、显式 stroke，不把整笔路径画成填充多边形')
def _():
    text = read(PAGE)
    assert 'PaintingStyle.stroke' in text
    assert 'canvas.drawLine' in text
    assert 'canvas.drawCircle' in text
    assert 'drawPath(' not in text, '仍在用整笔 Path 绘制，存在填充/成块风险'


@check('画板自绘图作为 OCR 兜底管线（数字墨水没认出时才走）')
def _():
    text = read(PAGE)
    assert 'RepaintBoundary' in text
    assert 'toImage' in text
    assert 'ImageByteFormat.png' in text
    assert 'Directory.systemTemp' in text
    assert 'Ocr.instance.scan(' in text


@check('识别双路：数字墨水矢量优先，未认出再回退截图 OCR')
def _():
    text = read(PAGE)
    assert 'DigitalInk.instance.ensureModel()' in text
    assert 'DigitalInk.instance.recognize(' in text
    assert 'Ocr.instance.scan(' in text
    ink = read(INK)
    assert 'class DigitalInk' in ink
    assert 'StrokePoint' in ink


@check('模型允许移动网络下载，失败抛可读异常，页面把引擎原因带到提示')
def _():
    ink = read(INK)
    assert 'isWifiRequired: false' in ink, '模型下载仍限定仅 Wi-Fi'
    assert 'class DigitalInkException' in ink
    text = read(PAGE)
    assert 'inkError' in text, '页面没保留手写引擎失败原因'
    assert 'humanizeError(e)' in text, '引擎异常被静默吞掉'


@check('橡皮按范围擦除：半径内点逐点剔除并把一笔切成多段，可切回画笔')
def _():
    text = read(PAGE)
    assert '_eraser' in text
    assert '_eraseAt' in text
    assert '_eraseRadius' in text
    assert "'橡皮'" in text


@check('工具栏为笔记软件形式：画笔/橡皮/清空，无撤销，粗细三档常驻，颜色仅画笔态')
def _():
    text = read(PAGE)
    assert "'撤销'" not in text, '撤销按钮应已移除'
    assert '_penWidth' in text and '_penColor' in text
    assert '_penSizes' in text and '_penColors' in text
    assert '_eraseSizes' in text and '_eraseRadius' in text
    assert "'画笔'" in text and "'橡皮'" in text
    # 第二行粗细/档位常驻，不能再按橡皮态整行收起导致卡片高度跳动
    assert 'if (!_eraser) ...[' not in text, '粗细行仍随工具整行收起'


@check('识别图自绘白底黑字、按包围盒放大，手写取词保留短词与功能词')
def _():
    text = read(PAGE)
    assert 'PictureRecorder' in text
    assert 'endRecording' in text
    assert '0xFFFFFFFF' in text
    assert 'keepStopWords: true' in text
    ocr = read(OCR)
    assert 'keepStopWords' in ocr


@check('识别结果先核对（勾选 + 手动兜底），不直接写库')
def _():
    text = read(PAGE)
    assert '_selected' in text
    assert '_manual' in text
    # 入库入参必须来自勾选集合与手动文本合并后的 words，不能把 scan.text 原样喂进去
    assert 'words.join' in text
    seg = text.split('Future<void> _submit()')[1][:1500]
    assert 'batchAdd(' in seg
    assert '_candidates[i].word' in seg
    assert '_manual.text' in seg


@check('候选默认只勾首选，可再勾选/取消；手动框留空仅作补词')
def _():
    text = read(PAGE)
    assert '_selected' in text
    assert 'ChoiceChip' in text
    assert 'onSelected' in text
    # 默认只勾索引 0（首选），不再全量 addAll；toggleAll 仍可全选。
    assert '..clear()' in text
    assert '[0]' in text
    assert '_manual.text = ' in text


@check('候选批量预查本地词典并在面板显示音标/释义或未收录')
def _():
    text = read(PAGE)
    assert 'lookupMany' in text, '识别后没有批量预查本地词典'
    assert '_lookupPreview' in text, '没有缓存候选词典预览'
    assert '_previewText' in text, '没有拼装候选预览文本'
    assert "'未收录'" in text, '查不到的候选没有标未收录'
    assert 'unfoundWords' in text, '结果区没有列出未收录词'



@check('页面没有引入新的第三方包')
def _():
    text = read(PAGE)
    imports = re.findall(r"^import '([^']+)'", text, re.MULTILINE)
    for imp in imports:
        base = imp.replace('.dart', '')
        assert imp in ALLOWED_IMPORTS or base in ALLOWED_IMPORTS, \
            '手写板引入了未登记依赖：%s' % imp
    # 画板落临时目录，不依赖 path_provider
    assert 'path_provider' not in text


@check('pubspec dependencies 对齐基线集合')
def _():
    pub = read(PUBSPEC)
    dep_block = pub.split('dependencies:')[1].split('dev_dependencies:')[0]
    deps = set(re.findall(r'^\s{2}([a-z0-9_]+):', dep_block, re.MULTILINE))
    assert deps == BASELINE_DEPS, '依赖集合变化：新增 %s，缺失 %s' % (
        deps - BASELINE_DEPS, BASELINE_DEPS - deps)


@check('离开页面释放控制器、识别器并清理临时截图')
def _():
    text = read(PAGE)
    assert 'void dispose()' in text
    assert '_manual.dispose()' in text
    assert 'DigitalInk.instance.close()' in text
    assert '_cleanShot()' in text
    assert '_shotPath' in text


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
