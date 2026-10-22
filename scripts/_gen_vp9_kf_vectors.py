#!/usr/bin/env python3
"""Generate VP9 keyframe test vectors with the docker ffmpeg 9.0.2 image.

For each stream:
  * encode N all-keyframe frames (libvpx-vp9) into IVF
  * extract per-frame VP9 payloads (IVF framing stripped)
  * decode the IVF with the reference decoder and take per-frame YUV MD5
Prints a python dict literal with hex payloads + expected MD5s for embedding
into `vp9_kf_realdata_wbtest.mbt`.
"""

import hashlib
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.path.normpath(os.path.join(HERE, '..', '.scratch', 'vp9k'))
MOUNT_SRC = 'D:/project/FFmpeg-n9.0.2/moonbit/.scratch'
IMAGE = 'linuxserver/ffmpeg:9.0.2'

STREAMS = [
    # name, size, frames, extra encoder options
    ('basic',   '160x144', 3, ['-q:v', '30', '-g', '1']),
    ('small',   '70x36',   3, ['-q:v', '10', '-g', '1']),
    ('qfull',   '64x48',   2, ['-q:v', '0', '-g', '1']),
    ('lossless','64x48',   2, ['-lossless', '1', '-g', '1']),
    ('tiles',   '512x128', 2, ['-q:v', '30', '-g', '1',
                              '-tile-columns', '2', '-tile-rows', '1']),
]


def sh(cmd, **kw):
    env = dict(os.environ, MSYS_NO_PATHCONV='1')
    print('+', ' '.join(cmd[:8]), '...')
    r = subprocess.run(cmd, capture_output=True, text=True, env=env, **kw)
    if r.returncode != 0:
        print(r.stdout[-2000:])
        print(r.stderr[-2000:])
        raise SystemExit('command failed: %s' % cmd[:4])
    return r


def docker(*args):
    return sh(['docker', 'run', '--rm', '-v', '%s:/s' % MOUNT_SRC,
               '--entrypoint', 'ffmpeg', IMAGE] + list(args))


def ffprobe_frames(path):
    r = sh(['docker', 'run', '--rm', '-v', '%s:/s' % MOUNT_SRC,
            '--entrypoint', 'ffprobe', IMAGE, '-v', 'quiet',
            '-show_packets', '-show_data', '-of', 'json', path])
    import json
    return json.loads(r.stdout)


def read_ivf(path):
    """Split an IVF file into VP9 frame payloads."""
    with open(path, 'rb') as f:
        data = f.read()
    assert data[:4] == b'DKIF', 'not IVF'
    hdrlen = struct.unpack('<H', data[6:8])[0]
    pos = hdrlen
    frames = []
    while pos + 12 <= len(data):
        size, pts = struct.unpack('<IQ', data[pos:pos + 12])
        pos += 12
        frames.append(data[pos:pos + size])
        pos += size
    return frames


def ref_md5s(path, w, h, n):
    """Per-frame YUV MD5 via the reference decoder."""
    env = dict(os.environ, MSYS_NO_PATHCONV='1')
    r = subprocess.run(['docker', 'run', '--rm', '-v', '%s:/s' % MOUNT_SRC,
                        '--entrypoint', 'ffmpeg', IMAGE, '-v', 'quiet',
                        '-i', path, '-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-'],
                       capture_output=True, env=env)
    if r.returncode != 0:
        raise SystemExit(r.stderr[-2000:].decode('utf-8', 'replace'))
    raw = r.stdout
    frame_len = w * h * 3 // 2
    assert len(raw) == frame_len * n, (len(raw), frame_len * n)
    return [hashlib.md5(raw[i * frame_len:(i + 1) * frame_len]).hexdigest()
            for i in range(n)]


def main():
    os.makedirs(SCRATCH, exist_ok=True)
    out = {}
    for name, size, n, extra in STREAMS:
        w, h = map(int, size.split('x'))
        ivf = '/s/vp9_%s.ivf' % name
        src = '/s/src_%s.mp4' % name
        # source: synthetic video, re-encoded every frame as a keyframe
        docker('-f', 'lavfi', '-i', 'testsrc2=size=%s:rate=10:duration=%d'
               % (size, n), '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt',
               'yuv420p', '-y', src)
        docker('-i', src, '-c:v', 'libvpx-vp9', '-pix_fmt', 'yuv420p',
               '-an', '-frames:v', str(n), '-y', *extra, ivf)
        frames = read_ivf(os.path.join(SCRATCH, '..', 'vp9_%s.ivf' % name))
        assert len(frames) == n, (name, len(frames))
        md5s = ref_md5s(ivf, w, h, n)
        out[name] = {'size': [w, h], 'md5': md5s,
                     'frames': [f.hex() for f in frames]}
        print(name, size, n, md5s)
    with open(os.path.join(SCRATCH, 'vp9_kf_vectors.py.txt'), 'w') as f:
        f.write(repr(out))
    print('WROTE', os.path.join(SCRATCH, 'vp9_kf_vectors.py.txt'))


if __name__ == '__main__':
    main()
