# Bộ điều khiển DDR3 tự thiết kế

## Phạm vi đã hiện thực

Project có thêm một bộ điều khiển DDR3 phần số do project sở hữu, không gọi
MIG hay một memory-controller IP của hãng:

- AXI4 slave 32-bit, giữ ID và backpressure;
- burst `FIXED`, `INCR`, `WRAP`, tối đa 256 beat;
- access 1, 2 hoặc 4 byte, hỗ trợ `WSTRB`;
- kiểm tra alignment, biên 4 KiB và aperture DDR;
- trả `DECERR`/`SLVERR`, phát hiện `WLAST` sớm hoặc thiếu;
- chuỗi lệnh khởi tạo DDR, yêu cầu calibration PHY;
- open-row tracking cho 8 bank, `ACT/PRE/READ/WRITE`;
- refresh định kỳ và `PRECHARGE ALL` trước refresh;
- biên DFI-lite có ready/valid, phản hồi read và báo lỗi;
- không có phép nhân và script tổng hợp bắt buộc số DSP bằng 0.

Các file chính:

- `src/Memory/axi_ddr3_controller.sv`: AXI4 front-end và hàng đợi timing;
- `src/Memory/ddr3_controller_core.sv`: init, refresh và DDR scheduler;
- `src/Memory/axi_bram_ddr3_subsystem.sv`: decoder BRAM + DDR;
- `testbench/ddr3_dfi_memory_model.sv`: mô hình memory tại biên DFI-lite;
- `testbench/tb_axi_ddr3_controller.sv`: regression tự kiểm tra;
- `scripts/synthesize_ddr3_controller.tcl`: tổng hợp OOC và kiểm tra 0 DSP;
- `scripts/implement_ddr3_controller_ooc.tcl`: place/route OOC và đo Fmax;
- `scripts/package_ddr3_controller_ip.tcl`: đóng gói thành Vivado IP.

## Tích hợp trong SoC

`dma_mmu_picorv32_soc` có parameter `ENABLE_DDR3`:

| `ENABLE_DDR3` | Vùng thấp | `0x8000_0000` – `0xBFFF_FFFF` |
|---|---|---|
| `0` (mặc định) | `axi_ram` hiện hữu | không decode |
| `1` | `axi_ram` boot, kích thước `2**BRAM_ADDR_WIDTH` | custom AXI DDR3 controller |

Nhờ giữ giá trị mặc định bằng 0, firmware và các test cũ vẫn dùng nguyên
`axi_ram`. Khi bật DDR, `picorv32_axil_router` cho phép địa chỉ DDR đi vào AXI
FULL, còn MMIO vẫn được ưu tiên decode như trước.

Biên kết nối hiện tại là:

```text
CPU/MMU + DMA -> AXI crossbar -> BRAM/DDRx decoder
                                  |-- axi_ram (boot)
                                  `-- AXI DDR controller -> DFI-lite -> board PHY
```

## Chạy kiểm thử

Trong Command Prompt ở thư mục project:

```bat
RUN_DDR3_CONTROLLER_TESTS.cmd
```

Regression kiểm tra init/calibration, read/write đơn, burst 16 beat, byte
strobe, narrow access, cả ba loại burst, AXI/DFI backpressure, address lỗi,
alignment, biên 4 KiB, `WLAST`, lỗi backend, row hit, row conflict, refresh và
reset giữa transaction. Sau đó regression tích hợp kiểm tra decoder thực sự
giữ BRAM ở vùng thấp và gửi vùng cao sang DDR. Test chỉ thành công khi có cả:

```text
DDR3 AXI CONTROLLER: checks=278 failures=0
ALL DDR3 AXI CONTROLLER TESTS PASSED
BRAM+DDR SUBSYSTEM: checks=10 failures=0
ALL BRAM+DDR SUBSYSTEM TESTS PASSED
```

Đây là simulation phần số ở biên command; nó không thay thế memory model DDR3
pin-level của Micron và không chứng minh được signal integrity trên bo mạch.

Các log XSim được script lưu lại để có thể kiểm tra/commit lên GitHub:

- `reports/ddr3_controller/xsim_controller_regression.log` — dòng kết thúc
  `checks=278 failures=0`;
- `reports/ddr3_controller/xsim_bram_ddr_integration.log` — dòng kết thúc
  `checks=10 failures=0`;
- `reports/xsim_unified_regression.log` — dòng kết thúc
  `ALL UNIFIED CPU/DMA/IOMMU/AXI TESTS PASSED`.

## Tổng hợp và đóng gói

Tổng hợp phần controller:

```bat
SYNTHESIZE_DDR3_CONTROLLER.cmd
```

Các report nằm trong `reports/ddr3_controller`. Script dừng bằng lỗi nếu tìm
thấy bất kỳ primitive `DSP*` nào. Fmax trong report OOC là ước lượng của part
đã chọn; Fmax cuối cùng của SoC phải lấy từ timing report sau route của toàn
thiết kế, không lấy từ simulation.

Kết quả mới nhất với license được cung cấp, Vivado 2025.1 trên đúng part VC707
`xc7vx485tffg1761-2`, constraint 3 ns:

| Chỉ số sau route OOC | Kết quả |
|---|---:|
| Logic LUT | 589 |
| Flip-flop | 576 |
| BRAM | 0 |
| DSP | **0** |
| Worst setup slack tại constraint 3 ns | +0,204 ns |
| Worst hold slack | +0,134 ns |
| Fmax ước lượng từ critical path | **357,654 MHz** |

Đây là kết quả của controller phần số chạy out-of-context trên Virtex-7, không
phải timing của PHY DDR hay toàn SoC. Router OOC cảnh báo các cổng giao tiếp
không có `HD.PARTPIN_LOCS`, vì vậy Fmax trên là ước lượng block. Regression toàn
SoC hiện hữu cũng kết thúc bằng `ALL UNIFIED CPU/DMA/IOMMU/AXI TESTS PASSED` khi
`ENABLE_DDR3=0`.

Log bằng chứng đầy đủ nằm tại
`reports/ddr3_controller/vivado_vc707_license_implementation.log`; bản tóm tắt
phạm vi đã/chưa chứng minh nằm tại
`reports/ddr3_controller/VC707_VERIFICATION_SUMMARY.md`.

Đóng gói IP:

```bat
PACKAGE_DDR3_CONTROLLER_IP.cmd
```

Kết quả mặc định là `ip_repo/axi_ddr3_controller_1_0/component.xml`. IP này
expose AXI4 ở một phía và DFI-lite ở phía còn lại.

## Giới hạn quan trọng: chưa phải PHY tương đương MIG

Controller phần số trên **chưa thể nối trực tiếp vào các chân DDR3 của VC707**.
MIG gồm hai phần khác nhau: controller và PHY phụ thuộc FPGA/bo mạch. PHY
Virtex-7 thực tế còn cần ít nhất:

- MMCM/PLL, clock DDR và clock chia pha;
- `OSERDESE2`, `ISERDESE2`, `ODELAYE2`, `IDELAYE2`, `IDELAYCTRL`;
- I/O vi sai cho CK/DQS và điều khiển tri-state DQ/DQS;
- write leveling, read-gate training, per-bit deskew và bitslip;
- điều khiển `RESET_N`, `CKE`, `ODT`, DM và burst BL8 x64;
- giá trị mode register/timing theo đúng SODIMM và tần số;
- pinout, I/O bank, DCI/VREF, clock-region placement và XDC của VC707;
- kiểm thử nhiệt độ/điện áp, nhiều lần power-cycle và memory stress trên bo.

DFI-lite hiện dùng một word 32-bit mỗi lệnh để giúp SoC và scheduler được test
độc lập. SODIMM x64 BL8 cần datapath 512-bit tại mỗi burst PHY hoặc một gear-box
tương đương. Vì vậy không được gọi bitstream là “MIG-equivalent” cho tới khi có
PHY x64, pin-level simulation, calibration thành công và stress test trên VC707.

## Trình tự xác minh phần cứng cần làm tiếp

1. Chốt đúng part/board, SODIMM, tần số DDR và pinout.
2. Hiện thực PHY 7-series x64 và CDC giữa clock AXI với clock PHY.
3. Chạy behavioral test hiện tại, rồi simulation với Micron DDR3 model.
4. Chạy post-synthesis và post-route timing simulation khi cần.
5. Nạp bo, chỉ cho phép AXI traffic sau `calib_done`.
6. Chạy walking-1/0, address bus, checkerboard, March C-, random LFSR và DMA
   read/write ở toàn bộ dung lượng.
7. Lặp lại sau warm reset, cold boot, nhiều power-cycle và thời gian dài; ghi
   lỗi theo byte lane/tap để đánh giá margin.

Nếu mục tiêu là bitstream VC707 đáng tin cậy trong thời gian ngắn, dùng MIG chỉ
cho PHY/calibration và giữ custom AXI controller ở trước native interface là
phương án thực tế nhất. Nếu yêu cầu tuyệt đối không dùng MIG, PHY phải là một
hạng mục riêng và chỉ được nghiệm thu bằng phần cứng thật.
