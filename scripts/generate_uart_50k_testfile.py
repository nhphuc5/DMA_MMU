#!/usr/bin/env python3
"""Generate the deterministic, byte-exact 50 KiB UART DMA input file."""

from pathlib import Path


SIZE_BYTES = 50 * 1024
ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "testdata" / "uart_input_50k.txt"


def build_payload() -> bytes:
    header = (
        b"DMA/IOMMU PicoRV32 UART large-file regression\n"
        b"Path: UART RX -> AXI-Stream -> DMA -> IOMMU -> AXI4 -> RAM\n"
        b"The following deterministic records are checked byte-for-byte.\n"
    )
    payload = bytearray(header)
    record = 0
    while len(payload) < SIZE_BYTES:
        line = (
            f"REC={record:06d} DATA="
            f"{(record * 0x9E3779B1) & 0xFFFFFFFF:08X} "
            f"{(record * 17 + 3) & 0xFFFFFFFF:08X} "
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\n"
        ).encode("ascii")
        payload.extend(line)
        record += 1
    return bytes(payload[:SIZE_BYTES])


def main() -> None:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_bytes(build_payload())
    print(f"Generated {OUTPUT} ({OUTPUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
