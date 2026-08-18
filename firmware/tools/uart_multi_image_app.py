#!/usr/bin/env python3
"""Upload full-size images to VC707 DDR3 and receive processed frames.

Images are not resized.  They are converted to GRAY8, padded only to a 4-pixel
boundary, tiled for the 4x4 systolic array, and transferred in page-bounded
chunks.  The returned tile stream is converted back to raster order before
the original image dimensions are restored.
"""

from __future__ import annotations

import argparse
import struct
import time
import zlib
from pathlib import Path

MAX_FRAMES = 4
MAX_FRAME_BYTES = 64 * 1024 * 1024
HEADER = struct.Struct("<4sIHHHHII")
STATUS = struct.Struct("<4sII")
READY_CHUNK = struct.Struct("<4sIII")
PERF_HEADER = struct.Struct("<4sIIII")
PERF_RECORD = struct.Struct("<12I")
TYPE_NAMES = ("M2M", "S2M", "M2S")


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


def pad_and_tile(path: Path) -> tuple[int, int, int, int, bytes, Image.Image]:
    with Image.open(path) as source:
        gray = source.convert("L")
    orig_w, orig_h = gray.size
    if orig_w == 0 or orig_h == 0:
        raise ValueError(f"Empty image: {path}")
    if orig_w > 65532 or orig_h > 65532:
        raise ValueError(
            f"{path.name}: {orig_w}x{orig_h} exceeds the 16-bit protocol "
            "geometry limit"
        )

    pad_w = (orig_w + 3) & ~3
    pad_h = (orig_h + 3) & ~3
    if pad_w * pad_h > MAX_FRAME_BYTES:
        raise ValueError(
            f"{path.name}: padded frame requires {pad_w * pad_h} bytes; "
            f"the DDR3 slot limit is {MAX_FRAME_BYTES} bytes"
        )
    padded = Image.new("L", (pad_w, pad_h), color=128)
    padded.paste(gray, (0, 0))
    raster = padded.tobytes()

    tiled = bytearray()
    for tile_y in range(0, pad_h, 4):
        for tile_x in range(0, pad_w, 4):
            for row in range(4):
                start = (tile_y + row) * pad_w + tile_x
                for pixel in raster[start : start + 4]:
                    tiled.append((pixel - 128) & 0xFF)
    return orig_w, orig_h, pad_w, pad_h, bytes(tiled), gray


def untile(payload: bytes, pad_w: int, pad_h: int) -> bytes:
    """Convert contiguous 4x4 tiles back to row-major grayscale pixels."""
    if len(payload) != pad_w * pad_h:
        raise ValueError("Tile payload length does not match padded geometry")
    raster = bytearray(len(payload))
    source = 0
    for tile_y in range(0, pad_h, 4):
        for tile_x in range(0, pad_w, 4):
            for row in range(4):
                destination = (tile_y + row) * pad_w + tile_x
                raster[destination : destination + 4] = payload[source : source + 4]
                source += 4
    return bytes(raster)


def write_hex(path: Path, payload: bytes) -> None:
    path.write_text("".join(f"{value:02X}\n" for value in payload),
                    encoding="ascii")


def save_input_reference(directory: Path, frame_id: int, source: Path,
                         gray: Image.Image, tiled: bytes) -> None:
    stem = f"frame_{frame_id:04d}_input"
    gray.save(directory / f"{stem}.png")
    tiled_path = directory / f"{stem}_tiled.bin"
    tiled_path.write_bytes(tiled)
    write_hex(directory / f"{stem}_tiled.hex", tiled)
    (directory / f"{stem}.txt").write_text(
        f"source={source.resolve()}\nwidth={gray.width}\nheight={gray.height}\n",
        encoding="utf-8",
    )


def upload_one(port, frame_id: int, path: Path,
               output_dir: Path) -> tuple[int, int]:
    orig_w, orig_h, pad_w, pad_h, payload, gray = pad_and_tile(path)
    crc = zlib.crc32(payload) & 0xFFFFFFFF
    header = HEADER.pack(
        b"UPL2", frame_id, orig_w, orig_h, pad_w, pad_h, len(payload), crc
    )
    start_ns = time.perf_counter_ns()
    port.write(header)
    port.flush()

    offset = 0
    while offset < len(payload):
        ready = read_exact(port, READY_CHUNK.size)
        marker, ready_id, ready_offset, chunk_length = READY_CHUNK.unpack(ready)
        if (marker != b"RDY2" or ready_id != frame_id or
                ready_offset != offset or chunk_length == 0 or
                offset + chunk_length > len(payload)):
            raise RuntimeError(f"Unexpected upload-ready response: {ready!r}")
        port.write(payload[offset : offset + chunk_length])
        port.flush()
        offset += chunk_length
    marker, ack_id, status = STATUS.unpack(read_exact(port, STATUS.size))
    if marker != b"ACK2" or ack_id != frame_id or status != 0:
        raise RuntimeError(
            f"Upload rejected: marker={marker!r} id={ack_id} status={status}"
        )
    save_input_reference(output_dir, frame_id, path, gray, payload)
    print(
        f"UPLOAD PASS frame={frame_id} source={path.name} "
        f"original={orig_w}x{orig_h} padded={pad_w}x{pad_h} "
        f"bytes={len(payload)} crc=0x{crc:08X}"
    )
    return len(payload), time.perf_counter_ns() - start_ns


def receive_one(port, output_dir: Path) -> tuple[int, int, int]:
    start_ns = time.perf_counter_ns()
    wait_for(port, b"OUT2")
    rest = read_exact(port, HEADER.size - 4)
    marker, frame_id, orig_w, orig_h, pad_w, pad_h, length, expected_crc = (
        HEADER.unpack(b"OUT2" + rest)
    )
    if marker != b"OUT2" or length != pad_w * pad_h:
        raise RuntimeError("Invalid output frame header")
    payload = read_exact(port, length)
    actual_crc = zlib.crc32(payload) & 0xFFFFFFFF
    if actual_crc != expected_crc:
        raise RuntimeError(
            f"Frame {frame_id} CRC mismatch: expected 0x{expected_crc:08X}, "
            f"got 0x{actual_crc:08X}"
        )
    if read_exact(port, 4) != b"PASS":
        raise RuntimeError(f"Frame {frame_id}: missing PASS trailer")

    stem = f"frame_{frame_id:04d}_output"
    (output_dir / f"{stem}.bin").write_bytes(payload)
    write_hex(output_dir / f"{stem}.hex", payload)
    raster = untile(payload, pad_w, pad_h)
    padded = Image.frombytes("L", (pad_w, pad_h), raster)
    result = padded.crop((0, 0, orig_w, orig_h))
    result.save(output_dir / f"{stem}.png")
    (output_dir / f"{stem}.txt").write_text(
        f"frame_id={frame_id}\noriginal={orig_w}x{orig_h}\n"
        f"padded={pad_w}x{pad_h}\nbytes={length}\ncrc32=0x{actual_crc:08X}\n",
        encoding="utf-8",
    )
    print(
        f"OUTPUT PASS frame={frame_id} size={orig_w}x{orig_h} "
        f"bytes={length} crc=0x{actual_crc:08X} -> {output_dir.resolve()}"
    )
    return frame_id, length, time.perf_counter_ns() - start_ns


def receive_perf_report(port) -> tuple[int, int, list[dict[str, int]]]:
    raw_header = read_exact(port, PERF_HEADER.size)
    marker, version, clock_hz, mode, count = PERF_HEADER.unpack(raw_header)
    if marker != b"PRF1" or version != 1 or count != 3:
        raise RuntimeError(
            f"Invalid performance report: marker={marker!r} version={version} "
            f"count={count}"
        )
    records = []
    keys = (
        "type", "commands", "payload_bytes", "command_cycles",
        "src_bytes", "src_span", "dst_bytes", "dst_span",
        "axi_r_bytes", "axi_r_cycles", "axi_w_bytes", "axi_w_cycles",
    )
    for expected_type in range(count):
        record = dict(zip(keys, PERF_RECORD.unpack(read_exact(port, PERF_RECORD.size))))
        if record["type"] != expected_type:
            raise RuntimeError(
                f"Performance record order mismatch: expected {expected_type}, "
                f"got {record['type']}"
            )
        records.append(record)
    return clock_hz, mode, records


def add_perf(total: list[dict[str, int]], records: list[dict[str, int]]) -> None:
    for dst, src in zip(total, records):
        for key, value in src.items():
            if key != "type":
                dst[key] += value


def mbps(byte_count: int, cycles: int, clock_hz: int) -> float:
    if cycles == 0:
        return 0.0
    return byte_count * clock_hz / cycles / 1_000_000.0


def host_mbps(byte_count: int, elapsed_ns: int) -> float:
    if elapsed_ns == 0:
        return 0.0
    return byte_count * 1_000.0 / elapsed_ns


def write_performance_logs(output_dir: Path, scenario: str, clock_hz: int,
                           records: list[dict[str, int]],
                           host_stats: dict[str, int]) -> None:
    formula = "speed_MB_s = bytes * clock_hz / cycles / 1e6"
    dma_lines = [
        "VC707 DMA ENDPOINT THROUGHPUT (MEASURED HARDWARE COUNTERS)",
        f"scenario={scenario}", f"dma_clock_hz={clock_hz}", formula,
        "type commands bytes cycles speed_MB_s endpoint",
    ]
    for name, record in zip(TYPE_NAMES, records):
        dma_lines.append(
            f"{name} {record['commands']} {record['src_bytes']} "
            f"{record['src_span']} "
            f"{mbps(record['src_bytes'], record['src_span'], clock_hz):.3f} SOURCE"
        )
        dma_lines.append(
            f"{name} {record['commands']} {record['dst_bytes']} "
            f"{record['dst_span']} "
            f"{mbps(record['dst_bytes'], record['dst_span'], clock_hz):.3f} DESTINATION"
        )
    (output_dir / f"dma_only_{scenario}.log").write_text(
        "\n".join(dma_lines) + "\n", encoding="utf-8"
    )

    axi_lines = [
        "VC707 DMA OVER AXI4-FULL THROUGHPUT (MEASURED HANDSHAKES)",
        f"scenario={scenario}", f"dma_clock_hz={clock_hz}", formula,
        "Read cycles span first AR handshake through last R handshake.",
        "Write cycles span first AW handshake through B response handshake.",
        "type commands bytes cycles speed_MB_s channel",
    ]
    for name, record in zip(TYPE_NAMES, records):
        axi_lines.append(
            f"{name} {record['commands']} {record['axi_r_bytes']} "
            f"{record['axi_r_cycles']} "
            f"{mbps(record['axi_r_bytes'], record['axi_r_cycles'], clock_hz):.3f} READ"
        )
        axi_lines.append(
            f"{name} {record['commands']} {record['axi_w_bytes']} "
            f"{record['axi_w_cycles']} "
            f"{mbps(record['axi_w_bytes'], record['axi_w_cycles'], clock_hz):.3f} WRITE"
        )
    (output_dir / f"dma_axi_bus_{scenario}.log").write_text(
        "\n".join(axi_lines) + "\n", encoding="utf-8"
    )

    system_lines = [
        "VC707 WHOLE-SYSTEM THROUGHPUT (REAL BOARD RUN)",
        f"scenario={scenario}", f"dma_clock_hz={clock_hz}",
        "DMA command rows include scheduler, IOMMU and AXI protocol latency.",
        "Hardware formula: speed_MB_s = payload_bytes * clock_hz / command_cycles / 1e6",
        "Host formula: speed_MB_s = payload_bytes / elapsed_seconds / 1e6",
        "type commands payload_bytes command_cycles hardware_MB_s",
    ]
    for name, record in zip(TYPE_NAMES, records):
        system_lines.append(
            f"{name} {record['commands']} {record['payload_bytes']} "
            f"{record['command_cycles']} "
            f"{mbps(record['payload_bytes'], record['command_cycles'], clock_hz):.3f}"
        )
    system_lines.extend([
        "",
        "PC-to-kit UART end-to-end measurements:",
        f"S2M_UPLOAD bytes={host_stats['upload_bytes']} "
        f"elapsed_ms={host_stats['upload_ns'] / 1_000_000.0:.3f} "
        f"speed_MB_s={host_mbps(host_stats['upload_bytes'], host_stats['upload_ns']):.6f}",
        f"M2S_DOWNLOAD bytes={host_stats['download_bytes']} "
        f"elapsed_ms={host_stats['download_ns'] / 1_000_000.0:.3f} "
        f"speed_MB_s={host_mbps(host_stats['download_bytes'], host_stats['download_ns']):.6f}",
        f"BATCH_TOTAL payload_bytes={host_stats['upload_bytes'] + host_stats['download_bytes']} "
        f"elapsed_ms={host_stats['batch_ns'] / 1_000_000.0:.3f} "
        f"speed_MB_s={host_mbps(host_stats['upload_bytes'] + host_stats['download_bytes'], host_stats['batch_ns']):.6f}",
    ])
    (output_dir / f"system_kit_{scenario}.log").write_text(
        "\n".join(system_lines) + "\n", encoding="utf-8"
    )


def image_files(directory: Path) -> list[Path]:
    extensions = {".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff"}
    files = sorted(
        path for path in directory.iterdir()
        if path.is_file() and path.suffix.lower() in extensions
    )
    if not files:
        raise SystemExit(f"No supported images found in {directory.resolve()}")
    return files


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("port", help="Serial port, for example COM5")
    parser.add_argument(
        "--input-dir", type=Path,
        default=Path("firmware/images/uart_batch_input"),
    )
    parser.add_argument(
        "--output-dir", type=Path,
        default=Path("reports/uart_batch_output"),
    )
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument(
        "--scenario", choices=("burst", "cycle-stealing", "transparent"),
        default="burst", help="DMA mode implemented by the loaded bitstream",
    )
    args = parser.parse_args()

    global Image
    try:
        from PIL import Image
    except ImportError as exc:
        raise SystemExit("Install Pillow: python -m pip install pillow") from exc

    try:
        import serial
    except ImportError as exc:
        raise SystemExit("Install pyserial: python -m pip install pyserial") from exc

    files = image_files(args.input_dir)
    # Validate every source before opening COM and consuming BCH1.  A bad
    # image must not leave the FPGA waiting halfway through a batch.
    for path in files:
        pad_and_tile(path)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    output_dir = args.output_dir / timestamp
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "scenario.txt").write_text(
        f"dma_mode={args.scenario}\nbitstream_mode_must_match=true\n"
        f"baud={args.baud}\ntimeout_seconds={args.timeout}\n",
        encoding="utf-8",
    )
    print(f"DMA TEST SCENARIO: {args.scenario.upper()}")

    perf_total = [
        {"type": transfer_type, "commands": 0, "payload_bytes": 0,
         "command_cycles": 0, "src_bytes": 0, "src_span": 0,
         "dst_bytes": 0, "dst_span": 0, "axi_r_bytes": 0,
         "axi_r_cycles": 0, "axi_w_bytes": 0, "axi_w_cycles": 0}
        for transfer_type in range(3)
    ]
    host_stats = {"upload_bytes": 0, "upload_ns": 0,
                  "download_bytes": 0, "download_ns": 0,
                  "batch_ns": 0}
    reported_clock_hz = 0

    with serial.Serial(args.port, args.baud, timeout=args.timeout) as port:
        port.reset_input_buffer()
        total_completed = 0
        next_file = 0
        batch_number = 0
        while next_file < len(files):
            batch_number += 1
            print(
                f"Waiting for BCH1 (batch {batch_number}). Program the FPGA "
                "or press/release CPU_RESET if this is the first batch."
            )
            wait_for(port, b"BCH1")
            capacity = int.from_bytes(read_exact(port, 4), "little")
            if capacity == 0 or capacity > MAX_FRAMES:
                raise RuntimeError(f"Invalid FPGA batch capacity={capacity}")
            batch = files[next_file : next_file + capacity]
            batch_start_ns = time.perf_counter_ns()
            print(
                f"FPGA ready: resident capacity={capacity}; sending "
                f"batch {batch_number} with {len(batch)} image(s)"
            )

            for local_index, path in enumerate(batch):
                frame_id = next_file + local_index + 1
                byte_count, elapsed_ns = upload_one(
                    port, frame_id, path, output_dir
                )
                host_stats["upload_bytes"] += byte_count
                host_stats["upload_ns"] += elapsed_ns

            port.write(struct.pack("<4sI", b"RUN1", len(batch)))
            port.flush()
            received_records = [receive_one(port, output_dir) for _ in batch]
            for _, byte_count, elapsed_ns in received_records:
                host_stats["download_bytes"] += byte_count
                host_stats["download_ns"] += elapsed_ns
            clock_hz, reported_mode, records = receive_perf_report(port)
            expected_mode = ("burst", "cycle-stealing", "transparent").index(
                args.scenario
            )
            if reported_mode != expected_mode:
                raise RuntimeError(
                    f"Loaded bitstream mode={reported_mode}, but "
                    f"--scenario expects {expected_mode}"
                )
            if reported_clock_hz not in (0, clock_hz):
                raise RuntimeError("Performance clock changed between batches")
            reported_clock_hz = clock_hz
            add_perf(perf_total, records)
            if read_exact(port, 4) != b"DONE":
                raise RuntimeError("Missing DONE after performance report")
            completed = int.from_bytes(read_exact(port, 4), "little")
            received = [frame_id for frame_id, _, _ in received_records]
            if completed != len(batch) or len(received) != len(batch):
                raise RuntimeError(
                    f"Incomplete batch {batch_number}: completed={completed}, "
                    f"received={received}"
                )
            next_file += len(batch)
            total_completed += completed
            host_stats["batch_ns"] += time.perf_counter_ns() - batch_start_ns
            print(f"BATCH {batch_number} PASS: {completed} image(s)")
    write_performance_logs(
        output_dir, args.scenario, reported_clock_hz, perf_total, host_stats
    )
    print(
        f"ALL BATCHES PASS: {total_completed} images; BIN/HEX/PNG saved in "
        f"{output_dir}"
    )


if __name__ == "__main__":
    main()
