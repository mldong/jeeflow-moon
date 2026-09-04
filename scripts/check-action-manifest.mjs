#!/usr/bin/env node
/**
 * M0 gate：45 action manifest ↔ Java JeeflowFacade 实查 diff（方案 §5 M0 通过条件）
 *
 * 用法（仓根目录）：
 *   node scripts/check-action-manifest.mjs
 *   node scripts/check-action-manifest.mjs --java <JeeflowFacade.java 路径>  # 覆盖默认路径
 *
 * 通过标准：manifest 与 Java 实查双向无差集。
 */
import { readFileSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const manifestPath = join(repoRoot, "docs", "action-manifest.json");

const javaArgIdx = process.argv.indexOf("--java");
const javaPath =
  javaArgIdx > -1
    ? resolve(process.argv[javaArgIdx + 1])
    : resolve(repoRoot, "..", "jeeflow-java", "jeeflow-core", "src", "main", "java", "com", "mldong", "jeeflow", "facade", "JeeflowFacade.java");

if (!existsSync(manifestPath)) {
  console.error(`FAIL: manifest 不存在: ${manifestPath}`);
  process.exit(1);
}
if (!existsSync(javaPath)) {
  console.error(`FAIL: Java 参考实现不存在: ${javaPath}`);
  process.exit(1);
}

// ── Java 实查：flow() switch 的 case 标签（action 必含 "/"，stats 维度子 switch 的 case 均不含） ──
const javaSrc = readFileSync(javaPath, "utf8");
const javaActions = [...javaSrc.matchAll(/case\s+"([^"]+)"\s*:\s*return\s+/g)]
  .map((m) => m[1])
  .filter((a) => a.includes("/"));
const javaSet = new Set(javaActions);
if (javaSet.size !== javaActions.length) {
  console.error("FAIL: Java switch 内 action 标签有重复（不应发生）");
  process.exit(1);
}

// ── manifest 展开 ──
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
const manifestActions = [];
for (const [group, g] of Object.entries(manifest.groups)) {
  for (const a of g.actions) {
    if (!a.action.startsWith(group + "/")) {
      console.error(`FAIL: action "${a.action}" 不属于其分组 "${group}/"`);
      process.exit(1);
    }
    manifestActions.push(a.action);
  }
}
const manifestSet = new Set(manifestActions);
if (manifestSet.size !== manifestActions.length) {
  console.error("FAIL: manifest 内 action 有重复");
  process.exit(1);
}

// ── 双向 diff ──
const onlyInJava = [...javaSet].filter((a) => !manifestSet.has(a));
const onlyInManifest = [...manifestSet].filter((a) => !javaSet.has(a));

console.log(`Java 实查: ${javaSet.size} action`);
console.log(`manifest : ${manifestSet.size} action`);
if (manifest._meta.count !== manifestSet.size) {
  console.error(`FAIL: _meta.count=${manifest._meta.count} 与实际 ${manifestSet.size} 不一致`);
  process.exit(1);
}
if (manifest.summary.total !== manifestSet.size) {
  console.error(`FAIL: summary.total=${manifest.summary.total} 与实际 ${manifestSet.size} 不一致`);
  process.exit(1);
}
for (const [g, n] of Object.entries(manifest.summary.byGroup)) {
  const actual = manifest.groups[g].actions.length;
  if (actual !== n) {
    console.error(`FAIL: summary.byGroup.${g}=${n} 与实际 ${actual} 不一致`);
    process.exit(1);
  }
}

if (onlyInJava.length || onlyInManifest.length) {
  if (onlyInJava.length) console.error(`FAIL: Java 有而 manifest 无 (${onlyInJava.length}): ${onlyInJava.join(", ")}`);
  if (onlyInManifest.length) console.error(`FAIL: manifest 有而 Java 无 (${onlyInManifest.length}): ${onlyInManifest.join(", ")}`);
  process.exit(1);
}

console.log("PASS — 45 action manifest 与 Java 实查双向无差集");
