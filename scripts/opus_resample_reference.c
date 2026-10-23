/* FFmpeg 9.0.2 scalar swresample golden harness for the Opus SILK resampler.
 * LGPL-2.1-or-later. Build inside the assembly-free tree:
 *   gcc -O2 -ffp-contract=off -I. scripts/opus_resample_reference.c \
 *     -Llibswresample -Llibavutil -lswresample -lavutil -lm -o /s/.scratch/swrref
 * Usage: swrref <in_rate> <channels>   (8000|12000|16000, 1|2)
 * Mirrors opus/dec.c: fltp in/out, out 48000, filter_size 16, initial
 * silence per bandwidth (4/8/11), 20 ms chunks (160/240/320 in, 960 out),
 * EOF flush of delayed_samples. Input pattern:
 *   ((global_index % 501) / 501.0f - 0.5f)
 * Dumps "C <got> <bits...>" lines per chunk (float32 bit patterns).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libavutil/opt.h"
#include "libavutil/channel_layout.h"
#include "libswresample/swresample.h"

int main(int argc, char **argv)
{
    if (argc != 3) return 1;
    int in_rate = atoi(argv[1]);
    int channels = atoi(argv[2]);
    int chunk_in = 160 * (in_rate / 8000);
    int chunk_out = 960;
    int delay = in_rate == 8000 ? 4 : (in_rate == 12000 ? 8 : 11);

    SwrContext *swr = swr_alloc();
    AVChannelLayout layout;
    if (channels == 1) av_channel_layout_default(&layout, 1);
    else av_channel_layout_default(&layout, 2);
    av_opt_set_int(swr, "in_sample_fmt", AV_SAMPLE_FMT_FLTP, 0);
    av_opt_set_int(swr, "out_sample_fmt", AV_SAMPLE_FMT_FLTP, 0);
    av_opt_set_chlayout(swr, "in_chlayout", &layout, 0);
    av_opt_set_chlayout(swr, "out_chlayout", &layout, 0);
    av_opt_set_int(swr, "out_sample_rate", 48000, 0);
    av_opt_set_int(swr, "filter_size", 16, 0);
    av_opt_set_int(swr, "in_sample_rate", in_rate, 0);
    if (swr_init(swr) < 0) return 2;

    static const float silence[16] = { 0.0f };
    const uint8_t *delayptr[2] = { (const uint8_t*)silence, (const uint8_t*)silence };
    if (swr_convert(swr, NULL, 0, delayptr, delay) < 0) return 3;

    float in[2][960];
    float out[2][960];
    const uint8_t *in_p[2];
    uint8_t *out_p[2];
    int delayed = 0;
    long global = 0;
    for (int chunk = 0; chunk < 40; chunk++) {
        for (int i = 0; i < chunk_in; i++) {
            float v = (float)((global % 501)) / 501.0f - 0.5f;
            in[0][i] = v;
            if (channels == 2) in[1][i] = -v;
            global++;
        }
        in_p[0] = (const uint8_t*)in[0];
        in_p[1] = (const uint8_t*)in[1];
        out_p[0] = (uint8_t*)out[0];
        out_p[1] = (uint8_t*)out[1];
        int got = swr_convert(swr, out_p, chunk_out, in_p, chunk_in);
        if (got < 0) return 4;
        delayed += chunk_out - got;
        printf("C %d", got);
        for (int i = 0; i < got; i++) {
            unsigned int bits0, bits1;
            memcpy(&bits0, &out[0][i], 4);
            printf(" %u", bits0);
            if (channels == 2) { memcpy(&bits1, &out[1][i], 4); printf(" %u", bits1); }
        }
        printf("\n");
    }
    /* flush */
    out_p[0] = (uint8_t*)out[0];
    out_p[1] = (uint8_t*)out[1];
    int got = swr_convert(swr, out_p, delayed, NULL, 0);
    printf("F %d", got);
    for (int i = 0; i < got; i++) {
        unsigned int bits0, bits1;
        memcpy(&bits0, &out[0][i], 4);
        printf(" %u", bits0);
        if (channels == 2) { memcpy(&bits1, &out[1][i], 4); printf(" %u", bits1); }
    }
    printf("\n");
    return 0;
}
