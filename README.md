# Oracle A1 Auto Provision

## Cấu hình chạy tự động hiện tại

Theo yêu cầu mới nhất, cấu hình mục tiêu là **2 OCPU / 12 GB RAM / 2 Gbps**, VM.Standard.A1.Flex, Singapore West và Ubuntu 24.04 ARM64.

GitHub Actions tự động thử tạo VPS mỗi **15 phút** (`*/15 * * * *`). Chỉ dùng `ap-singapore-2`, `VM.Standard.A1.Flex`, **2 OCPU / 12 GB RAM**, Ubuntu 24.04 ARM64 non-Minimal, Public IPv4, tên `oracle-free-a1` và SSH user `ubuntu`.

Project không nâng tài khoản lên PAYG, không tạo VCN/subnet riêng, không đổi shape hoặc CPU/RAM. VM sẽ có boot volume và VNIC do OCI tạo kèm; kiểm tra hạn mức miễn phí hiện có trên tài khoản trước khi chạy. Cấu hình nhỏ không tự chứng minh toàn bộ tài khoản còn trong hạn mức miễn phí. Không chạy nhiều bản sao workflow ở nhiều repository hoặc tự tạo VM cùng tên trong khi workflow đang chạy.

## 1. API Key và SSH Key

- **OCI API Key** cho OCI CLI quyền gọi API theo quyền IAM của user. Private key của cặp này đặt vào GitHub Secret `OCI_API_PRIVATE_KEY`.
- **SSH Key** để đăng nhập Ubuntu. Chỉ đưa public key vào `OCI_SSH_PUBLIC_KEY`; giữ SSH private key trên máy cá nhân.
- Mật khẩu oracle.com không dùng trong project. Không đặt mật khẩu vào repo hoặc Actions Secrets của project này.

## 2. Tạo OCI API Key

Đăng nhập Oracle Cloud Console, chọn Singapore West (`ap-singapore-2`). Nếu tenancy chưa được phép dùng region này, dừng và kiểm tra trong Console; script không chuyển region.

Vào **Profile → My profile → API Keys → Add API Key → Generate API Key Pair**. Tải private key về nơi an toàn, sau đó Add. Oracle hiển thị Configuration File Preview:

| Trường Oracle | GitHub Secret | Nội dung |
|---|---|---|
| user | OCI_USER_OCID | User OCID đầy đủ |
| tenancy | OCI_TENANCY_OCID | Tenancy OCID đầy đủ |
| fingerprint | OCI_FINGERPRINT | Fingerprint dạng các cặp hex cách nhau bởi dấu hai chấm |
| region | Không cần Secret | Script cố định ap-singapore-2 |
| File private key đã tải | OCI_API_PRIVATE_KEY | Toàn bộ PEM private key |

Private key phải bao gồm cả đầu và cuối, ví dụ:

```text
-----BEGIN PRIVATE KEY-----
...nội dung private key thật của bạn...
-----END PRIVATE KEY-----
```

PEM RSA private key cũng được OCI hỗ trợ. Không copy đường dẫn file vào Secret. User phải có quyền xem AD, images, subnet, VNIC và xem/tạo instance trong compartment mục tiêu. Nếu gặp lỗi quyền, nhờ quản trị tenancy cấp quyền phù hợp, không chia sẻ private key.

## 3. Chuẩn bị public subnet

Nếu có public subnet phù hợp, dùng subnet đó. Nếu chưa có, bạn tự vào **Networking → Virtual Cloud Networks → Start VCN Wizard → VCN with Internet Connectivity** trong Singapore West. Kiểm tra các tài nguyên và hạn mức trước khi xác nhận wizard.

Vào VCN → Subnets → public subnet → **OCID → Copy**, dùng làm `OCI_SUBNET_OCID`. Subnet phải cho phép Public IPv4 (`Prohibit public IP on VNIC` tắt), có Internet Gateway hoạt động, route `0.0.0.0/0` tới Internet Gateway, và egress cho lưu lượng cần thiết. Project chỉ kiểm tra quyền cấp public IP của subnet, không tự sửa route hoặc firewall.

Trong Security List của subnet (và NSG nếu áp dụng), thêm ingress TCP destination port **22**, source là Public IP nhà bạn theo dạng `x.x.x.x/32`. Không khuyến khích mở SSH `0.0.0.0/0` lâu dài. Nếu IP nhà thay đổi, cập nhật rule.

## 4. Tạo SSH Key trên Windows

Mở PowerShell:

```powershell
ssh-keygen -t ed25519 -C "oracle-a1"
```

Chọn vị trí mới nếu đã có key để tránh ghi đè. Nên dùng passphrase.

- `$HOME\.ssh\id_ed25519`: **PRIVATE KEY**, giữ trên máy, không upload GitHub.
- `$HOME\.ssh\id_ed25519.pub`: **PUBLIC KEY**, copy toàn bộ một dòng vào `OCI_SSH_PUBLIC_KEY`.

```powershell
Get-Content "$HOME\.ssh\id_ed25519.pub"
```

## 5. Đưa project lên GitHub và điền Secrets

Tạo repository riêng, nên dùng private. Upload các file source, bao gồm thư mục ẩn `.github`; giữ workflow trên default branch. Không upload key hay OCI config.

Vào **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Giá trị |
|---|---|
| OCI_USER_OCID | User OCID |
| OCI_TENANCY_OCID | Tenancy OCID |
| OCI_FINGERPRINT | API key fingerprint |
| OCI_API_PRIVATE_KEY | Toàn bộ API private key PEM nhiều dòng |
| OCI_SUBNET_OCID | Public subnet OCID trong ap-singapore-2 |
| OCI_SSH_PUBLIC_KEY | Nội dung file SSH `.pub` |
| OCI_COMPARTMENT_OCID (tùy chọn) | Compartment chứa instance; bỏ trống dùng root tenancy |

Bật GitHub Issues và GitHub Actions cho repository. Chính sách tổ chức có thể chặn `actions: write` hoặc `issues: write`; khi đó xem warning trong workflow. `GITHUB_TOKEN` được GitHub tự cấp, không cần tạo Secret tên này.

## 6. Chạy lần đầu

Vào **GitHub → Actions → Oracle A1 Auto Provision → Run workflow**, chọn default branch và Run workflow. Mở job để đọc log và Summary. Workflow cài OCI CLI trong virtualenv tạm, không lưu OCI config hoặc private key vào repo. SSH public key được ghi vào thư mục tạm quyền hạn chế và xóa khi script kết thúc.

| result | Ý nghĩa |
|---|---|
| capacity | Thiếu host capacity; job xanh, chờ lần sau |
| created | OCI đã nhận tạo VM; xem Lifecycle để biết đã RUNNING chưa |
| exists | Đã có instance cùng tên chưa TERMINATED/TERMINATING; không tạo tiếp |
| error | Lỗi cấu hình/API; sửa lỗi trước khi chạy tiếp |

Script chọn image AVAILABLE mới nhất theo time-created, tên có aarch64/arm64, không Minimal và tương thích A1. Nếu không có image phù hợp, dừng với lỗi; không tự đổi OS.

Sau khi OCI nhận tạo VM, script giữ Instance OCID trước khi chờ RUNNING tối đa 10 phút. Chờ quá hạn vẫn được xem là đã tạo, không launch lần nữa. Workflow tạo Issue khi `created`, rồi tự disable khi `created` hoặc `exists`. Nếu tạo Issue hoặc disable bị chặn, job vẫn tiếp tục; lần sau kiểm tra instance có sẵn. Kiểm tra log warning để biết thông báo/disable có thực sự thành công.

Concurrency bảo vệ các lượt trong cùng repository. Retry token cố định giúp OCI nhận diện yêu cầu lặp trong thời gian hiệu lực của token. Không thể bảo đảm tuyệt đối chống trùng khi có nhiều repository, người khác tạo song song, đổi tên VM, hoặc OCI chưa phản ánh instance sau lỗi mạng. Khi launch bị lỗi mạng/timeout, kiểm tra Console trước khi chạy lại; nếu chưa rõ, disable workflow trong Actions.

Schedule chỉ hoạt động trên default branch và có thể bị GitHub tự tắt trong repository public không hoạt động. Nếu muốn chạy lại sau khi đã disable, kiểm tra Console và hạn mức trước, rồi dùng **Enable workflow**; không đổi tên instance có sẵn để vượt qua kiểm tra.

## 7. Đăng nhập VPS

Vào **OCI Console → Singapore West → Compute → Instances → oracle-free-a1**, kiểm tra RUNNING và Public IP. Trên Windows:

```powershell
ssh ubuntu@PUBLIC_IP
ssh -i "C:\path\private_key" ubuntu@PUBLIC_IP
```

Thay `PUBLIC_IP` bằng địa chỉ thật. SSH dùng private key tương ứng public key đã nhập, không dùng OCI API private key.

## 8. Troubleshooting

| Lỗi | Cách kiểm tra |
|---|---|
| Out of capacity / Out of host capacity | Đợi lần chạy tiếp; không nâng PAYG hoặc đổi cấu hình để xử lý |
| NotAuthorizedOrNotFound | Kiểm tra IAM, region, OCID và compartment; tài nguyên có thể không tồn tại hoặc user không có quyền |
| InvalidParameter | Kiểm tra OCID, image, subnet và hạn mức; đọc thông báo OCI, không đổi shape/CPU/RAM |
| Subnet không hỗ trợ public IP | Chọn public subnet có quyền cấp Public IPv4 |
| SSH timeout | Kiểm tra RUNNING, public IP, route, Internet Gateway, Security List/NSG, IP nguồn và firewall Ubuntu |
| API private key sai | Paste đủ PEM nhiều dòng, đúng cặp key đã đăng ký, không dùng SSH key; key mã hóa passphrase chưa được project hỗ trợ |
| Fingerprint sai | Copy fingerprint từ API Keys của đúng user và đúng public key |
| LimitExceeded / quota | Kiểm tra VM/boot volume hiện có và quota; không tự nâng tài khoản |
| Không lấy được Public IP | Kiểm tra tab Attached VNICs trong Console; script không tự tạo IP riêng |
| Issue không tạo / workflow không disable | Bật Issues và kiểm tra chính sách GITHUB_TOKEN; đọc log step tương ứng |

Không commit `*.pem`, `*.key`, OCI config, `.env` hoặc SSH private key. `.gitignore` không thay thế việc rà soát file trước khi upload. Nếu lộ key, thu hồi API key hoặc thay SSH key tương ứng.

## Tài liệu chính thức

- [OCI instance launch](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/compute/instance/launch.html)
- [OCI image list](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/compute/image/list.html)
- [GitHub schedule](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)

Project chỉ dùng GitHub Actions, Bash, OCI CLI, jq và gh; không dùng Terraform.

## Kiểm tra offline

Trên Linux hoặc Git Bash có `jq` và `ssh-keygen`:

```bash
bash -n scripts/try-oracle-a1.sh
bash tests/mock-provision.sh
```

Mock kiểm tra instance tồn tại, hết capacity, tạo thành công, lỗi API, timeout chờ RUNNING và từ chối region khác. Mock không gọi OCI thật. Windows không thể hiện quyền executable kiểu Linux; Git lưu script chính với mode `100755`, workflow cũng gọi script bằng `bash`.
