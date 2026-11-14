#!/usr/bin/env node
// 对外发版快照归档工具：node prototype/snapshot-release.mjs v1.0.0 [YYYY-MM-DD]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ver = (process.argv[2] || '').trim();
if (!/^v\d+\.\d+\.\d+(-[\w.]+)?$/.test(ver)) {
  console.error('用法: node prototype/snapshot-release.mjs vX.Y.Z [YYYY-MM-DD]');
  process.exit(1);
}
const date = (process.argv[3] || new Date().toISOString().slice(0, 10)).trim();
const curPath = path.join(__dirname, 'current.html');
const idxPath = path.join(__dirname, 'index.html');
const relDir = path.join(__dirname, 'releases');
const snapPath = path.join(relDir, `${ver}.html`);

fs.mkdirSync(relDir, { recursive: true });
const slug = ver.replace(/[^a-zA-Z0-9]/g, '_');
let snap = fs.readFileSync(curPath, 'utf8');
snap = snap
  .replace(/<title>.*?<\/title>/, `<title>快照 ${ver} (${date}) · 录音卡</title>`)
  .replace('href="index.html"', 'href="../index.html"')
  .replace(/>当前版<\/button>/, `>快照 ${ver}</button><a class="ver-opt" href="../current.html" title="返回最新当前版">最新当前版</a>`)
  .replaceAll('"rc-route-cur-v1"', `"rc-route-snap-${slug}"`)
  .replaceAll('"rc-wifi-cur-v1"', `"rc-wifi-snap-${slug}"`)
  .replaceAll('href="releases/', 'href="');

fs.writeFileSync(snapPath, snap, 'utf8');

function updateSnapRegistry(filePath, prefix) {
  let html = fs.readFileSync(filePath, 'utf8');
  const m = html.match(/var RELEASE_SNAPSHOTS=(\[.*?\]);/);
  if (!m) throw new Error(`未在 ${path.basename(filePath)} 中找到 RELEASE_SNAPSHOTS`);
  const list = JSON.parse(m[1]).filter(x => x.v !== ver);
  list.unshift({ v: ver, date, href: `${prefix}${ver}.html` });
  html = html.replace(/var RELEASE_SNAPSHOTS=\[.*?\];/, `var RELEASE_SNAPSHOTS=${JSON.stringify(list)};`);
  fs.writeFileSync(filePath, html, 'utf8');
}

updateSnapRegistry(curPath, 'releases/');
updateSnapRegistry(idxPath, 'releases/');
updateSnapRegistry(snapPath, '');
console.log(`[OK] 已归档发版快照: prototype/releases/${ver}.html (${date})`);
