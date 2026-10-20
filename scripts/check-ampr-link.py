#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Artur Strazewicz
"""Link a synthetic issue #8 dependency graph without executing guest code.

Usage: python scripts/check-ampr-link.py zig-out/bin/graph-info.exe
Fixtures contain no game or firmware code and remain in out/ampr-link-regression.
The pre-fix diagnostic reports precisely the 21 libkernel imports from #8.
"""
import pathlib
import struct
import subprocess
import sys

NIDS = """5b3ZqlxJ+WE G-NhAZUNlwc 3M8jROcYzjs tNaDjIbVOwc
VZPXaaxp9xc G5tFhAqrCTg sJrF-d2uL0Y HYzkJb41fcE B4xIPqeRONI
2zLw9GwrtyI hrEIwWDKm-w rm5-jOxSZzQ TyzsoH-vx8o MCdZ06CSUOc
ahy8NSXrSbs H59T7YvKI5M 3GqBPApWgPY 9bfdLIyuwCY 9WK-vhNXimw
1yXS+iqB3wQ teiItL2boFw""".split()


def image(path, kind, imports, needed=None):
    strings = bytearray(b"\0libkernel\0")
    names = []
    for nid in imports:
        names.append(len(strings))
        strings.extend((nid + "#A#A\0").encode())
    needed_offset = len(strings)
    if needed:
        strings.extend(needed.encode() + b"\0")
    payload = bytearray(strings)
    payload.extend(bytes((-len(payload)) % 8))
    symbols_offset = len(payload)
    payload.extend(bytes(24))  # ELF symbol zero.
    for name in names:
        payload.extend(struct.pack("<IBBHQQ", name, 0x12, 0, 0, 0, 0))
    relocations_offset = len(payload)
    for index in range(len(imports)):
        payload.extend(struct.pack("<QQq", 0x1000 + 8 * index, ((index + 1) << 32) | 7, 0))
    entries = [
        (0x61000035, 0), (0x61000037, len(strings)),
        (0x61000039, symbols_offset), (0x6100003F, (1 + len(imports)) * 24),
        (0x61000029, relocations_offset), (0x6100002D, len(imports) * 24),
    ]
    if imports:
        entries.extend([(0x61000015, (1 << 32) | 1),
                        (0x6100000F, (1 << 40) | (1 << 32) | 1)])
    if needed:
        entries.append((1, needed_offset))
    entries.append((0, 0))
    dynamic = b"".join(struct.pack("<qQ", *entry) for entry in entries)
    data = bytearray(0x4000)
    ident = b"\x7fELF\x02\x01\x01" + bytes(9)
    data[:64] = struct.pack("<16sHHIQQQIHHHHHH", ident, kind, 62, 1, 0x800,
                           64, 0, 0, 64, 56, 3, 0, 0, 0)
    headers = [
        (1, 7, 0, 0, 0, len(data), len(data), 0x4000),
        (2, 4, 0x2000, 0x2000, 0, len(dynamic), len(dynamic), 8),
        (0x61000000, 4, 0x3000, 0, 0, len(payload), len(payload), 1),
    ]
    for index, header in enumerate(headers):
        data[64 + index * 56:64 + (index + 1) * 56] = struct.pack("<IIQQQQQQ", *header)
    data[0x800] = 0xC3  # RET; graph-info must never execute it.
    data[0x2000:0x2000 + len(dynamic)] = dynamic
    data[0x3000:0x3000 + len(payload)] = payload
    path.write_bytes(data)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    tool = pathlib.Path(sys.argv[1]).resolve(strict=True)
    root = pathlib.Path(__file__).resolve().parent.parent / "out" / "ampr-link-regression"
    (root / "fakelib").mkdir(parents=True, exist_ok=True)
    image(root / "eboot.bin", 0xFE10, [], "libSceAmpr.sprx")
    image(root / "fakelib" / "libSceAmpr.sprx", 0xFE18, NIDS)
    raise SystemExit(subprocess.run([str(tool), str(root / "eboot.bin")], check=False).returncode)


if __name__ == "__main__":
    main()
