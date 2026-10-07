"""Automated Dispatcher: Automatically triggers GitHub Actions provision workflows every 15 minutes."""
import json
import subprocess
import time
import urllib.request
import sys

REPO = 'Vietpc88/dkvps'

def get_token():
    try:
        p = subprocess.Popen(['git', 'credential', 'fill'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        out, _ = p.communicate('protocol=https\nhost=github.com\n\n')
        for line in out.splitlines():
            if line.startswith('password='):
                return line.split('=', 1)[1]
    except Exception as e:
        print(f"Lỗi đọc token: {e}", flush=True)
    return None

def get_active_workflows(token):
    url = f'https://api.github.com/repos/{REPO}/actions/workflows'
    req = urllib.request.Request(url, headers={'Authorization': f'token {token}', 'User-Agent': 'OracleDispatcher'})
    workflows = []
    with urllib.request.urlopen(req) as res:
        data = json.loads(res.read())
        for w in data.get('workflows', []):
            if w.get('state') == 'active' and any(k in w['path'] for k in ('oracle-a1-auto', 'oracle-e2-micro-auto')):
                workflows.append({'id': w['id'], 'name': w['name'], 'path': w['path']})
    return workflows

def trigger_workflow(token, workflow_id):
    url = f'https://api.github.com/repos/{REPO}/actions/workflows/{workflow_id}/dispatches'
    req = urllib.request.Request(
        url,
        data=json.dumps({'ref': 'main'}).encode('utf-8'),
        method='POST',
        headers={'Authorization': f'token {token}', 'User-Agent': 'OracleDispatcher', 'Content-Type': 'application/json'}
    )
    with urllib.request.urlopen(req) as res:
        return res.status

def check_latest_run(token, workflow_id):
    url = f'https://api.github.com/repos/{REPO}/actions/workflows/{workflow_id}/runs?per_page=1'
    req = urllib.request.Request(url, headers={'Authorization': f'token {token}', 'User-Agent': 'OracleDispatcher'})
    with urllib.request.urlopen(req) as res:
        data = json.loads(res.read())
        runs = data.get('workflow_runs', [])
        return runs[0] if runs else None

def main():
    interval_minutes = 15
    interval_seconds = interval_minutes * 60
    print("=" * 65, flush=True)
    print(f"=== TIẾN TRÌNH SĂN VPS TỰ ĐỘNG MỖI {interval_minutes} PHÚT (GITHUB ACTIONS) ===", flush=True)
    print("=" * 65, flush=True)
    
    token = get_token()
    if not token:
        print("Lỗi: Không tìm thấy GitHub token từ Git credentials.", flush=True)
        sys.exit(1)
        
    print(f"Repository: {REPO}", flush=True)
    print(f"Chu kỳ: {interval_minutes} phút/lần. Tiến trình đang chạy ngầm...\n", flush=True)
    
    while True:
        now_str = time.strftime("%Y-%m-%d %H:%M:%S")
        workflows = get_active_workflows(token)
        if not workflows:
            print(f"[{now_str}] Không có workflow nào đang active (có thể đã tạo thành công cả A1 và E2).", flush=True)
        else:
            for w in workflows:
                print(f"[{now_str}] Đang gửi yêu cầu săn: {w['name']}...", flush=True)
                try:
                    status = trigger_workflow(token, w['id'])
                    if status in (204, 200):
                        print(f"[{now_str}] -> Đã kích hoạt thành công {w['name']}!", flush=True)
                        time.sleep(5)
                        latest = check_latest_run(token, w['id'])
                        if latest:
                            print(f"[{now_str}] -> Lượt #{latest.get('run_number')} đang chạy: {latest.get('html_url')}", flush=True)
                    else:
                        print(f"[{now_str}] -> GitHub trả về mã HTTP: {status}", flush=True)
                except Exception as e:
                    print(f"[{now_str}] -> Gặp lỗi khi kích hoạt {w['name']}: {e}", flush=True)
                time.sleep(3)
                
        print(f"\n[{now_str}] Đang đếm ngược {interval_minutes} phút cho lượt săn tiếp theo...\n", flush=True)
        time.sleep(interval_seconds)

if __name__ == '__main__':
    main()
