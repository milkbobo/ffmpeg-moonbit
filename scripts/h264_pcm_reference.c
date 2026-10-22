/* FFmpeg's original CABAC test encoder generates two I_PCM macroblocks.
 * Copyright (c) 2003 Michael Niedermayer. LGPL-2.1-or-later.
 * Build in the configured C reference tree with -I. -lavcodec -lavutil.
 * The resulting payload is wrapped by generate_h264_marking_vectors.mbtx;
 * original FFmpeg then decodes the complete Annex B stream for its MD5.
 */
#define main original_cabac_test_main
#include "libavcodec/tests/cabac.c"
#undef main
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc!=2) return 1;
    FILE *out=fopen(argv[1],"wb"); if (!out) return 2;
    for (int mb=0;mb<2;mb++) {
        uint8_t bytes[1024]={0}; CABACTestContext c={0};
        /* I context 3 at QP26: pre=17, state=92; context4: pre=57, state=12. */
        uint8_t state=mb ? 12 : 92;
        init_cabac_encoder(&c,bytes,sizeof(bytes));
        if (mb) put_cabac_terminate(&c,0); // preceding PCM is not end of slice
        put_cabac(&c,&state,1); // intra type prefix
        int size=put_cabac_terminate(&c,1); // I_PCM escape
        fwrite(bytes,1,size,out);
        for (int plane=0;plane<3;plane++) for (int i=0;i<(plane ? 64 : 256);i++)
            fputc((20*(mb+1)+i%16+plane*37)&255,out);
    }
    uint8_t bytes[1024]={0}; CABACTestContext c={0};
    init_cabac_encoder(&c,bytes,sizeof(bytes));
    int size=put_cabac_terminate(&c,1); // end_of_slice after PCM restart
    fwrite(bytes,1,size,out);
    fclose(out);
    return 0;
}
