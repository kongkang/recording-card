/// 设置里的本机记忆检索：输入问题，先在手机上找总结和转写，再请云端根据片段回答。
library;

import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../services/memory/memory_chunk.dart';
import '../../services/memory/memory_search_service.dart';

class MemorySearchBody extends StatefulWidget {
  const MemorySearchBody({super.key, required this.ask});

  final Future<MemoryAnswer> Function(String query) ask;

  @override
  State<MemorySearchBody> createState() => _MemorySearchBodyState();
}

class _MemorySearchBodyState extends State<MemorySearchBody> {
  final _input = TextEditingController();
  var _busy = false;
  MemoryAnswer? _answer;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final query = _input.text.trim();
    if (query.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _answer = null;
    });
    final answer = await widget.ask(query);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _answer = answer;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final answer = _answer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '只在这台手机上查找已保存的总结和转写。音频和声纹不会上传。',
          style: TextStyle(fontSize: 13, height: 1.5, color: c.sec),
        ),
        const SizedBox(height: 14),
        TextField(
          key: const Key('memory-search-input'),
          controller: _input,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            hintText: '例如：前几天看的电影是什么名字',
            filled: true,
            fillColor: c.card,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: c.sep),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: c.sep),
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('memory-search-submit'),
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? '正在查找…' : '查找'),
        ),
        if (answer != null) ...[
          const SizedBox(height: 18),
          Text(
            answer.text,
            key: const Key('memory-search-answer'),
            style: TextStyle(fontSize: 15, height: 1.5, color: c.label),
          ),
          if (answer.hits.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '没有可引用的本机片段',
                key: const Key('memory-search-empty'),
                style: TextStyle(fontSize: 12, color: c.sec),
              ),
            )
          else ...[
            const SizedBox(height: 14),
            Text('来源', style: TextStyle(fontSize: 12, color: c.sec)),
            const SizedBox(height: 6),
            for (var i = 0; i < answer.hits.length; i++)
              _HitTile(index: i, hit: answer.hits[i]),
          ],
        ],
      ],
    );
  }
}

class _HitTile extends StatelessWidget {
  const _HitTile({required this.index, required this.hit});

  final int index;
  final MemoryHit hit;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final kind = hit.kind == 'summary' ? '总结' : '记录';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        key: Key('memory-search-hit-$index'),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.sep),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$kind · ${hit.dayLabel} ${hit.timeLabel} · ${hit.title}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: c.label,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                hit.snippet,
                style: TextStyle(fontSize: 12.5, height: 1.45, color: c.sec),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
