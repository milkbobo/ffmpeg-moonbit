#!/usr/bin/env python3
"""Regenerate libavcodec/av1_inter_hdr_vectors/av1_inter_hdr_test.mbt.

Vectors come from two docker-encoded streams (linuxserver/ffmpeg:9.0.2):

  testsrc2 160x120 2 frames -crf 30   -> plain P frame (identity GM)
  mandelbrot 160x120 4 frames -crf 20 -> P frames with a rot-zoom LAST
                                          model and skip-mode enabled

Run this from the repo root with both IVFs in %TEMP% (inter2.ivf/inter4.ivf;
see the docker commands printed below), then re-check the asserted field
values against the probe output.
"""
import base64
import io
import os
import struct
import subprocess
import sys

TMP = os.environ.get('TEMP', r'C:\Users\milkb\AppData\Local\Temp')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'libavcodec', 'av1_inter_hdr_vectors',
                   'av1_inter_hdr_test.mbt')

def ivf_packets(path):
    data = open(path, 'rb').read()
    pos = 32
    pkts = []
    while pos + 12 <= len(data):
        size = struct.unpack('<I', data[pos:pos + 4])[0]
        pkts.append(data[pos + 12:pos + 12 + size])
        pos += 12 + size
    return pkts

def decode_call(name, b64):
    lines = [f'  let {name} = @libavutil.av_base64_decode(',
             f'      b"{b64}",', '      65536,', '    ).unwrap()']
    return '\n'.join(lines)

def main():
    i2 = os.path.join(TMP, 'inter2.ivf')
    i4 = os.path.join(TMP, 'inter4.ivf')
    if not (os.path.exists(i2) and os.path.exists(i4)):
        print('encode first:')
        print(r'  docker run --rm -i linuxserver/ffmpeg:9.0.2 -v error -f lavfi'
              r' -i "testsrc2=size=160x120:rate=10" -frames:v 2 -pix_fmt'
              r' yuv420p -c:v libaom-av1 -crf 30 -deadline good -cpu-used 4'
              r' -f ivf pipe:1 > %TEMP%/inter2.ivf')
        print(r'  docker run --rm -i linuxserver/ffmpeg:9.0.2 -v error -f lavfi'
              r' -i "mandelbrot=size=160x120:rate=10" -frames:v 4 -pix_fmt'
              r' yuv420p -c:v libaom-av1 -crf 20 -deadline good -cpu-used 4'
              r' -f ivf pipe:1 > %TEMP%/inter4.ivf')
        sys.exit(1)
    p2 = ivf_packets(i2)
    p4 = ivf_packets(i4)
    out = io.StringIO()
    w = out.write
    w('///|\n')
    w('/// Inter-frame header vectors: docker linuxserver/ffmpeg:9.0.2\n')
    w('/// (libaom). testsrc2 -crf 30 (plain P frame) and mandelbrot\n')
    w('/// -crf 20 (rot-zoom LAST model, skip mode). Regenerate with\n')
    w('/// scripts/_gen_av1_inter_hdr_vectors.py.\n\n')
    w('///|\n')
    w('test "av1 inter frame header parse" {\n')
    w(decode_call('key_pkt', base64.b64encode(p2[0]).decode()) + '\n')
    w(decode_call('inter_pkt', base64.b64encode(p2[-1]).decode()) + '\n')
    w('  let seq = @libavcodec.av1_parse_sequence_header(key_pkt).unwrap()\n')
    w('  // ref slot 0 holds the decoded key frame (identity GM, same size).\n')
    w('  let slot0 = @libavcodec.av1_ref_slot_state(0, seq.width, seq.height)\n')
    w('  let hdr = @libavcodec.av1_parse_frame_header(inter_pkt, seq, ref_slots=[slot0]).unwrap()\n')
    w('  inspect(hdr.frame_type, content="1")\n')
    w('  inspect(hdr.upscaled_width, content="160")\n')
    w('  inspect(hdr.height, content="120")\n')
    w('  inspect(hdr.reference_select, content="false")\n')
    w('  inspect(hdr.skip_mode_enabled, content="false")\n')
    w('  inspect(hdr.allow_warped_motion, content="true")\n')
    w('  inspect(hdr.use_ref_frame_mvs, content="true")\n')
    w('  inspect(hdr.allow_high_precision_mv, content="true")\n')
    w('  inspect(hdr.is_motion_mode_switchable, content="true")\n')
    w('  inspect(hdr.order_hint, content="1")\n')
    w('  inspect(hdr.refresh_frame_flags, content="2")\n')
    w('  inspect(hdr.primary_ref_frame, content="7")\n')
    w('  inspect(hdr.ref_frame_idx.length(), content="7")\n')
    w('  for i in 0..<7 {\n    inspect(hdr.gm_types[i], content="0")\n  }\n')
    w('  // Bit-exactness of the header path: the tile group must still split.\n')
    w('  let group = @libavcodec.av1_parse_tile_group(inter_pkt, hdr).unwrap()\n')
    w('  inspect(group.num_tiles, content="1")\n')
    w('  ignore(key_pkt)\n')
    w('}\n\n')
    w('///|\n')
    w('test "av1 inter frame header parse with global motion" {\n')
    w(decode_call('mkey_pkt', base64.b64encode(p4[0]).decode()) + '\n')
    w(decode_call('p1_pkt', base64.b64encode(p4[1]).decode()) + '\n')
    w(decode_call('p2_pkt', base64.b64encode(p4[2]).decode()) + '\n')
    w('  let seq = @libavcodec.av1_parse_sequence_header(mkey_pkt).unwrap()\n')
    w('  // The key frame (order hint 0) refreshes all 8 slots; the first P\n')
    w('  // frame (order hint 1) then refreshes slot 1 only.\n')
    w('  let slot0 = @libavcodec.av1_ref_slot_state(0, seq.width, seq.height)\n')
    w('  let hdr1 = @libavcodec.av1_parse_frame_header(p1_pkt, seq, ref_slots=[slot0]).unwrap()\n')
    w('  inspect(hdr1.frame_type, content="1")\n')
    w('  inspect(hdr1.refresh_frame_flags, content="2")\n')
    w('  let slot1 = @libavcodec.av1_ref_slot_state(1, seq.width, seq.height)\n')
    w('  let pool = [\n    slot0, slot1, slot0, slot0, slot0, slot0, slot0, slot0,\n  ]\n')
    w('  let hdr2 = @libavcodec.av1_parse_frame_header(p2_pkt, seq, ref_slots=pool).unwrap()\n')
    w('  inspect(hdr2.frame_type, content="1")\n')
    w('  // P1: LAST ref carries a rot-zoom model (zoom ~0.983, dx ~1.125),\n')
    w('  // exercising the subexp delta decoding.\n')
    w('  inspect(hdr1.gm_types[0], content="2")\n')
    w('  for i in 1..<7 {\n    inspect(hdr1.gm_types[i], content="0")\n  }\n')
    w('  inspect(hdr1.gm_matrices[0][0], content="73728")\n')
    w('  inspect(hdr1.gm_matrices[0][1], content="67584")\n')
    w('  inspect(hdr1.gm_matrices[0][2], content="64458")\n')
    w('  inspect(hdr1.gm_matrices[0][3], content="72")\n')
    w('  inspect(hdr1.gm_matrices[0][4], content="-72")\n')
    w('  inspect(hdr1.gm_matrices[0][5], content="64458")\n')
    w('  // P2: skip mode enabled over refs [0, 6]; the refidx list mixes the\n')
    w('  // key (slot 2) and first P (slot 1).\n')
    w('  for i in 0..<7 {\n    inspect(hdr2.gm_types[i], content="0")\n  }\n')
    w('  inspect(hdr2.skip_mode_enabled, content="true")\n')
    w('  inspect(hdr2.skip_mode_refs[0], content="0")\n')
    w('  inspect(hdr2.skip_mode_refs[1], content="6")\n')
    w('  inspect(hdr2.ref_frame_idx[0], content="2")\n')
    w('  for i in 1..<6 {\n    inspect(hdr2.ref_frame_idx[i], content="0")\n  }\n')
    w('  inspect(hdr2.ref_frame_idx[6], content="1")\n')
    w('  inspect(@libavcodec.av1_parse_tile_group(p1_pkt, hdr1).unwrap().num_tiles, content="1")\n')
    w('  inspect(@libavcodec.av1_parse_tile_group(p2_pkt, hdr2).unwrap().num_tiles, content="1")\n')
    w('}\n')
    io.open(OUT, 'w', newline='\n').write(out.getvalue())
    print('wrote', OUT)

if __name__ == '__main__':
    main()
