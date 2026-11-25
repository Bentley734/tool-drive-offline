"""Exercise a built helper against an independent FFmpeg installation."""
import argparse
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("decoder", type=Path)
parser.add_argument("--ffmpeg", default="ffmpeg")
args = parser.parse_args()
decoder = args.decoder.resolve()
cases = [
    ("aiff", "pcm_s24be", "integer.aiff"),
    ("aiff", "pcm_s16le", "little-endian.aifc"),
    ("aiff", "pcm_f32be", "float.aifc"),
    ("caf", "alac", "compressed.caf"),
    ("caf", "pcm_s24le", "integer.caf"),
    ("ipod", "alac", "lossless.m4a"),
    ("ipod", "aac", "native.m4a"),
]
with TemporaryDirectory() as directory:
    root = Path(directory)
    # Reproducible, unequal left/right channels and partial trailing packets.
    pattern = b"".join((((j * 5903 + ch * 127093) % 14567891) - 7283945).to_bytes(
        3, "little", signed=True) for j in range(18007) for ch in range(2))
    for container, codec, name in cases:
        original = root / name
        wav = root / (name + ".wav")
        subprocess.run([args.ffmpeg, "-v", "error", "-f", "s24le", "-ar", "44100",
                        "-ac", "2", "-i", "pipe:0", "-c:a", codec, "-f", container,
                        str(original)], input=pattern, check=True)
        before = original.read_bytes()
        result = subprocess.run([str(decoder), str(original), str(wav)])
        assert original.read_bytes() == before
        if codec == "aac":
            assert result.returncode == 3 and not wav.exists()
            continue
        assert result.returncode == 0
        def samples(path):
            return subprocess.check_output([args.ffmpeg, "-v", "error", "-i", str(path),
                                            "-map", "0:a:0", "-f", "s32le", "-c:a", "pcm_s32le", "-"])
        assert samples(wav) == samples(original), name
    (root / "invalid.caf").write_bytes(b"caff\0" + bytes(80))
    invalid_output = root / "invalid.wav"
    result = subprocess.run([str(decoder), str(root / "invalid.caf"), str(invalid_output)])
    assert result.returncode == 1 and not invalid_output.exists()
print("Decoded AIFF, AIFC, PCM CAF, ALAC CAF and ALAC M4A sample-for-sample; AAC passed through.")
