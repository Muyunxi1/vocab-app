import 'package:vocab_app/wordform.dart';

/// 临时校验：变形词能否推出词典里真实存在的原形。
/// 用法：dart run tool/_verify_lemma_tmp.dart
void main() {
  const words = [
    'minutes',
    'remnants',
    'marvels',
    'evokes',
    'responding',
    'expressing',
  ];
  for (final w in words) {
    print('$w -> ${lemmaCandidates(w)}');
  }
}
