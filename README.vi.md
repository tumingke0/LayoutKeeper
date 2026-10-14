<p align="center"><img src="docs/images/icon.png" width="128" alt="Biểu tượng LayoutKeeper"></p>

# LayoutKeeper

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · **Tiếng Việt**

**Cắm lại màn hình ngoài, các cửa sổ tự trở về đúng chỗ cũ, kể cả đúng màn hình nền (Space) như trước.**

<p align="center"><img src="docs/images/main-window.png" width="720" alt="Cửa sổ chính: bố cục dùng chung, bố cục có tên và lịch sử"></p>

<p align="center">
  <img src="docs/images/menu.png" width="300" alt="Thanh menu: thanh trượt độ sáng, âm lượng, lưu và khôi phục">
  <img src="docs/images/brightness-hud.png" width="520" alt="Chỉ báo độ sáng ở phía trên màn hình">
</p>

## Ứng dụng giải quyết vấn đề gì

Bạn dùng một màn hình ngoài ở công ty và một cái khác ở nhà. Mỗi lần rút cáp, macOS dồn hết cửa sổ sang màn hình laptop. Khi cắm lại, bạn phải kéo từng cửa sổ về chỗ cũ, từng màn hình nền một.

LayoutKeeper nằm trên thanh menu và ghi nhớ vị trí từng cửa sổ trên màn hình ngoài, **kể cả cửa sổ nằm ở màn hình nền (Space trong Mission Control) nào**. Khi cắm màn hình lại, mọi thứ trở về chỗ cũ chỉ với một cú nhấp, hoặc tự động.

> Ảnh chụp dùng dữ liệu mẫu. Giao diện ứng dụng hiện chỉ có tiếng Trung.

## Tính năng

- **Mỗi màn hình một bố cục.** Màn hình được nhận diện theo phần cứng (EDID: hãng, model, số sê-ri). Màn hình ở nhà và ở công ty có bố cục riêng, không cần chọn tay.
- **Hoặc dùng chung một bố cục.** Nếu mỗi lần bạn chỉ cắm một màn hình ngoài, hãy chọn "mọi màn hình ngoài dùng chung một bố cục". Ở công ty hay ở nhà đều có cùng các màn hình nền và cửa sổ. Vị trí được lưu theo tỉ lệ màn hình nên khác độ phân giải vẫn khớp.
- **Đưa cửa sổ về đúng màn hình nền** (macOS 26 trở lên). Trên macOS cũ hơn, vị trí và kích thước vẫn được khôi phục trên màn hình nền hiện tại.
- **Tự thêm và xóa màn hình nền** (chế độ dùng chung, bật sẵn). Khi cắm vào, ứng dụng thêm các màn hình nền còn thiếu trong Mission Control. Khi rút ra, nó chỉ xóa các màn hình nền **trống** mà macOS đã chuyển sang màn hình tích hợp. Nếu có gì không khớp, nó dừng lại và nhắc bạn làm tay. Không cần tắt SIP.
- **Phím độ sáng và âm lượng.** Phím độ sáng chỉnh màn hình đang có con trỏ chuột (tích hợp hoặc ngoài) và hiện chỉ báo trong suốt ở phía trên màn hình. Phím âm lượng có thể chỉnh loa của màn hình ngoài. Điều khiển phần cứng (DDC) **chỉ hỗ trợ máy Mac Apple Silicon**. Nếu màn hình không phản hồi, ứng dụng làm tối bằng phần mềm. Khi BetterDisplay, MonitorControl hoặc Lunar đang chạy, LayoutKeeper nhường các phím cho chúng.
- **Nhiều bố cục có tên cho một màn hình**, ví dụ "Lập trình" và "Họp". Bạn đổi qua lại ngay trên thanh menu.
- **Lịch sử phiên bản.** Giữ 5 phiên bản gần nhất của mỗi màn hình để bạn quay lại.
- **Xem trước, hoàn tác bất cứ lúc nào.** Bạn thấy trước từng cửa sổ sẽ di chuyển thế nào, và mọi lần khôi phục đều hoàn tác được bằng một cú nhấp.
- **Không đoán mò.** Sau khi di chuyển mỗi cửa sổ, ứng dụng kiểm tra lại xem nó đã tới đúng chỗ chưa và hoàn lại nếu thất bại. Nếu không phân biệt được hai cửa sổ cùng tên, nó sẽ hỏi bạn.
- **Phím tắt toàn cục:** ⌃⌥⌘S lưu, ⌃⌥⌘R khôi phục, ⌃⌥⌘Z hoàn tác. Có thể đổi hoặc tắt.
- **Tự động cập nhật** qua Sparkle. Bản cập nhật được kiểm tra chữ ký và giữ nguyên quyền Trợ năng.

<p align="center">
  <img src="docs/images/settings-general.png" width="440" alt="Cài đặt: chế độ bố cục dùng chung và quản lý màn hình nền">
  <img src="docs/images/settings-display.png" width="440" alt="Cài đặt: màn hình, phím độ sáng và âm lượng">
</p>

## Cài đặt

1. Tải tệp `.dmg` từ [Releases](https://github.com/tumingke0/LayoutKeeper/releases/latest): chọn **AppleSilicon** cho chip dòng M, **Intel** cho Mac chip Intel.
2. Kéo LayoutKeeper vào thư mục Ứng dụng.
3. **Lần đầu mở**, nhấp chuột phải vào ứng dụng và chọn **Mở**. Bạn cũng có thể bấm "Vẫn mở" trong Cài đặt hệ thống → Quyền riêng tư & Bảo mật. Cần bước này vì ứng dụng tự ký, chưa được Apple công chứng.
4. Làm theo hướng dẫn 3 bước: cho phép **Trợ năng**, chọn có khởi động cùng máy không, rồi lưu bố cục đầu tiên.

**Cập nhật:** dùng thanh menu → "检查更新…" (Kiểm tra cập nhật). Mặc định ứng dụng tự kiểm tra mỗi ngày một lần. Mọi phiên bản đều ký bằng cùng một chứng chỉ, nên sau khi cập nhật bạn không phải cấp quyền lại.
Nếu bạn đang dùng 0.6.0 hoặc cũ hơn, hãy cài tay bản mới một lần cuối và cấp lại quyền Trợ năng. Nếu công tắc đã bật mà không hoạt động, hãy xóa LayoutKeeper bằng nút "−" rồi thêm lại.

## Cách dùng

1. Sắp xếp cửa sổ trên các màn hình nền của màn hình ngoài.
2. Biểu tượng trên thanh menu → "保存当前布局" (Lưu bố cục hiện tại), hoặc nhấn ⌃⌥⌘S.
3. Lần sau cắm màn hình đó, một thông báo nhỏ hiện ở góc trên bên phải. Bấm "恢复布局" (Khôi phục bố cục), hoặc nhấn ⌃⌥⌘R.
4. Không ưng ý? Nhấn ⌃⌥⌘Z để hoàn tác.

Khi cắm màn hình (Cài đặt → Chung):
- **Hỏi trước** (mặc định): một thông báo có thể đóng hiện ở góc trên bên phải, và không có gì di chuyển cho tới khi bạn bấm.
- **Tự động khôi phục**: đợi màn hình và cửa sổ ổn định rồi mới khôi phục.
- **Tắt**: chỉ khôi phục thủ công.

Chi tiết xem [docs/USABILITY.md](docs/USABILITY.md) (tiếng Trung).

## Yêu cầu

- macOS 14 trở lên. Đưa cửa sổ về đúng màn hình nền cần **macOS 26 trở lên** (đã thử trên macOS 27.0).
- Quyền Trợ năng. Không cần quyền Ghi màn hình hay Giám sát đầu vào.
- Mỗi lúc chỉ **một** màn hình ngoài.
- Bật "Màn hình có các Space riêng biệt" trong Cài đặt hệ thống → Màn hình nền & Dock (mặc định đã bật).

## Hạn chế

- Việc chuyển cửa sổ giữa các màn hình nền dùng API riêng của macOS, có thể ngừng hoạt động sau khi cập nhật hệ thống. Ứng dụng tự kiểm tra khi khởi động và tắt tính năng này nếu cần. Khôi phục trên cùng màn hình nền không bị ảnh hưởng.
- Cửa sổ Finder không chuyển được sang màn hình nền khác, nhưng vị trí và kích thước vẫn được khôi phục.
- Ứng dụng không mở hay thoát ứng dụng khác, không khôi phục tab hay thứ tự chồng cửa sổ. Cửa sổ toàn màn hình, Split View và thu nhỏ sẽ bị bỏ qua.
- Chỉnh độ sáng và âm lượng bằng phần cứng chỉ có trên Apple Silicon. Một số màn hình, bộ chuyển đổi, dock và cổng HDMI không hỗ trợ DDC.

## Câu hỏi thường gặp

**Ứng dụng có thu thập dữ liệu không?** Không. Truy cập mạng duy nhất là kiểm tra cập nhật, chỉ kết nối tới GitHub và có thể tắt trong Cài đặt. Bố cục chỉ lưu trên máy Mac của bạn tại `~/Library/Application Support/LayoutKeeper/`.

**Vì sao có cửa sổ bị đánh dấu "cần xác nhận"?** Một ứng dụng có nhiều cửa sổ cùng tiêu đề, và LayoutKeeper không đoán. Hãy chọn đúng cửa sổ trong phần xem trước.

**Vì sao macOS 14/15 không khôi phục được giữa các màn hình nền?** Giao diện hệ thống cũ bị chặn từ macOS 14.5, còn giao diện mới chỉ có từ macOS 26.

**Gỡ cài đặt thế nào?** Thoát ứng dụng, xóa `LayoutKeeper.app` và `~/Library/Application Support/LayoutKeeper/`, rồi chạy `defaults delete local.layoutkeeper.app`. Cuối cùng gỡ nó khỏi Mục đăng nhập và Trợ năng trong Cài đặt hệ thống.

**Trước đây tên là SpacePort?** Đúng vậy. Ứng dụng đổi tên ở bản 0.4.0 và sao chép dữ liệu cũ trong lần chạy đầu tiên.

## Tự build từ mã nguồn

Cần Xcode 16 trở lên (Swift 6).

```sh
git clone https://github.com/tumingke0/LayoutKeeper.git
cd LayoutKeeper
./scripts/test.sh     # tùy chọn: chạy kiểm thử
./scripts/build.sh    # tạo build-products/LayoutKeeper.app
open build-products/LayoutKeeper.app
```

Nếu keychain có chứng chỉ "LayoutKeeper Self-Signed", bản build sẽ dùng nó để ký. Nếu không, bản build được ký ad-hoc, và sau mỗi lần build lại bạn cần xóa rồi thêm lại ứng dụng trong Trợ năng. Chi tiết kỹ thuật xem [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Đóng góp

Hoan nghênh Issue và Pull Request, xem [CONTRIBUTING.md](CONTRIBUTING.md). Khi báo lỗi, vui lòng ghi phiên bản macOS (kèm số build) và đính kèm báo cáo từ Cài đặt → 诊断 → 一键自检 (tự kiểm tra). Báo cáo không chứa tiêu đề cửa sổ.

## Ghi nhận

- [AltTab](https://github.com/lwouis/alt-tab-macos) (GPL-3.0): ý tưởng tìm cửa sổ trên các màn hình nền khác. Phần cài đặt là độc lập.
- [yabai](https://github.com/koekeishiya/yabai) (MIT): ý nghĩa các cờ cửa sổ của WindowServer.
- [MonitorControl](https://github.com/MonitorControl/MonitorControl) (MIT): tham khảo cho điều khiển DDC.
- SnapBack: ý tưởng khôi phục khi cắm màn hình.

Xem thêm [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Giấy phép

[GPL-3.0-only](LICENSE). Copyright (C) 2026 LayoutKeeper contributors.
