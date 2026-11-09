#!/usr/bin/env python3
"""Print hspec --match arguments, one per line, for every failure in a test log.

Reads the "To rerun use: --match "..."" line hspec prints under each failure
and unescapes it, so that the output can be read into a Bash array and passed
back to the suite:

    mapfile -t args < <(scripts/rerun-args.py LOG)
    scripts/azure-sql-test.sh run "${args[@]}"
"""
import re
import sys

RERUN = re.compile(r'To rerun use: --match "((?:\\.|[^"\\])*)"')

for match in RERUN.finditer(open(sys.argv[1], encoding="utf-8").read()):
    print("--match")
    print(re.sub(r"\\(.)", r"\1", match.group(1)))
