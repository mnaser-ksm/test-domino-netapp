#!/usr/bin/env python3
from __future__ import annotations

import csv
import json
import os
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List

import yaml


@dataclass
class Config:
    run_name: str
    mode: str
    fail_fast: bool

    raw_dir: Path
    staging_dir: Path
    output_dir: Path
    reports_dir: Path
    logs_dir: Path

    source_file: str
    expected_columns: List[str]

    min_age: int
    add_migrated_at_utc: bool
    add_run_id: bool

    output_file: str
    report_file: str
    log_file: str


def die(msg: str, exit_code: int = 1) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(exit_code)


def log_line(log_path: Path, msg: str) -> None:
    ts = datetime.now(timezone.utc).isoformat()
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as f:
        f.write(f"{ts} {msg}\n")


def load_config(path: Path) -> Config:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))

    # Basic required fields (starter)
    run_name = data["run"]["name"]
    mode = data["run"].get("mode", "full")
    fail_fast = bool(data["run"].get("fail_fast", True))

    raw_dir = Path(data["paths"]["raw_dir"])
    staging_dir = Path(data["paths"]["staging_dir"])
    output_dir = Path(data["paths"]["output_dir"])
    reports_dir = Path(data["paths"]["reports_dir"])
    logs_dir = Path(data["paths"]["logs_dir"])

    source_file = data["inputs"]["source_file"]
    expected_columns = list(data["inputs"]["expected_columns"])

    min_age = int(data["transform"]["filter"].get("min_age", 0))
    add_cols = data["transform"].get("add_columns", {})
    add_migrated_at_utc = bool(add_cols.get("migrated_at_utc", True))
    add_run_id = bool(add_cols.get("run_id", True))

    output_file = data["outputs"]["output_file"]
    report_file = data["outputs"]["report_file"]
    log_file = data["outputs"]["log_file"]

    return Config(
        run_name=run_name,
        mode=mode,
        fail_fast=fail_fast,
        raw_dir=raw_dir,
        staging_dir=staging_dir,
        output_dir=output_dir,
        reports_dir=reports_dir,
        logs_dir=logs_dir,
        source_file=source_file,
        expected_columns=expected_columns,
        min_age=min_age,
        add_migrated_at_utc=add_migrated_at_utc,
        add_run_id=add_run_id,
        output_file=output_file,
        report_file=report_file,
        log_file=log_file,
    )


def ensure_dirs(cfg: Config) -> None:
    for d in [cfg.raw_dir, cfg.staging_dir, cfg.output_dir, cfg.reports_dir, cfg.logs_dir]:
        d.mkdir(parents=True, exist_ok=True)


def read_csv(input_path: Path) -> List[Dict[str, str]]:
    with input_path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames is None:
            die(f"No headers found in {input_path}")
        rows = list(reader)
    return rows


def validate_columns(rows: List[Dict[str, str]], expected: List[str], input_path: Path, fail_fast: bool) -> List[str]:
    if not rows:
        # still validate headers by re-reading quickly
        with input_path.open("r", encoding="utf-8", newline="") as f:
            reader = csv.DictReader(f)
            headers = reader.fieldnames or []
    else:
        headers = list(rows[0].keys())

    missing = [c for c in expected if c not in headers]
    extra = [c for c in headers if c not in expected]

    if missing and fail_fast:
        die(f"Missing expected columns {missing} in {input_path}. Headers were: {headers}")

    return headers  # return actual headers we saw


def transform_rows(
    rows: List[Dict[str, str]],
    cfg: Config,
    run_id: str,
    migrated_at: str,
) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []

    for r in rows:
        # Basic filter example
        try:
            age = int(r.get("age", "").strip())
        except ValueError:
            # Keep it simple: treat invalid age as -1 (filtered if min_age >= 0)
            age = -1

        if age < cfg.min_age:
            continue

        new_r: Dict[str, Any] = dict(r)
        if cfg.add_migrated_at_utc:
            new_r["migrated_at_utc"] = migrated_at
        if cfg.add_run_id:
            new_r["run_id"] = run_id

        out.append(new_r)

    return out


def write_csv(path: Path, rows: List[Dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        # Write an empty file with no rows; headers are unknown here
        path.write_text("", encoding="utf-8")
        return

    headers = list(rows[0].keys())
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=headers)
        writer.writeheader()
        writer.writerows(rows)


def write_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2), encoding="utf-8")


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python scripts/run_migration.py <config.yaml>", file=sys.stderr)
        return 2

    cfg_path = Path(sys.argv[1]).resolve()
    if not cfg_path.exists():
        die(f"Config file not found: {cfg_path}")

    cfg = load_config(cfg_path)
    ensure_dirs(cfg)

    run_id = str(uuid.uuid4())
    migrated_at = datetime.now(timezone.utc).isoformat()

    log_path = cfg.logs_dir / cfg.log_file
    log_line(log_path, f"START run_name={cfg.run_name} mode={cfg.mode} run_id={run_id}")

    input_path = cfg.raw_dir / cfg.source_file
    if not input_path.exists():
        log_line(log_path, f"FAIL missing_input file={input_path}")
        die(f"Input file not found: {input_path}")

    rows = read_csv(input_path)
    headers = validate_columns(rows, cfg.expected_columns, input_path, cfg.fail_fast)

    # Transform
    transformed = transform_rows(rows, cfg, run_id, migrated_at)

    # Write staging + final output (starter: same content; in real life staging differs)
    staging_path = cfg.staging_dir / f"staged_{cfg.source_file}"
    output_path = cfg.output_dir / cfg.output_file
    write_csv(staging_path, transformed)
    write_csv(output_path, transformed)

    report = {
        "run_name": cfg.run_name,
        "mode": cfg.mode,
        "run_id": run_id,
        "migrated_at_utc": migrated_at,
        "input_file": str(input_path),
        "staging_file": str(staging_path),
        "output_file": str(output_path),
        "input_rows": len(rows),
        "output_rows": len(transformed),
        "headers_seen": headers,
    }

    report_path = cfg.reports_dir / cfg.report_file
    write_json(report_path, report)

    log_line(
        log_path,
        f"SUCCESS input_rows={len(rows)} output_rows={len(transformed)} report={report_path}",
    )
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
