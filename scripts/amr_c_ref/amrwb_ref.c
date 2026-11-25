/* Standalone C reference for FFmpeg 9.0.2 amrwbdec.c: the decoder source
 * and the DSP files it uses are compiled in unmodified; only the avcodec
 * glue (frame buffers, logging) is stubbed. Decodes a raw AMR-WB frame
 * stream (TOC byte + payload per frame) and dumps, per frame, the decoder
 * state and the output, for a comparison against the MoonBit port.
 *
 * Usage: amrwb_ref <frames.bin> <dump.txt>
 */
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The decoder reads 16-bit reordering tables (amrwbdec.c defines this
 * before including amr.h; the harness includes amr.h first). */
#define AMR_USE_16BIT_TABLES
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
#include "libavcodec/amr.h"

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

static void report_missing(void *avcl, const char *fmt, ...)
{
    va_list ap;
    (void)avcl;
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
    (void)report_missing;
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
    frame->nb_extended_buf = 0;
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

/* libavcodec/audiodsp.c */
float ff_scalarproduct_float_c(const float *v1, const float *v2, int len)
{
    float p = 0.0;
    int i;

    for (i = 0; i < len; i++)
        p += v1[i] * v2[i];
    return p;
}

/* libavutil/samplefmt.c, for the FLTP frame only */
int av_sample_fmt_is_planar(enum AVSampleFormat sample_fmt)
{
    return sample_fmt == AV_SAMPLE_FMT_U8P || sample_fmt >= AV_SAMPLE_FMT_S16P;
}

int av_get_bytes_per_sample(enum AVSampleFormat sample_fmt)
{
    static const int size[AV_SAMPLE_FMT_NB] = { 1, 2, 4, 4, 8, 1, 2, 4, 4, 8, 8, 8 };
    return sample_fmt < 0 || sample_fmt >= AV_SAMPLE_FMT_NB ? 0 : size[sample_fmt];
}

/* av_lfg_init_from_data's CRC helpers are not used by the decoder */
const AVCRC *av_crc_get_table(AVCRCId id)
{
    (void)id;
    return NULL;
}

/* av_md5_alloc (not called) references the allocator */
void *av_mallocz(size_t size)
{
    return calloc(1, size);
}

uint32_t av_crc(const AVCRC *ctx, uint32_t crc,
                const uint8_t *buffer, size_t length)
{
    (void)ctx; (void)buffer; (void)length;
    return crc;
}

/* ---- the decoder, unmodified, so its statics are reachable ------------- */

#define ff_get_buffer ref_get_buffer
#define AMRWB_DECODER_REF 1
#include "libavcodec/amrwbdec.c"

#undef ff_get_buffer

static void dump_vec(FILE *out, const char *name, const float *v, int n)
{
    int i;
    fprintf(out, "%s", name);
    for (i = 0; i < n; i++)
        fprintf(out, " %.9g", (double)v[i]);
    fprintf(out, "\n");
}

static void dump_dvec(FILE *out, const char *name, const double *v, int n)
{
    int i;
    fprintf(out, "%s", name);
    for (i = 0; i < n; i++)
        fprintf(out, " %.9g", v[i]);
    fprintf(out, "\n");
}

int main(int argc, char **argv)
{
    FILE *in, *out;
    AVCodecContext avctx;
    AVFrame frame;
    AVPacket pkt;
    AMRWBChannelsContext *s;
    unsigned char *data;
    long size;
    int n = 0;

    if (argc < 3) {
        fprintf(stderr, "usage: amrwb_ref <frames.bin> <dump.txt>\n");
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

    memset(&avctx, 0, sizeof(avctx));
    avctx.ch_layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_MONO;
    avctx.sample_rate = 16000;
    s = calloc(1, sizeof(*s));
    avctx.priv_data = s;
    if (amrwb_decode_init(&avctx) < 0) {
        fprintf(stderr, "init failed\n");
        return 1;
    }

    for (n = 0; n < size; ) {
        int expected, got = 0, ret;
        AMRWBContext *ctx = &s->ch[0];
        unsigned mode;
        mode = data[n] >> 3 & 0x0F;
        expected = mode < 16 ? ((cf_sizes_wb[mode] + 7) >> 3) + 1 : 1;
        if (n + expected > size) break;
        memset(&frame, 0, sizeof(frame));
        frame.nb_samples = 4 * AMRWB_SFR_SIZE_16k;
        memset(&pkt, 0, sizeof(pkt));
        pkt.data = data + n;
        pkt.size = expected;
        ret = amrwb_decode_frame(&avctx, &frame, &got, &pkt);
        fprintf(out, "F %d mode=%d ret=%d got=%d\n", n, ctx->fr_cur_mode, ret, got);
        dump_vec(out, "isf", ctx->isf_cur, LP_ORDER);
        dump_dvec(out, "isp3", ctx->isp[3], LP_ORDER);
        dump_vec(out, "lp0", ctx->lp_coef[0], LP_ORDER);
        dump_vec(out, "lp3", ctx->lp_coef[3], LP_ORDER);
        fprintf(out, "gain pg=%.9g fg=%.9g lag=%d\n",
                (double)ctx->pitch_gain[0], (double)ctx->fixed_gain[0],
                ctx->pitch_lag_int);
        dump_vec(out, "fixed", ctx->fixed_vector, AMRWB_SFR_SIZE);
        dump_vec(out, "pitchv", ctx->pitch_vector, AMRWB_SFR_SIZE);
        dump_vec(out, "exc", ctx->excitation, AMRWB_SFR_SIZE);
        dump_vec(out, "az", ctx->samples_az, LP_ORDER + AMRWB_SFR_SIZE);
        dump_vec(out, "out", (float *)frame.extended_data[0], 4 * AMRWB_SFR_SIZE_16k);
        free(frame.extended_data[0]);
        free(frame.extended_data);
        n += expected;
    }
    fclose(out);
    printf("frames decoded up to offset %d of %ld\n", n, size);
    return 0;
}

