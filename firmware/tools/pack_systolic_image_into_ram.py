#!/usr/bin/env python3
"""Build a 256-KiB AXI-BRAM image for the DMA/systolic image pipeline."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageOps


IMAGE_SIDE = 64
TILE_SIDE = 4
INPUT_TILED_ADDR = 0x10000
IDENTITY_ADDR = 0x11000
SCRATCH_ADDR = 0x12000
OUTPUT_ADDR = 0x13000


def write_word_hex(memory: bytearray, path: Path) -> None:
    with path.open("w", encoding="ascii", newline="\n") as handle:
        for address in range(0, len(memory), 4):
            word = int.from_bytes(memory[address : address + 4], "little")
            handle.write(f"{word:08x}\n")


def write_byte_hex(data: bytes, path: Path) -> None:
    path.write_text("".join(f"{value:02x}\n" for value in data), encoding="ascii")


def center_and_tile(pixels: bytes) -> bytes:
    tiled = bytearray()
    tiles_per_axis = IMAGE_SIDE // TILE_SIDE
    for tile_row in range(tiles_per_axis):
        for tile_col in range(tiles_per_axis):
            for local_row in range(TILE_SIDE):
                for local_col in range(TILE_SIDE):
                    row = tile_row * TILE_SIDE + local_row
                    col = tile_col * TILE_SIDE + local_col
                    pixel = pixels[row * IMAGE_SIDE + col]
                    tiled.append((pixel - 128) & 0xFF)
    return bytes(tiled)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--firmware", required=True, type=Path)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--asset-dir", required=True, type=Path)
    parser.add_argument("--ram-bytes", type=int, default=256 * 1024)
    args = parser.parse_args()

    firmware = args.firmware.read_bytes()
    if len(firmware) > 0x3000:
        raise SystemExit(
            f"firmware is {len(firmware)} bytes and overlaps reserved page 0x3000"
        )
    if args.ram_bytes < OUTPUT_ADDR + IMAGE_SIDE * IMAGE_SIDE:
        raise SystemExit("RAM is too small for the image pipeline layout")

    resample = getattr(Image, "Resampling", Image).LANCZOS
    source = Image.open(args.image)
    gray = ImageOps.fit(source.convert("L"), (IMAGE_SIDE, IMAGE_SIDE),
                        method=resample)
    pixels = gray.tobytes()
    tiled = center_and_tile(pixels)

    memory = bytearray(args.ram_bytes)
    memory[: len(firmware)] = firmware
    memory[INPUT_TILED_ADDR : INPUT_TILED_ADDR + len(tiled)] = tiled
    # INT8 identity matrix, row-major.  It lets C=A*I reproduce each image
    # tile while still exercising every processing element and accumulator.
    identity = bytes(1 if row == col else 0
                     for row in range(TILE_SIDE)
                     for col in range(TILE_SIDE))
    memory[IDENTITY_ADDR : IDENTITY_ADDR + len(identity)] = identity

    args.asset_dir.mkdir(parents=True, exist_ok=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    gray.save(args.asset_dir / "input_64x64.png")
    gray.save(args.asset_dir / "expected_output_64x64.png")
    (args.asset_dir / "input_64x64.raw").write_bytes(pixels)
    (args.asset_dir / "input_tiled_centered.raw").write_bytes(tiled)
    (args.asset_dir / "expected_output_64x64.raw").write_bytes(pixels)
    write_byte_hex(pixels, args.asset_dir / "expected_output_64x64.hex8")
    write_word_hex(memory, args.output)

    metadata = {
        "source": str(args.image.resolve()),
        "ram_bytes": args.ram_bytes,
        "ram_words_32": args.ram_bytes // 4,
        "image": {"width": IMAGE_SIDE, "height": IMAGE_SIDE, "format": "GRAY8"},
        "layout": {
            "input_tiled_centered": hex(INPUT_TILED_ADDR),
            "identity_matrix": hex(IDENTITY_ADDR),
            "scratch_int32": hex(SCRATCH_ADDR),
            "output_raster": hex(OUTPUT_ADDR),
        },
        "pipeline": "BRAM -> DMA/AXI4 -> AXI-Stream -> systolic -> AXI-Stream -> DMA/AXI4 -> BRAM -> DMA -> UART",
    }
    (args.asset_dir / "manifest.json").write_text(
        json.dumps(metadata, indent=2), encoding="utf-8"
    )
    print(f"Packed {args.image} as 64x64 GRAY8 into {args.output}")
    print(f"RAM size: {args.ram_bytes // 1024} KiB ({args.ram_bytes // 4} x 32-bit words)")


if __name__ == "__main__":
    main()
