#!/usr/bin/env python3
"""Receive or replay the PicoRV32 DMA/Systolic image frame and create PNG."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


WIDTH = 64
HEIGHT = 64
PAYLOAD_BYTES = WIDTH * HEIGHT


def read_exact(port, count: int) -> bytes:
    data = bytearray()
    while len(data) < count:
        chunk = port.read(count - len(data))
        if not chunk:
            raise TimeoutError(f"UART timeout after {len(data)}/{count} bytes")
        data.extend(chunk)
    return bytes(data)


def wait_for(port, marker: bytes) -> None:
    window = bytearray()
    while True:
        value = read_exact(port, 1)
        window.extend(value)
        if len(window) > len(marker):
            del window[0]
        if bytes(window) == marker:
            return


def decode_sim1(stream, output: Path) -> None:
    wait_for(stream, b"SIM1")
    length = int.from_bytes(read_exact(stream, 4), "little")
    if length != PAYLOAD_BYTES:
        raise RuntimeError(f"Unexpected image length: {length}")
    payload = read_exact(stream, length)
    if read_exact(stream, 4) != b"PASS":
        raise RuntimeError("Missing PASS trailer")
    output.parent.mkdir(parents=True, exist_ok=True)
    Image.frombytes("L", (WIDTH, HEIGHT), payload).save(output)
    print(f"PASS: {len(payload)} UART bytes -> {output.resolve()}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("port", nargs="?", help="Serial port, for example COM5")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--input-file", type=Path,
                        help="Replay a Vivado raw UART frame instead of a COM port")
    parser.add_argument("--payload-file", type=Path,
                        help="Convert the 4096-byte Vivado UART payload capture directly")
    parser.add_argument("--output", type=Path, default=Path("received_image.png"))
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()

    if args.payload_file is not None:
        payload = args.payload_file.read_bytes()
        if len(payload) != PAYLOAD_BYTES:
            raise SystemExit(f"Expected {PAYLOAD_BYTES} payload bytes, got {len(payload)}")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        Image.frombytes("L", (WIDTH, HEIGHT), payload).save(args.output)
        print(f"PASS: {len(payload)} captured UART bytes -> {args.output.resolve()}")
        return

    if args.input_file is not None:
        with args.input_file.open("rb") as stream:
            decode_sim1(stream, args.output)
        return

    if not args.port:
        parser.error("provide a COM port, --input-file, or --payload-file")

    try:
        import serial
    except ImportError as exc:
        raise SystemExit("Install pyserial first: python -m pip install pyserial") from exc

    with serial.Serial(args.port, args.baud, timeout=args.timeout) as port:
        decode_sim1(port, args.output)


if __name__ == "__main__":
    main()
