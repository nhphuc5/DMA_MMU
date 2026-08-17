#!/usr/bin/env python3
#
# This is free and unencumbered software released into the public domain.
#
# Anyone is free to copy, modify, publish, use, compile, sell, or
# distribute this software, either in source code form or as a compiled
# binary, for any purpose, commercial or non-commercial, and by any
# means.

from sys import argv

binfile = argv[1]
nwords = int(argv[2])

with open(binfile, "rb") as f:
    bindata = f.read()

assert len(bindata) <= 4*nwords

# objcopy emits exactly the bytes present in the ELF load image.  A valid
# firmware image is not required to end on a 32-bit boundary, while Vivado's
# AXI RAM initialization file is word oriented.  Pad only the final partial
# word with zeros instead of rejecting an otherwise valid RV32 image.
if len(bindata) % 4:
    bindata += bytes(4 - (len(bindata) % 4))

for i in range(nwords):
    if i < len(bindata) // 4:
        w = bindata[4*i : 4*i+4]
        print("%02x%02x%02x%02x" % (w[3], w[2], w[1], w[0]))
    else:
        print("0")
