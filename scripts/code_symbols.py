"""Read symbol spans without confusing offsets in separate ELF text sections.

GHC info tables and alignment belong to the code footprint too. A span includes
the bytes up to the next symbol in its section, rather than just the function's
ELF size. The first symbol owns its section's prefix. Missing local symbols make
attribution coarser, but never change the section's total size.
"""
import collections
import subprocess


def text_symbols(path):
    sections = {}
    for line in subprocess.check_output(['size', '-A', path], text=True).splitlines():
        fields = line.split()
        if len(fields) == 3 and (fields[0] == '.text' or fields[0].startswith('.text.')):
            sections[fields[0]] = int(fields[1])
    symbols = collections.defaultdict(dict)
    for line in subprocess.check_output(['objdump', '-t', path], text=True).splitlines():
        fields = line.split()
        if len(fields) < 5:
            continue
        section, name = fields[-3], fields[-1]
        if section in sections and name != section:
            # Multiple aliases at one address describe the same bytes. Prefer
            # the first symbol rather than charging the span more than once.
            symbols[section].setdefault(int(fields[0], 16), name)
    for section, length in sections.items():
        entries = sorted(symbols[section].items())
        if not entries and length:
            yield section + ' (no symbols)', length
        for i, (address, name) in enumerate(entries):
            start = address if i else 0
            end = entries[i + 1][0] if i + 1 < len(entries) else length
            yield name, end - start
