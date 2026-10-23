/* FFmpeg 9.0.2 native Opus decoder golden harness over the real avcodec API.
 * LGPL-2.1-or-later. Build inside the assembly-free tree:
 *   gcc -O2 -ffp-contract=off -I. scripts/opus_dec_reference.c \
 *     -Llibavcodec -Llibswresample -Llibavutil -lavcodec -lswresample -lavutil \
 *     -lm -o opusdec
 * Input records (little-endian): [u32 len][bytes] extradata (OpusHead), then
 * one record per container packet. Dumps per output frame:
 *   F <nb_samples> <f32 bits interleaved across channels>
 * and finally "DRAIN <nb_samples> ..." for the EOF drain frame (if any).
 * No pre-skip or end-trim is applied: this is the raw decoder output.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libavcodec/avcodec.h"
#include "libavutil/opt.h"
#include "libavutil/intreadwrite.h"

static uint8_t *read_record(FILE *f, int *size)
{
    uint8_t len[4];
    if (fread(len, 1, 4, f) != 4) return NULL;
    *size = AV_RL32(len);
    if (*size <= 0 || *size > 1000000) return NULL;
    uint8_t *buf = av_mallocz(*size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!buf || fread(buf, 1, *size, f) != (size_t)*size) { av_free(buf); return NULL; }
    return buf;
}

static void dump_frame(AVFrame *frame, const char *tag)
{
    int channels = frame->ch_layout.nb_channels;
    printf("%s %d", tag, frame->nb_samples);
    for (int i = 0; i < frame->nb_samples; i++) {
        for (int c = 0; c < channels; c++) {
            unsigned int b;
            float v = ((float*)frame->extended_data[c])[i];
            memcpy(&b, &v, 4);
            printf(" %u", b);
        }
    }
    printf("\n");
}

int main(int argc, char **argv)
{
    if (argc != 2) return 1;
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 2;
    int extradata_size = 0;
    uint8_t *extradata = read_record(f, &extradata_size);
    if (!extradata) return 3;
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_OPUS);
    if (!codec) return 4;
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) return 5;
    ctx->extradata = av_mallocz(extradata_size + AV_INPUT_BUFFER_PADDING_SIZE);
    memcpy(ctx->extradata, extradata, extradata_size);
    ctx->extradata_size = extradata_size;
    ctx->request_sample_fmt = AV_SAMPLE_FMT_FLTP;
    if (avcodec_open2(ctx, codec, NULL) < 0) return 6;
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    if (!pkt || !frame) return 7;

    int size;
    uint8_t *data;
    while ((data = read_record(f, &size))) {
        pkt->data = data;
        pkt->size = size;
        int sent = avcodec_send_packet(ctx, pkt);
        if (sent < 0) { printf("SENDERR %d\n", sent); av_free(data); continue; }
        while (avcodec_receive_frame(ctx, frame) == 0) {
            dump_frame(frame, "F");
            av_frame_unref(frame);
        }
        av_free(data);
    }
    avcodec_send_packet(ctx, NULL);
    while (avcodec_receive_frame(ctx, frame) == 0) {
        dump_frame(frame, "DRAIN");
        av_frame_unref(frame);
    }
    return 0;
}
