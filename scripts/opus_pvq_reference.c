/* Independent golden vectors from original FFmpeg 9.0.2 opus/pvq.c.
 * LGPL-2.1-or-later. Build in a configured FFmpeg tree without SIMD/FMA:
 * gcc -O2 -ffp-contract=off -ffunction-sections -fdata-sections -I.
 *   -Wl,--gc-sections /s/scripts/opus_pvq_reference.c libavcodec/opus/tab.c
 *   libavcodec/mathtables.c -Llibavutil -lavutil -lm -o /s/.scratch/opus_pvq_reference
 * ./opus_pvq_reference > opus_pvq_reference.txt
 * Every line is one independent case; payloads are deterministic test input,
 * all expected vector coefficients and entropy states come from original C.
 */
#include <stdio.h>
#include <inttypes.h>
#include <string.h>
#include "libavutil/intmath.h"
#include "libavutil/intreadwrite.h"
#include "libavutil/md5.h"
#include "libavcodec/opus/rc.c"
#include "libavcodec/opus/pvq.c"

static const int max_col[15] = {176,176,176,176,176,176,96,54,37,28,24,19,18,16,14};
static int valid_u(int n, int k) {
    int row = FFMIN(n,k), col = FFMAX(n,k);
    return row < 15 && col <= max_col[row];
}

static struct AVMD5 *vector_md5;
static int vector_count;
static void emit_vector(int n, int k, uint32_t index) {
    int y[176];
    uint64_t norm = celt_cwrsi(n, k, index, y);
    uint8_t buf[24 + 176*4];
    AV_WL32(buf,n); AV_WL32(buf+4,k); AV_WL32(buf+8,index);
    AV_WL64(buf+12,norm);
    for (int i = 0; i < n; i++) AV_WL32(buf+20+4*i,y[i]);
    av_md5_update(vector_md5,buf,20+4*n);
    vector_count++;
}

int main(void) {
    vector_md5 = av_md5_alloc();
    if (!vector_md5) return 1;
    av_md5_init(vector_md5);
    /* All supported codebook cardinalities, including those over INT_MAX. */
    for (int n = 2; n <= 176; n++) {
        for (int k = 0; k <= 175; k++) {
            if (!valid_u(n,k) || !valid_u(n,k+1)) continue;
            uint64_t size64 = (uint64_t)CELT_PVQ_U(n,k) + CELT_PVQ_U(n,k+1);
            printf("S %d %d %"PRIu64"\n", n, k, size64);
            if (size64 > UINT32_MAX) continue;
            uint32_t size = size64;
            if (n <= 6 && k <= 5) {
                for (uint32_t i = 0; i < size; i++) emit_vector(n,k,i);
            } else {
                /* Boundaries and interior samples of every valid codebook. */
                const uint32_t indices[] = {0, size/3, size/2, size-1};
                for (int j = 0; j < 4; j++) emit_vector(n,k,indices[j]);
            }
        }
    }
    uint8_t digest[16];
    av_md5_final(vector_md5,digest);
    av_free(vector_md5);
    printf("D %d ",vector_count);
    for (int i = 0; i < 16; i++) printf("%02x",digest[i]);
    putchar('\n');
    /* Decode multiple bands on a shared forward/raw coder to catch state drift. */
    const int dims[][2] = {{2,1},{3,5},{8,4},{16,6},{24,4},{48,3},{96,2},{176,1},
                          {4,100},{5,80},{12,12},{13,13},{14,13}};
    for (int seed = 0; seed < 8; seed++) {
        uint8_t data[256 + AV_INPUT_BUFFER_PADDING_SIZE] = {0};
        for (int i = 0; i < 256; i++) data[i] = (seed*67 + i*29 + (i*i >> 2)) & 255;
        for (int spread = 0; spread < 4; spread++) {
            OpusRangeCoder rc = {0};
            ff_opus_rc_dec_init(&rc,data,256);
            ff_opus_rc_dec_raw_init(&rc,data+256,256);
            CeltPVQ pvq = {0};
            for (int j = 0; j < FF_ARRAY_ELEMS(dims); j++) {
                int n = dims[j][0], k = dims[j][1], blocks = 1 << (j%4);
                while (n%blocks) blocks >>= 1;
                float x[176], gain = 0.25f * (1 + j%5);
                uint32_t mask = celt_alg_unquant(&rc,x,n,k,spread,blocks,gain,&pvq);
                printf("B %d %d %d %d %u %u %u %u %u",seed,spread,n,k,mask,
                       rc.range,rc.value,rc.total_bits,opus_rc_tell_frac(&rc));
                for (int i = 0; i < n; i++) {
                    uint32_t bits;
                    memcpy(&bits,&x[i],4);
                    printf(" %u",bits);
                }
                putchar('\n');
            }
        }
    }
    return 0;
}
