#!/usr/bin/env python3
"""Convert the C-dumped dav1d decode tables (av1_tables.txt from
dump_av1_tables.c built in docker) into libavcodec/av1_tables.mbt."""

import io
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else r'C:\Users\milkb\AppData\Local\Temp\av1t\av1_tables.txt'
OUT = sys.argv[2] if len(sys.argv) > 2 else r'D:\project\FFmpeg-n9.0.2\moonbit\libavcodec\av1_tables.mbt'


def main():
    tables = {}
    order = []
    enums = None
    for line in io.open(SRC, encoding='utf-8'):
        line = line.strip()
        if not line:
            continue
        if line.startswith('enums '):
            enums = [int(x) for x in line.split()[1:]]
            continue
        parts = line.split()
        if len(parts) == 3 and not line[0].isdigit():
            name, count, elem = parts[0], int(parts[1]), int(parts[2])
            tables[name] = {'count': count, 'elem': elem, 'data': []}
            order.append(name)
            cur = name
            continue
        tables[cur]['data'].append(int(line))

    n_tx_sizes, n_rect_tx_sizes, n_tx_types_plus_ll, n_bs_sizes, \
        n_partitions, n_bl_levels, n_uv = enums
    with io.open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write('///|\n')
        f.write('/// AV1 decode tables extracted from dav1d 1.5.1\n')
        f.write('/// src/tables.c, src/scan.c and src/dequant_tables.h by\n')
        f.write('/// scripts/extract_av1_decode_tables.py from a C dump\n')
        f.write('/// (dump_av1_tables.c compiled against the dav1d source),\n')
        f.write('/// so every value matches upstream bit-for-bit. dav1d is\n')
        f.write('/// BSD-2-Clause; FFmpeg integrates it as libdav1d.\n')
        for name in order:
            t = tables[name]
            ty = 'FixedArray[Byte]' if t['elem'] == 1 else 'FixedArray[UInt16]'
            f.write('///|\n')
            f.write('/// %s (%d values).\n' % (name, t['count']))
            mbname = name.replace('dav1d_dq_tbl[0]', 'av1_dq_tbl_0').replace('dav1d_dq_tbl[1]', 'av1_dq_tbl_1').replace('dav1d_dq_tbl[2]', 'av1_dq_tbl_2').replace('dav1d_', 'av1_')
            f.write('let %s : %s = [' % (mbname, ty))
            f.write(', '.join(str(v) for v in t['data']))
            f.write(']\n')
        f.write('///|\n')
        f.write('/// dav1d levels.h enum sizes (for reference).\n')
    print('wrote %s (%d tables)' % (OUT, len(order)))


if __name__ == '__main__':
    main()
