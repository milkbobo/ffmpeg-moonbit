/* FFmpeg 9.0.2 PS payload + DSP reference; input is one bit string per line.
 * Generate the input with generate_aac_ps_tests.py --payloads-only. */
#define USE_FIXED 0
#include "libavcodec/aacps.h"
#include <stdio.h>
#include <string.h>

int main(void)
{
    PSContext ps = {0};
    float left[2][38][64], right[2][38][64];
    char bits[4096];
    int frame = 0;
    ff_ps_init_common();
    ff_ps_init();
    ff_ps_ctx_init(&ps);
    while (fgets(bits, sizeof(bits), stdin)) {
        uint8_t payload[1024] = {0};
        GetBitContext gb;
        int n = (int)strcspn(bits, "\r\n");
        if (n <= 0 || n > 7680) return 2;
        for (int i = 0; i < n; i++) {
            if (bits[i] == '1') payload[i / 8] |= 1 << (7 - i % 8);
            else if (bits[i] != '0') return 3;
        }
        if (init_get_bits(&gb, payload, n) < 0) return 4;
        int consumed = ff_ps_read_data(NULL, &gb, &ps.common, n);
        if (!ps.common.start || consumed != n) {
            fprintf(stderr, "bad payload %d: %d/%d start=%d\n", frame, consumed, n, ps.common.start);
            return 5;
        }
        for (int p = 0; p < 2; p++)
            for (int t = 0; t < 38; t++)
                for (int k = 0; k < 64; k++)
                    left[p][t][k] = ((p * 17 + t * 13 + k * 7 + frame * 11) % 127 - 63) / 64.0f;
        memset(right, 0, sizeof(right));
        ff_ps_apply(&ps, left, right, 20 + frame * 6);
        for (int ch = 0; ch < 2; ch++)
            for (int p = 0; p < 2; p++)
                for (int t = 0; t < 32; t += 7)
                    for (int k = 0; k < 64; k++) {
                        float v = ch ? right[p][t][k] : left[p][t][k];
                        if (fwrite(&v, sizeof(v), 1, stdout) != 1) return 6;
                    }
        frame++;
    }
    return frame == 8 ? 0 : 7;
}
