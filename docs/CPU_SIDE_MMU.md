# CPU-side MMU cho PicoRV32

## 1. Mục đích

`picorv32_cpu_mmu` là MMU đặt trên đường truy cập bộ nhớ của **CPU**. Khối này
nhận địa chỉ ảo (VA) do PicoRV32 phát ra, tra bảng trang/TLB, kiểm tra quyền rồi
phát địa chỉ vật lý (PA) về phía RAM. Nó không thay thế `dma_iommu_tlb`: hai khối
bảo vệ hai master khác nhau.

| Khối | Master được bảo vệ | Đầu vào | Đầu ra |
|---|---|---|---|
| CPU MMU (`picorv32_cpu_mmu`) | PicoRV32 | VA của lệnh hoặc dữ liệu CPU | PA hoặc CPU-MMU fault |
| DMA IOMMU (`dma_iommu_tlb`) | DMA | IOVA nguồn/đích của descriptor | PA hoặc DMA-IOMMU fault |

Đường truy cập RAM của CPU sau khi tích hợp:

```text
PicoRV32 (VA, R/W/X)
        -> CPU MMU: TLB/PT + permission check
        -> địa chỉ vật lý
        -> AXI-Lite address router
        -> CPU RAM adapter
        -> System AXI4-Full crossbar
        -> AXI RAM
```

Các cửa sổ MMIO `0x1000_0000` (DMA/IOMMU) và `0x2000_0000` (UART) là địa chỉ
vật lý, vì vậy được bypass dịch địa chỉ. Cửa sổ `0x3000_0000` được CPU MMU xử
lý nội bộ để firmware cấu hình chính MMU.

## 2. Kiến trúc được chọn

Thiết kế tham khảo cách CVA6 tách TLB, page-table translation, permission check
và fault reporting, nhưng không chép nguyên `cva6_mmu`. CVA6 cần `satp`, các CSR
đặc quyền, cache và pipeline exception mà PicoRV32 hiện không có. Phiên bản phù
hợp với SoC này gồm:

- Trang 4 KiB.
- Page table do phần mềm quản lý, 16 entry, tra cứu fully associative.
- TLB 4 entry, fully associative.
- Khi TLB miss: tra page table, nạp TLB rồi tiếp tục giao dịch.
- Chọn entry TLB invalid trước; nếu đầy thì thay thế pseudo-LRU.
- Quyền độc lập `Read`, `Write`, `Execute`.
- Invalidate toàn bộ TLB, bộ đếm hit/miss và fault sticky.
- Hai FSM đọc/ghi pipeline riêng các kết quả TLB và page table trước khi tạo PA,
  nhờ đó đường so sánh fully-associative không nối tổ hợp thẳng tới AXI.

Đây là **MMU phần cứng gọn cho bare-metal PicoRV32**, chưa phải triển khai Sv32
đầy đủ của đặc tả RISC-V: chưa có hardware page-table walker trong RAM, ASID,
supervisor mode hoặc precise/restartable page-fault exception. Truy cập sai bị
chặn, trả AXI error, lưu VA/mã lỗi và phát IRQ; firmware đọc trạng thái để xử lý.

## 3. Định dạng page-table entry

Firmware chọn một trong 16 entry rồi ghi:

| Trường | Ý nghĩa |
|---|---|
| VPN | Số trang ảo, `VA[31:12]` |
| PPN | Số trang vật lý, `PA[31:12]` |
| V | Entry hợp lệ |
| R | Cho phép CPU đọc dữ liệu |
| W | Cho phép CPU ghi dữ liệu |
| X | Cho phép CPU lấy lệnh |

Địa chỉ vật lý được tạo theo công thức:

```text
PA = {PPN, VA[11:0]}
```

## 4. Bản đồ thanh ghi CPU MMU

Base address: `0x3000_0000`.

| Offset | Thanh ghi | Chức năng |
|---:|---|---|
| `0x00` | `PT_INDEX` | Chọn entry page table 0..15 |
| `0x04` | `PT_VPN` | VPN đang chuẩn bị |
| `0x08` | `PT_PPN` | PPN đang chuẩn bị |
| `0x0C` | `PT_FLAGS` | Ghi V/R/W/X và commit entry; đồng thời invalidate TLB |
| `0x10` | `TLB_CTRL` | Invalidate TLB, xóa thống kê hoặc xóa fault |
| `0x14` | `CONTROL` | Bit 0 bật/tắt dịch địa chỉ CPU |
| `0x18` | `STATUS` | Enable, fault pending và fault code |
| `0x1C` | `FAULT_VA` | VA gây fault gần nhất |
| `0x20` | `TLB_HITS` | Số lần TLB hit |
| `0x24` | `TLB_MISSES` | Số lần TLB miss |
| `0x28` | `CONFIG` | Số PT/TLB entry và page shift |

Mã lỗi: `1=page not mapped`, `2=read`, `3=write`, `4=execute`.

## 5. Trình tự khởi động

1. CPU chạy ở chế độ bypass sau reset.
2. Firmware ghi các entry identity-map cần để tiếp tục chạy code, stack và vùng
   dữ liệu; có thể tạo thêm ánh xạ VA khác PA.
3. Firmware invalidate TLB rồi bật `CONTROL.enable`.
4. Mọi lần lấy lệnh/đọc/ghi RAM tiếp theo đi qua CPU MMU.
5. MMIO DMA/UART vẫn truy cập bằng địa chỉ vật lý và không cần entry page table.
6. Khi fault, phần cứng không phát giao dịch RAM, giữ thông tin lỗi và bật IRQ 6.

## 6. Bằng chứng mô phỏng

Firmware lập ánh xạ `VA 0x00008000 -> PA 0x00003000`, ghi và đọc lại
`0xC0DEC0DE` qua VA. Testbench không chỉ đọc tín hiệu trả về mà kiểm tra trực
tiếp word trong AXI RAM tại PA `0x3000`. Kết quả nằm trong
`reports/picorv32_soc_test.log`:

```text
PASS CPU MMU: VA 0x00008000 -> PA 0x00003000,
RAM=0xc0dec0de, TLB hits=14 misses=2
```

Sau bước này, toàn bộ D01-D09, descriptor queue 8 entry và DMA access-control
vẫn được chạy, vì vậy việc thêm CPU MMU không bỏ hoặc giả lập các chức năng DMA
cũ.

Testbench chuyên biệt `testbench/tb_picorv32_cpu_mmu.sv` còn kiểm tra bypass
khi MMU tắt, TLB hit/miss, quyền execute, page fault, trang chỉ đọc, sticky
fault/IRQ và cửa sổ MMIO bypass. Kết quả nằm trong
`reports/cpu_mmu_test.log` và kết thúc bằng `ALL CPU MMU TESTS PASSED`.

## 7. Kết quả implementation

Trên Artix-7 `xc7a35tcpg236-1`, toàn bộ SoC sau khi thêm CPU MMU đạt ràng buộc
clock `6.667 ns` (149.993 MHz): post-route WNS `+0.052 ns`, Fmax ước lượng
`151.172 MHz`. Tài nguyên toàn SoC là 6,303 Slice LUT, 6,020 Slice Register,
16 BRAM tile và 0 DSP.
