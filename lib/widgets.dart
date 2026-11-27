import 'package:flutter/material.dart';

import 'theme.dart';
/// 概览卡里的一格指标：上面数字、下面小标签，数字过宽时等比缩不截断。
class MetricCell extends StatelessWidget {
  const MetricCell({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(fontSize: 12, color: P.muted)),
        ],
      ),
    );
  }
}

/// 指标之间的竖线。
class AppDivider extends StatelessWidget {
  const AppDivider({super.key});

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 28, color: P.border);
}

/// 页面顶部的错误提示卡，带重试。
class ErrorCard extends StatelessWidget {
  const ErrorCard({
    super.key,
    required this.message,
    required this.onRetry,
    this.busy = false,
  });

  final String message;
  final Future<void> Function() onRetry;

  /// 重试进行中时禁用按钮。没有这个标志，用户连点会并发发起多次请求。
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: P.dangerBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, style: TextStyle(color: P.danger, fontSize: 13)),
            const SizedBox(height: 8),
            TextButton(onPressed: busy ? null : onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
