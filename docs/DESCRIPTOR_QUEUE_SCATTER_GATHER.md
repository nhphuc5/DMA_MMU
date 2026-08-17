# Hàng đợi 8 descriptor và Scatter-Gather

## Mục tiêu

CPU có thể ghi trước tối đa tám lệnh truyền vào FIFO. DMA lấy từng lệnh theo
đúng thứ tự vào, thực hiện qua scheduler/IOMMU/các AXI engine hiện có, rồi ghi
kết quả vào completion FIFO. Vì mỗi descriptor có địa chỉ nguồn và đích độc
lập, tám lệnh có thể thao tác trên tám vùng nhớ không liên tục (scatter-gather)
mà CPU không phải chờ từng lệnh hoàn thành.

Đường chạy cũ qua các thanh ghi `SRC/DST/LENGTH/CONTROL` vẫn được giữ nguyên để
tương thích. Nâng cấp chỉ thêm một đường cấp descriptor mới ở trước scheduler.

## Nội dung một descriptor

| Trường | Ý nghĩa |
|---|---|
| Source address | Địa chỉ ảo nguồn |
| Destination address | Địa chỉ ảo đích |
| Length | Số byte cần truyền |
| Transfer type | M2M, Peripheral-to-Memory hoặc Memory-to-Peripheral |
| DMA mode | Burst, Cycle-Stealing hoặc Transparent |
| Burst words | Số word tối đa trong một burst |
| IRQ flag | Descriptor này có phát ngắt khi hoàn tất hay không |
| Descriptor ID | Mã để phần mềm ghép completion với lệnh ban đầu |
| Next descriptor | Metadata dành cho linked-list; bản hiện tại thực thi tám descriptor đã được CPU đưa vào FIFO |

## Luồng hoạt động

1. CPU ghi các trường staging tại `0x40..0x54` qua AXI4-Lite.
2. CPU ghi `PUSH` tại `0x58`; toàn bộ trường được chụp nguyên tử vào descriptor FIFO.
3. Queue manager chỉ lấy descriptor khi scheduler rảnh, queue không pause/halt và completion FIFO còn chỗ.
4. Scheduler gửi địa chỉ ảo tới IOMMU; IOMMU dịch địa chỉ, kiểm tra trang, quyền và biên 4 KiB.
5. Nếu được phép, DMA thực hiện một trong ba hướng và một trong ba chế độ cũ.
6. Khi xong hoặc lỗi, queue manager đẩy ID, trạng thái, mã lỗi và số byte vào completion FIFO.
7. CPU đọc `COMP_STATUS/COMP_BYTES`, sau đó ghi `COMP_POP` để lấy kết quả kế tiếp.
8. Nếu descriptor lỗi, hàng đợi dừng; descriptor chưa chạy được giữ lại. CPU xử lý lỗi rồi `RESUME`, hoặc `FLUSH` để bỏ phần còn chờ.

## Bản đồ thanh ghi bổ sung

| Offset | Tên | Chức năng |
|---:|---|---|
| `0x40` | DESC_SRC | Địa chỉ nguồn staging |
| `0x44` | DESC_DST | Địa chỉ đích staging |
| `0x48` | DESC_LENGTH | Độ dài byte |
| `0x4C` | DESC_CONFIG | type `[1:0]`, mode `[3:2]`, burst `[15:8]` |
| `0x50` | DESC_FLAGS | IRQ `[0]`, descriptor ID `[15:8]` |
| `0x54` | DESC_NEXT | Con trỏ/metadata descriptor tiếp theo |
| `0x58` | DESC_COMMAND | PUSH `[0]`, FLUSH `[1]`, RESUME `[2]`, PAUSE `[3]` |
| `0x5C` | QUEUE_STATUS | count, empty/full, active, halted, overflow, completion valid/count, paused |
| `0x60` | COMP_STATUS | valid, done, fault, fault code, descriptor ID |
| `0x64` | COMP_BYTES | Số byte của descriptor đã kết thúc |
| `0x68` | COMP_POP | Ghi bit 0 để bỏ completion đầu FIFO |
| `0x6C` | COMP_TOTAL | Tổng số descriptor đã kết thúc kể từ reset |

## Chính sách lỗi và ngắt

- Ghi PUSH khi FIFO đầy không làm hỏng dữ liệu đang có; cờ overflow sticky được đặt.
- Mỗi descriptor có cờ IRQ riêng. Descriptor không yêu cầu IRQ vẫn sinh completion để CPU kiểm tra.
- Fault luôn được báo qua IRQ và completion.
- Completion FIFO đầy tạo backpressure: DMA không lấy descriptor mới cho tới khi CPU pop kết quả.
- `FLUSH` xóa các descriptor chưa chạy nhưng giữ completion đã sinh để phần mềm không mất kết quả.

## Mức Scatter-Gather hiện tại

Đây là **queue-based scatter-gather**: CPU chuẩn bị tối đa tám descriptor cho
tám vùng không liên tục rồi DMA tự chạy liên tiếp. Trường `NEXT` đã có trong
định dạng descriptor nhưng chưa có AXI descriptor-fetch engine để tự đọc một
linked list từ RAM. Vì vậy không nên mô tả bản hiện tại là linked-list SG không
giới hạn; giới hạn phần cứng hiện tại là tám descriptor resident trong FIFO.

## Kiểm chứng

- Component test Q01: đầy 8 entry, từ chối entry thứ 9, chạy đúng FIFO, so sánh
  dữ liệu của cả tám vùng, kiểm tra ID/completion/byte count và IRQ riêng.
- Component test Q02: descriptor tốt -> descriptor lỗi quyền IOMMU -> descriptor
  tốt; kiểm tra queue halt và descriptor cuối chưa bị thực thi.
- Firmware Q01: PicoRV32 tự ghi tám descriptor qua AXI4-Lite, DMA thực hiện tám
  phép copy rời rạc, CPU đọc/popup completion; SoC testbench đọc RAM thật và so
  sánh từng word.
