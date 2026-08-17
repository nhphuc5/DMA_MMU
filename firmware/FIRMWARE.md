# Firmware C++ cho PicoRV32

## 1. Tệp Markdown này là gì?

Markdown là tệp văn bản có đuôi `.md`. Nó dùng các ký hiệu đơn giản như `#`,
`-`, bảng và khối mã để trình bày tài liệu dễ đọc trên GitHub hoặc trong
Visual Studio Code. Markdown **không phải mã chạy trên CPU** và không tham gia
synthesis. Tệp này chỉ mô tả cách firmware hoạt động và cách build nó.

## 2. Firmware làm gì?

`src/soc_demo.cpp` là chương trình C++ bare-metal chạy thật trên PicoRV32.
Bare-metal nghĩa là CPU chạy trực tiếp mã máy, không có Windows, Linux hay hệ
điều hành trung gian. Firmware thực hiện các bước sau:

1. Đặt bộ chia baud và gửi marker `S` qua UART.
2. Lập trình CPU-side MMU, kiểm tra ánh xạ VA `0x8000` sang PA `0x3000`.
3. Tạo dữ liệu nguồn trong AXI RAM.
4. Lập trình page table của DMA-side IOMMU và quyền đọc/ghi.
5. Chạy đủ chín tổ hợp DMA D01-D09:
   - Memory → Memory;
   - UART → Memory;
   - Memory → UART;
   - mỗi hướng chạy Burst, Cycle-Stealing và Transparent.
6. Chạy Q01: đẩy tám descriptor vào FIFO rồi kiểm tra dữ liệu và completion.
7. Chạy P01: UART tự tạo DMA request, CPU đọc request và cấp quyền.
8. Gửi `P` khi mọi kiểm tra đều đúng hoặc `F` khi phát hiện lỗi.

Hai lệnh inline Assembly trong `_start` chỉ đặt stack ở đỉnh RAM 64 KiB và
nhảy vào `firmware_main`. Toàn bộ thuật toán kiểm tra và cấu hình còn lại là
C++.

## 3. Vai trò của các tệp

| Tệp | Vai trò |
|---|---|
| `src/soc_demo.cpp` | Mã nguồn C++ chạy trên PicoRV32 |
| `include/soc_map.h` | Địa chỉ và bit thanh ghi CPU MMU, DMA/IOMMU, UART |
| `linker.ld` | Đặt reset vector, code/data và stack trong AXI RAM 64 KiB |
| `Makefile` | Mô tả phụ thuộc và tự động chạy toàn bộ các bước build |
| `build_firmware.cmd` | Nút chạy thuận tiện trên Windows; gọi Vitis Makefile |
| `tools/makehex.py` | Đổi binary little-endian thành 16.384 word HEX |
| `build/soc_demo.elf` | Tệp ELF32 RISC-V chứa mã máy và thông tin liên kết |
| `build/soc_demo.bin` | Ảnh nhị phân thô lấy từ ELF |
| `build/soc_demo.hex` | Ảnh 64 KiB được Vivado `$readmemh` nạp vào AXI RAM |

## 4. Makefile tự động hóa là gì?

Makefile không chứa firmware. Nó là một “bản hướng dẫn build” cho chương trình
GNU Make. Make đọc quan hệ phụ thuộc giữa các tệp rồi chỉ chạy những bước cần
thiết:

```text
soc_demo.cpp + soc_map.h + linker.ld
                  |
                  | riscv32-xilinx-elf-g++
                  v
             soc_demo.elf
                  |
                  | riscv32-xilinx-elf-objcopy
                  v
             soc_demo.bin
                  |
                  | Python + makehex.py
                  v
             soc_demo.hex
```

Ví dụ, nếu chỉ sửa `soc_demo.cpp`, Make sẽ tạo lại ELF, BIN và HEX. Nếu không
có tệp đầu vào nào thay đổi, Make không biên dịch lại không cần thiết.

## 5. Tool được sử dụng

Vitis 2025.1 trên máy cung cấp:

- `riscv32-xilinx-elf-g++`: biên dịch C++ thành RV32I;
- `riscv32-xilinx-elf-objcopy`: tạo binary từ ELF;
- `riscv32-xilinx-elf-readelf`: xác nhận ELF32, RISC-V và ISA `rv32i2p1`;
- `D:\2025.1\Vitis\gnuwin\bin\make.exe`: thực thi Makefile;
- Python: chạy `makehex.py`.

Các cờ quan trọng là `-march=rv32i -mabi=ilp32`. Chúng yêu cầu mã lệnh RISC-V
32 bit và ABI 32 bit, phù hợp với PicoRV32.

## 6. Cách build

Cách dễ nhất là nhấp đúp:

```text
firmware\build_firmware.cmd
```

Hoặc mở terminal tại thư mục `firmware` và chạy trực tiếp GNU Make của Vitis:

```bat
D:\2025.1\Vitis\gnuwin\bin\make.exe all
```

Các lệnh hỗ trợ:

```bat
D:\2025.1\Vitis\gnuwin\bin\make.exe verify
D:\2025.1\Vitis\gnuwin\bin\make.exe clean
D:\2025.1\Vitis\gnuwin\bin\make.exe rebuild
```

Sau khi build thành công, Vivado sử dụng `build/soc_demo.hex`. Chạy simulation
top `tb_dma_iommu_picorv32_unified` để kiểm tra toàn bộ CPU, CPU MMU, DMA,
IOMMU, AXI, descriptor FIFO và UART.
