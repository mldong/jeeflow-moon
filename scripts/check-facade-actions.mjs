#!/usr/bin/env node
/**
 * 门面 action 三向对账（仓内自证版，CI 可跑）：
 *   scripts/action-manifest.json（权威清单）
 *   ↔ facade/facade.mbt 的 match 臂（真正接受实参的那份代码）
 *   ↔ facade/README.md「The action surface」表（包面用户读到的清单）
 *
 * 与 scripts/check-action-manifest.mjs 的分工：那一条腿要兄弟目录 jeeflow-java 的
 * JeeflowFacade.java 实查（跨仓，本仓 CI 拿不到），本脚本只在仓内比，所以能挂进每次 push。
 *
 * 用法（仓根）：node scripts/check-facade-actions.mjs
 * 退出码：0＝三向零差集；1＝任一方向有差集 / 清单里的分组计数与 summary.byGroup 不符。
 */
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const read = (p) => readFileSync(join(root, p), "utf8").replace(/\r\n/g, "\n");

// ── ① manifest ──
const manifest = JSON.parse(read("scripts/action-manifest.json"));
const fromManifest = [];
for (const [group, g] of Object.entries(manifest.groups)) {
  for (const a of g.actions || []) fromManifest.push(a.action);
}

// ── ② 派发臂：`"group/name" => ...` ──
const src = read("facade/facade.mbt");
const fromDispatch = [...src.matchAll(/^\s*"([A-Za-z0-9_/]+\/[A-Za-z0-9_/]+)"\s*=>/gm)].map(
  (m) => m[1],
);

// ── ③ README 表：`| \`processTask\` … | a · b · stats/c |` ──
const readmeAll = read("facade/README.md");
const readme = readmeAll.slice(readmeAll.indexOf("## The action surface"));
const fromReadme = [];
for (const line of readme.split("\n")) {
  const m = line.match(/^\|\s*`([A-Za-z]+)`[^|]*\|\s*([^|]+?)\s*\|\s*$/);
  if (!m) continue;
  for (const name of m[2].split("·").map((s) => s.trim())) fromReadme.push(`${m[1]}/${name}`);
}

const dup = (label, xs) => {
  const seen = new Set();
  const dups = xs.filter((x) => (seen.has(x) ? true : (seen.add(x), false)));
  if (dups.length) {
    console.error(`FAIL: ${label} 内部有重名臂：${[...new Set(dups)].join(", ")}`);
    process.exit(1);
  }
};
dup("manifest", fromManifest);
dup("facade.mbt 派发臂", fromDispatch);
dup("README 表", fromReadme);

const only = (a, b) => {
  const set = new Set(b);
  return [...new Set(a)].filter((x) => !set.has(x)).sort();
};
const legs = [
  ["manifest", fromManifest],
  ["dispatch", fromDispatch],
  ["readme", fromReadme],
];
let rc = 0;
for (const [xa, a] of legs) {
  for (const [xb, b] of legs) {
    if (xa === xb) continue;
    const d = only(a, b);
    if (d.length) {
      console.error(`FAIL: 在 ${xa} 有、在 ${xb} 没有（${d.length} 条）：${d.join(", ")}`);
      rc = 1;
    }
  }
}

// ── summary.byGroup 与 manifest 逐组计数对账 ──
const byGroup = manifest.summary.byGroup;
for (const [group, g] of Object.entries(manifest.groups)) {
  const n = (g.actions || []).length;
  if (byGroup[group] !== n) {
    console.error(`FAIL: summary.byGroup.${group}=${byGroup[group]} 与清单实际 ${n} 条不符`);
    rc = 1;
  }
}
if (manifest.summary.total !== fromManifest.length) {
  console.error(`FAIL: summary.total=${manifest.summary.total} 与清单实际 ${fromManifest.length} 条不符`);
  rc = 1;
}

const perGroup = (xs) =>
  Object.entries(
    xs.reduce((acc, x) => {
      const g = x.split("/")[0];
      acc[g] = (acc[g] || 0) + 1;
      return acc;
    }, {}),
  )
    .map(([g, n]) => `${g}:${n}`)
    .join(" ");

console.log(
  `action 三向对账 ${rc === 0 ? "OK" : "FAIL"}｜manifest=${fromManifest.length} dispatch=${fromDispatch.length} readme=${fromReadme.length}｜${perGroup(fromDispatch)}`,
);
process.exit(rc);
