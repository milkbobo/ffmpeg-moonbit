import base64

NAMES = ["static", "mov", "movb"]
REFS = {
    "static": ["7ca70ded8054a87d125a3771318d3742"] * 7,
    "mov": [
        "97757b938efb57582b41445d9f29192b",
        "4b269c45de3097f92599fe2e4acd5b2c",
        "bcdd735420cdb5e0d3dafd05e25ef13e",
        "8071fa08313a8de5774f89f7c565e59d",
        "8b73cbc2c439f05f8d2f509e1938ac3a",
        "d82ad5c1daa3e81d2c03ef5a568169b9",
        "b553f1ab4d4c81c43dadbc493180649c",
    ],
    "movb": [
        "97757b938efb57582b41445d9f29192b",
        "7513509d2e664e66dddce29881fc858a",
        "a9cfd48b11d6f3351ae934c0e32540ce",
        "6d38a93848491ab9c599afdb7a9ac984",
        "2df76eb1674d25f90fdf04b4aa486f69",
        "6e66438c19b503956cd7de9c6dba2018",
        "7b682957df8034efba751040ceafd6ed",
    ],
}

TMP = r"C:\Users\milkb\AppData\Local\Temp\hevcp"

header = '''///|
/// Real x265 Annex B streams and FFmpeg 9.0.2 default-decode per-frame YUV420P
/// MD5 references for the HEVC P/B slice decoder, plus bit-patched variants
/// that exercise the decoder's rejected paths.
///
/// Generation (docker `linuxserver/ffmpeg:9.0.2`, cwd = this directory):
///
/// ```
/// docker run --rm -i linuxserver/ffmpeg:9.0.2 -v error \\
///   -f lavfi -i "color=c=gray:s=64x48:rate=10" -frames:v 7 \\
///   -c:v libx265 -x265-params "keyint=7:min-keyint=7:bframes=0:scenecut=0" \\
///   -f hevc pipe:1 > hevc_p_static.265
/// docker run --rm -i linuxserver/ffmpeg:9.0.2 -v error \\
///   -f lavfi -i "testsrc2=duration=1:size=64x48:rate=10" -frames:v 7 \\
///   -c:v libx265 -x265-params "keyint=7:min-keyint=7:bframes=0:scenecut=0" \\
///   -f hevc pipe:1 > hevc_p_mov.265
/// docker run --rm -i linuxserver/ffmpeg:9.0.2 -v error \\
///   -f lavfi -i "testsrc2=duration=1:size=64x48:rate=10" -frames:v 7 \\
///   -c:v libx265 -x265-params "keyint=7:min-keyint=7:bframes=2:scenecut=0" \\
///   -f hevc pipe:1 > hevc_p_movb.265
/// # two slices per picture (second slice has first_slice_segment_in_pic_flag=0):
/// docker run --rm -i linuxserver/ffmpeg:9.0.2 -v error \\
///   -f lavfi -i "testsrc2=duration=1:size=64x48:rate=10" -frames:v 3 \\
///   -c:v libx265 -x265-params "keyint=7:min-keyint=7:slices=2" \\
///   -f hevc pipe:1 > hevc_pb_slices.265
/// # references:
/// docker run --rm -i -v "$PWD:/s" linuxserver/ffmpeg:9.0.2 \\
///   -v error -i /s/hevc_p_mov.265 -f framemd5 -
/// ```
///
/// The `*_neg_*` variants are produced by this script from `hevc_p_static.265`
/// and `hevc_pb_slices.265`: the SPS/PPS RBSP is walked field-by-field,
/// `pcm_enabled_flag` / `tiles_enabled_flag` are set and the parameter set is
/// re-serialized (all other fields keep their values, the SPS VUI is dropped).
/// Decoding them must fail with the specific PATCHWELCOME error strings
/// asserted in `hevc_inter_wbtest.mbt`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
'''

# ---------------------------------------------------------------------------
# bit reader / writer over RBSP bytes (emulation prevention already removed)
# ---------------------------------------------------------------------------

class BR:
    def __init__(self, data):
        self.d = data
        self.p = 0

    def u(self, n):
        v = 0
        for _ in range(n):
            if self.p >= len(self.d) * 8:
                raise EOFError("overread")
            v = (v << 1) | ((self.d[self.p >> 3] >> (7 - (self.p & 7))) & 1)
            self.p += 1
        return v

    def u1(self):
        return self.u(1)

    def ue(self):
        lz = 0
        while self.u1() == 0:
            lz += 1
            if lz > 32:
                raise ValueError("bad ue")
        if lz == 0:
            return 0
        return (1 << lz) - 1 + self.u(lz)

    def se(self):
        k = self.ue()
        return (k + 1) >> 1 if k & 1 else -(k >> 1)


class BW:
    def __init__(self):
        self.bits = []

    def u(self, n, v):
        for i in range(n - 1, -1, -1):
            self.bits.append((v >> i) & 1)

    def u1(self, v):
        self.bits.append(v & 1)

    def ue(self, v):
        v += 1
        n = v.bit_length()
        self.u(n - 1, 0)
        self.u(n, v)

    def se(self, v):
        k = 2 * v - 1 if v > 0 else -2 * v
        self.ue(k)

    def align_one(self):
        self.bits.append(1)
        while len(self.bits) % 8:
            self.bits.append(0)

    def bytes(self):
        assert len(self.bits) % 8 == 0
        out = bytearray()
        for i in range(0, len(self.bits), 8):
            b = 0
            for j in range(8):
                b = (b << 1) | self.bits[i + j]
            out.append(b)
        return bytes(out)


def unescape(b):
    out = bytearray()
    i = 0
    while i < len(b):
        if i + 2 < len(b) and b[i] == 0 and b[i + 1] == 0 and b[i + 2] == 3:
            out += b[i:i + 2]
            i += 3
        else:
            out.append(b[i])
            i += 1
    return bytes(out)


def escape(b):
    out = bytearray()
    zeros = 0
    for byte in b:
        if zeros >= 2 and byte <= 3:
            out.append(3)
            zeros = 0
        out.append(byte)
        zeros = zeros + 1 if byte == 0 else 0
    return bytes(out)


def split_nals(data):
    starts = []
    i = 0
    while i < len(data) - 3:
        if data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1:
            starts.append((i, 3))
            i += 3
        elif (data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 0
              and data[i + 3] == 1):
            starts.append((i, 4))
            i += 4
        else:
            i += 1
    nals = []
    for k, (pos, sclen) in enumerate(starts):
        end = starts[k + 1][0] if k + 1 < len(starts) else len(data)
        nals.append((pos, sclen, data[pos + sclen:end]))
    return nals


# ---------------------------------------------------------------------------
# SPS / PPS field walkers (field order matches hevc_ps.mbt / H.265 7.3.2)
# ---------------------------------------------------------------------------

def ptl_constraint_bits(profile_idc):
    if 4 <= profile_idc <= 10:
        return 8 + (1 + 33 if profile_idc in (5, 9, 10) else 34)
    if profile_idc == 2:
        return 7 + 1 + 35
    return 43


def walk_ptl(r):
    r.u(2)   # profile_space
    r.u(1)   # tier
    pid = r.u(5)
    for _ in range(32):
        r.u1()
    r.u1(); r.u1(); r.u1(); r.u1()  # progressive/interlaced/non_packed/frame_only
    r.u(ptl_constraint_bits(pid))
    r.u1()   # inbld or reserved
    level = r.u(8)
    return pid, level


def parse_sps(rbsp):
    r = BR(rbsp)
    f = {}
    f['vps_id'] = r.u(4)
    msl = r.u(3)
    f['temporal_id_nesting'] = r.u1()
    pid, level = walk_ptl(r)
    f['profile_idc'] = pid
    f['level_idc'] = level
    f['sps_id'] = r.ue()
    f['chroma_format_idc'] = r.ue()
    f['width'] = r.ue()
    f['height'] = r.ue()
    f['conf_win'] = r.u1()
    f['bit_depth_luma_minus8'] = r.ue()
    f['bit_depth_chroma_minus8'] = r.ue()
    f['log2_max_poc_lsb_minus4'] = r.ue()
    f['sub_layer_ordering_info'] = r.u1()
    f['dpb'] = []
    for _ in range(0 if f['sub_layer_ordering_info'] else msl, msl + 1):
        f['dpb'].append((r.ue(), r.ue(), r.ue()))
    f['log2_min_cb_minus3'] = r.ue()
    f['log2_diff_max_min_cb'] = r.ue()
    f['log2_min_tb_minus2'] = r.ue()
    f['log2_diff_max_min_tb'] = r.ue()
    f['max_trafo_depth_inter'] = r.ue()
    f['max_trafo_depth_intra'] = r.ue()
    f['scaling_list_enabled'] = r.u1()
    f['amp_enabled'] = r.u1()
    f['sao_enabled'] = r.u1()
    f['pcm_enabled'] = r.u1()
    if f['pcm_enabled']:
        r.u(4); r.u(4); r.ue(); r.ue(); r.u1()
    f['nb_st_rps'] = r.ue()
    for _ in range(f['nb_st_rps']):
        raise NotImplementedError("st_rps in SPS not handled")
    f['lt_rps_present'] = r.u1()
    f['temporal_mvp'] = r.u1()
    f['strong_intra_smoothing'] = r.u1()
    f['vui_present'] = r.u1()
    return f


def build_sps(f):
    w = BW()
    w.u(4, f['vps_id'])
    w.u(3, 0)  # single sub-layer
    w.u1(f['temporal_id_nesting'])
    w.u(2, 0)
    w.u1(0)
    w.u(5, f['profile_idc'])
    for i in range(32):
        w.u1(1 if i == f['profile_idc'] else 0)
    w.u1(1); w.u1(0); w.u1(0); w.u1(1)
    w.u(ptl_constraint_bits(f['profile_idc']), 0)
    w.u1(0)
    w.u(8, f['level_idc'])
    w.ue(f['sps_id'])
    w.ue(f['chroma_format_idc'])
    w.ue(f['width'])
    w.ue(f['height'])
    w.u1(f['conf_win'])
    w.ue(f['bit_depth_luma_minus8'])
    w.ue(f['bit_depth_chroma_minus8'])
    w.ue(f['log2_max_poc_lsb_minus4'])
    w.u1(f['sub_layer_ordering_info'])
    for mdpb, reorder, latency in f['dpb']:
        w.ue(mdpb); w.ue(reorder); w.ue(latency)
    w.ue(f['log2_min_cb_minus3'])
    w.ue(f['log2_diff_max_min_cb'])
    w.ue(f['log2_min_tb_minus2'])
    w.ue(f['log2_diff_max_min_tb'])
    w.ue(f['max_trafo_depth_inter'])
    w.ue(f['max_trafo_depth_intra'])
    w.u1(f['scaling_list_enabled'])
    w.u1(f['amp_enabled'])
    w.u1(f['sao_enabled'])
    w.u1(1)     # pcm_enabled_flag
    w.u(4, 0)   # pcm_sample_bit_depth_luma_minus1
    w.u(4, 0)   # pcm_sample_bit_depth_chroma_minus1
    w.ue(3)     # log2_min_pcm_luma_coding_block_size_minus3
    w.ue(0)     # log2_diff_max_min_pcm_luma_coding_block_size
    w.u1(0)     # pcm_loop_filter_disabled_flag
    w.ue(f['nb_st_rps'])
    w.u1(f['lt_rps_present'])
    w.u1(f['temporal_mvp'])
    w.u1(f['strong_intra_smoothing'])
    w.u1(0)     # vui_parameters_present_flag (dropped)
    w.u1(0)     # sps_extension_flag
    w.align_one()
    return w.bytes()


def parse_pps(rbsp):
    r = BR(rbsp)
    f = {}
    f['pps_id'] = r.ue()
    f['sps_id'] = r.ue()
    f['dependent_slices'] = r.u1()
    f['output_flag_present'] = r.u1()
    f['num_extra_slice_header_bits'] = r.u(3)
    f['sign_data_hiding'] = r.u1()
    f['cabac_init_present'] = r.u1()
    f['num_ref_idx_l0_default_active_minus1'] = r.ue()
    f['num_ref_idx_l1_default_active_minus1'] = r.ue()
    f['init_qp_minus26'] = r.se()
    f['constrained_intra_pred'] = r.u1()
    f['transform_skip'] = r.u1()
    f['cu_qp_delta_enabled'] = r.u1()
    f['diff_cu_qp_delta_depth'] = r.ue() if f['cu_qp_delta_enabled'] else None
    f['cb_qp_offset'] = r.se()
    f['cr_qp_offset'] = r.se()
    f['slice_chroma_qp_offsets_present'] = r.u1()
    f['weighted_pred'] = r.u1()
    f['weighted_bipred'] = r.u1()
    f['transquant_bypass'] = r.u1()
    f['tiles_enabled'] = r.u1()
    f['entropy_sync'] = r.u1()
    if f['tiles_enabled']:
        f['num_tile_columns_minus1'] = r.ue()
        f['num_tile_rows_minus1'] = r.ue()
        f['uniform_spacing'] = r.u1()
        f['loop_filter_across_tiles'] = r.u1()
    f['loop_filter_across_slices'] = r.u1()
    f['deblocking_control_present'] = r.u1()
    f['deblocking'] = None
    if f['deblocking_control_present']:
        override = r.u1()
        disabled = r.u1()
        if not disabled:
            beta = r.se()
            tc = r.se()
            f['deblocking'] = (override, disabled, beta, tc)
        else:
            f['deblocking'] = (override, disabled, None, None)
    f['scaling_list_data_present'] = r.u1()
    f['lists_modification_present'] = r.u1()
    f['log2_parallel_merge_level_minus2'] = r.ue()
    f['slice_header_extension_present'] = r.u1()
    f['pps_extension_present'] = r.u1()
    return f


def build_pps(f):
    w = BW()
    w.ue(f['pps_id'])
    w.ue(f['sps_id'])
    w.u1(f['dependent_slices'])
    w.u1(f['output_flag_present'])
    w.u(3, f['num_extra_slice_header_bits'])
    w.u1(f['sign_data_hiding'])
    w.u1(f['cabac_init_present'])
    w.ue(f['num_ref_idx_l0_default_active_minus1'])
    w.ue(f['num_ref_idx_l1_default_active_minus1'])
    w.se(f['init_qp_minus26'])
    w.u1(f['constrained_intra_pred'])
    w.u1(f['transform_skip'])
    w.u1(f['cu_qp_delta_enabled'])
    if f['diff_cu_qp_delta_depth'] is not None:
        w.ue(f['diff_cu_qp_delta_depth'])
    w.se(f['cb_qp_offset'])
    w.se(f['cr_qp_offset'])
    w.u1(f['slice_chroma_qp_offsets_present'])
    w.u1(f['weighted_pred'])
    w.u1(f['weighted_bipred'])
    w.u1(f['transquant_bypass'])
    w.u1(1)     # tiles_enabled_flag
    w.u1(f['entropy_sync'])
    w.ue(1)     # num_tile_columns_minus1
    w.ue(0)     # num_tile_rows_minus1
    w.u1(1)     # uniform_spacing_flag
    w.u1(1)     # loop_filter_across_tiles_enabled_flag
    w.u1(f['loop_filter_across_slices'])
    w.u1(f['deblocking_control_present'])
    if f['deblocking_control_present']:
        override, disabled, beta, tc = f['deblocking']
        w.u1(override)
        w.u1(disabled)
        if not disabled:
            w.se(beta)
            w.se(tc)
    w.u1(f['scaling_list_data_present'])
    w.u1(f['lists_modification_present'])
    w.ue(f['log2_parallel_merge_level_minus2'])
    w.u1(f['slice_header_extension_present'])
    w.u1(f['pps_extension_present'])
    w.align_one()
    return w.bytes()


def splice(data, replace_idx, new_rbsp):
    out = bytearray()
    last = 0
    for k, (pos, sclen, payload) in enumerate(split_nals(data)):
        out += data[last:pos + sclen]
        out += payload[:2] + (new_rbsp if k == replace_idx else payload[2:])
        last = pos + sclen + len(payload)
    out += data[last:]
    return bytes(out)[:len(data)]


def build_neg_streams():
    static = open(f"{TMP}\\static.265", "rb").read()
    slices = open(f"{TMP}\\slices.265", "rb").read()
    nals = split_nals(static)
    sps_idx = pps_idx = None
    for k, (_, _, payload) in enumerate(nals):
        nt = (payload[0] >> 1) & 0x3F
        if nt == 33:
            sps_idx = k
        if nt == 34:
            pps_idx = k
    sf = parse_sps(unescape(nals[sps_idx][2][2:]))
    pf = parse_pps(unescape(nals[pps_idx][2][2:]))
    pcm = splice(static, sps_idx, escape(build_sps(sf)))
    tiles = splice(static, pps_idx, escape(build_pps(pf)))
    # verify the rebuilt parameter sets parse back with the flag set
    for k, (_, _, payload) in enumerate(split_nals(pcm)):
        if (payload[0] >> 1) & 0x3F == 33:
            assert parse_sps(unescape(payload[2:]))['pcm_enabled'] == 1
    for k, (_, _, payload) in enumerate(split_nals(tiles)):
        if (payload[0] >> 1) & 0x3F == 34:
            assert parse_pps(unescape(payload[2:]))['tiles_enabled'] == 1
    return pcm, tiles, slices


parts = [header]
for name in NAMES:
    raw = open(f"{TMP}\\{name}.265", "rb").read()
    b64 = base64.b64encode(raw).decode()
    parts.append(f'///|\nlet hevc_pb_{name}_b64 : Bytes = b"{b64}"\n')

neg_pcm, neg_tiles, neg_slices = build_neg_streams()
for var, raw in (
    ("hevc_pb_neg_pcm_b64", neg_pcm),
    ("hevc_pb_neg_tiles_b64", neg_tiles),
    ("hevc_pb_neg_slices_b64", neg_slices),
):
    parts.append(
        f'///|\nlet {var} : Bytes = b"{base64.b64encode(raw).decode()}"\n')

parts.append(
    "///|\n/// Per-frame YUV420P MD5 of the FFmpeg default decode.\n"
    "let hevc_pb_refs : Array[Array[String]] = [")
for idx, name in enumerate(NAMES):
    refs = REFS[name]
    comma = "," if idx + 1 < len(NAMES) else ""
    parts.append("\n  // " + name + "\n")
    parts.append("  [\n" + "".join(f'    "{r}",\n' for r in refs) + "  ]" + comma + "\n")
parts.append("]\n")

open("libavcodec/hevc_inter_realdata_wbtest.mbt", "wb").write(
    "".join(parts).encode())
print("written", sum(len(p) for p in parts), "chars")
