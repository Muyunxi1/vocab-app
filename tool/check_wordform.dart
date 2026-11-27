// 临时校验脚本：确认词形还原给出的候选符合预期。
// 只打印候选，不查库；是否采用由 api.dart 回查词典决定。
import '../lib/wordform.dart';

void main() {
  const samples = <String>[
    'experiencing',
    'has',
    'continued',
    'expanding',
    'covering',
    'studies',
    'stopped',
    'running',
    'children',
    'went',
    'nguez',
    'Alzheimer',
    'therapy',
  ];
  for (final word in samples) {
    print('$word -> ${lemmaCandidates(word)}');
  }
}
