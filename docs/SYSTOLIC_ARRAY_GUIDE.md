# Bộ tăng tốc systolic 4x4 trong SoC PicoRV32

## Mục đích

Khối mới thực hiện phép nhân ma trận có dấu `C = A x B`. Hai ma trận đầu vào
`A` và `B` có kích thước 4x4, mỗi phần tử là số nguyên có dấu INT8. Ma trận
kết quả `C` có 16 phần tử INT32 để tránh tràn khi cộng các tích.

Đây là khối tăng tốc phần cứng độc lập. DMA, IOMMU, CPU MMU, UART và các chế
độ truyền DMA cũ không bị thay đổi. Firmware PicoRV32 điều khiển khối qua một
vùng thanh ghi AXI4-Lite mới tại `0x4000_0000`.

## Luồng hoạt động

1. PicoRV32 ghi bốn hàng của A và bốn hàng của B vào các thanh ghi đầu vào.
2. CPU ghi bit `START`.
3. Mỗi chu kỳ, A dịch từ trái sang phải và B dịch từ trên xuống dưới qua mảng
   4x4 processing elements (PE).
4. Mỗi PE thực hiện một phép nhân-cộng có dấu và giữ tổng cục bộ.
5. Sau 12 chu kỳ phần cứng, 16 phần tử C sẵn sàng; `DONE` và IRQ bit 7 lên 1.
6. CPU đọc C, tự so sánh với ma trận tham chiếu rồi phát PASS/FAIL qua UART.

Với ảnh lớn hơn, phần mềm phải chia dữ liệu ảnh thành các tile 4x4 và gọi khối
nhiều lần. Đây là primitive nhân ma trận, chưa phải toàn bộ NPU hay bộ xử lý
ảnh hoàn chỉnh.

## Sơ đồ kết nối

```text
PicoRV32
   |
   | AXI4-Lite, base 0x4000_0000
   v
Register wrapper (systolic_accel_axil)
   | A[4x4] INT8, B[4x4] INT8, START
   v
4x4 systolic MAC array (systolic_matmul_4x4)
   | 16 x DSP48E1 product pipeline + output-stationary accumulation
   v
C[4x4] INT32 + DONE + cycle counter
   |
   +---- IRQ[7] ----> PicoRV32
```

## Bản đồ thanh ghi

| Offset | Thanh ghi | Chức năng |
|---:|---|---|
| `0x00` | CONTROL | bit 0 START, bit 1 CLEAR_DONE |
| `0x04` | STATUS | bit 0 BUSY, bit 1 DONE, bit 2 IRQ |
| `0x08` | CONFIG | kích thước mảng và độ rộng dữ liệu |
| `0x0C` | CYCLES | số chu kỳ phần cứng lần chạy gần nhất |
| `0x10..0x1C` | A_ROW0..3 | mỗi thanh ghi chứa 4 phần tử INT8 |
| `0x20..0x2C` | B_ROW0..3 | mỗi thanh ghi chứa 4 phần tử INT8 |
| `0x40..0x7C` | C00..C33 | 16 kết quả INT32 |
| `0x80` | ID | `0x53595354`, chuỗi `SYST` |

## Ví dụ đã kiểm tra

```text
A = [ 1  2  3  4 ]    B = [ 1  0  2 -1 ]
    [-1  0  2  1 ]        [ 2  1  0  3 ]
    [ 5 -2  1  0 ]        [-1  4  1  0 ]
    [ 3  3  3  3 ]        [ 3 -2  2  1 ]

C = [14  6 13   9]
    [ 0  6  2   2]
    [ 0  2 11 -11]
    [15  9 15   9]
```

Testbench không gán trực tiếp kết quả. Nó thực hiện giao dịch AXI4-Lite thật,
chờ phần cứng tính, đọc lại đủ 16 thanh ghi C và đối chiếu từng phần tử.

## File quan trọng

- `src/Systolic/systolic_matmul_4x4.sv`: datapath systolic và 16 PE MAC.
- `src/Systolic/systolic_accel_axil.sv`: thanh ghi AXI4-Lite, trạng thái, IRQ.
- `testbench/tb_systolic_accel_axil.sv`: unit test tự kiểm tra khối tăng tốc.
- `testbench/tb_soc_systolic_demo.sv`: test PicoRV32 + firmware + accelerator.
- `firmware/src/soc_systolic_demo.cpp`: chương trình C++ chạy trên PicoRV32.
- `scripts/create_vc707_systolic_project.tcl`: tạo project Vivado VC707.

## Cách mở và nạp VC707

Chạy `OPEN_VC707_SYSTOLIC_PROJECT.cmd` để build firmware và mở project. Chạy
`BUILD_VC707_SYSTOLIC_BITSTREAM.cmd` để synthesize, implement và tạo bitstream.
Bitstream cuối nằm tại:

`bitstream/DMA_IOMMU_PicoRV32_VC707_Systolic.bit`

## Kết quả kiểm chứng thực tế

### Mô phỏng toàn SoC

XSim đã chạy PicoRV32 với firmware C++ thật. CPU ghi hai ma trận qua
AXI4-Lite, khởi động accelerator, chờ IRQ/DONE, đọc đủ 16 kết quả rồi tự so
sánh. Kết quả là `SYSTOLIC PASS`; thời gian tính trong lõi là 12 chu kỳ.

Log mô phỏng: `reports/systolic_soc_test.log`.

### Implementation trên VC707

| Thông số | Kết quả post-route |
|---|---:|
| FPGA | `xc7vx485tffg1761-2` |
| Clock constraint | 6.667 ns = 149.993 MHz |
| WNS | +0.844 ns |
| Fmax ước lượng | 171.733 MHz |
| LUT toàn SoC | 8,374 |
| FF toàn SoC | 8,243 |
| RAMB36 toàn SoC | 16 |
| DSP toàn SoC | 16 |
| LUT riêng accelerator | 2,006 |
| FF riêng accelerator | 2,134 |
| DSP riêng accelerator | 16 |
| DRC errors | 0 |

Công thức Fmax ước lượng:

`Fmax = 1000 / (Tconstraint - WNS) = 1000 / (6.667 - 0.844) = 171.733 MHz`.

Thiết kế vẫn chạy ở clock 149.993 MHz do MMCM/constraint đặt như vậy. Giá trị
171.733 MHz là mức ước lượng từ đường timing xấu nhất sau place-and-route,
không phải clock tự động được cấp cho mạch.

Các report nằm trong `reports/vc707_systolic/`.
