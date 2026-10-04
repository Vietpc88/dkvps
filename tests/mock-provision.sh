#!/usr/bin/env bash
# Offline behavior checks. No OCI request, private key or account is needed.
set -Eeuo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/oci" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$MOCK_CALLS"
case "$*" in
  *'compute instance list-vnics'*) echo '{"data":[{"is-primary":true,"public-ip":"192.0.2.1"}]}' ;;
  *'compute instance list '*)
    if [[ "$MOCK_CASE" == exists ]]; then
      echo '{"data":[{"id":"ocid1.instance.mock","display-name":"oracle-free-a1","lifecycle-state":"RUNNING"}]}'
    else
      echo '{"data":[{"id":"old","display-name":"oracle-free-a1","lifecycle-state":"TERMINATED"}]}'
    fi ;;
  *'network subnet get'*) echo '{"data":{"prohibit-public-ip-on-vnic":false}}' ;;
  *'compute image list'*)
    echo '{"data":[{"id":"minimal","display-name":"Ubuntu-Minimal-aarch64","lifecycle-state":"AVAILABLE","time-created":"2026-10-01"},{"id":"x86","display-name":"Ubuntu-x86_64","lifecycle-state":"AVAILABLE","time-created":"2026-10-01"},{"id":"old-arm","display-name":"Ubuntu-aarch64","lifecycle-state":"AVAILABLE","time-created":"2026-01-01"},{"id":"new-arm","display-name":"Ubuntu-aarch64","lifecycle-state":"AVAILABLE","time-created":"2026-09-01"}]}' ;;
  *'iam availability-domain list'*) echo '{"data":[{"name":"mock-ad"}]}' ;;
  *'compute instance launch'*)
    case "$MOCK_CASE" in
      capacity) echo 'ServiceError: Out of host capacity' >&2; exit 1 ;;
      error) echo 'ServiceError: NotAuthorizedOrNotFound' >&2; exit 1 ;;
      *) echo '{"data":{"id":"ocid1.instance.mock"}}' ;;
    esac ;;
  *'compute instance get'*)
    if [[ "$MOCK_CASE" == wait-timeout && "$*" == *'--wait-for-state'* ]]; then
      echo 'Timeout' >&2; exit 2
    fi
    echo '{"data":{"lifecycle-state":"RUNNING"}}' ;;
  *) echo 'Unexpected mock command' >&2; exit 1 ;;
esac
MOCK
chmod +x "$tmp/bin/oci"
export PATH="$tmp/bin:$PATH"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/ssh"
export OCI_CLI_USER=ocid1.user.mock OCI_CLI_TENANCY=ocid1.tenancy.mock
export OCI_CLI_FINGERPRINT=00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00
export OCI_CLI_KEY_CONTENT='-----BEGIN PRIVATE KEY----- mock -----END PRIVATE KEY-----'
export OCI_CLI_REGION=ap-singapore-2 OCI_SUBNET_OCID=ocid1.subnet.mock
export OCI_SSH_PUBLIC_KEY="$(cat "$tmp/ssh.pub")"
export MOCK_CALLS="$tmp/calls" GITHUB_OUTPUT="$tmp/output" GITHUB_STEP_SUMMARY="$tmp/summary"
for scenario in exists capacity created error wait-timeout wrong-region; do
  export MOCK_CASE="$scenario"
  : > "$MOCK_CALLS"; : > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
  export OCI_CLI_REGION=ap-singapore-2
  [[ "$scenario" != wrong-region ]] || export OCI_CLI_REGION=ap-singapore-1
  status=0
  bash "$root/scripts/try-oracle-a1.sh" > "$tmp/log" 2>&1 || status=$?
  case "$scenario" in
    error|wrong-region) [[ "$status" != 0 ]]; grep -qx 'result=error' "$GITHUB_OUTPUT" ;;
    wait-timeout) [[ "$status" == 0 ]]; grep -qx 'result=created' "$GITHUB_OUTPUT" ;;
    *) [[ "$status" == 0 ]]; grep -qx "result=$scenario" "$GITHUB_OUTPUT" ;;
  esac
  if [[ "$scenario" == exists || "$scenario" == wrong-region ]]; then
    ! grep -q 'compute instance launch' "$MOCK_CALLS"
  elif [[ "$scenario" == created || "$scenario" == wait-timeout ]]; then
    [[ "$(grep -c 'compute instance launch' "$MOCK_CALLS")" == 1 ]]
    grep -q -- '--image-id new-arm' "$MOCK_CALLS"
    grep -q -- '--shape VM.Standard.A1.Flex' "$MOCK_CALLS"
    grep -q -- '"ocpus":2,"memoryInGBs":12' "$MOCK_CALLS"
    grep -qx 'instance_id=ocid1.instance.mock' "$GITHUB_OUTPUT"
    grep -qx 'public_ip=192.0.2.1' "$GITHUB_OUTPUT"
  fi
  echo "PASS $scenario"
done
