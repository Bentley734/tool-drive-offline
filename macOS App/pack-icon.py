"""Package PNG representations in the macOS ICNS container."""
from pathlib import Path
import struct
import sys
source, target = map(Path, sys.argv[1:])
chunks = []
for kind, name in [('icp4','icon_16x16'),('icp5','icon_32x32'),('icp6','icon_32x32@2x'),('ic07','icon_128x128'),('ic08','icon_256x256'),('ic09','icon_512x512'),('ic10','icon_512x512@2x')]:
    data = (source / (name + '.png')).read_bytes()
    chunks.append(kind.encode() + struct.pack('>I', len(data) + 8) + data)
body = b''.join(chunks)
target.write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
