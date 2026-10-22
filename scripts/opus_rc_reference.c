/* Golden-vector harness for the original FFmpeg 9.0.2 Opus rc.c.
 * LGPL-2.1-or-later. Compile in a configured FFmpeg source tree:
 * gcc -O2 -I. -I/path/to/FFmpeg /path/to/opus_rc_reference.c
 *     libavcodec/mathtables.c -Llibavutil -lavutil -lm -o opus_rc_reference
 * ./opus_rc_reference > opus_rc_reference.txt
 */
#include <stdio.h>
#include "libavutil/intmath.h"
#include "libavcodec/opus/rc.c"

int main(void) {
    static const uint16_t cdf[] = {256, 1, 5, 17, 49, 113, 193, 255, 256};
    for (int seed = 0; seed < 32; seed++) {
        uint8_t data[64 + AV_INPUT_BUFFER_PADDING_SIZE] = {0};
        for (int i = 0; i < 64; i++) data[i] = (seed * 67 + i * 29 + (i * i >> 2)) & 255;
        OpusRangeCoder rc = {0};
        if (ff_opus_rc_dec_init(&rc, data, 64) < 0) return 1;
        ff_opus_rc_dec_raw_init(&rc, data + 64, 64);
        for (int op = 0; op < 14; op++) {
            int result;
            switch (op % 7) {
            case 0: result = ff_opus_rc_dec_log(&rc, 1 + seed % 12); break;
            case 1: result = ff_opus_rc_dec_cdf(&rc, cdf); break;
            case 2: result = ff_opus_rc_dec_uint(&rc, op < 7 ? 251 : 65537); break;
            case 3: result = ff_opus_rc_dec_uint_step(&rc, 1 + seed % 24); break;
            case 4: result = ff_opus_rc_dec_uint_tri(&rc, 2 * (1 + seed % 32)); break;
            case 5: result = ff_opus_rc_dec_laplace(&rc, 6000 + seed * 13, 9000 + seed * 31); break;
            default: result = ff_opus_rc_get_raw(&rc, 1 + seed % 25); break;
            }
            printf("%d %u %u %u %u %u\n", result, rc.range, rc.value,
                   rc.total_bits, opus_rc_tell(&rc), opus_rc_tell_frac(&rc));
        }
    }
    return 0;
}
