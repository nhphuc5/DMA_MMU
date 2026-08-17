# Demo truyền 3 ảnh từ RAM ra UART bằng DMA

## Mục đích

Ba ảnh gốc trong thư mục `firmware` được chuyển thành ảnh xám 64 x 64 pixel.
Mỗi pixel chiếm 1 byte, vì vậy mỗi ảnh dùng 4096 byte trong AXI RAM 64 KiB.

| Ảnh | Địa chỉ RAM | Kích thước | Chuỗi UART trước dữ liệu |
|---|---:|---:|---|
| IMG1 | `0x8000` | 4096 byte | `IMG1` |
| IMG2 | `0x9000` | 4096 byte | `IMG2` |
| IMG3 | `0xA000` | 4096 byte | `IMG3` |

Luồng dữ liệu thật:

`Ảnh trong AXI RAM -> DMA Memory-to-Peripheral -> AXI-Stream -> UART TX`

CPU chỉ cấu hình IOMMU, UART và descriptor DMA. CPU không tự chép 12.288 byte ảnh.

## Build lại firmware và ảnh

- Mô phỏng nhanh: chạy `firmware/build_image_demo.cmd`.
- Kit VC707, 150 MHz và UART 115200 baud: chạy
  `firmware/build_vc707_image_demo.cmd`.

File RAM hoàn chỉnh cho VC707:

`firmware/build/vc707_image_demo/soc_image_demo_with_images.hex`

## Mô phỏng tự kiểm tra

Mở project:

`build/vivado/vc707_image_demo/DMA_IOMMU_PicoRV32_VC707_Image_Demo.xpr`

Trong Vivado chọn **Run Simulation -> Run Behavioral Simulation**, rồi **Run All**.
Testbench `tb_soc_image_uart_demo.sv` so sánh từng byte UART với từng byte ảnh
được nạp trong RAM. Kết quả nằm tại:

`reports/image_uart_dma_test.log`

PASS hợp lệ phải ghi đủ IMG1, IMG2, IMG3, tổng cộng 12.288 byte và
`mismatches=0`.

## Nhận ảnh thật từ kit VC707

Sau khi nạp bitstream, nối UART và chạy (thay `COM5` bằng cổng của máy):

```powershell
python firmware/tools/receive_images_uart.py COM5 --baud 115200 --output received_images
```

Script đọc các khung `IMG1`, `IMG2`, `IMG3`, nhận đúng 4096 byte mỗi ảnh và
tạo lại ba file PNG trong thư mục `received_images`.
