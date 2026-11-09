/* §370: emits libavcodec/aac_mdct_tx/aac_mdct_tx_ref_checks.mbt - 32-bit checksums
 * (sum and xor of the f32 bit patterns) of every av_tx runtime table and of
 * two reference transforms. The MoonBit port regenerates the tables from the
 * same formulas (aac_mdct_tx.mbt) and the white-box test compares the
 * checksums, pinning the exact f32 values the oracle computes without
 * embedding thousands of literals (the package initializer is at the wasm
 * local-count limit).
 *
 * Build & run inside the ffref oracle image (same glibc as the oracle):
 *   gcc -O1 -o /tmp/aac_mdct_tx_dump scripts/aac_mdct_tx_dump.c \
 *       -I/usr/local/include /usr/local-ref/libavcodec_ref.a \
 *       -L/usr/local/lib -lavutil -lm
 *   /tmp/aac_mdct_tx_dump > /work/libavcodec/aac_mdct_tx/aac_mdct_tx_ref_checks.mbt
 *
 * The reference transform inputs use the same LCG the MoonBit test runs:
 *   s = s * 1664525 + 1013904223 (mod 2^32);
 *   x[i] = (float)((s >> 8 & 0xFFFF) / 32768.0 - 1.0).
 */
#include <stdio.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

#include "libavutil/tx.h"
#include "libavutil/cpu.h"

extern float ff_sine_1024[1024];
extern float ff_sine_128[128];
extern void ff_init_ff_sine_windows(int index);
/* §371: the KBD windows the encoder applies on window_shape 1. */
extern float ff_aac_kbd_long_1024[1024];
extern float ff_aac_kbd_short_128[128];
extern void ff_aac_float_common_init(void);

static uint32_t ck_sum, ck_xor;

static void ck_f32(const float *v, int n)
{
    ck_sum = ck_xor = 0;
    for (int i = 0; i < n; i++) {
        uint32_t bits;
        memcpy(&bits, &v[i], 4);
        ck_sum += bits;
        ck_xor ^= bits;
    }
}

static void ck_i32(const int32_t *v, int n)
{
    ck_sum = ck_xor = 0;
    for (int i = 0; i < n; i++) {
        uint32_t bits = (uint32_t)v[i];
        ck_sum += bits;
        ck_xor ^= bits;
    }
}

static void emit_check(const char *name)
{
    printf("  // %s\n  0x%08XU, 0x%08XU,\n", name, ck_sum, ck_xor);
}

/* glibc's sinf is not correctly rounded for a handful of the window angles;
 * emit (index, f32-bits) pairs where it differs from f32(sin(double angle)),
 * the value a generic libm yields. The port applies these fixes after
 * generating the window (aac_mdct_tx.mbt). */
static void emit_sine_fix(const char *name, const float *tab, int n)
{
    int cnt = 0;
    for (int i = 0; i < n; i++) {
        float mine = (float)sin((double)(float)((i + 0.5) * (M_PI / (2.0 * n))));
        uint32_t a, b;
        memcpy(&a, &tab[i], 4);
        memcpy(&b, &mine, 4);
        if (a != b)
            cnt++;
    }
    printf("///|\n/// %d entries where glibc's sinf differs from f32(sin(double)).\n", cnt);
    printf("let %s : Array[UInt] = [\n", name);
    for (int i = 0; i < n; i++) {
        float mine = (float)sin((double)(float)((i + 0.5) * (M_PI / (2.0 * n))));
        uint32_t a, b;
        memcpy(&a, &tab[i], 4);
        memcpy(&b, &mine, 4);
        if (a != b)
            printf("  %d, 0x%08XU,\n", i, a);
    }
    printf("]\n\n");
}

static void gen_cos(float *out, int n)
{
    double freq = 2 * M_PI / n;
    for (int i = 0; i < n / 4; i++)
        out[i] = (float)cos(i * freq);
    out[n / 4] = 0;
}

static void gen_exp(float *re, float *im, int len)
{
    int len4 = len >> 1;
    double scale = sqrt(fabs(32768.0));
    const double theta = 0.0 + 1.0 / 8.0;
    for (int i = 0; i < len4; i++) {
        const double alpha = M_PI_2 * (i + theta) / len4;
        re[i] = (float)(cos(alpha) * scale);
        im[i] = (float)(sin(alpha) * scale);
    }
}

static int split_radix_permutation(int i, int len, int inv)
{
    len >>= 1;
    if (len <= 1)
        return i & 1;
    if (!(i & len))
        return split_radix_permutation(i, len, inv) * 2;
    len >>= 1;
    return split_radix_permutation(i, len, inv) * 4 + 1 - 2 * (!(i & len) ^ inv);
}

static void gen_map(int32_t *map, int len)
{
    for (int i = 0; i < len; i++)
        map[-split_radix_permutation(i, len, 0) & (len - 1)] = i;
}

static void gen_input(float *x, int n, uint32_t seed)
{
    uint32_t s = seed;
    for (int i = 0; i < n; i++) {
        s = s * 1664525u + 1013904223u;
        x[i] = (float)((double)((s >> 8) & 0xFFFFu) / 32768.0 - 1.0);
    }
}

int main(void)
{
    float sine_long[1024], sine_short[128];
    float cos512[129], cos256[65], cos128[33], cos64[17], cos32[9], cos16[5], cos8[3];
    float e1024_re[512], e1024_im[512], e128_re[64], e128_im[64];
    int32_t map512[512], map64[64];
    float in_long[2048], out_long[1024], in_short[256], out_short[128];

    ff_init_ff_sine_windows(10);
    ff_init_ff_sine_windows(7);
    ff_aac_float_common_init();
    memcpy(sine_long, ff_sine_1024, sizeof(sine_long));
    memcpy(sine_short, ff_sine_128, sizeof(sine_short));

    gen_cos(cos512, 512);
    gen_cos(cos256, 256);
    gen_cos(cos128, 128);
    gen_cos(cos64, 64);
    gen_cos(cos32, 32);
    gen_cos(cos16, 16);
    gen_cos(cos8, 8);
    gen_exp(e1024_re, e1024_im, 1024);
    gen_exp(e128_re, e128_im, 128);
    gen_map(map512, 512);
    gen_map(map64, 64);

    av_force_cpu_flags(0);
    {
        AVTXContext *tx = NULL;
        av_tx_fn fn = NULL;
        float scale = 32768.0f;
        gen_input(in_long, 2048, 12345u);
        gen_input(in_short, 256, 67890u);
        if (av_tx_init(&tx, &fn, AV_TX_FLOAT_MDCT, 0, 1024, &scale, 0) < 0) {
            fprintf(stderr, "mdct1024 init failed\n");
            return 1;
        }
        fn(tx, out_long, in_long, sizeof(float));
        av_tx_uninit(&tx);
        if (av_tx_init(&tx, &fn, AV_TX_FLOAT_MDCT, 0, 128, &scale, 0) < 0) {
            fprintf(stderr, "mdct128 init failed\n");
            return 1;
        }
        fn(tx, out_short, in_short, sizeof(float));
        av_tx_uninit(&tx);
    }

    printf("///|\n");
    printf("/// AUTOGENERATED by scripts/aac_mdct_tx_dump.c (FFmpeg 9.0.2 av_tx)\n");
    printf("/// inside the ffref oracle image: sum/xor of the f32 bit patterns of\n");
    printf("/// every runtime table and of two reference transforms. Do not edit.\n");
    printf("/// Original FFmpeg code is LGPL-2.1-or-later.\n\n");
    printf("///|\n");
    printf("/// Checksum pairs `(sum, xor)` in the order checked by\n");
    printf("/// `aac_mdct_tx_wbtest.mbt`.\n");
    printf("let aac_mdct_tx_ref_checks : Array[UInt] = [\n");

    ck_f32(sine_long, 1024);                    emit_check("sine1024");
    ck_f32(sine_short, 128);                    emit_check("sine128");
    ck_f32(cos512, 129);                        emit_check("cos512");
    ck_f32(cos256, 65);                         emit_check("cos256");
    ck_f32(cos128, 33);                         emit_check("cos128");
    ck_f32(cos64, 17);                          emit_check("cos64");
    ck_f32(cos32, 9);                           emit_check("cos32");
    ck_f32(cos16, 5);                           emit_check("cos16");
    ck_f32(cos8, 3);                            emit_check("cos8");
    ck_f32(e1024_re, 512);                      emit_check("exp1024_re");
    ck_f32(e1024_im, 512);                      emit_check("exp1024_im");
    ck_f32(e128_re, 64);                        emit_check("exp128_re");
    ck_f32(e128_im, 64);                        emit_check("exp128_im");
    ck_i32(map512, 512);                        emit_check("map512");
    ck_i32(map64, 64);                          emit_check("map64");
    ck_f32(in_long, 2048);                      emit_check("vec_long_in");
    ck_f32(out_long, 1024);                     emit_check("vec_long_out");
    ck_f32(in_short, 256);                      emit_check("vec_short_in");
    ck_f32(out_short, 128);                     emit_check("vec_short_out");
    ck_f32(ff_aac_kbd_long_1024, 1024);         emit_check("kbd1024");
    ck_f32(ff_aac_kbd_short_128, 128);          emit_check("kbd128");

    printf("]\n\n");
    emit_sine_fix("aac_mdct_tx_sine1024_fix", sine_long, 1024);
    emit_sine_fix("aac_mdct_tx_sine128_fix", sine_short, 128);
    return 0;
}
