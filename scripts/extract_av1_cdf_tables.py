#!/usr/bin/env python3
"""Extract dav1d default CDF tables (src/cdf.c) into MoonBit fixed arrays.

Usage: python extract_av1_cdf_tables.py <dav1d-src-dir> <out.mbt> [--check]

The tables keep dav1d's field dimensions (including SIMD padding slots);
CDFn(a,b,..) args are cumulative probabilities; entries are 32768-a_i. The output
array name pattern is av1_cdf_<field> for CdfModeContext/kfym/mv fields and
av1_cdf_coef<qcat>_<field> for the four per-qcat CdfCoefContext tables.
"""

import re
import sys

# Field dims from dav1d src/cdf.h; names must match the .name initializers in
# cdf.c. Enum names are resolved from levels.h.
MODE_FIELDS = [
    ("uv_mode", "[2][13][16]"),
    ("partition", "[5][4][16]"),
    ("cfl_alpha", "[6][16]"),
    ("txtp_inter1", "[2][16]"),
    ("txtp_inter2", "[16]"),
    ("txtp_intra1", "[2][13][8]"),
    ("txtp_intra2", "[3][13][8]"),
    ("cfl_sign", "[8]"),
    ("angle_delta", "[8][8]"),
    ("filter_intra", "[8]"),
    ("seg_id", "[3][8]"),
    ("pal_sz", "[2][7][8]"),
    ("color_map", "[2][7][5][8]"),
    ("txsz", "[4][3][4]"),
    ("delta_q", "[4]"),
    ("delta_lf", "[5][4]"),
    ("restore_switchable", "[4]"),
    ("restore_wiener", "[2]"),
    ("restore_sgrproj", "[2]"),
    ("txtp_inter3", "[4][2]"),
    ("use_filter_intra", "[22][2]"),
    ("txpart", "[7][3][2]"),
    ("skip", "[3][2]"),
    ("pal_y", "[7][3][2]"),
    ("pal_uv", "[2][2]"),
    ("intrabc", "[2]"),
    ("y_mode", "[4][16]"),
    ("wedge_idx", "[9][16]"),
    ("comp_inter_mode", "[8][8]"),
    ("filter", "[2][8][4]"),
    ("interintra_mode", "[4][4]"),
    ("motion_mode", "[22][4]"),
    ("skip_mode", "[3][2]"),
    ("newmv_mode", "[6][2]"),
    ("globalmv_mode", "[2][2]"),
    ("refmv_mode", "[6][2]"),
    ("drl_bit", "[3][2]"),
    ("intra", "[4][2]"),
    ("comp", "[5][2]"),
    ("comp_dir", "[5][2]"),
    ("jnt_comp", "[6][2]"),
    ("mask_comp", "[6][2]"),
    ("wedge_comp", "[9][2]"),
    ("ref", "[6][3][2]"),
    ("comp_fwd_ref", "[3][3][2]"),
    ("comp_bwd_ref", "[2][3][2]"),
    ("comp_uni_ref", "[3][3][2]"),
    ("seg_pred", "[3][2]"),
    ("interintra", "[7][2]"),
    ("interintra_wedge", "[7][2]"),
    ("obmc", "[22][2]"),
]
MV_FIELDS = [
    ("classes", "[16]"),
    ("sign", "[2]"),
    ("class0", "[2]"),
    ("class0_fp", "[2][4]"),
    ("class0_hp", "[2]"),
    ("classN", "[10][2]"),
    ("classN_fp", "[4]"),
    ("classN_hp", "[2]"),
]
COEF_FIELDS = [
    ("eob_bin_16", "[2][2][8]"),
    ("eob_bin_32", "[2][2][8]"),
    ("eob_bin_64", "[2][2][8]"),
    ("eob_bin_128", "[2][2][8]"),
    ("eob_bin_256", "[2][2][16]"),
    ("eob_bin_512", "[2][16]"),
    ("eob_bin_1024", "[2][16]"),
    ("eob_base_tok", "[5][2][4][4]"),
    ("base_tok", "[5][2][41][4]"),
    ("br_tok", "[4][2][21][4]"),
    ("eob_hi_bit", "[5][2][11][2]"),
    ("skip", "[5][13][2]"),
    ("dc_sign", "[2][3][2]"),
]
KFYM_DIMS = "[5][5][16]"


def parse_enums(levels_text):
    levels_text = re.sub(r'/\*.*?\*/', ' ', levels_text, flags=re.S)
    levels_text = re.sub(r'//[^\n]*', ' ', levels_text)
    enums = {}
    for m in re.finditer(r'enum\s+\w+\s*\{(.*?)\}', levels_text, re.S):
        body = m.group(1)
        next_val = 0
        for item in body.split(','):
            item = item.strip()
            if not item:
                continue
            if '=' in item:
                name, val = item.split('=', 1)
                name = name.strip()
                val = val.strip()
                try:
                    v = int(val)
                except ValueError:
                    v = enums[val]
                enums[name] = v
                next_val = v + 1
            else:
                if re.match(r'^[A-Za-z_]\w*$', item):
                    enums[item] = next_val
                    next_val += 1
    return enums


def eval_dim(expr, enums):
    total = [1]
    for part in re.findall(r'\[([^\]]+)\]', expr):
        e = part.strip()
        tokens = re.split(r'([+-])', e)
        val = None
        op = '+'
        for tok in tokens:
            tok = tok.strip()
            if not tok:
                continue
            if tok in '+-':
                op = tok
                continue
            tval = int(tok) if tok.isdigit() else enums[tok]
            if val is None:
                val = tval
            elif op == '+':
                val += tval
            else:
                val -= tval
        total.append(val)
    out = 1
    for t in total:
        out *= t
    return out


def dims_list(expr, enums):
    out = []
    for part in re.findall(r'\[([^\]]+)\]', expr):
        e = part.strip()
        tokens = re.split(r'([+-])', e)
        val = None
        op = '+'
        for tok in tokens:
            tok = tok.strip()
            if not tok:
                continue
            if tok in '+-':
                op = tok
                continue
            tval = int(tok) if tok.isdigit() else enums[tok]
            if val is None:
                val = tval
            elif op == '+':
                val += tval
            else:
                val -= tval
        out.append(val)
    return out


class Node:
    """Initializer: dict of position -> child (Node or list of ints)."""

    def __init__(self):
        self.items = []

    def add(self, key, value):
        self.items.append((key, value))


TOKEN_RE = re.compile(
    r'\s*(\{|\}|\,|\(|\)|=|\.?[A-Za-z_][A-Za-z_0-9]*|\[[A-Za-z_0-9]+\]|-?\d+)')


def tokenize(text):
    text = re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)
    text = re.sub(r'//[^\n]*', ' ', text)
    pos = 0
    out = []
    while pos < len(text):
        m = TOKEN_RE.match(text, pos)
        if not m:
            if text[pos:].strip() == '':
                break
            raise ValueError('tokenize failed at %r' % text[pos:pos + 40])
        out.append(m.group(1))
        pos = m.end()
    return out


class Parser:
    def __init__(self, toks, enums):
        self.toks = toks
        self.i = 0
        self.enums = enums

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else None

    def next(self):
        t = self.toks[self.i]
        self.i += 1
        return t

    def parse_init(self):
        """Parse contents until matching '}' (not consumed) or designator."""
        node = Node()
        idx = 0
        while True:
            t = self.peek()
            if t is None or t == '}':
                return node
            if t == ',':
                self.next()
                continue
            if t.startswith('['):
                name = t[1:-1]
                if name.isdigit():
                    idx = int(name)
                else:
                    idx = self.enums[name]
                self.next()
                assert self.next() == '='
                node.add(idx, self.parse_value())
                idx += 1
                continue
            if t.startswith('.') and self.peek_next_is_eq():
                # .name = value (shouldn't appear beyond top level)
                name = self.next()[1:]
                assert self.next() == '='
                node.add(idx, (name, self.parse_value()))
                idx += 1
                continue
            node.add(idx, self.parse_value())
            idx += 1

    def peek_next_is_eq(self):
        return (self.i + 1 < len(self.toks)
                and self.toks[self.i + 1] == '=')

    def parse_value(self):
        t = self.peek()
        if t == '{':
            self.next()
            node = self.parse_init()
            assert self.next() == '}'
            return node
        m = re.match(r'^CDF(\d+)$', t)
        if m:
            self.next()
            assert self.next() == '('
            n = int(m.group(1))
            probs = []
            while True:
                tok = self.next()
                if tok == ')':
                    break
                if tok == ',':
                    continue
                probs.append(int(tok))
            assert len(probs) == n, (n, probs)
            # Macro args are cumulative probabilities already: CDFn(a0,..)
            # expands elementwise to 32768-a0, 32768-a1, ...
            cdf = [32768 - p for p in probs]
            return cdf
        return int(self.next())


def prod(dims):
    out = 1
    for d in dims:
        out *= d
    return out


def flatten(node, dims):
    """Flatten a parsed Node into a list of ints of length prod(dims)."""
    out = [0] * prod(dims)

    def rec(node, base, dims):
        dim = dims[0]
        rest = dims[1:]
        stride = prod(rest) if rest else 1
        for key, value in node.items:
            if not (0 <= key < dim):
                raise ValueError('index %d out of range %r' % (key, dims))
            b = base + key * stride
            if isinstance(value, list):
                # CDFn(...) or consecutive scalar list starting at key.
                for j, v in enumerate(value):
                    if key + j >= dim:
                        raise ValueError('cdf overruns subarray %r' % (dims,))
                    out[b + j] = v
            elif isinstance(value, Node):
                if rest:
                    rec(value, b, rest)
                else:
                    for k2, v2 in value.items:
                        if isinstance(v2, list):
                            for j, v in enumerate(v2):
                                out[b + k2 + j] = v
                        else:
                            out[b + k2] = v2
            else:
                out[b] = value

    rec(node, 0, dims)
    return out


def extract_region(text, start_marker):
    start = text.index(start_marker)
    brace = text.index('{', start)
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[brace + 1:i]
    raise ValueError('unbalanced')


def field_nodes(node):
    """Top-level .name = {..} entries -> dict name->Node."""
    out = {}
    for key, value in node.items:
        if isinstance(value, tuple):
            name, sub = value
            out[name] = sub
    return out


def main():
    src, out_path = sys.argv[1], sys.argv[2]
    check = '--check' in sys.argv
    cdf_text = open(src + '/src/cdf.c').read()
    levels_text = open(src + '/src/levels.h').read()
    enums = parse_enums(levels_text)

    # default_cdf: .m = { .field = {...} }, .mv = { .comp = {...}, .joint },
    # .kfym = {...}
    region = extract_region(cdf_text, 'static const CdfDefaultContext default_cdf')
    parser = Parser(tokenize(region), enums)
    parser.next()  # consume nothing; parse_init expects inner tokens
    root = Parser(tokenize(region), enums).parse_init()
    top = field_nodes(root)

    arrays = []
    m_node = field_nodes(top['m'])
    for name, dims_expr in MODE_FIELDS:
        dims = dims_list(dims_expr, enums)
        node = m_node[name]
        arrays.append(('av1_cdf_%s' % name, flatten(node, dims), dims))

    mv_node = field_nodes(top['mv'])
    comp = field_nodes(mv_node['comp'])
    joint_node = mv_node['joint']
    for name, dims_expr in MV_FIELDS:
        dims = dims_list(dims_expr, enums)
        arrays.append(('av1_cdf_mv0_%s' % name, flatten(comp[name], dims),
                       dims))
        arrays.append(('av1_cdf_mv1_%s' % name, flatten(comp[name], dims),
                       dims))
    arrays.append(('av1_cdf_joint', flatten(joint_node, [4]), [4]))
    kfym_dims = dims_list(KFYM_DIMS, enums)
    arrays.append(('av1_cdf_kfym', flatten(top['kfym'], kfym_dims),
                   kfym_dims))

    # default_coef_cdf[4]
    coef_region = extract_region(cdf_text, 'default_coef_cdf[4]')
    coef_parser = Parser(tokenize(coef_region), enums)
    coef_root = coef_parser.parse_init()
    qcat_nodes = {}
    for key, value in coef_root.items:
        qcat_nodes[key] = value
    assert sorted(qcat_nodes) == [0, 1, 2, 3], sorted(qcat_nodes)
    for qcat in range(4):
        node = field_nodes(qcat_nodes[qcat])
        for name, dims_expr in COEF_FIELDS:
            dims = dims_list(dims_expr, enums)
            arrays.append(('av1_cdf_coef%d_%s' % (qcat, name),
                           flatten(node[name], dims), dims))

    if check:
        total = sum(len(a[1]) for a in arrays)
        print('extracted %d arrays, %d u16 values' % (len(arrays), total))
        # Spot checks against hand-decoded values from cdf.c
        spot = {
            'av1_cdf_y_mode': (0, 32768 - 22801),
            'av1_cdf_kfym': (0, None),
        }
        for name, data, dims in arrays:
            assert all(0 <= v <= 32768 for v in data), name
        ym = dict((a[0], a[1]) for a in arrays)['av1_cdf_y_mode']
        assert ym[0] == 32768 - 22801
        assert ym[1] == 32768 - 23489
        part = dict((a[0], a[1]) for a in arrays)['av1_cdf_partition']
        # partition[BL_8X8=0][ctx 0] first value: 23232,1368,8218 -> cdf
        assert part[0] == 32768 - 27899
        assert part[1] == 32768 - 28219
        print('spot checks passed')
        return

    with open(out_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('///|\n')
        f.write('/// AV1 default CDF tables, extracted from dav1d 1.5.1\n')
        f.write('/// src/cdf.c (default_cdf + default_coef_cdf[4]) by\n')
        f.write('/// scripts/extract_av1_cdf_tables.py. Dims mirror\n')
        f.write('/// dav1d src/cdf.h including SIMD padding slots; CDFn\n')
        f.write('/// entries are 32768 minus the cumulative probability args. dav1d is\n')
        f.write('/// BSD-2-Clause; FFmpeg integrates it as libdav1d.\n')
        f.write('/// This generated table keeps the upstream values.\n')
        for name, data, dims in arrays:
            f.write('///|\n')
            f.write('/// dims %s\n' % repr(dims))
            f.write('let %s : FixedArray[UInt16] = [' % name)
            f.write(', '.join(str(v) for v in data))
            f.write(']\n')
    print('wrote %s (%d arrays)' % (out_path, len(arrays)))


if __name__ == '__main__':
    main()
