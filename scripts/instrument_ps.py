#!/usr/bin/env python3
"""Instrument copies of FFmpeg's aacps.c / aacps_common.c for staged PS dumps.

Usage: instrument_ps.py <aacps.c copy> <aacps_common.c copy>
Writes the files in place. Dumps produced at runtime:
  /tmp/ps_syntax.txt          per-frame PS syntax state (text)
  /tmp/psbin/<TAG>_<id>.f32   staged float buffers, id = ff_ps_apply call count
Tags: LIN LBUF DEC H11 H12 H21 H22 HOUT ROUT
Plus a one-shot /tmp/ps_tables.txt (hex f32 bits of every tablegen table).
"""
import sys

HELPERS_COMMON = r'''
/* ---- PS TRACE BEGIN ---- */
#include <stdio.h>
#include <stdlib.h>
static int g_ps_apply_cnt __attribute__((unused));
static int g_ps_read_cnt __attribute__((unused));
static int g_ps_payload_cnt;
static void ps_dump_payload(GetBitContext *gb, int bits_left)
{
    FILE *f = fopen("/tmp/ps_payloads.txt", "a");
    fprintf(f, "PAYLOAD %d bits_left=%d ", ++g_ps_payload_cnt, bits_left);
    for (int i = 0; i < bits_left; i++) {
        int idx = get_bits_count(gb) + i;
        unsigned byte = idx >> 3;
        fprintf(f, "%u", (gb->buffer[byte] >> (7 - (idx & 7))) & 1);
    }
    fprintf(f, "\n");
    fclose(f);
}
static void ps_dump_syntax(int id, const PSCommonContext *ps)
{
    FILE *f = fopen("/tmp/ps_syntax.txt", "a");
    fprintf(f, "PS %d start=%d eiid=%d iquant=%d nriid=%d nripd=%d eicc=%d iccm=%d nricc=%d eext=%d fcls=%d nenvo=%d nenv=%d eipd=%d is34=%d is34o=%d bp=",
            id, ps->start, ps->enable_iid, ps->iid_quant, ps->nr_iid_par,
            ps->nr_ipdopd_par, ps->enable_icc, ps->icc_mode, ps->nr_icc_par,
            ps->enable_ext, ps->frame_class, ps->num_env_old, ps->num_env,
            ps->enable_ipdopd, ps->is34bands, ps->is34bands_old);
    for (int i = 0; i < 6; i++) fprintf(f, "%d,", ps->border_position[i]);
    fprintf(f, " iid=");
    for (int e = 0; e < 5; e++) for (int b = 0; b < 34; b++) fprintf(f, "%d,", ps->iid_par[e][b]);
    fprintf(f, " icc=");
    for (int e = 0; e < 5; e++) for (int b = 0; b < 34; b++) fprintf(f, "%d,", ps->icc_par[e][b]);
    fprintf(f, " ipd=");
    for (int e = 0; e < 5; e++) for (int b = 0; b < 34; b++) fprintf(f, "%d,", ps->ipd_par[e][b]);
    fprintf(f, " opd=");
    for (int e = 0; e < 5; e++) for (int b = 0; b < 34; b++) fprintf(f, "%d,", ps->opd_par[e][b]);
    fprintf(f, "\n");
    fclose(f);
}
/* ---- PS TRACE END ---- */
'''

HELPERS_FULL = r'''
/* ---- PS TRACE BEGIN ---- */
#include <stdio.h>
#include <stdlib.h>
static int g_ps_apply_cnt;
static int g_ps_read_cnt __attribute__((unused));
static void mkdir_psbin(void)
{
    static int done;
    if (!done) { done = 1; system("mkdir -p /tmp/psbin"); }
}
static void ps_dump_f32(const char *tag, int id, const void *p, int n)
{
    mkdir_psbin();
    char name[128];
    snprintf(name, sizeof name, "/tmp/psbin/%s_%03d.f32", tag, id);
    FILE *f = fopen(name, "wb");
    fwrite(p, 4, n, f);
    fclose(f);
}
static void ps_dump_tables(void)
{
    static int done;
    if (done) return;
    done = 1;
    FILE *f = fopen("/tmp/ps_tables.txt", "w");
#define DUMPT(var, n) do { unsigned u; const float *p = (const float*)(var); \
    fprintf(f, #var); for (int i = 0; i < (n); i++) { \
        memcpy(&u, &p[i], 4); fprintf(f, " %08x", u); } fprintf(f, "\n"); } while (0)
    DUMPT(pd_re_smooth, 8*8*8);
    DUMPT(pd_im_smooth, 8*8*8);
    DUMPT(HA, 46*8*4);
    DUMPT(HB, 46*8*4);
    DUMPT(f20_0_8, 8*8*2);
    DUMPT(f34_0_12, 12*8*2);
    DUMPT(f34_1_8, 8*8*2);
    DUMPT(f34_2_4, 4*8*2);
    DUMPT(Q_fract_allpass, 2*50*3*2);
    DUMPT(phi_fract, 2*50*2);
    DUMPT(g1_Q2, 7);
    fclose(f);
}
/* ---- PS TRACE END ---- */
'''

ps_common = open(sys.argv[2], encoding="utf-8").read()
anchor = '#include "aacpsdata.c"'
anchor_entry = (
    "int ff_ps_read_data(void *logctx, GetBitContext *gb_host,\n"
    "                    PSCommonContext *ps, int bits_left)\n"
    "{"
)
assert anchor_entry in ps_common
ps_common = ps_common.replace(
    anchor_entry, anchor_entry + "\n    ps_dump_payload(gb_host, bits_left);", 1)

assert anchor in ps_common
ps_common = ps_common.replace(anchor, anchor + "\n" + HELPERS_COMMON, 1)

old = "err:\n    ps->start = 0;"
new = "err:\n    ps_dump_syntax(-g_ps_read_cnt, ps);\n    ps->start = 0;"
assert old in ps_common
ps_common = ps_common.replace(old, new, 1)

old = "    if (bits_consumed <= bits_left) {\n        skip_bits_long(gb_host, bits_consumed);\n        return bits_consumed;\n    }"
new = '    if (bits_consumed <= bits_left) {\n        ps_dump_syntax(++g_ps_read_cnt, ps);\n        skip_bits_long(gb_host, bits_consumed);\n        return bits_consumed;\n    }'
assert old in ps_common
ps_common = ps_common.replace(old, new, 1)
open(sys.argv[2], "w", encoding="utf-8").write(ps_common)

ps = open(sys.argv[1], encoding="utf-8").read()
anchor2 = "static void ipdopd_reset"
assert anchor2 in ps
ps = ps.replace(anchor2, HELPERS_FULL + "\n" + anchor2, 1)

old = "av_cold void AAC_RENAME(ff_ps_init)(void) {\n    ps_tableinit();\n}"
new = "av_cold void AAC_RENAME(ff_ps_init)(void) {\n    ps_tableinit();\n    ps_dump_tables();\n}"
assert old in ps
ps = ps.replace(old, new, 1)

old_apply = """    hybrid_analysis(&ps->dsp, Lbuf, ps->in_buf, L, is34, len);
    decorrelation(ps, Rbuf, (const INTFLOAT (*)[32][2]) Lbuf, is34);
    stereo_processing(ps, Lbuf, Rbuf, is34);
    hybrid_synthesis(&ps->dsp, L, Lbuf, is34, len);
    hybrid_synthesis(&ps->dsp, R, Rbuf, is34, len);"""
new_apply = """    int tr_id = ++g_ps_apply_cnt;
    ps_dump_f32("LIN", tr_id, L, 2*38*64);
    hybrid_analysis(&ps->dsp, Lbuf, ps->in_buf, L, is34, len);
    ps_dump_f32("LBUF", tr_id, Lbuf, 91*32*2);
    decorrelation(ps, Rbuf, (const INTFLOAT (*)[32][2]) Lbuf, is34);
    ps_dump_f32("DEC", tr_id, Rbuf, 91*32*2);
    stereo_processing(ps, Lbuf, Rbuf, is34);
    ps_dump_f32("H11", tr_id, ps->H11, 2*6*34);
    ps_dump_f32("H12", tr_id, ps->H12, 2*6*34);
    ps_dump_f32("H21", tr_id, ps->H21, 2*6*34);
    ps_dump_f32("H22", tr_id, ps->H22, 2*6*34);
    hybrid_synthesis(&ps->dsp, L, Lbuf, is34, len);
    hybrid_synthesis(&ps->dsp, R, Rbuf, is34, len);
    ps_dump_f32("HOUT", tr_id, L, 2*38*64);
    ps_dump_f32("ROUT", tr_id, R, 2*38*64);"""
assert old_apply in ps
ps = ps.replace(old_apply, new_apply, 1)
open(sys.argv[1], "w", encoding="utf-8").write(ps)
print("INSTRUMENT_OK")
