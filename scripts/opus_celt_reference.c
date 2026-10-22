/* Original FFmpeg 9.0.2 CELT allocation/setup golden harness, LGPL-2.1-or-later.
 * gcc -O2 -ffp-contract=off -ffunction-sections -fdata-sections -I.
 *   -Wl,--gc-sections /s/scripts/opus_celt_reference.c libavcodec/opus/tab.c
 *   libavcodec/opus/frame_duration_tab.c libavcodec/vorbis_data.c
 *   -Llibavcodec -Llibavutil -lavcodec -lavutil -lm -lpthread -o harness
 * ./harness /s/.scratch/opus_51_packets.bin > /s/.scratch/opus_celt_reference.txt
 * Real inputs are the independent ffprobe records from the preceding slice.
 * All synthetic expectations also come directly from the unmodified C kernels.
 */
#include <stdio.h>
#include <string.h>
#include "libavutil/intmath.h"
#include "libavutil/internal.h"
#include "libavcodec/opus/rc.c"
#include "libavcodec/opus/celt.c"
#include "libavcodec/opus/dec_celt.c"
#include "libavcodec/opus/parse.c"

static void state(OpusRangeCoder *rc) {
    printf(" %u %u %u %u",rc->range,rc->value,rc->total_bits,opus_rc_tell_frac(rc));
}
static void allocation(CeltFrame *f, OpusRangeCoder *rc) {
    printf(" %d %d %d %d %d %d %d",f->spread,f->alloc_trim,f->anticollapse_needed,
           f->coded_bands,f->intensity_stereo,f->dual_stereo,f->remaining);
    state(rc);
    for (int i = 0; i < 21; i++) printf(" %d",f->caps[i]);
    for (int i = 0; i < 21; i++) printf(" %d",f->pulses[i]);
    for (int i = 0; i < 21; i++) printf(" %d",f->fine_bits[i]);
    for (int i = 0; i < 21; i++) printf(" %d",f->fine_priority[i]);
}
static void float_bits(float value) {
    uint32_t bits;
    memcpy(&bits,&value,4);
    printf(" %u",bits);
}
static void setup(CeltFrame *f, OpusRangeCoder *rc, int size, int channels,
                  int start, int end, int history) {
    f->size = size; f->channels = channels; f->start_band = start; f->end_band = end;
    f->framebits = rc->rb.bytes*8;
    if (history) for (int j = 0; j < 2; j++) for (int i = 0; i < 21; i++)
        f->block[j].energy[i] = ((i*7+j*11+history)%193-128)/8.0f;
    int consumed = opus_rc_tell(rc);
    if (consumed >= f->framebits) f->silence = 1;
    else if (consumed == 1) f->silence = ff_opus_rc_dec_log(rc,15);
    if (f->silence) {
        consumed = f->framebits;
        rc->total_bits += f->framebits - opus_rc_tell(rc);
    }
    consumed = parse_postfilter(f,rc,consumed);
    if (size && consumed+3 <= f->framebits) f->transient = ff_opus_rc_dec_log(rc,3);
    f->blocks = f->transient ? 1<<size : 1;
    if (channels == 1) for (int i = 0; i < 21; i++)
        f->block[0].energy[i] = FFMAX(f->block[0].energy[i],f->block[1].energy[i]);
    celt_decode_coarse_energy(f,rc);
    celt_decode_tf_changes(f,rc);
    ff_celt_bitalloc(f,rc,0);
    celt_decode_fine_energy(f,rc);
    allocation(f,rc);
    printf(" %d %d %d %d",f->silence,f->transient,f->blocks,f->block[0].pf_period_new);
    for (int i = 0; i < 3; i++) float_bits(f->block[0].pf_gains_new[i]);
    for (int i = 0; i < 21; i++) printf(" %d",f->tf_change[i]);
    for (int j = 0; j < 2; j++) for (int i = 0; i < 21; i++) float_bits(f->block[j].energy[i]);
    putchar('\n');
}
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
    const int bands[][2] = {{0,13},{0,17},{0,19},{0,21},{17,21},{20,21},{0,1}};
    const int lengths[] = {1,2,4,8,16,64,256,1275};
    int index = 0;
    for (int c = 1; c <= 2; c++) for (int size = 0; size < 4; size++)
    for (int b = 0; b < 7; b++) for (int t = 0; t < 2; t++) for (int l = 0; l < 8; l++) {
        int bytes = lengths[l], seed = index%32;
        uint8_t data[1275 + AV_INPUT_BUFFER_PADDING_SIZE] = {0};
        for (int i = 0; i < bytes; i++) data[i] = (seed*67+i*29+(i*i>>2))&255;
        CeltFrame f = {0};
        f.channels=c; f.size=size; f.start_band=bands[b][0]; f.end_band=bands[b][1];
        f.framebits=bytes*8; f.transient=t;
        OpusRangeCoder rc = {0};
        ff_opus_rc_dec_init(&rc,data,bytes); ff_opus_rc_dec_raw_init(&rc,data+bytes,bytes);
        if (index&1) ff_opus_rc_dec_log(&rc,1);
        printf("A %d",index);
        ff_celt_bitalloc(&f,&rc,0);
        allocation(&f,&rc);
        printf(" %u\n",ff_opus_rc_get_raw(&rc,3));
        /* Setup: restart entropy, exercise zero and nonzero energy history. */
        memset(&rc,0,sizeof(rc)); memset(&f,0,sizeof(f));
        ff_opus_rc_dec_init(&rc,data,bytes); ff_opus_rc_dec_raw_init(&rc,data+bytes,bytes);
        if (index&1) ff_opus_rc_dec_log(&rc,1);
        printf("E %d",index);
        setup(&f,&rc,size,c,bands[b][0],bands[b][1],index%5);
        index++;
    }
    for (int c = 1; c <= 2; c++) for (int size = 0; size < 4; size++) {
        uint8_t data[2+AV_INPUT_BUFFER_PADDING_SIZE] = {255,254};
        OpusRangeCoder rc={0}; CeltFrame f={0};
        ff_opus_rc_dec_init(&rc,data,2); ff_opus_rc_dec_raw_init(&rc,data+2,2);
        printf("Z %d %d",c,size);
        setup(&f,&rc,size,c,0,21,0);
    }
    if (argc != 2) return 1;
    FILE *input = fopen(argv[1],"rb");
    if (!input) return 2;
    int bytes;
    uint8_t *head = read_record(input,&bytes);
    if (!head) return 3;
    int streams = head[19];
    av_free(head);
    uint8_t *data;
    int packet = 0;
    while ((data = read_record(input,&bytes))) {
        int offset=0;
        for (int stream = 0; stream < streams; stream++) {
            OpusPacket p = {0};
            if (ff_opus_parse_packet(&p,data+offset,bytes-offset,stream+1<streams)<0 || p.mode!=OPUS_MODE_CELT) return 4;
            for (int j = 0; j < p.frame_count; j++) {
                uint8_t *frame = data+offset+p.frame_offset[j];
                int length = p.frame_size[j];
                OpusRangeCoder rc={0}; CeltFrame f={0};
                ff_opus_rc_dec_init(&rc,frame,length); ff_opus_rc_dec_raw_init(&rc,frame+length,length);
                printf("R %d %d %d",packet,stream,j);
                setup(&f,&rc,av_log2(p.frame_duration/120),p.stereo+1,0,ff_celt_band_end[p.bandwidth],0);
            }
            offset+=p.packet_size;
        }
        av_free(data); packet++;
    }
    fclose(input);
    return packet == 4 ? 0 : 5;
}
