/* Original FFmpeg 9.0.2 complete CELT synthesis reference, LGPL-2.1-or-later.
 * Same build as opus_celt_reference.c, adding libavcodec/opus/dsp.c.
 * Input: emit_opus_multistream_vectors.mbtx --prepare records.
 */
#define main celt_setup_reference_main
#include "opus_celt_reference.c"
#undef main
#include "libavcodec/opus/pvq.c"

static QUANT_FN(pcm_reference_band) {
    return quant_band_template(pvq,f,rc,band,X,Y,N,b,blocks,lowband,duration,
                               lowband_out,level,gain,lowband_scratch,fill,0);
}
int main(int argc, char **argv) {
    if (argc!=2) return 1;
    FILE *input=fopen(argv[1],"rb"); if (!input) return 2;
    int bytes; uint8_t *head=read_record(input,&bytes); if (!head) return 3;
    int streams=head[18] ? head[19] : 1; av_free(head);
    if (streams>4) return 4;
    CeltFrame *histories[2][4]={{0}};
    AVCodecContext context={0};
    uint8_t *data; int packet=0;
    while ((data=read_record(input,&bytes))) {
        int offset=0;
        for (int stream=0;stream<streams;stream++) {
            OpusPacket p={0};
            if (ff_opus_parse_packet(&p,data+offset,bytes-offset,stream+1<streams)<0 ||
                p.mode!=OPUS_MODE_CELT || p.frame_count!=1) return 5;
            for (int phase=0;phase<2;phase++) {
                CeltFrame **f=&histories[phase][stream];
                if (!*f && ff_celt_init(&context,f,p.stereo+1,phase)<0) return 6;
                (*f)->pvq->quant_band=pcm_reference_band;
                int length=p.frame_size[0]; uint8_t *frame=data+offset+p.frame_offset[0];
                OpusRangeCoder rc={0};
                ff_opus_rc_dec_init(&rc,frame,length); ff_opus_rc_dec_raw_init(&rc,frame+length,length);
                float pcm[2][960]={{0}}; float *output[2]={pcm[0],pcm[1]};
                if (ff_celt_decode_frame(*f,&rc,output,p.stereo+1,p.frame_duration,0,ff_celt_band_end[p.bandwidth])<0) return 7;
                printf("P %d %d %d %d %d",packet,stream,phase,p.frame_duration,p.stereo+1);
                state(&rc);
                for (int c=0;c<=p.stereo;c++) for (int i=0;i<p.frame_duration;i++) float_bits(pcm[c][i]);
                putchar('\n');
            }
            offset+=p.packet_size;
        }
        av_free(data); packet++;
    }
    const int sizes[]={120,960,240,480,120,960};
    for (int stream=0;stream<streams;stream++) for (int phase=0;phase<2;phase++) {
        CeltFrame *f=histories[phase][stream];
        if (!f) return 8;
        for (int step=0;step<6;step++) {
            uint8_t silent[2+AV_INPUT_BUFFER_PADDING_SIZE]={255,254};
            OpusRangeCoder rc={0};
            ff_opus_rc_dec_init(&rc,silent,2); ff_opus_rc_dec_raw_init(&rc,silent+2,2);
            float pcm[2][960]={{0}}; float *output[2]={pcm[0],pcm[1]};
            if (ff_celt_decode_frame(f,&rc,output,f->channels,sizes[step],0,13)<0) return 9;
            printf("Q %d %d %d %d %d",stream,phase,step,sizes[step],f->channels);
            state(&rc);
            for (int c=0;c<f->channels;c++) for (int i=0;i<sizes[step];i++) float_bits(pcm[c][i]);
            putchar('\n');
        }
        ff_celt_free(&histories[phase][stream]);
    }
    fclose(input);
    return 0;
}
