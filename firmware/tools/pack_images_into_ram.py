#!/usr/bin/env python3
"""Build one 64-KiB AXI-RAM HEX image containing firmware and pictures.

The output format matches axi_ram.v: one little-endian 32-bit word per line
for use with SystemVerilog $readmemh and Vivado BRAM initialization.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageOps


RAM_BYTES = 64 * 1024
STACK_GUARD_BASE = 0xE000


def parse_address(value: object) -> int:
    return int(str(value), 0)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--firmware", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--asset-dir", required=True, type=Path)
    args = parser.parse_args()

    manifest_path = args.manifest.resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    width = int(manifest["width"])
    height = int(manifest["height"])
    if manifest.get("format") != "grayscale8":
        raise ValueError("Only grayscale8 is supported by this image demo")

    firmware = args.firmware.read_bytes()
    if len(firmware) > 0x3000:
        raise ValueError("Firmware exceeds the reserved low-RAM region")

    ram = bytearray(RAM_BYTES)
    ram[: len(firmware)] = firmware
    args.asset_dir.mkdir(parents=True, exist_ok=True)
    metadata: list[dict[str, object]] = []

    for entry in manifest["images"]:
        image_id = int(entry["id"])
        source = (manifest_path.parent / str(entry["source"])).resolve()
        address = parse_address(entry["ram_address"])
        payload_size = width * height
        if address % 0x1000:
            raise ValueError(f"Image {image_id} address must be 4-KiB aligned")
        if address + payload_size > STACK_GUARD_BASE:
            raise ValueError(f"Image {image_id} overlaps the CPU stack guard")

        with Image.open(source) as original:
            # Fit fills the complete 64x64 frame while preserving proportions;
            # only the outer excess is cropped.  No synthetic pixels are made.
            gray = ImageOps.fit(
                original.convert("L"),
                (width, height),
                method=Image.Resampling.LANCZOS,
                centering=(0.5, 0.5),
            )
            payload = gray.tobytes()
            preview_path = args.asset_dir / f"image_{image_id}_64x64.png"
            raw_path = args.asset_dir / f"image_{image_id}_64x64.raw"
            hex8_path = args.asset_dir / f"image_{image_id}_64x64.hex8"
            gray.save(preview_path)
            raw_path.write_bytes(payload)
            hex8_path.write_text(
                "".join(f"{byte:02x}\n" for byte in payload),
                encoding="ascii",
            )

        ram[address : address + payload_size] = payload
        metadata.append(
            {
                "id": image_id,
                "source": str(source),
                "ram_address": f"0x{address:04X}",
                "width": width,
                "height": height,
                "bytes": payload_size,
                "preview": str(preview_path.resolve()),
                "raw": str(raw_path.resolve()),
            }
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="ascii", newline="\n") as output:
        for offset in range(0, RAM_BYTES, 4):
            word = int.from_bytes(ram[offset : offset + 4], "little")
            output.write(f"{word:08x}\n")

    metadata_path = args.output.with_suffix(".json")
    metadata_path.write_text(
        json.dumps(
            {
                "ram_bytes": RAM_BYTES,
                "firmware_bytes": len(firmware),
                "hex_file": str(args.output.resolve()),
                "images": metadata,
            },
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    print(f"Firmware: {len(firmware)} bytes")
    for item in metadata:
        print(
            f"IMG{item['id']}: {item['bytes']} bytes at "
            f"{item['ram_address']} ({item['width']}x{item['height']} gray8)"
        )
    print(f"RAM HEX: {args.output.resolve()}")
    print(f"Metadata: {metadata_path.resolve()}")


if __name__ == "__main__":
    main()
