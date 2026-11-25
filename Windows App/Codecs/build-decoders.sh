#!/usr/bin/env bash
# Build the bundled audio-only console helpers with MinGW-w64 (GCC).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="${1:-$(mktemp -d)}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
archive="$here/ffmpeg-8.1.3.tar.xz"
digest=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
python3 - "$archive" "$digest" <<'PY'
import hashlib,sys
from pathlib import Path
if hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest() != sys.argv[2]:
    sys.exit("FFmpeg source checksum mismatch")
PY
tar -xf "$archive" -C "$build"
src="$build/ffmpeg-8.1.3"
build_one() (
    arch="$1"
    prefix="$2"
    target="$3"
    mkdir -p "$build/$arch"
    cd "$build/$arch"
    "$src/configure" --target-os=mingw32 --arch="$target" --cross-prefix="$prefix-" \
        --enable-cross-compile --disable-all --disable-autodetect --disable-network \
        --disable-doc --disable-debug --disable-x86asm --disable-pthreads \
        --enable-avutil --enable-avcodec --enable-avformat \
        --enable-demuxer=aiff,caf,mov \
        --enable-decoder='alac,pcm_*,adpcm_ima_qt,mace3,mace6' \
        --extra-cflags=-Os --enable-small
    make -j"${JOBS:-4}" libavformat/libavformat.a libavcodec/libavcodec.a libavutil/libavutil.a
    "$prefix-gcc" -std=c11 -Os -static -municode -Wall -Wextra -I. -I"$src" \
        "$here/lossless.c" -Wl,--start-group libavformat/libavformat.a libavcodec/libavcodec.a \
        libavutil/libavutil.a -Wl,--end-group -lm -lbcrypt -lsecur32 -luser32 -lole32 -lws2_32 \
        -Wl,--no-insert-timestamp -s -o "$here/Lossless-$arch.exe"
)
build_one x86 i686-w64-mingw32 x86 &
first=$!
build_one x64 x86_64-w64-mingw32 x86_64 &
second=$!
wait "$first"; wait "$second"
