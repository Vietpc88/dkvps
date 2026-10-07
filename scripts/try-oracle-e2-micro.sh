#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

output() { [[ -z "${GITHUB_OUTPUT:-}" ]] || printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; }
fail() { echo "Lỗi: $*" >&2; output result error; exit 1; }
trap 'output result error' ERR
for cmd in oci jq ssh-keygen sha256sum; do command -v "$cmd" >/dev/null || fail "Thiếu $cmd"; done
for var in OCI_CLI_USER OCI_CLI_TENANCY OCI_CLI_FINGERPRINT OCI_CLI_KEY_CONTENT OCI_CLI_REGION OCI_SUBNET_OCID OCI_SSH_PUBLIC_KEY; do
  [[ -n "${!var:-}" ]] || fail "Thiếu biến $var"
done
OCI_CLI_USER="${OCI_CLI_USER#*user=}"
OCI_CLI_USER="${OCI_CLI_USER#*user:}"
OCI_CLI_USER="$(echo -n "$OCI_CLI_USER" | tr -d '[:space:]"'\''')"

OCI_CLI_TENANCY="${OCI_CLI_TENANCY#*tenancy=}"
OCI_CLI_TENANCY="${OCI_CLI_TENANCY#*tenancy:}"
OCI_CLI_TENANCY="$(echo -n "$OCI_CLI_TENANCY" | tr -d '[:space:]"'\''')"

OCI_CLI_FINGERPRINT="${OCI_CLI_FINGERPRINT#*fingerprint=}"
OCI_CLI_FINGERPRINT="${OCI_CLI_FINGERPRINT#*fingerprint:}"
OCI_CLI_FINGERPRINT="$(echo -n "$OCI_CLI_FINGERPRINT" | tr -d '[:space:]"'\''')"

OCI_CLI_REGION="$(echo -n "$OCI_CLI_REGION" | tr -d '[:space:]"'\''')"

OCI_SUBNET_OCID="${OCI_SUBNET_OCID#*subnet=}"
OCI_SUBNET_OCID="${OCI_SUBNET_OCID#*subnet:}"
OCI_SUBNET_OCID="${OCI_SUBNET_OCID#*vcn=}"
OCI_SUBNET_OCID="${OCI_SUBNET_OCID#*vcn:}"
OCI_SUBNET_OCID="$(echo -n "$OCI_SUBNET_OCID" | tr -d '[:space:]"'\''')"

if [[ ! "$OCI_CLI_FINGERPRINT" =~ ^([[:xdigit:]]{2}:){15}[[:xdigit:]]{2}$ ]]; then
  echo "Fingerprint từ secret không khớp định dạng hex 16 cặp. Đang tự động trích xuất fingerprint từ OCI Private Key..."
  derived_fp="$(python3 -c "
import hashlib, sys
from cryptography.hazmat.primitives import serialization
try:
    k = serialization.load_pem_private_key(sys.stdin.read().encode(), password=None)
    der = k.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    d = hashlib.md5(der).hexdigest()
    print(':'.join(d[i:i+2] for i in range(0, 32, 2)))
except Exception:
    pass
" <<< "$OCI_CLI_KEY_CONTENT")"
  if [[ "$derived_fp" =~ ^([[:xdigit:]]{2}:){15}[[:xdigit:]]{2}$ ]]; then
    echo "Đã tự động tính toán Fingerprint thành công từ Private Key!"
    OCI_CLI_FINGERPRINT="$derived_fp"
  fi
fi

export OCI_CLI_USER OCI_CLI_TENANCY OCI_CLI_FINGERPRINT OCI_CLI_REGION OCI_SUBNET_OCID

[[ "$OCI_CLI_REGION" == ap-singapore-2 ]] || fail 'Chỉ cho phép ap-singapore-2'
[[ "$OCI_CLI_USER" == ocid1.user.* ]] || fail 'User OCID không hợp lệ'
[[ "$OCI_CLI_TENANCY" == ocid1.tenancy.* ]] || fail 'Tenancy OCID không hợp lệ'
[[ "$OCI_SUBNET_OCID" == ocid1.subnet.* || "$OCI_SUBNET_OCID" == ocid1.vcn.* ]] || fail 'Subnet OCID không hợp lệ'
[[ "$OCI_CLI_FINGERPRINT" =~ ^([[:xdigit:]]{2}:){15}[[:xdigit:]]{2}$ ]] || fail 'Fingerprint không hợp lệ'
[[ "$OCI_CLI_KEY_CONTENT" == *'PRIVATE KEY-----'* ]] || fail 'API key phải là PEM private key'

# E2.1.Micro configuration (Fixed shape: 1 OCPU / 1 GB RAM, AMD x86_64)
readonly shape='VM.Standard.E2.1.Micro' name='oracle-free-e2-micro'
readonly compartment="${OCI_COMPARTMENT_OCID:-$OCI_CLI_TENANCY}"
[[ "$compartment" == ocid1.compartment.* || "$compartment" == ocid1.tenancy.* ]] || fail 'Compartment OCID không hợp lệ'
readonly tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
printf '%s\n' "$OCI_SSH_PUBLIC_KEY" > "$tmp/ssh.pub"
ssh-keygen -l -f "$tmp/ssh.pub" >/dev/null 2>&1 || fail 'SSH public key không hợp lệ'

cli() { oci --region ap-singapore-2 --auth api_key --output json "$@"; }
cli compute instance list --compartment-id "$compartment" --display-name "$name" --all > "$tmp/instances.json"
id="$(jq -r --arg name "$name" '[.data[] | select(."display-name" == $name and ."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING")][0].id // empty' "$tmp/instances.json")"
result=exists
if [[ -z "$id" ]]; then
  if [[ "$OCI_SUBNET_OCID" == ocid1.vcn.* ]]; then
    echo "Phát hiện VCN OCID, đang tự động tìm public subnet trong VCN..."
    subnet_id="$(cli network subnet list --compartment-id "$compartment" --vcn-id "$OCI_SUBNET_OCID" --all | jq -r '[.data[] | select(.["prohibit-public-ip-on-vnic"] == false and .["lifecycle-state"] == "AVAILABLE")][0].id // empty')"
    [[ -n "$subnet_id" ]] || fail 'Không tìm thấy public subnet AVAILABLE nào trong VCN này'
    OCI_SUBNET_OCID="$subnet_id"
  fi
  cli network subnet get --subnet-id "$OCI_SUBNET_OCID" > "$tmp/subnet.json"
  [[ "$(jq -r '.data."prohibit-public-ip-on-vnic"' "$tmp/subnet.json")" == false ]] || fail 'Subnet không cho phép Public IPv4'

  # Find eligible Ubuntu x86_64 image compatible with VM.Standard.E2.1.Micro
  cli compute image list --compartment-id "$compartment" --operating-system 'Canonical Ubuntu' --operating-system-version '24.04' --shape "$shape" --all > "$tmp/images.json"
  image="$(jq -r '[.data[] | select(."lifecycle-state" == "AVAILABLE") | select(."display-name" | test("minimal"; "i") | not) | select(."display-name" | test("x86_64|amd64"; "i"))] | sort_by(."time-created") | last | .id // empty' "$tmp/images.json")"
  if [[ -z "$image" ]]; then
    echo "Không tìm thấy image Ubuntu 24.04 x86_64, đang kiểm tra tất cả phiên bản Ubuntu tương thích..."
    cli compute image list --compartment-id "$compartment" --operating-system 'Canonical Ubuntu' --shape "$shape" --all > "$tmp/images.json"
    image="$(jq -r '[.data[] | select(."lifecycle-state" == "AVAILABLE") | select(."display-name" | test("minimal"; "i") | not) | select(."display-name" | test("x86_64|amd64"; "i"))] | sort_by(."time-created") | last | .id // empty' "$tmp/images.json")"
  fi
  [[ -n "$image" ]] || fail 'Không tìm thấy image Ubuntu x86_64 AVAILABLE phù hợp cho VM.Standard.E2.1.Micro'

  cli iam availability-domain list --compartment-id "$OCI_CLI_TENANCY" > "$tmp/ads.json"
  ad="$(jq -r '.data[0].name // empty' "$tmp/ads.json")"
  [[ -n "$ad" ]] || fail 'Không tìm thấy Availability Domain'

  echo "Đang thử tạo E2.1.Micro (1 OCPU AMD / 1 GB RAM)..."
  # VM.Standard.E2.1.Micro is a fixed shape, so DO NOT pass --shape-config
  if cli compute instance launch --availability-domain "$ad" --compartment-id "$compartment" \
    --shape "$shape" \
    --image-id "$image" --subnet-id "$OCI_SUBNET_OCID" --display-name "$name" \
    --ssh-authorized-keys-file "$tmp/ssh.pub" --assign-public-ip true \
    > "$tmp/launch.json" 2> "$tmp/error"; then
    id="$(jq -r '.data.id // empty' "$tmp/launch.json")"
    [[ -n "$id" ]] || fail 'Launch không trả Instance OCID; kiểm tra Console trước khi chạy lại'
    result=created
  else
    combine="$tmp/error_all"
    cat "$tmp/error" "$tmp/launch.json" > "$combine" 2>/dev/null || true
    if grep -Eiq 'out of (host )?capacity|insufficient capacity|capacity unavailable|host capacity|out of capacity' "$combine"; then
      echo 'E2.1.Micro vẫn đang hết host capacity (Oracle chưa có tài nguyên trống). Sẽ tự động thử lại ở chu kỳ kế tiếp.'
      output result capacity
      exit 0
    fi
    if grep -Eiq 'TooManyRequests|429' "$combine"; then
      echo 'Oracle tạm thời giới hạn tần suất API (429 TooManyRequests). Sẽ tự động thử lại ở chu kỳ kế tiếp.'
      output result capacity
      exit 0
    fi
    echo "--- CHI TIẾT PHẢN HỒI TỪ ORACLE OCI ---" >&2
    cat "$combine" >&2
    echo "--------------------------------------" >&2
    fail 'Launch thất bại; xem chi tiết lỗi bên trên.'
  fi
fi

output instance_id "$id"
output result "$result"
echo "Instance OCID: $id ($result)"
state=UNKNOWN
if cli compute instance get --instance-id "$id" --wait-for-state RUNNING --max-wait-seconds 600 --wait-interval-seconds 15 > "$tmp/state.json" 2> "$tmp/wait-error"; then
  state="$(jq -r '.data."lifecycle-state"' "$tmp/state.json")"
else
  echo '::warning::Chưa xác nhận RUNNING sau khi chờ. Không tạo thêm VM; kiểm tra OCI Console.'
  if cli compute instance get --instance-id "$id" > "$tmp/state.json"; then
    state="$(jq -r '.data."lifecycle-state"' "$tmp/state.json")"
  fi
fi

ip=''
if cli compute instance list-vnics --instance-id "$id" > "$tmp/vnics.json"; then
  ip="$(jq -r '[.data[] | select(."is-primary" == true)][0]."public-ip" // empty' "$tmp/vnics.json")"
fi
output public_ip "$ip"
output lifecycle_state "$state"
echo "Lifecycle: $state; Public IPv4: ${ip:-Chưa lấy được}"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '### Oracle E2.1.Micro: %s\n\n- Instance: `%s`\n- Region: ap-singapore-2\n- Shape: VM.Standard.E2.1.Micro\n- CPU / RAM: 1 OCPU AMD / 1 GB RAM\n- Instance OCID: `%s`\n- Lifecycle: %s\n- Public IPv4: %s\n' "$result" "$name" "$id" "$state" "${ip:-Chưa lấy được}" >> "$GITHUB_STEP_SUMMARY"
fi
