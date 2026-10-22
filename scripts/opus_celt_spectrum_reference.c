/* Original FFmpeg CELT recursive-band reference, LGPL-2.1-or-later.
 * Build like opus_celt_reference.c, adding no runtime FFI to MoonBit.
 * ./harness opus_51_packets.bin > opus_celt_spectrum_reference.txt
 * CONFIG_OPUS_DECODER may be disabled in the minimal reference tree: call
 * quant_band_template(...,quant=0) explicitly through the original callback.
 */
#define main celt_setup_reference_main
#include "opus_celt_reference.c"
#undef main
#include "libavcodec/opus/pvq.c"

static QUANT_FN(reference_band) {
    return quant_band_template(pvq,f,rc,band,X,Y,N,b,blocks,lowband,duration,
                               lowband_out,level,gain,lowband_scratch,fill,0);
}
static void spectrum(CeltFrame *f, OpusRangeCoder *rc, int samples) {
    CeltPVQ pvq = {0}; pvq.quant_band = reference_band; f->pvq = &pvq;
    ff_celt_quant_bands(f,rc);
    state(rc);
    printf(" %u",f->seed);
    for (int c = 0; c < f->channels; c++) for (int i = 0; i < 21; i++) printf(" %u",f->block[c].collapse_masks[i]);
    for (int c = 0; c < f->channels; c++) for (int i = 0; i < samples; i++) float_bits(f->block[c].coeffs[i]);
    putchar('\n');
}
static void complete_spectrum(CeltFrame *f, OpusRangeCoder *rc, int samples) {
    CeltPVQ pvq={0}; pvq.quant_band=reference_band; f->pvq=&pvq;
    ff_celt_quant_bands(f,rc);
    f->anticollapse=f->anticollapse_needed ? ff_opus_rc_get_raw(rc,1) : 0;
    celt_decode_final_energy(f,rc);
    for (int c=0;c<f->channels;c++) {
        if (f->anticollapse) process_anticollapse(f,&f->block[c],f->block[c].coeffs);
        celt_denormalize(f,&f->block[c],f->block[c].coeffs);
    }
    if (f->silence) for (int c=0;c<2;c++) {
        for (int i=0;i<21;i++) f->block[c].energy[i]=-28.0f;
        memset(f->block[c].coeffs,0,sizeof(f->block[c].coeffs));
    }
    if (f->channels==1) memcpy(f->block[1].energy,f->block[0].energy,sizeof(f->block[0].energy));
    for (int c=0;c<2;c++) for (int i=0;i<21;i++) {
        CeltBlock *block=&f->block[c];
        if (!f->transient) {
            block->prev_energy[1][i]=block->prev_energy[0][i];
            block->prev_energy[0][i]=block->energy[i];
        } else block->prev_energy[0][i]=FFMIN(block->prev_energy[0][i],block->energy[i]);
        if (i<f->start_band || i>=f->end_band) { block->prev_energy[0][i]=-28.0f; block->energy[i]=0.0f; }
    }
    f->seed=rc->range;
    state(rc);
    printf(" %u %d %d %d %d %d",f->seed,f->silence,f->transient,f->blocks,f->anticollapse,f->block[0].pf_period_new);
    for (int i=0;i<3;i++) float_bits(f->block[0].pf_gains_new[i]);
    for (int c=0;c<f->channels;c++) for (int i=0;i<21;i++) printf(" %u",f->block[c].collapse_masks[i]);
    for (int c=0;c<2;c++) for (int i=0;i<21;i++) float_bits(f->block[c].energy[i]);
    for (int age=0;age<2;age++) for (int c=0;c<2;c++) for (int i=0;i<21;i++) float_bits(f->block[c].prev_energy[age][i]);
    for (int c=0;c<f->channels;c++) for (int i=0;i<samples;i++) float_bits(f->block[c].coeffs[i]);
    putchar('\n');
}
int main(int argc, char **argv) {
    if (argc != 2) return 1;
    FILE *input=fopen(argv[1],"rb"); if (!input) return 2;
    int bytes; uint8_t *head=read_record(input,&bytes); if (!head) return 3;
    int streams=head[18] ? head[19] : 1; av_free(head);
    if (streams>4) return 6;
    static CeltFrame histories[2][4];
    for (int phase=0;phase<2;phase++) for (int stream=0;stream<streams;stream++) ff_celt_flush(&histories[phase][stream]);
    for (int channels=1;channels<=2;channels++) for (int size=0;size<4;size++) {
        uint8_t silent[2+AV_INPUT_BUFFER_PADDING_SIZE]={255,254};
        CeltFrame f={0}; OpusRangeCoder rc={0};
        ff_celt_flush(&f);
        ff_opus_rc_dec_init(&rc,silent,2); ff_opus_rc_dec_raw_init(&rc,silent+2,2);
        printf("H"); setup(&f,&rc,size,channels,0,13,0);
        printf("Z %d %d",channels,size);
        complete_spectrum(&f,&rc,120<<size);
    }
    uint8_t *data; int packet=0;
    while ((data=read_record(input,&bytes))) {
        int offset=0;
        for (int stream=0; stream<streams; stream++) {
            OpusPacket p={0};
            if (ff_opus_parse_packet(&p,data+offset,bytes-offset,stream+1<streams)<0 || p.mode!=OPUS_MODE_CELT || p.frame_count!=1) return 4;
            for (int phase=0; phase<2; phase++) {
                int length=p.frame_size[0]; uint8_t *frame=data+offset+p.frame_offset[0];
                OpusRangeCoder rc={0}; CeltFrame f={0};
                ff_opus_rc_dec_init(&rc,frame,length); ff_opus_rc_dec_raw_init(&rc,frame+length,length);
                printf("H"); setup(&f,&rc,av_log2(p.frame_duration/120),p.stereo+1,0,ff_celt_band_end[p.bandwidth],0);
                f.seed=12345+packet*17+stream*37; f.apply_phase_inv=phase;
                printf("S %d %d %d %d %d",packet,stream,phase,p.frame_duration,f.channels);
                spectrum(&f,&rc,p.frame_duration);
                CeltFrame *history=&histories[phase][stream];
                history->silence=history->transient=0;
                history->block[0].pf_period_new=history->block[1].pf_period_new=0;
                for (int c=0;c<2;c++) {
                    memset(history->block[c].coeffs,0,sizeof(history->block[c].coeffs));
                    memset(history->block[c].collapse_masks,0,sizeof(history->block[c].collapse_masks));
                }
                memset(&rc,0,sizeof(rc));
                ff_opus_rc_dec_init(&rc,frame,length); ff_opus_rc_dec_raw_init(&rc,frame+length,length);
                printf("H"); setup(history,&rc,av_log2(p.frame_duration/120),p.stereo+1,0,ff_celt_band_end[p.bandwidth],0);
                history->apply_phase_inv=phase;
                printf("T %d %d %d %d %d",packet,stream,phase,p.frame_duration,history->channels);
                complete_spectrum(history,&rc,p.frame_duration);
            }
            offset+=p.packet_size;
        }
        av_free(data); packet++;
    }
    fclose(input);
    return packet>0 ? 0 : 5;
}
