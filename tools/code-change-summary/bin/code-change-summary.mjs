#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import process from "node:process";

const GraphMode = {
  ASCII: "ascii",
  MERMAID: "mermaid",
  NONE: "none",
};

const ViewMode = {
  DAILY: "daily",
  WEEKLY: "weekly",
  MONTHLY: "monthly",
};

const BASELINE_EXCLUDED_DIRS = [
  ".git",
  ".hg",
  ".svn",
  "node_modules",
  ".next",
  ".claude",
  ".codex",
  "coverage",
  "dist",
  "build",
  ".turbo",
  "_generated",
];

function die(message) {
  console.error(message);
  process.exit(1);
}

function run(cmd, args, cwd) {
  try {
    return execFileSync(cmd, args, {
      cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      env: process.env,
      maxBuffer: 1024 * 1024 * 50,
    }).trim();
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    die(`Command failed: ${cmd} ${args.join(" ")}\n${reason}`);
  }
}

function formatLocalDate(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function parseDateOnly(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    die(`Invalid date: ${value}. Expected YYYY-MM-DD.`);
  }
  const [year, month, day] = value.split("-").map(Number);
  return new Date(year, month - 1, day);
}

function printHelp() {
  console.log(`Code change summary

Usage:
  ccs
  ccs --repo /path/to/repo --days 14
  ccs --repo /path/to/repo --view weekly --periods 8
  ccs --repo /path/to/repo --view monthly --periods 6 --graph mermaid

Flags:
  --view <mode>         daily | weekly | monthly. Default: overview when omitted
  --periods <n>         Number of periods to show for --view
  --days <n>            Legacy alias for --view daily --periods <n>
  --end-date <date>     Inclusive end date in YYYY-MM-DD. Default: today
  --include-tests       Include *.test.ts(x), *.spec.ts(x), and tests/
  --details             Show add/delete counts in addition to net values
  --graph <mode>        ascii | mermaid | none. Default: ascii
  --repo <path>         Repo path. Default: current working directory
`);
}

function parseArgs(argv) {
  const today = formatLocalDate(new Date());
  const out = {
    repoPath: process.cwd(),
    view: ViewMode.DAILY,
    periods: 5,
    endDate: today,
    includeTests: false,
    graph: GraphMode.ASCII,
    details: false,
    hasExplicitWindow: false,
  };

  const readValue = (index) => {
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      die(`Missing value for ${argv[index]}`);
    }
    return value;
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--repo") {
      out.repoPath = readValue(index);
      index += 1;
      continue;
    }
    if (arg === "--days") {
      out.view = ViewMode.DAILY;
      out.periods = Number.parseInt(readValue(index), 10);
      out.hasExplicitWindow = true;
      index += 1;
      continue;
    }
    if (arg === "--periods") {
      out.periods = Number.parseInt(readValue(index), 10);
      out.hasExplicitWindow = true;
      index += 1;
      continue;
    }
    if (arg === "--view") {
      const view = readValue(index);
      if (!Object.values(ViewMode).includes(view)) {
        die(`Invalid view: ${view}`);
      }
      out.view = view;
      out.hasExplicitWindow = true;
      index += 1;
      continue;
    }
    if (arg === "--end-date") {
      out.endDate = readValue(index);
      index += 1;
      continue;
    }
    if (arg === "--include-tests") {
      out.includeTests = true;
      continue;
    }
    if (arg === "--details") {
      out.details = true;
      continue;
    }
    if (arg === "--graph") {
      const graph = readValue(index);
      if (!Object.values(GraphMode).includes(graph)) {
        die(`Invalid graph mode: ${graph}`);
      }
      out.graph = graph;
      index += 1;
      continue;
    }
    if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    }
    die(`Unknown argument: ${arg}`);
  }

  if (!Number.isFinite(out.periods) || out.periods <= 0) {
    die(`Invalid period count: ${out.periods}`);
  }

  parseDateOnly(out.endDate);
  return out;
}

function atNoon(date) {
  const copy = new Date(date);
  copy.setHours(12, 0, 0, 0);
  return copy;
}

function shiftDays(date, days) {
  const copy = atNoon(date);
  copy.setDate(copy.getDate() + days);
  return copy;
}

function startOfWeek(date) {
  const copy = atNoon(date);
  const day = copy.getDay();
  const diff = day === 0 ? -6 : 1 - day;
  copy.setDate(copy.getDate() + diff);
  return copy;
}

function endOfWeek(date) {
  return shiftDays(startOfWeek(date), 6);
}

function startOfMonth(date) {
  const copy = atNoon(date);
  copy.setDate(1);
  return copy;
}

function endOfMonth(date) {
  const copy = atNoon(date);
  copy.setMonth(copy.getMonth() + 1, 0);
  return copy;
}

function shortDate(date) {
  return date.slice(5);
}

function shortRangeLabel(start, end) {
  return `${start.slice(5)}..${end.slice(5)}`;
}

function buildPeriods(view, endDate, count) {
  const periods = [];
  const finalEnd = atNoon(parseDateOnly(endDate));
  let cursorEnd = finalEnd;

  for (let index = 0; index < count; index += 1) {
    if (view === ViewMode.DAILY) {
      const start = formatLocalDate(cursorEnd);
      periods.unshift({
        label: start,
        shortLabel: shortDate(start),
        start,
        end: start,
      });
      cursorEnd = shiftDays(cursorEnd, -1);
      continue;
    }

    if (view === ViewMode.WEEKLY) {
      const startDate = startOfWeek(cursorEnd);
      const endDateForPeriod = index === 0 ? cursorEnd : endOfWeek(cursorEnd);
      const start = formatLocalDate(startDate);
      const end = formatLocalDate(endDateForPeriod);
      periods.unshift({
        label: `${start}..${end}`,
        shortLabel: shortRangeLabel(start, end),
        start,
        end,
      });
      cursorEnd = shiftDays(startDate, -1);
      continue;
    }

    const startDate = startOfMonth(cursorEnd);
    const endDateForPeriod = index === 0 ? cursorEnd : endOfMonth(cursorEnd);
    const start = formatLocalDate(startDate);
    const end = formatLocalDate(endDateForPeriod);
    const monthLabel = start.slice(0, 7);
    periods.unshift({
      label: monthLabel,
      shortLabel: monthLabel,
      start,
      end,
    });
    cursorEnd = shiftDays(startDate, -1);
  }

  return periods;
}

function makeDateRange(startDate, endDate) {
  const start = atNoon(parseDateOnly(startDate));
  const end = atNoon(parseDateOnly(endDate));
  const dates = [];
  for (let date = new Date(start); date <= end; date = shiftDays(date, 1)) {
    dates.push(formatLocalDate(date));
  }
  return dates;
}

function buildOverviewSpecs() {
  return [
    { key: "daily", title: "last 5 days", view: ViewMode.DAILY, periods: 5 },
    { key: "weekly", title: "this week + previous 2 weeks", view: ViewMode.WEEKLY, periods: 3 },
    { key: "monthly", title: "this month + previous month", view: ViewMode.MONTHLY, periods: 2 },
  ];
}

function isTestFile(location) {
  return (
    location.startsWith("tests/") ||
    /(^|\/).+\.(test|spec)\.(ts|tsx)$/.test(location)
  );
}

function isExcluded(location, includeTests) {
  if (includeTests) return false;
  return isTestFile(location);
}

function createBucketStats() {
  return { files: 0, lines: 0 };
}

function createBaselineStats() {
  return {
    ts: createBucketStats(),
    tsTests: createBucketStats(),
    tsx: createBucketStats(),
    tsxTests: createBucketStats(),
    totalFiles: 0,
    totalLines: 0,
  };
}

function addFileToBaseline(baseline, bucket, lines) {
  baseline[bucket].files += 1;
  baseline[bucket].lines += lines;
  baseline.totalFiles += 1;
  baseline.totalLines += lines;
}

function getBucketStats(baseline, key) {
  return baseline[key];
}

function findCoverageSummaryPath(repoPath) {
  const candidates = [
    "coverage/coverage-summary.json",
    "coverage/summary.json",
    ".nyc_output/coverage-summary.json",
  ];

  for (const candidate of candidates) {
    const output = run("find", [".", "-path", `./${candidate}`, "-print", "-quit"], repoPath);
    if (output) return output.replace(/^\.\//, "");
  }

  const found = run(
    "find",
    [
      ".",
      "-path",
      "./node_modules",
      "-prune",
      "-o",
      "-path",
      "./.git",
      "-prune",
      "-o",
      "(",
      "-name",
      "coverage-summary.json",
      "-o",
      "-name",
      "summary.json",
      ")",
      "-path",
      "*/coverage/*",
      "-print",
      "-quit",
    ],
    repoPath,
  );

  return found ? found.replace(/^\.\//, "") : null;
}

function getCoverageSummary(repoPath) {
  const coveragePath = findCoverageSummaryPath(repoPath);
  if (!coveragePath) return null;

  const raw = run("cat", [coveragePath], repoPath);
  const parsed = JSON.parse(raw);
  const totals = parsed.total ?? parsed;

  if (!totals || typeof totals !== "object") {
    return null;
  }

  const lines = totals.lines;
  if (!lines || typeof lines.pct !== "number") {
    return null;
  }

  return {
    path: coveragePath,
    lines: {
      pct: lines.pct,
      covered: typeof lines.covered === "number" ? lines.covered : null,
      total: typeof lines.total === "number" ? lines.total : null,
    },
    statements:
      totals.statements && typeof totals.statements.pct === "number"
        ? {
            pct: totals.statements.pct,
            covered: typeof totals.statements.covered === "number" ? totals.statements.covered : null,
            total: typeof totals.statements.total === "number" ? totals.statements.total : null,
          }
        : null,
    branches:
      totals.branches && typeof totals.branches.pct === "number"
        ? {
            pct: totals.branches.pct,
            covered: typeof totals.branches.covered === "number" ? totals.branches.covered : null,
            total: typeof totals.branches.total === "number" ? totals.branches.total : null,
          }
        : null,
    functions:
      totals.functions && typeof totals.functions.pct === "number"
        ? {
            pct: totals.functions.pct,
            covered: typeof totals.functions.covered === "number" ? totals.functions.covered : null,
            total: typeof totals.functions.total === "number" ? totals.functions.total : null,
          }
        : null,
  };
}

function getBaseline(args) {
  const raw = run(
    "scc",
    [
      "--include-ext",
      "ts,tsx",
      "--exclude-dir",
      BASELINE_EXCLUDED_DIRS.join(","),
      "--by-file",
      "--format",
      "json",
      "--no-complexity",
      "--no-cocomo",
      "--no-size",
      ".",
    ],
    args.repoPath,
  );

  const parsed = JSON.parse(raw);
  const files = parsed[0]?.Files ?? [];
  const baseline = createBaselineStats();

  for (const file of files) {
    const location = file.Location ?? "";
    const lines = file.Code ?? 0;
    if (file.Extension === "ts") {
      addFileToBaseline(baseline, isTestFile(location) ? "tsTests" : "ts", lines);
      continue;
    }
    if (file.Extension === "tsx") {
      addFileToBaseline(baseline, isTestFile(location) ? "tsxTests" : "tsx", lines);
    }
  }

  baseline.coverage = getCoverageSummary(args.repoPath);
  return baseline;
}

function getGitPathspecs(includeTests) {
  const base = [
    "*.ts",
    "*.tsx",
    ...BASELINE_EXCLUDED_DIRS.flatMap((dir) => [`:(exclude)${dir}/**`, `:(exclude)**/${dir}/**`]),
  ];
  if (includeTests) return base;
  return [
    ...base,
    ":(exclude)tests/**",
    ":(exclude)**/*.test.ts",
    ":(exclude)**/*.spec.ts",
    ":(exclude)**/*.test.tsx",
    ":(exclude)**/*.spec.tsx",
  ];
}

function emptyDay(date) {
  return { date, ts: { add: 0, del: 0 }, tsx: { add: 0, del: 0 } };
}

function createPeriodSummary(period) {
  return {
    ...period,
    ts: { add: 0, del: 0 },
    tsx: { add: 0, del: 0 },
  };
}

function getSummariesForPeriods(args, periods) {
  const summaries = periods.map(createPeriodSummary);
  const start = `${summaries[0].start} 00:00:00`;
  const end = `${summaries[summaries.length - 1].end} 23:59:59`;
  const raw = run(
    "git",
    [
      "log",
      `--since=${start}`,
      `--until=${end}`,
      "--numstat",
      "--pretty=tformat:%ct",
      "--",
      ...getGitPathspecs(args.includeTests),
    ],
    args.repoPath,
  );

  let currentDate = null;

  for (const line of raw.split(/\r?\n/)) {
    if (!line.trim()) continue;
    if (/^\d+$/.test(line)) {
      currentDate = formatLocalDate(new Date(Number(line) * 1000));
      continue;
    }

    const [addRaw, delRaw, path] = line.split("\t");
    if (!currentDate || !addRaw || !delRaw || !path) continue;
    if (!/^\d+$/.test(addRaw) || !/^\d+$/.test(delRaw)) continue;

    const ext = path.endsWith(".tsx") ? "tsx" : path.endsWith(".ts") ? "ts" : null;
    if (!ext) continue;

    for (const summary of summaries) {
      if (currentDate < summary.start || currentDate > summary.end) continue;
      summary[ext].add += Number(addRaw);
      summary[ext].del += Number(delRaw);
    }
  }

  return summaries;
}

function percent(value, total) {
  if (total === 0) return "0.00%";
  return `${((value / total) * 100).toFixed(2)}%`;
}

function formatCount(value) {
  return value.toLocaleString("en-US");
}

function formatPercent(value) {
  return `${value.toFixed(2)}%`;
}

function formatSignedCount(value) {
  const abs = formatCount(Math.abs(value));
  if (value > 0) return `+${abs}`;
  if (value < 0) return `-${abs}`;
  return "0";
}

function padCell(value, width) {
  return value.padStart(width, " ");
}

function padLabel(value, width) {
  return value.padEnd(width, " ");
}

function formatCoverageMetric(label, metric) {
  if (!metric) return `${label} n/a`;
  if (metric.covered == null || metric.total == null) {
    return `${label} ${formatPercent(metric.pct)}`;
  }
  return `${label} ${formatPercent(metric.pct)} (${formatCount(metric.covered)}/${formatCount(metric.total)})`;
}

function makeSummaryRows(periods, baseline) {
  let totalTs = 0;
  let totalTsx = 0;
  const rows = periods.map((period) => {
    const tsNet = period.ts.add - period.ts.del;
    const tsxNet = period.tsx.add - period.tsx.del;
    const allAdd = period.ts.add + period.tsx.add;
    const allDel = period.ts.del + period.tsx.del;
    const allNet = tsNet + tsxNet;
    totalTs += tsNet;
    totalTsx += tsxNet;

    return {
      period: period.shortLabel,
      allNet: formatSignedCount(allNet),
      allPct: percent(allNet, baseline.totalLines),
      tsNet: formatSignedCount(tsNet),
      tsPct: percent(tsNet, baseline.ts.lines),
      tsxNet: formatSignedCount(tsxNet),
      tsxPct: percent(tsxNet, baseline.tsx.lines),
      churn: `+${formatCount(allAdd)} / -${formatCount(allDel)}`,
    };
  });

  return {
    rows,
    totals: {
      all: totalTs + totalTsx,
      ts: totalTs,
      tsx: totalTsx,
    },
  };
}

function getColumnWidths(sections, details) {
  const rows = sections.flatMap((section) => section.rows);
  return {
    period: Math.max("period".length, ...rows.map((row) => row.period.length)),
    allNet: Math.max("total net".length, ...rows.map((row) => row.allNet.length)),
    allPct: Math.max("total %".length, ...rows.map((row) => row.allPct.length)),
    tsNet: Math.max("ts net".length, ...rows.map((row) => row.tsNet.length)),
    tsPct: Math.max("ts %".length, ...rows.map((row) => row.tsPct.length)),
    tsxNet: Math.max("tsx net".length, ...rows.map((row) => row.tsxNet.length)),
    tsxPct: Math.max("tsx %".length, ...rows.map((row) => row.tsxPct.length)),
    churn: details ? Math.max("adds / dels".length, ...rows.map((row) => row.churn.length)) : 0,
  };
}

function renderTableHeader(widths, details) {
  return (
    `${padLabel("period", widths.period)}  ` +
    `${padCell("total net", widths.allNet)}  ${padCell("total %", widths.allPct)}  ` +
    `${padCell("ts net", widths.tsNet)}  ${padCell("ts %", widths.tsPct)}  ` +
    `${padCell("tsx net", widths.tsxNet)}  ${padCell("tsx %", widths.tsxPct)}` +
    (details ? `  ${padCell("adds / dels", widths.churn)}` : "")
  );
}

function renderRow(row, widths, details) {
  return (
    `${padLabel(row.period, widths.period)}  ` +
    `${padCell(row.allNet, widths.allNet)}  ${padCell(row.allPct, widths.allPct)}  ` +
    `${padCell(row.tsNet, widths.tsNet)}  ${padCell(row.tsPct, widths.tsPct)}  ` +
    `${padCell(row.tsxNet, widths.tsxNet)}  ${padCell(row.tsxPct, widths.tsxPct)}` +
    (details ? `  ${padCell(row.churn, widths.churn)}` : "")
  );
}

function renderWindowTotals(totals, baseline) {
  return (
    `total ${formatSignedCount(totals.all)}  ${percent(totals.all, baseline.totalLines)} | ` +
    `ts ${formatSignedCount(totals.ts)}  ${percent(totals.ts, baseline.ts.lines)} | ` +
    `tsx ${formatSignedCount(totals.tsx)}  ${percent(totals.tsx, baseline.tsx.lines)}`
  );
}

function renderCodebaseSummary(baseline) {
  const lines = [];
  lines.push("codebase");
  lines.push(`total files ${formatCount(baseline.totalFiles)} | total lines ${formatCount(baseline.totalLines)}`);

  const baselineRows = [
    { label: "tsx", stats: getBucketStats(baseline, "tsx") },
    { label: "tsx tests", stats: getBucketStats(baseline, "tsxTests") },
    { label: "ts", stats: getBucketStats(baseline, "ts") },
    { label: "ts tests", stats: getBucketStats(baseline, "tsTests") },
  ];

  const labelWidth = Math.max(...baselineRows.map((row) => row.label.length));
  const fileWidth = Math.max("files".length, ...baselineRows.map((row) => formatCount(row.stats.files).length));
  const lineWidth = Math.max("lines".length, ...baselineRows.map((row) => formatCount(row.stats.lines).length));

  for (const row of baselineRows) {
    lines.push(
      `${padLabel(row.label, labelWidth)}  ` +
        `${padCell(formatCount(row.stats.files), fileWidth)} files  ` +
        `${padCell(formatCount(row.stats.lines), lineWidth)} lines  ` +
        `${percent(row.stats.lines, baseline.totalLines)}`,
    );
  }

  lines.push("");
  lines.push("coverage");
  if (baseline.coverage) {
    lines.push(`source ${baseline.coverage.path}`);
    lines.push(formatCoverageMetric("lines", baseline.coverage.lines));
    lines.push(formatCoverageMetric("statements", baseline.coverage.statements));
    lines.push(formatCoverageMetric("functions", baseline.coverage.functions));
    lines.push(formatCoverageMetric("branches", baseline.coverage.branches));
  } else {
    lines.push("unavailable");
  }

  return lines.join("\n");
}

function renderWindowSummary(periods, baseline, details, widths, title) {
  const { rows, totals } = makeSummaryRows(periods, baseline);
  const lines = [];
  if (title) lines.push(title);

  for (const row of rows) {
    lines.push(renderRow(row, widths, details));
  }

  lines.push("");
  lines.push(renderWindowTotals(totals, baseline));

  return lines.join("\n");
}

function renderAsciiGraph(periods, baseline, title = "graph") {
  const values = periods.map((period) => period.ts.add - period.ts.del + (period.tsx.add - period.tsx.del));
  const maxAbs = Math.max(...values.map((value) => Math.abs(value)), 1);
  const width = 18;
  const labels = periods.map((period) => period.shortLabel);
  const periodWidth = Math.max("period".length, ...labels.map((label) => label.length));
  const totalNetWidth = Math.max("total net".length, ...values.map((value) => formatSignedCount(value).length));
  const totalPctWidth = Math.max("total %".length, ...values.map((value) => percent(value, baseline.totalLines).length));

  return [
    title,
    `${padLabel("period", periodWidth)}  ${padCell("total net", totalNetWidth)}  ${padCell("total %", totalPctWidth)}  trend`,
    ...periods.map((period, index) => {
      const net = values[index];
      const barWidth = Math.round((Math.abs(net) / maxAbs) * width);
      const bar = barWidth === 0 ? "" : "█".repeat(barWidth);
      const left = net < 0 ? bar.padStart(width, " ") : "".padStart(width, " ");
      const right = net > 0 ? bar.padEnd(width, " ") : "".padEnd(width, " ");
      return `${padLabel(period.shortLabel, periodWidth)}  ${padCell(formatSignedCount(net), totalNetWidth)}  ${padCell(percent(net, baseline.totalLines), totalPctWidth)}  ${left}│${right}`;
    }),
  ].join("\n");
}

function renderMermaidGraph(periods, view) {
  const values = periods.map((period) => period.ts.add - period.ts.del + (period.tsx.add - period.tsx.del));
  const min = Math.min(...values, 0);
  const max = Math.max(...values, 0);
  const padding = Math.max(Math.ceil((max - min) * 0.1), 1);
  const lower = min - padding;
  const upper = max + padding;
  const labels = periods.map((period) => `"${period.shortLabel}"`).join(", ");
  const bars = values.join(", ");
  const title = `${view[0].toUpperCase()}${view.slice(1)} Net Code Change`;

  return [
    "```mermaid",
    "xychart-beta",
    `    title "${title}"`,
    `    x-axis [${labels}]`,
    `    y-axis "Net lines" ${lower} --> ${upper}`,
    `    bar [${bars}]`,
    "```",
  ].join("\n");
}

function renderGraph(periods, baseline, view, mode, title) {
  if (mode === GraphMode.NONE) return null;
  if (mode === GraphMode.MERMAID) {
    return renderMermaidGraph(periods, view);
  }
  return renderAsciiGraph(periods, baseline, title);
}

function getOverviewSummaries(args, specs) {
  const periods = specs.flatMap((spec) =>
    buildPeriods(spec.view, args.endDate, spec.periods).map((period) => ({
      ...period,
      sectionKey: spec.key,
    })),
  );
  return getSummariesForPeriods(args, periods);
}

function renderOverview(args, baseline) {
  const specs = buildOverviewSpecs();
  const allSummaries = getOverviewSummaries(args, specs);
  const overviewSections = specs.map((spec) => {
    const summaries = allSummaries.filter((summary) => summary.sectionKey === spec.key);
    return {
      title: spec.title,
      view: spec.view,
      periods: summaries,
      rows: makeSummaryRows(summaries, baseline).rows,
    };
  });
  const widths = getColumnWidths(overviewSections, args.details);
  const output = [
    renderCodebaseSummary(baseline),
    args.includeTests ? "churn includes tests" : "churn excludes tests (use --include-tests to include them)",
    renderTableHeader(widths, args.details),
  ];

  for (const section of overviewSections.slice().reverse()) {
    output.push(renderWindowSummary(section.periods, baseline, args.details, widths, section.title));
    const graph = renderGraph(section.periods, baseline, section.view, args.graph, `${section.title} trend`);
    if (graph) {
      output.push(graph);
    }
  }

  return output.join("\n\n");
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const baseline = getBaseline(args);
  if (!args.hasExplicitWindow) {
    console.log(renderOverview(args, baseline));
    return;
  }

  const periods = buildPeriods(args.view, args.endDate, args.periods);
  const summaries = getSummariesForPeriods(args, periods);
  const widths = getColumnWidths([{ rows: makeSummaryRows(summaries, baseline).rows }], args.details);
  const summary = [
    renderCodebaseSummary(baseline),
    args.includeTests ? "churn includes tests" : "churn excludes tests (use --include-tests to include them)",
    renderTableHeader(widths, args.details),
    renderWindowSummary(summaries, baseline, args.details, widths),
  ].join("\n\n");
  const graph = renderGraph(summaries, baseline, args.view, args.graph);

  console.log(summary);
  if (graph) {
    console.log("");
    console.log(graph);
  }
}

main();
