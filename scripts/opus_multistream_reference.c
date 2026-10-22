/* FFmpeg 9.0.2 OpusHead and multistream packet golden harness.
 * LGPL-2.1-or-later. Input: length-prefixed LE32 OpusHead, then packets,
 * produced from independent ffprobe dumps by emit_opus_multistream_vectors.mbtx.
 * gcc -O2 -ffunction-sections -fdata-sections -I. -Wl,--gc-sections
 *   /s/scripts/opus_multistream_reference.c libavcodec/vorbis_data.c
 *   libavcodec/opus/frame_duration_tab.c
 *   -Llibavcodec -Llibavutil -lavcodec -lavutil -lm -lpthread -o harness
 * ./harness /s/.scratch/opus_51_packets.bin > /s/.scratch/opus_51_reference.txt
 */
#include <stdio.h>
#include "libavutil/internal.h"
#include "libavcodec/opus/parse.c"

static uint8_t *read_record(FILE *f, int *size) {
    uint8_t len[4];
    if (fread(len,1,4,f) != 4) return NULL;
    *size = AV_RL32(len);
    if (*size <= 0 || *size > 100000) return NULL;
    uint8_t *buf = av_mallocz(*size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!buf || fread(buf,1,*size,f) != *size) { av_free(buf); return NULL; }
    return buf;
}

int main(int argc, char **argv) {
    if (argc != 2) return 1;
    FILE *f = fopen(argv[1],"rb");
    if (!f) return 2;
    AVCodecContext avctx = {0};
    OpusParseContext s = {0};
    avctx.extradata = read_record(f,&avctx.extradata_size);
    if (!avctx.extradata || ff_opus_parse_extradata(&avctx,&s) < 0) return 3;
    printf("H %d %d %d %d %d\n",avctx.ch_layout.nb_channels,avctx.delay,
           s.gain_i,s.nb_streams,s.nb_stereo_streams);
    for (int i = 0; i < avctx.ch_layout.nb_channels; i++) {
        ChannelMap *m = &s.channel_maps[i];
        printf("M %d %d %d %d %d\n",i,m->silence ? -1 : m->stream_idx,
               m->channel_idx,m->silence,m->copy ? m->copy_idx : -1);
    }
    int size, packet = 0;
    uint8_t *data;
    while ((data = read_record(f,&size))) {
        int offset = 0, samples = -1;
        for (int i = 0; i < s.nb_streams; i++) {
            OpusPacket p = {0};
            if (ff_opus_parse_packet(&p,data+offset,size-offset,i+1<s.nb_streams) < 0) return 4;
            int total = p.frame_duration*p.frame_count;
            if (samples >= 0 && samples != total) return 5;
            samples = total;
            printf("P %d %d %d %d %d %d %d %d\n",packet,i,offset,p.packet_size,
                   p.config,p.stereo,p.frame_count,p.frame_duration);
            for (int j = 0; j < p.frame_count; j++)
                printf("F %d %d %d %d %d\n",packet,i,j,p.frame_offset[j],p.frame_size[j]);
            offset += p.packet_size;
        }
        if (offset != size) return 6;
        av_free(data);
        packet++;
    }
    av_free(s.channel_maps);
    av_free(avctx.extradata);
    av_channel_layout_uninit(&avctx.ch_layout);
    fclose(f);
    return packet == 4 ? 0 : 7;
}
