/* FFmpeg 9.0.2 SILK-layer golden harness. LGPL-2.1-or-later.
 * Build inside the assembly-free tree:
 *   gcc -O2 -ffp-contract=off -I. scripts/opus_silk_reference.c \
 *     -Llibavcodec -Llibswresample -Llibavutil -lavcodec -lswresample -lavutil \
 *     -lm -o silkref
 * Usage: silkref <packets.bin> <channels>
 * Input: length-prefixed (LE32) Opus packets INCLUDING the TOC byte.
 * For every SILK/hybrid packet, runs ff_silk_decode_superframe on the real
 * range decoder and then the scalar swr exactly like opus/dec.c, dumping:
 *   S <silk_samples> <f32 bits at the silk rate, channel-interleaved>
 *   R <out_samples>  <f32 bits at 48 kHz, channel-interleaved>
 * CELT-only packets produce a single "K" line (skipped).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libavutil/opt.h"
#include "libavutil/channel_layout.h"
#include "libavcodec/opus/rc.h"
#include "libavcodec/opus/silk.h"
#include "libswresample/swresample.h"

static const uint16_t silk_frame_duration_ms[16] = {
    10, 20, 40, 60,
    10, 20, 40, 60,
    10, 20, 40, 60,
    10, 20,
    10, 20,
};
static const int silk_resample_delay[] = { 4, 8, 11, 11, 11 };

static uint8_t *read_packet(FILE *f, int *size)
{
    uint8_t len[4];
    if (fread(len, 1, 4, f) != 4) return NULL;
    *size = AV_RL32(len);
    if (*size <= 0 || *size > 100000) return NULL;
    uint8_t *buf = av_mallocz(*size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!buf || fread(buf, 1, *size, f) != (size_t)*size) { av_free(buf); return NULL; }
    return buf;
}

int main(int argc, char **argv)
{
    if (argc != 3) return 1;
    int channels = atoi(argv[2]);
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 2;
    SilkContext *silk = NULL;
    if (ff_silk_init(NULL, &silk, channels) < 0) return 3;
    SwrContext *swr = swr_alloc();
    AVChannelLayout layout;
    av_channel_layout_default(&layout, channels);
    av_opt_set_int(swr, "in_sample_fmt", AV_SAMPLE_FMT_FLTP, 0);
    av_opt_set_int(swr, "out_sample_fmt", AV_SAMPLE_FMT_FLTP, 0);
    av_opt_set_chlayout(swr, "in_chlayout", &layout, 0);
    av_opt_set_chlayout(swr, "out_chlayout", &layout, 0);
    av_opt_set_int(swr, "out_sample_rate", 48000, 0);
    av_opt_set_int(swr, "filter_size", 16, 0);
    int delayed = 0;
    int swr_open = 0;

    uint8_t *packet;
    int size;
    float silk_buf[2][1920];
    float out[2][2880];
    while ((packet = read_packet(f, &size))) {
        int config = (packet[0] >> 3) & 31;
        int stereo = (packet[0] >> 2) & 1;
        int mode = config < 12 ? 0 : (config < 16 ? 1 : 2);
        if (mode == 2) {
            printf("K\n");
            av_free(packet);
            continue;
        }
        int bandwidth = config < 12 ? config >> 2 : 3 + (config >= 14);
        int silk_bw = bandwidth < 2 ? bandwidth : 2;
        if (!swr_open) {
            int silk_rate = config < 4 ? 8000 : (config < 8 ? 12000 : 16000);
            av_opt_set_int(swr, "in_sample_rate", silk_rate, 0);
            if (swr_init(swr) < 0) return 4;
            static const float silence[16] = { 0.0f };
            const uint8_t *delayptr[2] = { (const uint8_t*)silence, (const uint8_t*)silence };
            if (swr_convert(swr, NULL, 0, delayptr, silk_resample_delay[bandwidth]) < 0) return 5;
            swr_open = 1;
        }
        OpusRangeCoder rc;
        if (ff_opus_rc_dec_init(&rc, packet + 1, size - 1) < 0) {
            printf("E rc\n");
            av_free(packet);
            continue;
        }
        float *silk_output[2] = { silk_buf[0], silk_buf[1] };
        int samples = ff_silk_decode_superframe(silk, &rc, silk_output, silk_bw,
                                                stereo + 1, silk_frame_duration_ms[config]);
        if (samples < 0) { printf("E silk\n"); av_free(packet); continue; }
        printf("T %d\n", (int)opus_rc_tell(&rc));
        printf("S %d", samples);
        for (int i = 0; i < samples; i++) {
            for (int c = 0; c < channels; c++) {
                unsigned int b;
                memcpy(&b, &silk_buf[c][i], 4);
                printf(" %u", b);
            }
        }
        printf("\n");
        uint8_t *out_p[2] = { (uint8_t*)out[0], (uint8_t*)out[1] };
        const uint8_t *in_p[2] = { (const uint8_t*)silk_buf[0], (const uint8_t*)silk_buf[1] };
        int frame_duration = silk_frame_duration_ms[config] * 48;
        int got = swr_convert(swr, out_p, frame_duration, in_p, samples);
        if (got < 0) return 6;
        delayed += frame_duration - got;
        printf("R %d", got);
        for (int i = 0; i < got; i++) {
            for (int c = 0; c < channels; c++) {
                unsigned int b;
                memcpy(&b, &out[c][i], 4);
                printf(" %u", b);
            }
        }
        printf("\n");
        av_free(packet);
    }
    fclose(f);
    return 0;
}
