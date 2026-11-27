// 词形还原回归：拿词典自带的 forms 映射逐条跑 lemmaCandidates，统计准确率。
//
// 用法：
//   dart run tool/check_lemma_coverage.dart <dict_words.txt> <forms_map.tsv>
//
// 期望：还原错误条数为 0，查不到条数尽量低。
import 'dart:io';

import 'package:vocab_app/wordform.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('用法: dart run tool/check_lemma_coverage.dart <dict_words.txt> <forms_map.tsv>');
    exit(2);
  }

  final words = File(args[0])
      .readAsLinesSync()
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toSet();
  stdout.writeln('词典条目 ${words.length}');

  final lines = File(args[1]).readAsLinesSync();

  var right = 0;
  var none = 0;
  var wrong = 0;
  final wrongSamples = <String>[];
  final noneSamples = <String>[];

  for (final line in lines) {
    final parts = line.split('\t');
    if (parts.length < 2) continue;
    final token = parts[0].trim().toLowerCase();
    final lemma = parts[1].trim().toLowerCase();
    if (token.isEmpty || lemma.isEmpty) continue;
    if (token == lemma) continue;
    // 变形词本身在词典里有独立条目时走精确匹配，不经过回退，不计入
    if (words.contains(token)) continue;

    final candidates = lemmaCandidates(token);

    // 新 lookup 的裁决顺序：候选里若出现「词典 forms 字段写明的真原形」，必选中它。
    // forms_map.tsv 的每一行都来自 forms 字段，所以 lemma 就是那个真原形。
    if (candidates.contains(lemma) && words.contains(lemma)) {
      right++;
      continue;
    }

    // 真原形不在候选里，只能退回「第一个能在词典命中的候选」，这一档才可能给错释义
    var first = '';
    for (final c in candidates) {
      if (words.contains(c)) {
        first = c;
        break;
      }
    }

    if (first.isEmpty) {
      none++;
      if (noneSamples.length < 12) noneSamples.add('$token (原形 $lemma)');
    } else {
      wrong++;
      if (wrongSamples.length < 12) {
        wrongSamples.add('$token (原形 $lemma) -> 误还原成 $first');
      }
    }
  }

  final total = right + none + wrong;
  String pct(num v) =>
      total == 0 ? '0.0' : (v * 100 / total).toStringAsFixed(1);

  stdout.writeln('需要回退的变形词 $total');
  stdout.writeln('  还原正确 $right (${pct(right)}%)');
  stdout.writeln('  还原错误 $wrong (${pct(wrong)}%)');
  stdout.writeln('  查不到   $none (${pct(none)}%)');
  if (wrongSamples.isNotEmpty) {
    stdout.writeln('\n误还原样例:');
    for (final s in wrongSamples) {
      stdout.writeln('  $s');
    }
  }
  if (noneSamples.isNotEmpty) {
    stdout.writeln('\n查不到样例:');
    for (final s in noneSamples) {
      stdout.writeln('  $s');
    }
  }

  // 还原错误必须是 0，否则退出码非 0，便于 CI / 手工校验
  exit(wrong == 0 ? 0 : 1);
}
