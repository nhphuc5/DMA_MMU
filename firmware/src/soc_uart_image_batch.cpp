/* Multi-image UART <-> DMA/IOMMU <-> DDR3 <-> systolic pipeline.
 *
 * The host uploads up to four grayscale frames without rebuilding the FPGA.
 * Images retain their original dimensions.  The host pads each edge
 * to a multiple of four and converts raster pixels to signed, centered 4x4
 * tiles.  Each real frame exercises all three DMA directions in Burst mode:
 *
 *   UART RX -> S2M -> input slot
 *   input slot -> M2M -> shared work buffer
 *   work buffer -> M2S -> systolic -> S2M -> scratch/output slot
 *   output slot -> M2S -> UART TX
 *
 * Packet protocol (all integers little-endian):
 *   host:   "UPL2", id:u32, orig_w:u16, orig_h:u16,
 *                    pad_w:u16, pad_h:u16, len:u32, crc32:u32
 *   device: repeated "RDY2", id:u32, offset:u32, chunk_len:u32
 *   host:   chunk_len bytes of tiled/centered GRAY8 payload per RDY2
 *   device: "ACK2", id:u32, status:u32
 *   host:   "RUN1", count:u32
 *   device: "OUT2", same geometry, len:u32, crc32:u32,
 *                    len bytes of tiled/centered GRAY8, "PASS"
 *   device: "PRF1", version:u32, dma_clock_hz:u32, mode:u32,
 *                    record_count:u32, then three 12-u32 performance records
 *                    (M2M, S2M, M2S)
 *   device: "DONE", count:u32
 */

#include "soc_map.h"

using u8  = unsigned char;
using s8  = signed char;
using u16 = unsigned short;
using u32 = unsigned int;
using s32 = signed int;

#ifndef SOC_UART_DIVIDER
#define SOC_UART_DIVIDER 4u
#endif

// Select the DMA arbitration mode at firmware-build time.  Keeping this as a
// build option lets the Burst, Cycle-Stealing and Transparent VC707 images use
// exactly the same packet protocol and data-validation code.
#ifndef SOC_DMA_MODE
#define SOC_DMA_MODE 0u
#endif

static_assert(SOC_DMA_MODE <= 2u,
              "SOC_DMA_MODE must be 0=BURST, 1=CYCLE_STEALING or 2=TRANSPARENT");

namespace {

constexpr u32 MAX_FRAMES       = 4u;
constexpr u32 PAGE_BYTES       = 4096u;
constexpr u32 SLOT_BYTES       = 64u * 1024u * 1024u; // 64 MiB/frame
constexpr u32 SLOT_STRIDE      = SLOT_BYTES;
constexpr u32 INPUT_BASE       = 0x80000000u; // external VC707 DDR3
constexpr u32 WORK_BASE        = 0x90000000u; // external VC707 DDR3
constexpr u32 OUTPUT_BASE      = 0xa0000000u; // external VC707 DDR3
constexpr u32 SCRATCH_ADDR     = 0x00034000u;
constexpr u32 IDENTITY_ADDR    = 0x00035000u;

constexpr u32 DMA_TYPE_M2M = 0u;
constexpr u32 DMA_TYPE_S2M = 1u;
constexpr u32 DMA_TYPE_M2S = 2u;
constexpr u32 DMA_MODE_SELECTED = SOC_DMA_MODE;
constexpr u32 DMA_STATUS_DONE  = 1u << 1;
constexpr u32 DMA_STATUS_FAULT = 1u << 2;

struct FrameInfo {
    u32 id;
    u16 orig_w;
    u16 orig_h;
    u16 pad_w;
    u16 pad_h;
    u32 length;
    u32 input_crc;
    // Keep the structure at 32 bytes so frame-slot indexing is a shift on
    // baseline RV32I and never pulls in a software multiply helper.
    u32 reserved[3];
};

FrameInfo frames[MAX_FRAMES];
u32 last_dma_status;

// Accumulated from real hardware counters.  One record is maintained for each
// transfer direction so a single VC707 run reports M2M, S2M and M2S separately.
struct PerfAggregate {
    u32 commands;
    u32 payload_bytes;
    u32 command_cycles;
    u32 src_bytes;
    u32 src_span;
    u32 dst_bytes;
    u32 dst_span;
    u32 axi_r_bytes;
    u32 axi_r_cycles;
    u32 axi_w_bytes;
    u32 axi_w_cycles;
};

PerfAggregate perf[3];

inline volatile u8* bytes_at(u32 address)
{
    return reinterpret_cast<volatile u8*>(address);
}

inline volatile s32* words_at(u32 address)
{
    return reinterpret_cast<volatile s32*>(address);
}

inline u32 input_addr(u32 slot)  { return INPUT_BASE + slot * SLOT_STRIDE; }
inline u32 work_addr(u32 slot)   { return WORK_BASE + slot * SLOT_STRIDE; }
inline u32 output_addr(u32 slot) { return OUTPUT_BASE + slot * SLOT_STRIDE; }

inline u32 minimum_u32(u32 a, u32 b) { return a < b ? a : b; }

inline u32 page_chunk(u32 address, u32 remaining)
{
    return minimum_u32(remaining, PAGE_BYTES - (address & (PAGE_BYTES - 1u)));
}

u32 multiply_u32(u32 a, u32 b)
{
    u32 result = 0u;
    while (b != 0u) {
        if (b & 1u)
            result += a;
        a <<= 1;
        b >>= 1;
    }
    return result;
}

inline void uart_putc(u8 value) { UART_DATA = static_cast<u32>(value); }

void uart_write(const char* text, u32 count)
{
    for (u32 i = 0; i < count; ++i)
        uart_putc(static_cast<u8>(text[i]));
}

void uart_u16(u16 value)
{
    uart_putc(static_cast<u8>(value));
    uart_putc(static_cast<u8>(value >> 8));
}

void uart_u32(u32 value)
{
    uart_putc(static_cast<u8>(value));
    uart_putc(static_cast<u8>(value >> 8));
    uart_putc(static_cast<u8>(value >> 16));
    uart_putc(static_cast<u8>(value >> 24));
}

void wait_uart_drain()
{
    while ((UART_STATUS & 0x9u) != 0x1u) {
    }
}

u8 uart_getc()
{
    while ((UART_STATUS & 0x2u) == 0u) {
    }
    return static_cast<u8>(UART_DATA);
}

u16 uart_get_u16()
{
    u16 value = uart_getc();
    value |= static_cast<u16>(uart_getc()) << 8;
    return value;
}

u32 uart_get_u32()
{
    u32 value = uart_getc();
    value |= static_cast<u32>(uart_getc()) << 8;
    value |= static_cast<u32>(uart_getc()) << 16;
    value |= static_cast<u32>(uart_getc()) << 24;
    return value;
}

constexpr u32 tag4(char a, char b, char c, char d)
{
    return static_cast<u32>(static_cast<u8>(a)) |
           (static_cast<u32>(static_cast<u8>(b)) << 8) |
           (static_cast<u32>(static_cast<u8>(c)) << 16) |
           (static_cast<u32>(static_cast<u8>(d)) << 24);
}

// Recover command framing after reset, USB-UART reconnects, or an isolated
// byte injected between batches.  Reading fixed four-byte words permanently
// loses alignment after one stray byte; a sliding window finds the next real
// protocol marker without changing the packet format.
u32 uart_get_command()
{
    const u32 upload = tag4('U', 'P', 'L', '2');
    const u32 run    = tag4('R', 'U', 'N', '1');
    u32 window = 0u;
    for (;;) {
        window = (window >> 8) | (static_cast<u32>(uart_getc()) << 24);
        if (window == upload || window == run)
            return window;
    }
}

u32 crc32(const volatile u8* data, u32 length)
{
    u32 crc = 0xffffFFFFu;
    for (u32 i = 0; i < length; ++i) {
        crc ^= data[i];
        for (u32 bit = 0; bit < 8u; ++bit)
            crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

void program_cpu_page(u32 index, u32 vpn, u32 flags)
{
    CPU_MMU_PT_INDEX = index;
    CPU_MMU_PT_VPN   = vpn;
    CPU_MMU_PT_PPN   = vpn;
    CPU_MMU_PT_FLAGS = flags;
}

void configure_cpu_base()
{
    const u32 rx = CPU_MMU_PTE_VALID | CPU_MMU_PTE_READ |
                   CPU_MMU_PTE_EXEC;
    const u32 rw = CPU_MMU_PTE_VALID | CPU_MMU_PTE_READ |
                   CPU_MMU_PTE_WRITE;
    program_cpu_page(0u, 0x00u, rx);
    program_cpu_page(1u, 0x01u, rw); // .data/.bss from linker_uart_batch.ld
    program_cpu_page(2u, 0x0fu, rw); // stack
}

void configure_cpu_window(u32 base, u32 pages, bool include_scratch)
{
    const u32 rw = CPU_MMU_PTE_VALID | CPU_MMU_PTE_READ |
                   CPU_MMU_PTE_WRITE;
    configure_cpu_base();
    u32 index = 3u;
    for (u32 page = 0; page < pages; ++page)
        program_cpu_page(index++, (base >> 12) + page, rw);
    if (include_scratch)
        program_cpu_page(index++, SCRATCH_ADDR >> 12, rw);
    for (; index < 16u; ++index)
        program_cpu_page(index, 0u, 0u);
    CPU_MMU_TLB_CTRL = CPU_MMU_TLB_INVALIDATE | CPU_MMU_CLEAR_FAULT;
    CPU_MMU_CONTROL = CPU_MMU_ENABLE;
}

void program_iommu_page(u32 index, u32 vpn, bool read, bool write)
{
    u32 flags = 1u | (read ? 2u : 0u) | (write ? 4u : 0u);
    IOMMU_PT_INDEX = index;
    IOMMU_PT_VPN   = vpn;
    IOMMU_PT_PPN   = vpn;
    IOMMU_PT_FLAGS = flags;
}

void clear_iommu()
{
    for (u32 i = 0; i < 16u; ++i) {
        IOMMU_PT_INDEX = i;
        IOMMU_PT_VPN = 0u;
        IOMMU_PT_PPN = 0u;
        IOMMU_PT_FLAGS = 0u;
    }
}

u32 map_iommu_range(u32 index, u32 address, u32 length,
                    bool read, bool write)
{
    const u32 first = address >> 12;
    const u32 last = (address + length - 1u) >> 12;
    for (u32 vpn = first; vpn <= last; ++vpn)
        program_iommu_page(index++, vpn, read, write);
    return index;
}

void finish_iommu_map(u32 next)
{
    for (u32 i = next; i < 16u; ++i) {
        IOMMU_PT_INDEX = i;
        IOMMU_PT_VPN = 0u;
        IOMMU_PT_PPN = 0u;
        IOMMU_PT_FLAGS = 0u;
    }
    IOMMU_TLB_CTRL = 1u;
}

bool prepare_iommu_transfer(u32 type, u32 source, u32 destination, u32 bytes)
{
    if (bytes == 0u)
        return false;

    clear_iommu();
    u32 next = 0u;
    if (type == DMA_TYPE_M2M) {
        next = map_iommu_range(next, source, bytes, true, false);
        next = map_iommu_range(next, destination, bytes, false, true);
    } else if (type == DMA_TYPE_S2M) {
        next = map_iommu_range(next, destination, bytes, false, true);
    } else if (type == DMA_TYPE_M2S) {
        next = map_iommu_range(next, source, bytes, true, false);
    } else {
        return false;
    }
    if (next > 16u)
        return false;
    finish_iommu_map(next);
    return true;
}

u32 dma_config(u32 type)
{
    return (16u << 8) | (DMA_MODE_SELECTED << 2) | type;
}

bool run_dma(u32 type, u32 source, u32 destination, u32 bytes)
{
    const u32 perf_seq_before = DMA_PERF_SEQ;
    last_dma_status = 0u;
    DMA_CONTROL      = 2u;
    DMA_SRC_VADDR    = source;
    DMA_DST_VADDR    = destination;
    DMA_LENGTH_BYTES = bytes;
    DMA_CONFIG       = dma_config(type);
    DMA_CONTROL      = 1u;
    for (;;) {
        const u32 status = DMA_STATUS;
        if (status & DMA_STATUS_FAULT) {
            last_dma_status = status;
            while (DMA_PERF_SEQ == perf_seq_before) { }
            const u32 meta = DMA_PERF_META;
            if ((meta & DMA_PERF_VALID) && DMA_PERF_TYPE(meta) == type) {
                PerfAggregate& p = perf[type];
                ++p.commands;
                p.payload_bytes += DMA_PERF_LENGTH;
                p.command_cycles += DMA_PERF_TOTAL_CYCLES;
                p.src_bytes += DMA_PERF_SRC_BYTES;
                p.src_span += DMA_PERF_SRC_SPAN;
                p.dst_bytes += DMA_PERF_DST_BYTES;
                p.dst_span += DMA_PERF_DST_SPAN;
                p.axi_r_bytes += DMA_PERF_AXI_R_BYTES;
                p.axi_r_cycles += DMA_PERF_AXI_R_CYCLES;
                p.axi_w_bytes += DMA_PERF_AXI_W_BYTES;
                p.axi_w_cycles += DMA_PERF_AXI_W_CYCLES;
            }
            return false;
        }
        if (status & DMA_STATUS_DONE) {
            last_dma_status = status;
            // Scheduler DONE may precede the final buffered M2S beat.  The
            // hardware performance monitor increments SEQ only after its
            // complete endpoint/AXI snapshot is ready.
            while (DMA_PERF_SEQ == perf_seq_before) { }
            const u32 meta = DMA_PERF_META;
            if ((meta & DMA_PERF_VALID) && DMA_PERF_TYPE(meta) == type) {
                PerfAggregate& p = perf[type];
                ++p.commands;
                p.payload_bytes += DMA_PERF_LENGTH;
                p.command_cycles += DMA_PERF_TOTAL_CYCLES;
                p.src_bytes += DMA_PERF_SRC_BYTES;
                p.src_span += DMA_PERF_SRC_SPAN;
                p.dst_bytes += DMA_PERF_DST_BYTES;
                p.dst_span += DMA_PERF_DST_SPAN;
                p.axi_r_bytes += DMA_PERF_AXI_R_BYTES;
                p.axi_r_cycles += DMA_PERF_AXI_R_CYCLES;
                p.axi_w_bytes += DMA_PERF_AXI_W_BYTES;
                p.axi_w_cycles += DMA_PERF_AXI_W_CYCLES;
            }
            return true;
        }
    }
}

void clear_perf()
{
    for (u32 type = 0u; type < 3u; ++type) {
        u32* value = reinterpret_cast<u32*>(&perf[type]);
        for (u32 i = 0u; i < sizeof(PerfAggregate) / sizeof(u32); ++i)
            value[i] = 0u;
    }
}

void send_perf_report()
{
    wait_uart_drain();
    uart_write("PRF1", 4u);
    uart_u32(1u);          // protocol version
    uart_u32(150000000u);  // measured counters use the 150 MHz SoC clock
    uart_u32(DMA_MODE_SELECTED);
    uart_u32(3u);
    for (u32 type = 0u; type < 3u; ++type) {
        const PerfAggregate& p = perf[type];
        uart_u32(type);
        uart_u32(p.commands);
        uart_u32(p.payload_bytes);
        uart_u32(p.command_cycles);
        uart_u32(p.src_bytes);
        uart_u32(p.src_span);
        uart_u32(p.dst_bytes);
        uart_u32(p.dst_span);
        uart_u32(p.axi_r_bytes);
        uart_u32(p.axi_r_cycles);
        uart_u32(p.axi_w_bytes);
        uart_u32(p.axi_w_cycles);
    }
    wait_uart_drain();
}

void send_status(const char* tag, u32 id, u32 status)
{
    wait_uart_drain();
    uart_write(tag, 4u);
    uart_u32(id);
    uart_u32(status);
    wait_uart_drain();
}

bool receive_frame(u32 slot)
{
    FrameInfo& frame = frames[slot];
    frame.id        = uart_get_u32();
    frame.orig_w    = uart_get_u16();
    frame.orig_h    = uart_get_u16();
    frame.pad_w     = uart_get_u16();
    frame.pad_h     = uart_get_u16();
    frame.length    = uart_get_u32();
    frame.input_crc = uart_get_u32();

    const bool geometry_ok = frame.orig_w != 0u && frame.orig_h != 0u &&
        frame.orig_w <= frame.pad_w && frame.orig_h <= frame.pad_h &&
        (frame.pad_w & 3u) == 0u && (frame.pad_h & 3u) == 0u &&
        frame.length == multiply_u32(frame.pad_w, frame.pad_h) &&
        frame.length != 0u && frame.length <= SLOT_BYTES &&
        (frame.length & 3u) == 0u;
    if (!geometry_ok) {
        send_status("NAK2", frame.id, 1u);
        return false;
    }

    // Transfer one page-bounded chunk at a time.  RDY2 is both flow control
    // for the small UART FIFO and the guarantee that every IOMMU request
    // remains within one 4 KiB page.
    u32 offset = 0u;
    while (offset < frame.length) {
        const u32 destination = input_addr(slot) + offset;
        const u32 chunk = page_chunk(destination, frame.length - offset);
        if (!prepare_iommu_transfer(DMA_TYPE_S2M, 0u, destination, chunk)) {
            send_status("NAK2", frame.id, 2u);
            return false;
        }

        wait_uart_drain();
        uart_write("RDY2", 4u);
        uart_u32(frame.id);
        uart_u32(offset);
        uart_u32(chunk);
        wait_uart_drain();
        UART_CONTROL = 3u;
        const bool dma_ok = run_dma(DMA_TYPE_S2M, 0u, destination, chunk);
        UART_CONTROL = 1u;
        if (!dma_ok) {
            send_status("NAK2", frame.id, last_dma_status);
            return false;
        }
        offset += chunk;
    }

    if (crc32(bytes_at(input_addr(slot)), frame.length) != frame.input_crc) {
        send_status("NAK2", frame.id, 3u);
        return false;
    }
    send_status("ACK2", frame.id, 0u);
    return true;
}

// Process one page-sized block using the systolic accelerator's batch-image
// datapath.  The accelerator generates the identity matrix internally and
// packs/clamps all 4x4 results, so firmware no longer launches three DMA
// commands and executes sixteen scalar clamp operations for every tile.
bool process_page(u32 source, u32 output, u32 length)
{
    if (length == 0u || length > PAGE_BYTES || (length & 15u) != 0u)
        return false;

    if (!prepare_iommu_transfer(DMA_TYPE_M2S, source, 0u, length))
        return false;

    SYSTOLIC_STREAM_CTRL = SYSTOLIC_STREAM_SELECT |
                           SYSTOLIC_STREAM_RESET_INPUT |
                           SYSTOLIC_STREAM_CLEAR_ERROR |
                           SYSTOLIC_STREAM_BATCH_IMAGE;
    if (!run_dma(DMA_TYPE_M2S, source, 0u, length))
        return false;

    if (!prepare_iommu_transfer(DMA_TYPE_S2M, 0u, output, length))
        return false;
    if (!run_dma(DMA_TYPE_S2M, 0u, output, length))
        return false;
    return (SYSTOLIC_STREAM_STATUS & SYSTOLIC_STREAM_ERROR) == 0u;
}

bool process_and_send(u32 slot)
{
    const FrameInfo& frame = frames[slot];
    const u32 input = input_addr(slot);
    const u32 work = work_addr(slot);
    const u32 output = output_addr(slot);

    // Copy input to the frame's DDR3 work slot using page-bounded M2M
    // commands.  This supports images much larger than the 16-entry IOMMU PT.
    SYSTOLIC_STREAM_CTRL = 0u;
    u32 offset = 0u;
    while (offset < frame.length) {
        u32 chunk = page_chunk(input + offset, frame.length - offset);
        chunk = minimum_u32(chunk,
                            page_chunk(work + offset, frame.length - offset));
        if (!prepare_iommu_transfer(DMA_TYPE_M2M, input + offset,
                                    work + offset, chunk) ||
            !run_dma(DMA_TYPE_M2M, input + offset, work + offset, chunk))
            return false;
        offset += chunk;
    }

    // Process complete page-bounded groups of 4x4 tiles.  This retains tile
    // order while reducing the systolic DMA-command count by roughly 256x.
    offset = 0u;
    while (offset < frame.length) {
        u32 chunk = page_chunk(work + offset, frame.length - offset);
        chunk = minimum_u32(chunk,
                            page_chunk(output + offset, frame.length - offset));
        // Host padding guarantees 4x4 tiles (16 bytes), and page-aligned frame
        // slots keep all intermediate chunks tile aligned.
        if (!process_page(work + offset, output + offset, chunk))
            return false;
        offset += chunk;
    }

    const u32 output_crc = crc32(bytes_at(output), frame.length);
    SYSTOLIC_STREAM_CTRL = 0u;
    UART_CONTROL = 1u;
    wait_uart_drain();
    uart_write("OUT2", 4u);
    uart_u32(frame.id);
    uart_u16(frame.orig_w);
    uart_u16(frame.orig_h);
    uart_u16(frame.pad_w);
    uart_u16(frame.pad_h);
    uart_u32(frame.length);
    uart_u32(output_crc);
    wait_uart_drain();

    offset = 0u;
    while (offset < frame.length) {
        const u32 source = output + offset;
        const u32 chunk = page_chunk(source, frame.length - offset);
        if (!prepare_iommu_transfer(DMA_TYPE_M2S, source, 0u, chunk) ||
            !run_dma(DMA_TYPE_M2S, source, 0u, chunk))
            return false;
        offset += chunk;
    }
    wait_uart_drain();
    uart_write("PASS", 4u);
    wait_uart_drain();
    return true;
}

[[noreturn]] void batch_main()
{
    UART_DIVIDER = SOC_UART_DIVIDER;
    UART_CONTROL = 1u; // CPU reads headers; DMA RX is enabled only for payload.
    DMA_ACCESS_CTRL = 0u;

    // Never issue the first high-address AXI transaction until the real MIG
    // PHY has completed power-up calibration. The behavioral integration
    // test drives the same status bits, so this guard is covered in XSim.
    for (;;) {
        const u32 status = DDR_STATUS;
        if ((status & DDR_STATUS_CALIB_ERROR) != 0u) {
            uart_write("DERR", 4u);
            wait_uart_drain();
            for (;;) {
            }
        }
        if ((status & (DDR_STATUS_EXTERNAL_MIG | DDR_STATUS_CALIB_DONE))
            == (DDR_STATUS_EXTERNAL_MIG | DDR_STATUS_CALIB_DONE))
            break;
    }

    // Initialize identity B before enabling CPU-side MMU translation.
    volatile u8* identity = bytes_at(IDENTITY_ADDR);
    for (u32 i = 0; i < 16u; ++i)
        identity[i] = 0u;
    identity[0] = 1u;
    identity[5] = 1u;
    identity[10] = 1u;
    identity[15] = 1u;
    // High DDR addresses bypass the CPU-side MMU.  Only the low-BRAM
    // scratch page must be mapped here; the identity matrix is consumed by
    // DMA after initialization and does not need a second CPU mapping.
    configure_cpu_window(SCRATCH_ADDR, 1u, false);
    CPU_MMU_TLB_CTRL = CPU_MMU_TLB_INVALIDATE | CPU_MMU_CLEAR_STATS;

    for (;;) {
        clear_perf();
        uart_write("BCH1", 4u);
        uart_u32(MAX_FRAMES);
        wait_uart_drain();

        u32 loaded = 0u;
        while (loaded < MAX_FRAMES) {
            const u32 command = uart_get_command();
            if (command == tag4('U', 'P', 'L', '2')) {
                if (receive_frame(loaded))
                    ++loaded;
            } else if (command == tag4('R', 'U', 'N', '1')) {
                const u32 requested = uart_get_u32();
                if (loaded != 0u && requested == loaded)
                    break;
                send_status("NAK2", 0u, 4u);
            }
        }

        for (u32 slot = 0; slot < loaded; ++slot) {
            if (!process_and_send(slot)) {
                send_status("FAIL", frames[slot].id, 5u);
                break;
            }
        }
        send_perf_report();
        uart_write("DONE", 4u);
        uart_u32(loaded);
        wait_uart_drain();
    }
}

} // namespace

extern "C" [[noreturn, gnu::naked, gnu::section(".text.start")]] void _start()
{
    __asm__ volatile (
        "li sp, 0x10000\n"
        "j uart_image_batch_entry\n"
    );
}

extern "C" [[noreturn]] void uart_image_batch_entry()
{
    batch_main();
}
