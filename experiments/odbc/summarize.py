#!/usr/bin/env python3
"""Summarize the five measured rounds; warmups have no BENCH lines."""
import collections
import statistics
import sys

groups = collections.defaultdict(list)
for filename in sys.argv[1:]:
    with open(filename) as source:
        for line in source:
            if not line.startswith("BENCH "):
                continue
            _, operation, *fields = line.split()
            values = dict(field.split("=", 1) for field in fields)
            config = " ".join(f"{k}={values[k]}" for k in
                              ("mars", "encoding", "rowset", "parameter_array") if k in values)
            metrics = {
                "fetch": ["rows_per_sec"],
                "select1": ["us_per_query"],
                "prepared_select": ["us_per_query"],
                "connect_close": ["ms_per_connection"],
                "blob": ["upload_MiB_per_sec", "download_MiB_per_sec"],
                "insert": ["ms"],
            }[operation]
            for metric in metrics:
                groups[(operation, config, metric)].append(float(values[metric]))

print("| Operation | Configuration | Metric | Rounds | Median | Min | Max |")
print("|---|---|---|---:|---:|---:|---:|")
for (operation, config, metric), samples in sorted(groups.items()):
    print(f"| {operation} | {config} | {metric} | {len(samples)} | "
          f"{statistics.median(samples):,.3f} | {min(samples):,.3f} | {max(samples):,.3f} |")
