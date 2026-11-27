import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../speech.dart';

import '../theme.dart';
import '../errors.dart';
/// 查词页：输入任意单词看本地词典里的音标、释义和常用变形，不会加进词库。
class LookupPage extends StatefulWidget {
  const LookupPage({super.key});

  @override
  State<LookupPage> createState() => _LookupPageState();
}

class _LookupPageState extends State<LookupPage> {
  final _input = TextEditingController();
  Timer? _debounce;
  LookupResult? _result;
  bool _busy = false;
  String _lastQuery = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final q = value.trim();
    if (q.isEmpty) {
      setState(() {
        _result = null;
        _busy = false;
        _lastQuery = '';
      });
      return;
    }
    // 清空按钮要跟着有没有内容出现，这里得重建一次
    setState(() {});
    if (q == _lastQuery) return;
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(q));
  }

  Future<void> _search(String q) async {
    _debounce?.cancel();
    if (!mounted) return;
    setState(() => _busy = true);
    _lastQuery = q;
    try {
      final result = await Api.instance.lookup(q);
      // 输入已经改过或清空了，这次的结果作废，免得旧结果盖掉新的
      if (!mounted || q != _input.text.trim()) return;
      setState(() {
        _result = result;
        _busy = false;
      });
    } catch (e) {
      if (!mounted || q != _input.text.trim()) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(humanizeError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('查词', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _input,
              autofocus: true,
              autocorrect: false,
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              onSubmitted: (v) {
                final q = v.trim();
                if (q.isNotEmpty) _search(q);
              },
              decoration: InputDecoration(
                hintText: '输入英文单词',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _input.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _input.clear();
                          setState(() {
                            _result = null;
                            _lastQuery = '';
                          });
                        },
                      ),
                filled: true,
                fillColor: P.card,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: result == null
                ? Center(
                    child: Text(
                      '输入单词后自动查询\n只看释义，不会加进词库',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: P.faint, height: 1.6),
                    ),
                  )
                : !result.found
                    ? Center(
                        child: Text(
                          '词库里没有「${result.spelling}」',
                          style: TextStyle(color: P.muted),
                        ),
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                        child: Card(
                          elevation: 0,
                          color: P.card,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        result.spelling,
                                        style: const TextStyle(
                                            fontSize: 26, fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                    if ((result.phonetic ?? '').isNotEmpty) ...[
                                      const SizedBox(width: 10),
                                      Text(
                                        result.phonetic!,
                                        style: TextStyle(
                                            fontSize: 14, color: P.muted),
                                      ),
                                    ],
                                    const SizedBox(width: 4),
                                    IconButton(
                                      tooltip: '朗读',
                                      visualDensity: VisualDensity.compact,
                                      constraints:
                                          const BoxConstraints(minWidth: 34, minHeight: 34),
                                      padding: EdgeInsets.zero,
                                      icon: Icon(Icons.volume_up_outlined,
                                          size: 20, color: P.muted),
                                      onPressed: () => Speech.instance.speak(result.spelling),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 14),
                                const Divider(height: 1),
                                const SizedBox(height: 14),
                                Text(
                                  result.definition ?? '暂无释义',
                                  style: const TextStyle(fontSize: 15, height: 1.7),
                                ),
                                if ((result.forms ?? '').isNotEmpty) ...[
                                  const SizedBox(height: 16),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: P.chipAlt,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '常用变形',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: P.faint,
                                              fontWeight: FontWeight.w600),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          result.forms!,
                                          style: TextStyle(
                                              fontSize: 13, color: P.body, height: 1.6),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
