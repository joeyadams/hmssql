#!/usr/bin/env python3
"""Print median/min/max by API, preserving the C/Haskell distinction."""
import collections
import statistics
import sys

samples = collections.defaultdict(list)
for filename in sys.argv[1:]:
    language = "Haskell" if "odbc-haskell" in filename and "c-baseline" not in filename else "C"
    with open(filename) as source:
        for line in source:
            if not line.startswith("BENCH "):
                continue
            _, operation, *parts = line.split()
            v = dict(p.split("=", 1) for p in parts)
            config = " ".join(f"{k}={v[k]}" for k in
                              ("mars", "api", "encoding", "rowset", "parameter_array") if k in v)
            metrics = {"fetch": ["rows_per_sec"], "select1": ["us_per_query"],
                       "prepared_select": ["us_per_query"], "insert": ["ms"],
                       "connect_close": ["ms_per_connection"],
                       "blob": ["upload_MiB_per_sec", "download_MiB_per_sec"]}[operation]
            for metric in metrics:
                samples[(language, operation, config, metric)].append(float(v[metric]))
print("| Client | Operation | Configuration | Metric | N | Median | Min | Max |")
print("|---|---|---|---|---:|---:|---:|---:|")
for (client, operation, config, metric), xs in sorted(samples.items()):
    print(f"| {client} | {operation} | {config} | {metric} | {len(xs)} | "
          f"{statistics.median(xs):,.3f} | {min(xs):,.3f} | {max(xs):,.3f} |")
