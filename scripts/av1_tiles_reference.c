/* Tile-boundary golden harness. The tile loop follows FFmpeg 9.0.2
 * libavcodec/av1dec.c:get_tiles_info with its original bytestream2 accessors.
 * LGPL-2.1-or-later. Args: input.ivf aligned_group_header_bytes tile_count
 * tile_size_bytes. The header byte count comes from trace_headers, not the
 * MoonBit tile parser. Link configured FFmpeg libavutil for per-tile MD5.
 */
#include <stdio.h>
#include <stdlib.h>
#include "libavcodec/bytestream.h"
#include "libavutil/md5.h"

int main(int argc, char **argv) {
    if (argc != 5) return 1;
    FILE *input = fopen(argv[1], "rb");
    if (!input) return 2;
    fseek(input, 0, SEEK_END);
    int length = ftell(input);
    rewind(input);
    uint8_t *bytes = malloc(length);
    if (!bytes || fread(bytes, 1, length, input) != length) return 3;
    fclose(input);
    int frame_size = AV_RL32(bytes + 32), pos = 44;
    int end = pos + frame_size, group_header = atoi(argv[2]);
    int tile_count = atoi(argv[3]), size_bytes = atoi(argv[4]);
    while (pos < end) {
        int type = (bytes[pos++] >> 3) & 15;
        unsigned size = 0, shift = 0, b;
        do {
            if (pos >= end || shift > 28) return 4;
            b = bytes[pos++];
            size |= (b & 127) << shift;
            shift += 7;
        } while (b & 128);
        if (size > end - pos) return 5;
        if (type != 6) { pos += size; continue; }
        if (group_header > size) return 6;
        GetByteContext gb;
        bytestream2_init(&gb, bytes + pos + group_header, size - group_header);
        for (int tile = 0; tile < tile_count; tile++) {
            uint32_t tile_size;
            if (tile == tile_count - 1) tile_size = bytestream2_get_bytes_left(&gb);
            else {
                if (bytestream2_get_bytes_left(&gb) < size_bytes) return 7;
                tile_size = 0;
                for (int i = 0; i < size_bytes; i++) tile_size |= bytestream2_get_byteu(&gb) << (8 * i);
                if (bytestream2_get_bytes_left(&gb) <= tile_size) return 8;
                tile_size++;
            }
            int offset = group_header + bytestream2_tell(&gb);
            uint8_t md5[16];
            av_md5_sum(md5, bytes + pos + offset, tile_size);
            printf("%d %d %u ", tile, offset, tile_size);
            for (int i = 0; i < 16; i++) printf("%02x", md5[i]);
            printf("\n");
            bytestream2_skipu(&gb, tile_size);
        }
        free(bytes);
        return 0;
    }
    free(bytes);
    return 9;
}
