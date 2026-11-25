/* Standalone C reference for FFmpeg 9.0.2 amrnbdec.c, the AMR-NB counterpart
 * of amrwb_ref.c: the decoder and its DSP sources are compiled in
 * unmodified, the avcodec glue is stubbed. Decodes a raw AMR-NB stream
 * (optional "#!AMR\n" magic, then TOC byte + payload frames) and dumps the
 * output per frame.
 *
 * Usage: amrnb_ref <file.amr> <dump.txt>
 */
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavcodec/lsp.h"
#include "libavcodec/celp_filters.h"
#include "libavcodec/celp_math.h"
#include "libavcodec/acelp_filters.h"
#include "libavcodec/acelp_vectors.h"
#include "libavcodec/acelp_pitch_delay.h"
#include "libavutil/lfg.h"
#include "libavutil/md5.h"
#include "libavutil/crc.h"
#include "libavcodec/codec_internal.h"
#include "libavcodec/decode.h"

/* the DSP sources, unmodified */
#include "libavcodec/lsp.c"
#include "libavcodec/celp_filters.c"
#include "libavcodec/celp_math.c"
#include "libavcodec/acelp_filters.c"
#include "libavcodec/acelp_vectors.c"
#include "libavcodec/acelp_pitch_delay.c"
#include "libavutil/lfg.c"
#include "libavutil/md5.c"

/* ---- glue stubs -------------------------------------------------------- */

void av_log(void *avcl, int level, const char *fmt, ...)
{
    va_list ap;
    (void)avcl; (void)level;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

void avpriv_report_missing_feature(void *avcl, const char *fmt, ...)
{
    va_list ap;
    (void)avcl;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

void avpriv_request_sample(void *avcl, const char *msg, ...)
{
    (void)avcl;
    fprintf(stderr, "request_sample: %s\n", msg);
}

int av_samples_set_silence(uint8_t * const *audio_data, int offset, int nb_samples,
                           int nb_channels, enum AVSampleFormat sample_fmt)
{
    int planar = av_sample_fmt_is_planar(sample_fmt);
    int block_align = av_get_bytes_per_sample(sample_fmt) *
                      (planar ? 1 : nb_channels);
    int ch;
    for (ch = 0; ch < (planar ? nb_channels : 1); ch++) {
        memset(audio_data[ch] + offset * block_align, 0,
               (size_t)nb_samples * block_align);
    }
    return 0;
}

static int ref_get_buffer(AVCodecContext *avctx, AVFrame *frame, int flags)
{
    int ch;
    (void)flags;
    frame->format = avctx->sample_fmt;
    frame->ch_layout = avctx->ch_layout;
    frame->extended_data = calloc(avctx->ch_layout.nb_channels,
                                  sizeof(*frame->extended_data));
    for (ch = 0; ch < avctx->ch_layout.nb_channels; ch++) {
        frame->extended_data[ch] = calloc(frame->nb_samples, sizeof(float));
        if (ch < AV_NUM_DATA_POINTERS)
            frame->data[ch] = frame->extended_data[ch];
    }
    return 0;
}

void av_channel_layout_uninit(AVChannelLayout *channel_layout)
{
    memset(channel_layout, 0, sizeof(*channel_layout));
}

float ff_scalarproduct_float_c(const float *v1, const float *v2, int len)
{
    float p = 0.0;
    int i;
    for (i = 0; i < len; i++)
        p += v1[i] * v2[i];
    return p;
}

int av_sample_fmt_is_planar(enum AVSampleFormat sample_fmt)
{
    return sample_fmt == AV_SAMPLE_FMT_U8P || sample_fmt >= AV_SAMPLE_FMT_S16P;
}

int av_get_bytes_per_sample(enum AVSampleFormat sample_fmt)
{
    static const int size[AV_SAMPLE_FMT_NB] = { 1, 2, 4, 4, 8, 1, 2, 4, 4, 8, 8, 8 };
    return sample_fmt < 0 || sample_fmt >= AV_SAMPLE_FMT_NB ? 0 : size[sample_fmt];
}

const AVCRC *av_crc_get_table(AVCRCId id)
{
    (void)id;
    return NULL;
}

uint32_t av_crc(const AVCRC *ctx, uint32_t crc,
                const uint8_t *buffer, size_t length)
{
    (void)ctx; (void)buffer; (void)length;
    return crc;
}

void *av_mallocz(size_t size)
{
    return calloc(1, size);
}

/* ---- the decoder, unmodified ------------------------------------------- */

#define ff_get_buffer ref_get_buffer
#include "libavcodec/amrnbdec.c"
#undef ff_get_buffer

static const uint8_t amrnb_packed_size[16] = {
    13, 14, 16, 18, 20, 21, 27, 32, 6, 1, 1, 1, 1, 1, 1, 1
};

static void dump_vec(FILE *out, const char *name, const float *v, int n)
{
    int i;
    fprintf(out, "%s", name);
    for (i = 0; i < n; i++)
        fprintf(out, " %.9g", (double)v[i]);
    fprintf(out, "\n");
}

int main(int argc, char **argv)
{
    FILE *in, *out;
    AVCodecContext avctx;
    AVFrame frame;
    AVPacket pkt;
    AMRContext *p;
    unsigned char *data;
    long size;
    long n = 0;

    if (argc < 3) {
        fprintf(stderr, "usage: amrnb_ref <file.amr> <dump.txt>\n");
        return 1;
    }
    in = fopen(argv[1], "rb");
    if (!in) { perror("open"); return 1; }
    fseek(in, 0, SEEK_END);
    size = ftell(in);
    fseek(in, 0, SEEK_SET);
    data = malloc(size);
    if (fread(data, 1, size, in) != (size_t)size) return 1;
    fclose(in);
    out = fopen(argv[2], "w");
    if (size >= 6 && !memcmp(data, "#!AMR\n", 6))
        n = 6;

    memset(&avctx, 0, sizeof(avctx));
    avctx.ch_layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_MONO;
    avctx.sample_rate = 8000;
    p = calloc(1, sizeof(*p));
    avctx.priv_data = p;
    if (amrnb_decode_init(&avctx) < 0) {
        fprintf(stderr, "init failed\n");
        return 1;
    }

    for (; n < size; ) {
        int expected, got = 0, ret;
        unsigned mode;
        mode = data[n] >> 3 & 0x0F;
        expected = amrnb_packed_size[mode];
        if (n + expected > size) break;
        memset(&frame, 0, sizeof(frame));
        frame.nb_samples = AMR_BLOCK_SIZE;
        memset(&pkt, 0, sizeof(pkt));
        pkt.data = data + n;
        pkt.size = expected;
        ret = amrnb_decode_frame(&avctx, &frame, &got, &pkt);
        fprintf(out, "F %ld mode=%u ret=%d got=%d\n", n, mode, ret, got);
        if (got)
            dump_vec(out, "out", (float *)frame.extended_data[0], AMR_BLOCK_SIZE);
        else
            fprintf(out, "out\n");
        free(frame.extended_data[0]);
        free(frame.extended_data);
        n += expected;
    }
    fclose(out);
    printf("frames decoded up to offset %ld of %ld\n", n, size);
    return 0;
}

