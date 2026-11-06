#!/usr/bin/env python3
"""OneOS local patch for MysticGSI's payload extractor.

Android 17 full OTAs use OP_REPLACE_ZSTD (op type 14), which the bundled
update_metadata.proto does not know. Such an op parses as an unknown field
- op.HasField("type") is false - and the unpatched extractor then fails
with a message that does not name the cause (docs/new-guest-systems.md).

This script:
  1. adds OP_REPLACE_ZSTD = 14 to the InstallOperation.Type enum in the
     generated update_metadata_pb2.py (by editing its serialized
     descriptor) and to update_metadata.proto, so the op parses normally;
  2. adds op 14 to FULL_OPS and a zstd decoder to payload.py.

Usage: python3 fix-mysticgsi-payload.py [path/to/mysticgsi]
Idempotent: re-running detects both fixes and does nothing.
"""
import os
import re
import sys

from google.protobuf import descriptor_pb2

HERE = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
FORMATS = os.path.join(HERE, "tools", "extractor", "formats")
PB2 = os.path.join(FORMATS, "update_metadata_pb2.py")
PROTO = os.path.join(FORMATS, "update_metadata.proto")
PAYLOAD = os.path.join(FORMATS, "payload.py")


def patch_pb2() -> None:
    src = open(PB2, encoding="utf-8").read()
    m = re.search(r"AddSerializedFile\(\n((?:\s*b['\"].*['\"]\n)+)\)", src)
    if not m:
        sys.exit("update_metadata_pb2.py: serialized descriptor not found")
    current = eval("".join(m.group(1).split("\n")))
    fdp = descriptor_pb2.FileDescriptorProto.FromString(current)
    iom = next(x for x in fdp.message_type if x.name == "InstallOperation")
    enum = next(x for x in iom.enum_type if x.name == "Type")
    if any(v.number == 14 for v in enum.value):
        print("  update_metadata_pb2.py: op 14 already known")
        return
    v = enum.value.add()
    v.name = "OP_REPLACE_ZSTD"
    v.number = 14
    new_lit = "    b'" + repr(fdp.SerializeToString())[2:-1] + "'\n"
    src = src[: m.start(1)] + new_lit + src[m.end(1):]
    open(PB2, "w", encoding="utf-8").write(src)
    print("  update_metadata_pb2.py: added OP_REPLACE_ZSTD = 14")


def patch_proto() -> None:
    src = open(PROTO, encoding="utf-8").read()
    if "REPLACE_ZSTD = 14" in src:
        print("  update_metadata.proto: already patched")
        return
    old = "    LZ4DIFF_PUFFDIFF = 13;\n"
    if old not in src:
        sys.exit("update_metadata.proto: LZ4DIFF_PUFFDIFF not found")
    src = src.replace(
        old, old + "    REPLACE_ZSTD = 14;  # OneOS local patch\n", 1
    )
    open(PROTO, "w", encoding="utf-8").write(src)
    print("  update_metadata.proto: added REPLACE_ZSTD = 14")


def patch_payload() -> None:
    src = open(PAYLOAD, encoding="utf-8").read()
    if "OP_REPLACE_ZSTD" in src:
        print("  payload.py: already patched")
        return
    old = """OP_REPLACE = 0
OP_REPLACE_BZ = 1
OP_ZERO = 6
OP_DISCARD = 7
OP_REPLACE_XZ = 8
FULL_OPS = {OP_REPLACE, OP_REPLACE_BZ, OP_REPLACE_XZ, OP_ZERO, OP_DISCARD}
"""
    new = """OP_REPLACE = 0
OP_REPLACE_BZ = 1
OP_ZERO = 6
OP_DISCARD = 7
OP_REPLACE_XZ = 8
# OneOS local patch: Android 17 full OTAs use OP_REPLACE_ZSTD (op type 14),
# which the bundled update_metadata.proto does not know. The proto fix that
# goes with this patch adds the enum value; without it the op parses as an
# unknown field and the extractor fails without naming the cause.
OP_REPLACE_ZSTD = 14
FULL_OPS = {OP_REPLACE, OP_REPLACE_BZ, OP_REPLACE_XZ, OP_ZERO, OP_DISCARD,
            OP_REPLACE_ZSTD}
"""
    if old not in src:
        sys.exit("payload.py: FULL_OPS block not found")
    src = src.replace(old, new)
    old = """DECODERS = {
    OP_REPLACE: _sniff_replace,
    OP_REPLACE_BZ: bz2.decompress,
    OP_REPLACE_XZ: lzma.decompress,
}
"""
    new = """DECODERS = {
    OP_REPLACE: _sniff_replace,
    OP_REPLACE_BZ: bz2.decompress,
    OP_REPLACE_XZ: lzma.decompress,
    OP_REPLACE_ZSTD: _zstd_decompress,
}
"""
    if old not in src:
        sys.exit("payload.py: DECODERS block not found")
    src = src.replace(old, new)
    open(PAYLOAD, "w", encoding="utf-8").write(src)
    print("  payload.py: op 14 accepted and decoded with zstd")


if __name__ == "__main__":
    patch_pb2()
    patch_proto()
    patch_payload()
