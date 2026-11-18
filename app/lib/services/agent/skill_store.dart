/// 本地 `SKILL.md` 渐进披露仓库与私有笔记沙盒存储。
///
/// 遵循 Pi 设计：启动只扫 YAML frontmatter（name + 一句话 description），
/// 模型命中时再按需 `read_file` / `readSkill` 加载正文；所有读写路径严格限制在
/// `<agentDir>/` 沙盒目录内，禁止路径穿越。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent_models.dart';

class AgentSkillStore {
  AgentSkillStore(this.agentDirPath);

  final String agentDirPath;

  Directory get _rootDir => Directory(agentDirPath);
  Directory get _skillsDir => Directory(p.join(agentDirPath, 'skills'));
  Directory get _notesDir => Directory(p.join(agentDirPath, 'notes'));

  String? resolveSafePath(String relPath) {
    if (agentDirPath.trim().isEmpty) return null;
    final clean = relPath.trim().replaceFirst(RegExp(r'^/+'), '');
    if (clean.isEmpty) return null;
    final base = p.normalize(p.absolute(agentDirPath));
    final target = p.normalize(p.absolute(base, clean));
    if (target == base || !p.isWithin(base, target)) return null;
    return target;
  }

  static String slugify(String raw) {
    final lower = raw.trim().toLowerCase();
    final cleaned = lower
        .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff._-]+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return cleaned.isEmpty ? 'skill' : cleaned;
  }

  Future<List<AgentSkillSummary>> listSkills() async {
    if (agentDirPath.trim().isEmpty) return const [];
    if (!await _skillsDir.exists()) return const [];
    final out = <AgentSkillSummary>[];
    await for (final entity in _skillsDir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final file = File(p.join(entity.path, 'SKILL.md'));
      if (!await file.exists()) continue;
      try {
        final raw = await file.readAsString();
        final fm = _parseFrontmatter(raw);
        final dirName = p.basename(entity.path);
        final name = fm.name.isNotEmpty ? fm.name : dirName;
        final desc = fm.description.isNotEmpty
            ? fm.description
            : _firstContentLine(raw);
        out.add(
          AgentSkillSummary(
            name: name,
            description: desc,
            path: p.posix.join('skills', dirName, 'SKILL.md'),
          ),
        );
      } on Object {
        // 损坏的技能文件跳过，不影响其他技能加载
      }
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  Future<String?> readSkill(String nameOrSlug) async {
    if (agentDirPath.trim().isEmpty) return null;
    final trimmed = nameOrSlug.trim();
    if (trimmed.isEmpty) return null;
    final direct = resolveSafePath(
      p.posix.join('skills', slugify(trimmed), 'SKILL.md'),
    );
    if (direct != null && await File(direct).exists()) {
      return File(direct).readAsString();
    }
    final all = await listSkills();
    for (final s in all) {
      if (s.name.toLowerCase() == trimmed.toLowerCase()) {
        final full = resolveSafePath(s.path);
        if (full != null && await File(full).exists()) {
          return File(full).readAsString();
        }
      }
    }
    return null;
  }

  Future<AgentSkillSummary?> saveSkill({
    required String name,
    required String description,
    required String body,
  }) async {
    if (agentDirPath.trim().isEmpty) return null;
    final cleanName = name.trim();
    final cleanDesc = description.trim();
    final cleanBody = body.trim();
    if (cleanName.isEmpty || cleanBody.isEmpty) return null;
    final slug = slugify(cleanName);
    final rel = p.posix.join('skills', slug, 'SKILL.md');
    final targetPath = resolveSafePath(rel);
    if (targetPath == null) return null;
    final file = File(targetPath);
    await file.parent.create(recursive: true);
    final content =
        '---\nname: $cleanName\ndescription: ${cleanDesc.isEmpty ? cleanName : cleanDesc}\n---\n\n$cleanBody\n';
    await _atomicWrite(file, content);
    return AgentSkillSummary(
      name: cleanName,
      description: cleanDesc.isEmpty ? cleanName : cleanDesc,
      path: rel,
    );
  }

  Future<String?> readSandboxFile(String relPath) async {
    final target = resolveSafePath(relPath);
    if (target == null) return null;
    final file = File(target);
    if (!await file.exists()) return null;
    final content = await file.readAsString();
    if (content.length > 16000) {
      return '${content.substring(0, 16000)}\n...(已截断，共 ${content.length} 字符)';
    }
    return content;
  }

  Future<String?> writeSandboxFile(String relPath, String content) async {
    final target = resolveSafePath(relPath);
    if (target == null) return null;
    final file = File(target);
    await file.parent.create(recursive: true);
    await _atomicWrite(file, content);
    return relPath;
  }

  Future<List<String>> listNotes() async {
    if (agentDirPath.trim().isEmpty || !await _notesDir.exists()) {
      return const [];
    }
    final out = <String>[];
    await for (final entity in _notesDir.list(followLinks: false)) {
      if (entity is File) {
        out.add(p.posix.join('notes', p.basename(entity.path)));
      }
    }
    out.sort();
    return out;
  }

  Future<void> ensureRoot() async {
    if (agentDirPath.trim().isEmpty) return;
    if (!await _rootDir.exists()) {
      await _rootDir.create(recursive: true);
    }
  }

  Future<void> _atomicWrite(File target, String content) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    if (await target.exists()) {
      await target.delete();
    }
    await tmp.rename(target.path);
  }

  static ({String name, String description}) _parseFrontmatter(String raw) {
    final normalized = raw.replaceAll('\r\n', '\n').trimLeft();
    if (!normalized.startsWith('---')) return (name: '', description: '');
    final end = normalized.indexOf('\n---', 3);
    if (end < 0) return (name: '', description: '');
    final block = normalized.substring(3, end);
    var name = '';
    var desc = '';
    for (final line in block.split('\n')) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final k = line.substring(0, idx).trim().toLowerCase();
      var v = line.substring(idx + 1).trim();
      if ((v.startsWith('"') && v.endsWith('"')) ||
          (v.startsWith("'") && v.endsWith("'"))) {
        if (v.length >= 2) v = v.substring(1, v.length - 1);
      }
      if (k == 'name') name = v;
      if (k == 'description') desc = v;
    }
    return (name: name, description: desc);
  }

  static String _firstContentLine(String raw) {
    for (final line in raw.split('\n')) {
      final t = line.trim();
      if (t.isEmpty || t == '---') continue;
      return t.replaceFirst(RegExp(r'^#+\s*'), '');
    }
    return '';
  }
}
