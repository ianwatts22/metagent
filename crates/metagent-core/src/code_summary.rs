use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

const BASELINE_EXCLUDED_DIRS: &[&str] = &[
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodeSummaryGraphMode {
    Ascii,
    Mermaid,
    None,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodeSummaryView {
    Daily,
    Weekly,
    Monthly,
}

#[derive(Debug)]
pub struct CodeSummaryOptions {
    pub repo_path: PathBuf,
    pub view: CodeSummaryView,
    pub periods: usize,
    pub end_date: Option<String>,
    pub include_tests: bool,
    pub details: bool,
    pub graph: CodeSummaryGraphMode,
    pub has_explicit_window: bool,
}

#[derive(Debug)]
pub struct CodeSummaryReport {
    pub text: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
struct Date {
    year: i32,
    month: u32,
    day: u32,
}

#[derive(Clone, Debug)]
struct Period {
    short_label: String,
    start: Date,
    end: Date,
    section_key: Option<&'static str>,
}

#[derive(Clone, Debug)]
struct ChangeStats {
    add: i64,
    del: i64,
}

#[derive(Clone, Debug)]
struct PeriodSummary {
    short_label: String,
    start: Date,
    end: Date,
    section_key: Option<&'static str>,
    ts: ChangeStats,
    tsx: ChangeStats,
}

#[derive(Clone, Debug, Default)]
struct BucketStats {
    files: u64,
    lines: u64,
}

#[derive(Clone, Debug, Default)]
struct BaselineStats {
    ts: BucketStats,
    ts_tests: BucketStats,
    tsx: BucketStats,
    tsx_tests: BucketStats,
    total_files: u64,
    total_lines: u64,
    coverage: Option<CoverageSummary>,
}

#[derive(Clone, Debug)]
struct CoverageSummary {
    path: String,
    lines: CoverageMetric,
    statements: Option<CoverageMetric>,
    functions: Option<CoverageMetric>,
    branches: Option<CoverageMetric>,
}

#[derive(Clone, Debug)]
struct CoverageMetric {
    pct: f64,
    covered: Option<u64>,
    total: Option<u64>,
}

#[derive(Clone, Debug)]
struct SummaryRow {
    period: String,
    all_net: String,
    all_pct: String,
    ts_net: String,
    ts_pct: String,
    tsx_net: String,
    tsx_pct: String,
    churn: String,
}

#[derive(Clone, Debug)]
struct SummaryRows {
    rows: Vec<SummaryRow>,
    totals: SummaryTotals,
}

#[derive(Clone, Debug)]
struct SummaryTotals {
    all: i64,
    ts: i64,
    tsx: i64,
}

#[derive(Clone, Debug)]
struct ColumnWidths {
    period: usize,
    all_net: usize,
    all_pct: usize,
    ts_net: usize,
    ts_pct: usize,
    tsx_net: usize,
    tsx_pct: usize,
    churn: usize,
}

#[derive(Clone, Debug)]
struct OverviewSpec {
    key: &'static str,
    title: &'static str,
    view: CodeSummaryView,
    periods: usize,
}

#[derive(Clone, Debug)]
struct OverviewSection {
    title: &'static str,
    view: CodeSummaryView,
    periods: Vec<PeriodSummary>,
    rows: Vec<SummaryRow>,
}

pub fn code_summary(options: &CodeSummaryOptions) -> Result<CodeSummaryReport, String> {
    if options.periods == 0 {
        return Err("period count must be greater than zero".to_string());
    }

    let repo_path = expand_tilde(&options.repo_path);
    if !repo_path.is_dir() {
        return Err(format!(
            "repo path is not a directory: {}",
            repo_path.display()
        ));
    }

    let end_date = match &options.end_date {
        Some(value) => parse_date(value)?,
        None => current_local_date()?,
    };
    let baseline = get_baseline(&repo_path)?;

    let text = if options.has_explicit_window {
        render_explicit_window(options, &repo_path, end_date, &baseline)?
    } else {
        render_overview(options, &repo_path, end_date, &baseline)?
    };

    Ok(CodeSummaryReport { text })
}

fn render_explicit_window(
    options: &CodeSummaryOptions,
    repo_path: &Path,
    end_date: Date,
    baseline: &BaselineStats,
) -> Result<String, String> {
    let periods = build_periods(options.view, end_date, options.periods, None);
    let summaries = get_summaries_for_periods(options, repo_path, &periods)?;
    let rows = make_summary_rows(&summaries, baseline);
    let widths = get_column_widths(std::slice::from_ref(&rows.rows), options.details);
    let mut sections = vec![
        render_codebase_summary(baseline),
        churn_scope_line(options),
        render_table_header(&widths, options.details),
        render_window_summary(&summaries, baseline, options.details, &widths, None),
    ];

    if let Some(graph) = render_graph(&summaries, baseline, options.view, options.graph, "graph") {
        sections.push(graph);
    }

    Ok(sections.join("\n\n"))
}

fn render_overview(
    options: &CodeSummaryOptions,
    repo_path: &Path,
    end_date: Date,
    baseline: &BaselineStats,
) -> Result<String, String> {
    let specs = build_overview_specs();
    let periods: Vec<Period> = specs
        .iter()
        .flat_map(|spec| build_periods(spec.view, end_date, spec.periods, Some(spec.key)))
        .collect();
    let all_summaries = get_summaries_for_periods(options, repo_path, &periods)?;

    let sections: Vec<OverviewSection> = specs
        .iter()
        .map(|spec| {
            let periods: Vec<PeriodSummary> = all_summaries
                .iter()
                .filter(|summary| summary.section_key == Some(spec.key))
                .cloned()
                .collect();
            let rows = make_summary_rows(&periods, baseline).rows;
            OverviewSection {
                title: spec.title,
                view: spec.view,
                periods,
                rows,
            }
        })
        .collect();

    let row_sets: Vec<Vec<SummaryRow>> = sections
        .iter()
        .map(|section| section.rows.clone())
        .collect();
    let widths = get_column_widths(&row_sets, options.details);
    let mut output = vec![
        render_codebase_summary(baseline),
        churn_scope_line(options),
        render_table_header(&widths, options.details),
    ];

    for section in sections.iter().rev() {
        output.push(render_window_summary(
            &section.periods,
            baseline,
            options.details,
            &widths,
            Some(section.title),
        ));
        if let Some(graph) = render_graph(
            &section.periods,
            baseline,
            section.view,
            options.graph,
            &format!("{} trend", section.title),
        ) {
            output.push(graph);
        }
    }

    Ok(output.join("\n\n"))
}

fn build_overview_specs() -> Vec<OverviewSpec> {
    vec![
        OverviewSpec {
            key: "daily",
            title: "last 5 days",
            view: CodeSummaryView::Daily,
            periods: 5,
        },
        OverviewSpec {
            key: "weekly",
            title: "this week + previous 2 weeks",
            view: CodeSummaryView::Weekly,
            periods: 3,
        },
        OverviewSpec {
            key: "monthly",
            title: "this month + previous month",
            view: CodeSummaryView::Monthly,
            periods: 2,
        },
    ]
}

fn build_periods(
    view: CodeSummaryView,
    end_date: Date,
    count: usize,
    section_key: Option<&'static str>,
) -> Vec<Period> {
    let mut periods = Vec::new();
    let mut cursor_end = end_date;

    for _ in 0..count {
        match view {
            CodeSummaryView::Daily => {
                periods.push(Period {
                    short_label: short_date(cursor_end),
                    start: cursor_end,
                    end: cursor_end,
                    section_key,
                });
                cursor_end = add_days(cursor_end, -1);
            }
            CodeSummaryView::Weekly => {
                let start = start_of_week(cursor_end);
                let end = if periods.is_empty() {
                    cursor_end
                } else {
                    end_of_week(cursor_end)
                };
                periods.push(Period {
                    short_label: short_range_label(start, end),
                    start,
                    end,
                    section_key,
                });
                cursor_end = add_days(start, -1);
            }
            CodeSummaryView::Monthly => {
                let start = start_of_month(cursor_end);
                let end = if periods.is_empty() {
                    cursor_end
                } else {
                    end_of_month(cursor_end)
                };
                periods.push(Period {
                    short_label: format!("{}-{:02}", start.year, start.month),
                    start,
                    end,
                    section_key,
                });
                cursor_end = add_days(start, -1);
            }
        }
    }

    periods.reverse();
    periods
}

fn get_baseline(repo_path: &Path) -> Result<BaselineStats, String> {
    let raw = run(
        "scc",
        &[
            "--include-ext",
            "ts,tsx",
            "--exclude-dir",
            &BASELINE_EXCLUDED_DIRS.join(","),
            "--by-file",
            "--format",
            "csv",
            "--no-complexity",
            "--no-cocomo",
            "--no-size",
            ".",
        ],
        repo_path,
    )?;

    let mut baseline = BaselineStats::default();
    for (index, line) in raw.lines().enumerate() {
        if index == 0 || line.trim().is_empty() {
            continue;
        }
        let fields = parse_csv_line(line);
        if fields.len() < 5 {
            continue;
        }

        let location = fields[1].trim();
        let code = fields[4].trim().parse::<u64>().unwrap_or(0);
        if location.ends_with(".ts") {
            if is_test_file(location) {
                add_file_to_baseline(&mut baseline.ts_tests, code);
            } else {
                add_file_to_baseline(&mut baseline.ts, code);
            }
            baseline.total_files += 1;
            baseline.total_lines += code;
            continue;
        }
        if location.ends_with(".tsx") {
            if is_test_file(location) {
                add_file_to_baseline(&mut baseline.tsx_tests, code);
            } else {
                add_file_to_baseline(&mut baseline.tsx, code);
            }
            baseline.total_files += 1;
            baseline.total_lines += code;
        }
    }

    baseline.coverage = get_coverage_summary(repo_path);
    Ok(baseline)
}

fn add_file_to_baseline(bucket: &mut BucketStats, lines: u64) {
    bucket.files += 1;
    bucket.lines += lines;
}

fn get_summaries_for_periods(
    options: &CodeSummaryOptions,
    repo_path: &Path,
    periods: &[Period],
) -> Result<Vec<PeriodSummary>, String> {
    let mut summaries: Vec<PeriodSummary> = periods
        .iter()
        .map(|period| PeriodSummary {
            short_label: period.short_label.clone(),
            start: period.start,
            end: period.end,
            section_key: period.section_key,
            ts: ChangeStats { add: 0, del: 0 },
            tsx: ChangeStats { add: 0, del: 0 },
        })
        .collect();

    let Some(first) = summaries.first() else {
        return Ok(summaries);
    };
    let Some(last) = summaries.last() else {
        return Ok(summaries);
    };

    let mut args = vec![
        "log".to_string(),
        format!("--since={} 00:00:00", format_date(first.start)),
        format!("--until={} 23:59:59", format_date(last.end)),
        "--numstat".to_string(),
        "--pretty=tformat:%ct".to_string(),
        "--".to_string(),
    ];
    args.extend(get_git_pathspecs(options.include_tests));

    let raw = run_owned("git", &args, repo_path)?;
    let mut current_date: Option<Date> = None;
    let mut date_cache = HashMap::new();

    for line in raw.lines() {
        if line.trim().is_empty() {
            continue;
        }
        if line.chars().all(|char| char.is_ascii_digit()) {
            let epoch = line.parse::<u64>().unwrap_or(0);
            current_date = Some(epoch_to_local_date(epoch, &mut date_cache)?);
            continue;
        }

        let mut parts = line.split('\t');
        let Some(add_raw) = parts.next() else {
            continue;
        };
        let Some(del_raw) = parts.next() else {
            continue;
        };
        let Some(path) = parts.next() else {
            continue;
        };
        let Some(date) = current_date else {
            continue;
        };
        let Ok(add) = add_raw.parse::<i64>() else {
            continue;
        };
        let Ok(del) = del_raw.parse::<i64>() else {
            continue;
        };

        let ext = if path.ends_with(".tsx") {
            Some("tsx")
        } else if path.ends_with(".ts") {
            Some("ts")
        } else {
            None
        };
        let Some(ext) = ext else {
            continue;
        };

        for summary in &mut summaries {
            if date < summary.start || date > summary.end {
                continue;
            }
            match ext {
                "ts" => {
                    summary.ts.add += add;
                    summary.ts.del += del;
                }
                "tsx" => {
                    summary.tsx.add += add;
                    summary.tsx.del += del;
                }
                _ => {}
            }
        }
    }

    Ok(summaries)
}

fn get_git_pathspecs(include_tests: bool) -> Vec<String> {
    let mut out = vec!["*.ts".to_string(), "*.tsx".to_string()];
    for dir in BASELINE_EXCLUDED_DIRS {
        out.push(format!(":(exclude){dir}/**"));
        out.push(format!(":(exclude)**/{dir}/**"));
    }
    if !include_tests {
        out.extend([
            ":(exclude)tests/**".to_string(),
            ":(exclude)**/tests/**".to_string(),
            ":(exclude)**/*.test.ts".to_string(),
            ":(exclude)**/*.spec.ts".to_string(),
            ":(exclude)**/*.test.tsx".to_string(),
            ":(exclude)**/*.spec.tsx".to_string(),
        ]);
    }
    out
}

fn make_summary_rows(periods: &[PeriodSummary], baseline: &BaselineStats) -> SummaryRows {
    let mut total_ts = 0;
    let mut total_tsx = 0;
    let rows = periods
        .iter()
        .map(|period| {
            let ts_net = period.ts.add - period.ts.del;
            let tsx_net = period.tsx.add - period.tsx.del;
            let all_add = period.ts.add + period.tsx.add;
            let all_del = period.ts.del + period.tsx.del;
            let all_net = ts_net + tsx_net;
            total_ts += ts_net;
            total_tsx += tsx_net;

            SummaryRow {
                period: period.short_label.clone(),
                all_net: format_signed_count(all_net),
                all_pct: percent(all_net, baseline.total_lines),
                ts_net: format_signed_count(ts_net),
                ts_pct: percent(ts_net, baseline.ts.lines),
                tsx_net: format_signed_count(tsx_net),
                tsx_pct: percent(tsx_net, baseline.tsx.lines),
                churn: format!(
                    "+{} / -{}",
                    format_count_i64(all_add),
                    format_count_i64(all_del)
                ),
            }
        })
        .collect();

    SummaryRows {
        rows,
        totals: SummaryTotals {
            all: total_ts + total_tsx,
            ts: total_ts,
            tsx: total_tsx,
        },
    }
}

fn get_column_widths(row_sets: &[Vec<SummaryRow>], details: bool) -> ColumnWidths {
    let rows: Vec<&SummaryRow> = row_sets.iter().flat_map(|set| set.iter()).collect();
    ColumnWidths {
        period: max_width("period", rows.iter().map(|row| row.period.as_str())),
        all_net: max_width("total net", rows.iter().map(|row| row.all_net.as_str())),
        all_pct: max_width("total %", rows.iter().map(|row| row.all_pct.as_str())),
        ts_net: max_width("ts net", rows.iter().map(|row| row.ts_net.as_str())),
        ts_pct: max_width("ts %", rows.iter().map(|row| row.ts_pct.as_str())),
        tsx_net: max_width("tsx net", rows.iter().map(|row| row.tsx_net.as_str())),
        tsx_pct: max_width("tsx %", rows.iter().map(|row| row.tsx_pct.as_str())),
        churn: if details {
            max_width("adds / dels", rows.iter().map(|row| row.churn.as_str()))
        } else {
            0
        },
    }
}

fn max_width<'a>(label: &str, values: impl Iterator<Item = &'a str>) -> usize {
    values.fold(label.len(), |width, value| width.max(value.len()))
}

fn render_table_header(widths: &ColumnWidths, details: bool) -> String {
    let mut out = format!(
        "{}  {}  {}  {}  {}  {}  {}",
        pad_label("period", widths.period),
        pad_cell("total net", widths.all_net),
        pad_cell("total %", widths.all_pct),
        pad_cell("ts net", widths.ts_net),
        pad_cell("ts %", widths.ts_pct),
        pad_cell("tsx net", widths.tsx_net),
        pad_cell("tsx %", widths.tsx_pct)
    );
    if details {
        out.push_str(&format!("  {}", pad_cell("adds / dels", widths.churn)));
    }
    out
}

fn render_row(row: &SummaryRow, widths: &ColumnWidths, details: bool) -> String {
    let mut out = format!(
        "{}  {}  {}  {}  {}  {}  {}",
        pad_label(&row.period, widths.period),
        pad_cell(&row.all_net, widths.all_net),
        pad_cell(&row.all_pct, widths.all_pct),
        pad_cell(&row.ts_net, widths.ts_net),
        pad_cell(&row.ts_pct, widths.ts_pct),
        pad_cell(&row.tsx_net, widths.tsx_net),
        pad_cell(&row.tsx_pct, widths.tsx_pct)
    );
    if details {
        out.push_str(&format!("  {}", pad_cell(&row.churn, widths.churn)));
    }
    out
}

fn render_window_summary(
    periods: &[PeriodSummary],
    baseline: &BaselineStats,
    details: bool,
    widths: &ColumnWidths,
    title: Option<&str>,
) -> String {
    let rows = make_summary_rows(periods, baseline);
    let mut lines = Vec::new();
    if let Some(title) = title {
        lines.push(title.to_string());
    }
    for row in &rows.rows {
        lines.push(render_row(row, widths, details));
    }
    lines.push(String::new());
    lines.push(render_window_totals(&rows.totals, baseline));
    lines.join("\n")
}

fn render_window_totals(totals: &SummaryTotals, baseline: &BaselineStats) -> String {
    format!(
        "total {}  {} | ts {}  {} | tsx {}  {}",
        format_signed_count(totals.all),
        percent(totals.all, baseline.total_lines),
        format_signed_count(totals.ts),
        percent(totals.ts, baseline.ts.lines),
        format_signed_count(totals.tsx),
        percent(totals.tsx, baseline.tsx.lines)
    )
}

fn render_codebase_summary(baseline: &BaselineStats) -> String {
    let rows = [
        ("tsx", &baseline.tsx),
        ("tsx tests", &baseline.tsx_tests),
        ("ts", &baseline.ts),
        ("ts tests", &baseline.ts_tests),
    ];
    let label_width = rows
        .iter()
        .fold("".len(), |width, (label, _)| width.max(label.len()));
    let file_width = rows.iter().fold("files".len(), |width, (_, stats)| {
        width.max(format_count(stats.files).len())
    });
    let line_width = rows.iter().fold("lines".len(), |width, (_, stats)| {
        width.max(format_count(stats.lines).len())
    });

    let mut lines = vec![
        "codebase".to_string(),
        format!(
            "total files {} | total lines {}",
            format_count(baseline.total_files),
            format_count(baseline.total_lines)
        ),
    ];

    for (label, stats) in rows {
        lines.push(format!(
            "{}  {} files  {} lines  {}",
            pad_label(label, label_width),
            pad_cell(&format_count(stats.files), file_width),
            pad_cell(&format_count(stats.lines), line_width),
            percent_u64(stats.lines, baseline.total_lines)
        ));
    }

    lines.push(String::new());
    lines.push("coverage".to_string());
    if let Some(coverage) = &baseline.coverage {
        lines.push(format!("source {}", coverage.path));
        lines.push(format_coverage_metric("lines", Some(&coverage.lines)));
        lines.push(format_coverage_metric(
            "statements",
            coverage.statements.as_ref(),
        ));
        lines.push(format_coverage_metric(
            "functions",
            coverage.functions.as_ref(),
        ));
        lines.push(format_coverage_metric(
            "branches",
            coverage.branches.as_ref(),
        ));
    } else {
        lines.push("unavailable".to_string());
    }

    lines.join("\n")
}

fn render_graph(
    periods: &[PeriodSummary],
    baseline: &BaselineStats,
    view: CodeSummaryView,
    mode: CodeSummaryGraphMode,
    title: &str,
) -> Option<String> {
    match mode {
        CodeSummaryGraphMode::None => None,
        CodeSummaryGraphMode::Mermaid => Some(render_mermaid_graph(periods, view)),
        CodeSummaryGraphMode::Ascii => Some(render_ascii_graph(periods, baseline, title)),
    }
}

fn render_ascii_graph(periods: &[PeriodSummary], baseline: &BaselineStats, title: &str) -> String {
    let values: Vec<i64> = periods
        .iter()
        .map(|period| period.ts.add - period.ts.del + period.tsx.add - period.tsx.del)
        .collect();
    let max_abs = values
        .iter()
        .map(|value| value.abs())
        .max()
        .unwrap_or(1)
        .max(1);
    let width = 18usize;
    let period_width = max_width(
        "period",
        periods.iter().map(|period| period.short_label.as_str()),
    );
    let net_values: Vec<String> = values
        .iter()
        .map(|value| format_signed_count(*value))
        .collect();
    let net_width = max_width("total net", net_values.iter().map(String::as_str));
    let pct_values: Vec<String> = values
        .iter()
        .map(|value| percent(*value, baseline.total_lines))
        .collect();
    let pct_width = max_width("total %", pct_values.iter().map(String::as_str));

    let mut lines = vec![
        title.to_string(),
        format!(
            "{}  {}  {}  trend",
            pad_label("period", period_width),
            pad_cell("total net", net_width),
            pad_cell("total %", pct_width)
        ),
    ];

    for (index, period) in periods.iter().enumerate() {
        let net = values[index];
        let bar_width = ((net.abs() as f64 / max_abs as f64) * width as f64).round() as usize;
        let bar = "#".repeat(bar_width);
        let left = if net < 0 {
            pad_cell(&bar, width)
        } else {
            " ".repeat(width)
        };
        let right = if net > 0 {
            pad_label(&bar, width)
        } else {
            " ".repeat(width)
        };
        lines.push(format!(
            "{}  {}  {}  {}|{}",
            pad_label(&period.short_label, period_width),
            pad_cell(&format_signed_count(net), net_width),
            pad_cell(&percent(net, baseline.total_lines), pct_width),
            left,
            right
        ));
    }

    lines.join("\n")
}

fn render_mermaid_graph(periods: &[PeriodSummary], view: CodeSummaryView) -> String {
    let values: Vec<i64> = periods
        .iter()
        .map(|period| period.ts.add - period.ts.del + period.tsx.add - period.tsx.del)
        .collect();
    let min = values.iter().copied().min().unwrap_or(0).min(0);
    let max = values.iter().copied().max().unwrap_or(0).max(0);
    let padding = (((max - min) as f64) * 0.1).ceil().max(1.0) as i64;
    let labels = periods
        .iter()
        .map(|period| format!("\"{}\"", period.short_label))
        .collect::<Vec<_>>()
        .join(", ");
    let bars = values
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(", ");
    let title = match view {
        CodeSummaryView::Daily => "Daily Net Code Change",
        CodeSummaryView::Weekly => "Weekly Net Code Change",
        CodeSummaryView::Monthly => "Monthly Net Code Change",
    };

    [
        "```mermaid".to_string(),
        "xychart-beta".to_string(),
        format!("    title \"{title}\""),
        format!("    x-axis [{labels}]"),
        format!(
            "    y-axis \"Net lines\" {} --> {}",
            min - padding,
            max + padding
        ),
        format!("    bar [{bars}]"),
        "```".to_string(),
    ]
    .join("\n")
}

fn churn_scope_line(options: &CodeSummaryOptions) -> String {
    if options.include_tests {
        "churn includes tests".to_string()
    } else {
        "churn excludes tests (use --include-tests to include them)".to_string()
    }
}

fn format_coverage_metric(label: &str, metric: Option<&CoverageMetric>) -> String {
    let Some(metric) = metric else {
        return format!("{label} n/a");
    };
    match (metric.covered, metric.total) {
        (Some(covered), Some(total)) => format!(
            "{label} {} ({} / {})",
            format_percent(metric.pct),
            format_count(covered),
            format_count(total)
        ),
        _ => format!("{label} {}", format_percent(metric.pct)),
    }
}

fn get_coverage_summary(repo_path: &Path) -> Option<CoverageSummary> {
    let path = find_coverage_summary_path(repo_path)?;
    let raw = fs::read_to_string(repo_path.join(&path)).ok()?;
    let scope = extract_object_after_key(&raw, "total").unwrap_or_else(|| raw.clone());
    let lines = extract_metric(&scope, "lines")?;
    Some(CoverageSummary {
        path,
        lines,
        statements: extract_metric(&scope, "statements"),
        functions: extract_metric(&scope, "functions"),
        branches: extract_metric(&scope, "branches"),
    })
}

fn find_coverage_summary_path(repo_path: &Path) -> Option<String> {
    for candidate in [
        "coverage/coverage-summary.json",
        "coverage/summary.json",
        ".nyc_output/coverage-summary.json",
    ] {
        if repo_path.join(candidate).is_file() {
            return Some(candidate.to_string());
        }
    }

    let mut stack = vec![repo_path.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let entries = fs::read_dir(&dir).ok()?;
        for entry in entries.flatten() {
            let path = entry.path();
            let file_name = entry.file_name();
            let name = file_name.to_string_lossy();
            if path.is_dir() {
                if matches!(
                    name.as_ref(),
                    ".git" | "node_modules" | "target" | "dist" | "build"
                ) {
                    continue;
                }
                stack.push(path);
                continue;
            }
            if name != "coverage-summary.json" && name != "summary.json" {
                continue;
            }
            let relative = path.strip_prefix(repo_path).ok()?;
            let value = relative.to_string_lossy().replace('\\', "/");
            if value.contains("/coverage/") || value.starts_with("coverage/") {
                return Some(value);
            }
        }
    }
    None
}

fn extract_metric(scope: &str, key: &str) -> Option<CoverageMetric> {
    let object = extract_object_after_key(scope, key)?;
    let pct = extract_number_field(&object, "pct")?;
    Some(CoverageMetric {
        pct,
        covered: extract_number_field(&object, "covered").map(|value| value as u64),
        total: extract_number_field(&object, "total").map(|value| value as u64),
    })
}

fn extract_object_after_key(input: &str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\"");
    let start = input.find(&needle)?;
    let object_start = input[start..].find('{')? + start;
    let mut depth = 0i32;
    let mut in_string = false;
    let mut escaped = false;
    for (index, char) in input[object_start..].char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if char == '\\' && in_string {
            escaped = true;
            continue;
        }
        if char == '"' {
            in_string = !in_string;
            continue;
        }
        if in_string {
            continue;
        }
        if char == '{' {
            depth += 1;
        } else if char == '}' {
            depth -= 1;
            if depth == 0 {
                let end = object_start + index + char.len_utf8();
                return Some(input[object_start..end].to_string());
            }
        }
    }
    None
}

fn extract_number_field(input: &str, key: &str) -> Option<f64> {
    let needle = format!("\"{key}\"");
    let start = input.find(&needle)?;
    let colon = input[start..].find(':')? + start;
    let value_start = input[colon + 1..]
        .find(|char: char| char.is_ascii_digit() || char == '-' || char == '.')?
        + colon
        + 1;
    let value_end = input[value_start..]
        .find(|char: char| !(char.is_ascii_digit() || char == '-' || char == '.'))
        .map(|offset| value_start + offset)
        .unwrap_or(input.len());
    input[value_start..value_end].parse().ok()
}

fn is_test_file(location: &str) -> bool {
    location.starts_with("tests/")
        || location.contains("/tests/")
        || location.ends_with(".test.ts")
        || location.ends_with(".spec.ts")
        || location.ends_with(".test.tsx")
        || location.ends_with(".spec.tsx")
}

fn parse_csv_line(line: &str) -> Vec<String> {
    let mut fields = Vec::new();
    let mut current = String::new();
    let mut chars = line.chars().peekable();
    let mut in_quotes = false;

    while let Some(char) = chars.next() {
        match char {
            '"' if in_quotes && chars.peek() == Some(&'"') => {
                current.push('"');
                chars.next();
            }
            '"' => in_quotes = !in_quotes,
            ',' if !in_quotes => {
                fields.push(current);
                current = String::new();
            }
            _ => current.push(char),
        }
    }
    fields.push(current);
    fields
}

fn run(cmd: &str, args: &[&str], cwd: &Path) -> Result<String, String> {
    let args = args
        .iter()
        .map(|arg| (*arg).to_string())
        .collect::<Vec<_>>();
    run_owned(cmd, &args, cwd)
}

fn run_owned(cmd: &str, args: &[String], cwd: &Path) -> Result<String, String> {
    let output = Command::new(cmd)
        .args(args)
        .current_dir(cwd)
        .output()
        .map_err(|error| format!("failed running {cmd}: {error}"))?;
    if output.status.success() {
        return Ok(String::from_utf8_lossy(&output.stdout).trim().to_string());
    }
    Err(format!(
        "command failed: {} {}\n{}{}",
        cmd,
        args.join(" "),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    ))
}

fn current_local_date() -> Result<Date, String> {
    let output = Command::new("date").arg("+%Y-%m-%d").output();
    if let Ok(output) = output
        && output.status.success()
    {
        let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
        return parse_date(&value);
    }

    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| format!("system clock is before UNIX epoch: {error}"))?
        .as_secs();
    Ok(civil_from_days((seconds / 86_400) as i64))
}

fn epoch_to_local_date(epoch: u64, cache: &mut HashMap<u64, Date>) -> Result<Date, String> {
    if let Some(date) = cache.get(&epoch) {
        return Ok(*date);
    }

    let output = Command::new("date")
        .arg("-r")
        .arg(epoch.to_string())
        .arg("+%Y-%m-%d")
        .output();
    let date = if let Ok(output) = output {
        if output.status.success() {
            parse_date(String::from_utf8_lossy(&output.stdout).trim())?
        } else {
            civil_from_days((epoch / 86_400) as i64)
        }
    } else {
        civil_from_days((epoch / 86_400) as i64)
    };

    cache.insert(epoch, date);
    Ok(date)
}

fn parse_date(value: &str) -> Result<Date, String> {
    let parts: Vec<&str> = value.split('-').collect();
    if parts.len() != 3 {
        return Err(format!("invalid date: {value}. Expected YYYY-MM-DD."));
    }
    let year = parts[0]
        .parse::<i32>()
        .map_err(|_| format!("invalid date: {value}. Expected YYYY-MM-DD."))?;
    let month = parts[1]
        .parse::<u32>()
        .map_err(|_| format!("invalid date: {value}. Expected YYYY-MM-DD."))?;
    let day = parts[2]
        .parse::<u32>()
        .map_err(|_| format!("invalid date: {value}. Expected YYYY-MM-DD."))?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return Err(format!("invalid date: {value}. Expected YYYY-MM-DD."));
    }
    Ok(Date { year, month, day })
}

fn format_date(date: Date) -> String {
    format!("{:04}-{:02}-{:02}", date.year, date.month, date.day)
}

fn short_date(date: Date) -> String {
    format!("{:02}-{:02}", date.month, date.day)
}

fn short_range_label(start: Date, end: Date) -> String {
    format!("{}..{}", short_date(start), short_date(end))
}

fn start_of_week(date: Date) -> Date {
    let day = weekday_sunday_zero(date);
    let diff = if day == 0 { -6 } else { 1 - day as i64 };
    add_days(date, diff)
}

fn end_of_week(date: Date) -> Date {
    add_days(start_of_week(date), 6)
}

fn start_of_month(date: Date) -> Date {
    Date {
        year: date.year,
        month: date.month,
        day: 1,
    }
}

fn end_of_month(date: Date) -> Date {
    let next_month = if date.month == 12 {
        Date {
            year: date.year + 1,
            month: 1,
            day: 1,
        }
    } else {
        Date {
            year: date.year,
            month: date.month + 1,
            day: 1,
        }
    };
    add_days(next_month, -1)
}

fn add_days(date: Date, days: i64) -> Date {
    civil_from_days(days_from_civil(date) + days)
}

fn weekday_sunday_zero(date: Date) -> u32 {
    (days_from_civil(date) + 4).rem_euclid(7) as u32
}

fn days_from_civil(date: Date) -> i64 {
    let mut year = date.year as i64;
    let month = date.month as i64;
    let day = date.day as i64;
    year -= if month <= 2 { 1 } else { 0 };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let yoe = year - era * 400;
    let mp = month + if month > 2 { -3 } else { 9 };
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil_from_days(days: i64) -> Date {
    let days = days + 719_468;
    let era = if days >= 0 { days } else { days - 146_096 } / 146_097;
    let doe = days - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let mut year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    year += if month <= 2 { 1 } else { 0 };
    Date {
        year: year as i32,
        month: month as u32,
        day: day as u32,
    }
}

fn percent(value: i64, total: u64) -> String {
    if total == 0 {
        return "0.00%".to_string();
    }
    format!("{:.2}%", (value as f64 / total as f64) * 100.0)
}

fn percent_u64(value: u64, total: u64) -> String {
    if total == 0 {
        return "0.00%".to_string();
    }
    format!("{:.2}%", (value as f64 / total as f64) * 100.0)
}

fn format_percent(value: f64) -> String {
    format!("{value:.2}%")
}

fn format_signed_count(value: i64) -> String {
    if value > 0 {
        format!("+{}", format_count_i64(value))
    } else if value < 0 {
        format!("-{}", format_count_i64(value.abs()))
    } else {
        "0".to_string()
    }
}

fn format_count_i64(value: i64) -> String {
    format_count(value.unsigned_abs())
}

fn format_count(value: u64) -> String {
    let raw = value.to_string();
    let mut out = String::new();
    for (index, char) in raw.chars().rev().enumerate() {
        if index > 0 && index % 3 == 0 {
            out.push(',');
        }
        out.push(char);
    }
    out.chars().rev().collect()
}

fn pad_cell(value: &str, width: usize) -> String {
    format!("{value:>width$}")
}

fn pad_label(value: &str, width: usize) -> String {
    format!("{value:<width$}")
}

fn expand_tilde(path: &Path) -> PathBuf {
    let Some(raw) = path.to_str() else {
        return path.to_path_buf();
    };
    if raw == "~" {
        return home_dir();
    }
    if let Some(rest) = raw.strip_prefix("~/") {
        return home_dir().join(rest);
    }
    path.to_path_buf()
}

fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn date_math_round_trips_unix_epoch() {
        let date = Date {
            year: 1970,
            month: 1,
            day: 1,
        };
        assert_eq!(days_from_civil(date), 0);
        assert_eq!(civil_from_days(0), date);
    }

    #[test]
    fn weekly_period_starts_on_monday() {
        let sunday = Date {
            year: 2026,
            month: 6,
            day: 7,
        };
        assert_eq!(
            start_of_week(sunday),
            Date {
                year: 2026,
                month: 6,
                day: 1
            }
        );
    }

    #[test]
    fn detects_test_files() {
        assert!(is_test_file("tests/foo.ts"));
        assert!(is_test_file("src/foo.test.tsx"));
        assert!(is_test_file("src/foo.spec.ts"));
        assert!(!is_test_file("src/foo.ts"));
    }

    #[test]
    fn parses_basic_csv_line() {
        let fields = parse_csv_line("TypeScript,src/a.ts,a.ts,10,8,0,2,0,100,0");
        assert_eq!(fields[1], "src/a.ts");
        assert_eq!(fields[4], "8");
    }
}
