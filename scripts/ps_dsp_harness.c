/* Independent FFmpeg PS DSP vectors. Compile against FFmpeg 9.0.2's
 * libavcodec/libavutil after configuring with --disable-asm. The generated
 * little-endian float samples are consumed by generate_aac_ps_tests.py. */
#define USE_FIXED 0
#include "libavcodec/aacps.h"
#include <stdio.h>
#include <string.h>

int main(void)
{
    PSContext ps = {0};
    float left[2][38][64], right[2][38][64];
    int old34 = 0;
    ff_ps_init();
    ff_ps_ctx_init(&ps);
    for (int frame = 0; frame < 6; frame++) {
        PSCommonContext *c = &ps.common;
        int is34 = frame != 3;
        c->is34bands_old = old34;
        c->is34bands = is34;
        c->nr_iid_par = is34 ? 34 : 20;
        c->nr_icc_par = is34 ? 34 : 20;
        c->nr_ipdopd_par = is34 ? 17 : 11;
        c->icc_mode = frame % 2 ? 4 : 2;
        c->iid_quant = frame % 2;
        c->enable_ipdopd = frame != 4;
        c->num_env_old = c->num_env;
        c->num_env = frame % 4 + 1;
        c->border_position[0] = -1;
        for (int e = 0; e < c->num_env; e++) {
            c->border_position[e + 1] = (32 * (e + 1) / c->num_env) - 1;
            for (int b = 0; b < 34; b++) {
                c->iid_par[e][b] = (b * 3 + e + frame) % 15 - 7;
                c->icc_par[e][b] = (b + 2 * e + frame) % 8;
                c->ipd_par[e][b] = (b + e + frame) % 8;
                c->opd_par[e][b] = (3 * b + 2 * e + frame) % 8;
            }
        }
        for (int p = 0; p < 2; p++)
            for (int t = 0; t < 38; t++)
                for (int k = 0; k < 64; k++)
                    left[p][t][k] = ((p * 17 + t * 13 + k * 7 + frame * 11) % 127 - 63) / 64.0f;
        memset(right, 0, sizeof(right));
        ff_ps_apply(&ps, left, right, 64);
        for (int ch = 0; ch < 2; ch++)
            for (int p = 0; p < 2; p++)
                for (int t = 0; t < 32; t += 7)
                    for (int k = 0; k < 64; k++) {
                        float v = ch ? right[p][t][k] : left[p][t][k];
                        if (fwrite(&v, sizeof(v), 1, stdout) != 1) return 1;
                    }
        old34 = is34;
    }
    return 0;
}
