/* Standalone C reference for the ADPCM decoders of FFmpeg 9.0.2
 * (libavcodec/adpcm.c + adpcm_data.c, compiled in unmodified; only the
 * avcodec glue is stubbed), the ADPCM counterpart of scripts/amr_c_ref/.
 *
 * Decodes a list of packets through adpcm_decode_frame the way decode.c
 * does (the decoder reports how many bytes it consumed; the rest of the
 * packet is fed back) and dumps every frame per channel.
 *
 * Usage: adpcm_ref <spec.txt> <packets.bin> <dump.txt>
 *   spec.txt, one case per line followed by its packet sizes on the next
 *   lines (any number of packets):
 *     <codec> <channels> <block_align> <bits> <n>
 *     <size1> <size2> ... <sizeN>
 *   packets.bin holds the raw packet bytes of every case, in order.
 *   Output per frame:
 *     F <ret> <got> <nb_samples> <fmt: P (planar) | I (interleaved)>
 *     S <channel> <s16 samples...>
 *   and `E <ret>` when the decoder rejects a packet.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "config_components.h"
#undef CONFIG_ADPCM_MS_DECODER
#undef CONFIG_ADPCM_IMA_WAV_DECODER
#undef CONFIG_ADPCM_IMA_OKI_DECODER
#undef CONFIG_ADPCM_YAMAHA_DECODER
#undef CONFIG_ADPCM_IMA_QT_DECODER
#define CONFIG_ADPCM_MS_DECODER 1
#define CONFIG_ADPCM_IMA_WAV_DECODER 1
#define CONFIG_ADPCM_IMA_OKI_DECODER 1
#define CONFIG_ADPCM_YAMAHA_DECODER 1
#define CONFIG_ADPCM_IMA_QT_DECODER 1

#include "libavcodec/avcodec.h"
#include "libavcodec/codec_internal.h"
#include "libavcodec/decode.h"

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
    (void)avcl; (void)fmt;
}

void avpriv_request_sample(void *avcl, const char *msg, ...)
{
    (void)avcl; (void)msg;
}

static int ref_get_buffer(AVCodecContext *avctx, AVFrame *frame, int flags)
{
    int ch, planar;
    (void)flags;
    frame->format = avctx->sample_fmt;
    frame->ch_layout = avctx->ch_layout;
    planar = av_sample_fmt_is_planar(frame->format);
    frame->extended_data = calloc(avctx->ch_layout.nb_channels,
                                  sizeof(*frame->extended_data));
    for (ch = 0; ch < avctx->ch_layout.nb_channels; ch++) {
        int n = planar ? frame->nb_samples
                       : (ch == 0 ? frame->nb_samples * avctx->ch_layout.nb_channels : 0);
        frame->extended_data[ch] = calloc(n ? n : 1, sizeof(int16_t));
        if (ch < AV_NUM_DATA_POINTERS)
            frame->data[ch] = frame->extended_data[ch];
    }
    return 0;
}

static int planar_fmt(enum AVSampleFormat f)
{
    return f == AV_SAMPLE_FMT_S16P || f == AV_SAMPLE_FMT_FLTP ||
           f == AV_SAMPLE_FMT_S32P || f == AV_SAMPLE_FMT_U8P ||
           f == AV_SAMPLE_FMT_DBLP || f == AV_SAMPLE_FMT_S64P;
}

/* libavutil/samplefmt.c and channel_layout.c, the parts used here */
int av_sample_fmt_is_planar(enum AVSampleFormat sample_fmt)
{
    return planar_fmt(sample_fmt);
}

void av_channel_layout_default(AVChannelLayout *ch_layout, int nb_channels)
{
    ch_layout->order = AV_CHANNEL_ORDER_NATIVE;
    ch_layout->nb_channels = nb_channels;
    ch_layout->u.mask = nb_channels <= 64 ? ((1ULL << nb_channels) - 1) : 0;
    ch_layout->opaque = NULL;
}

/* ---- the decoders, unmodified ------------------------------------------ */

#define ff_get_buffer ref_get_buffer
#include "libavcodec/adpcm.c"
#include "libavcodec/adpcm_data.c"
#undef ff_get_buffer

static const struct { const char *name; const FFCodec *codec; } codecs[] = {
    { "adpcm_ms",       &ff_adpcm_ms_decoder       },
    { "adpcm_ima_wav",  &ff_adpcm_ima_wav_decoder  },
    { "adpcm_ima_oki",  &ff_adpcm_ima_oki_decoder  },
    { "adpcm_yamaha",   &ff_adpcm_yamaha_decoder   },
    { "adpcm_ima_qt",   &ff_adpcm_ima_qt_decoder   },
};

int main(int argc, char **argv)
{
    FILE *spec, *bin, *out;
    char line[4096];
    char *toks[5];
    int caseno = 0;

    if (argc < 4) {
        fprintf(stderr, "usage: adpcm_ref <spec.txt> <packets.bin> <dump.txt>\n");
        return 1;
    }
    spec = fopen(argv[1], "r");
    bin = fopen(argv[2], "rb");
    out = fopen(argv[3], "w");
    if (!spec || !bin || !out) { perror("open"); return 1; }

    while (fgets(line, sizeof(line), spec)) {
        AVCodecContext avctx;
        AVPacket pkt;
        const FFCodec *codec = NULL;
        int ch, block_align, bits, n, ret, i;
        char name[64];
        int size;
        char *tok, *next;
        int ntok = 0;
        if (line[0] == '#' || line[0] == '\n')
            continue;
        for (tok = strtok_r(line, " \t\r\n", &next); tok && ntok < 5;
             tok = strtok_r(NULL, " \t\r\n", &next))
            toks[ntok++] = tok;
        if (ntok < 5)
            continue;
        strncpy(name, toks[0], sizeof(name) - 1);
        name[sizeof(name) - 1] = 0;
        ch = atoi(toks[1]);
        block_align = atoi(toks[2]);
        bits = atoi(toks[3]);
        n = atoi(toks[4]);
        if (n < 0)
            continue;
        for (i = 0; i < (int)(sizeof(codecs) / sizeof(codecs[0])); i++)
            if (!strcmp(codecs[i].name, name))
                codec = codecs[i].codec;
        if (!codec) { fprintf(stderr, "unknown codec %s\n", name); return 1; }
        fprintf(out, "C %d %s %d %d %d\n", caseno, name, ch, block_align, bits);

        memset(&avctx, 0, sizeof(avctx));
        avctx.codec = &codec->p;
        avctx.ch_layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_MONO;
        if (ch == 2)
            avctx.ch_layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO;
        else if (ch > 2)
            av_channel_layout_default(&avctx.ch_layout, ch);
        avctx.block_align = block_align;
        avctx.bits_per_coded_sample = bits;
        avctx.priv_data = calloc(1, sizeof(ADPCMDecodeContext));
        if (adpcm_decode_init(&avctx) < 0) {
            fprintf(out, "E init\n");
            caseno++;
            continue;
        }
        for (i = 0; i < n; i++) {
            int size = 0;
            uint8_t *bufstart;
            if (fscanf(spec, "%d", &size) != 1) {
                fprintf(stderr, "bad size list for case %d\n", caseno);
                return 1;
            }
            if (size < 0)
                size = 0;
            fprintf(out, "P %d %d\n", i, size);
            memset(&pkt, 0, sizeof(pkt));
            pkt.data = malloc(size ? size : 1);
            bufstart = pkt.data;
            if (size && fread(pkt.data, 1, size, bin) != (size_t)size) {
                fprintf(stderr, "short packet data\n");
                return 1;
            }
            pkt.size = size;
            while (pkt.size > 0) {
                AVFrame frame;
                int got = 0;
                memset(&frame, 0, sizeof(frame));
                ret = adpcm_decode_frame(&avctx, &frame, &got, &pkt);
                if (ret < 0) {
                    fprintf(out, "E %d\n", ret);
                    break;
                }
                fprintf(out, "F %d %d %d %c\n", ret, got, frame.nb_samples,
                        planar_fmt(frame.format) ? 'P' : 'I');
                if (got) {
                    int planar = planar_fmt(frame.format);
                    for (int c = 0; c < ch; c++) {
                        fprintf(out, "S %d", c);
                        for (int s = 0; s < frame.nb_samples; s++) {
                            int16_t v = planar
                                ? ((int16_t *)frame.extended_data[c])[s]
                                : ((int16_t *)frame.extended_data[0])[s * ch + c];
                            fprintf(out, " %d", v);
                        }
                        fprintf(out, "\n");
                    }
                }
                if (got) {
                    for (int c = 0; c < ch; c++)
                        free(frame.extended_data[c]);
                }
                free(frame.extended_data);
                if (ret == 0)
                    break;
                pkt.data += ret;
                pkt.size -= ret;
            }
            free(bufstart);
        }
        free(avctx.priv_data);
        caseno++;
    }
    fclose(out);
    printf("cases: %d\n", caseno);
    return 0;
}
