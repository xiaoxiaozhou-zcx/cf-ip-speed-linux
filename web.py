#!/usr/bin/env python3
"""
Cloudflare IP 优选助手 - Web 管理面板
基于原项目: https://github.com/10000ge10000/cf-ip-speed-panel
"""

import json
import os
import subprocess
import threading
import time
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

INSTALL_DIR = "/opt/cf-ip-speed"

# 检测飞牛系统
import glob as _glob
if not os.path.exists(INSTALL_DIR):
    if os.path.isdir("/vol1/docker"):
        INSTALL_DIR = "/vol1/docker/cf-ip-speed"
    elif os.path.isdir("/vol1"):
        INSTALL_DIR = "/vol1/cf-ip-speed"
CONFIG_FILE = f"{INSTALL_DIR}/config"
LOG_FILE = f"{INSTALL_DIR}/cf-ip-speed.log"
CFST_LOG = f"{INSTALL_DIR}/cfst.log"
RESULT_CSV = f"{INSTALL_DIR}/result.csv"
LOCK_FILE = f"{INSTALL_DIR}/running.lock"
SCRIPT_PATH = f"{INSTALL_DIR}/cf-ip-speed.sh"

# ==================== 配置读写 ====================

def load_config():
    config = {}
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, _, value = line.partition('=')
                    config[key.strip()] = value.strip().strip('"').strip("'")
    return config

def save_config(config):
    content = "# Cloudflare IP 优选助手配置\n"
    keys = ['NICKNAME', 'DEVICE_ID', 'DEVICE_TOKEN', 'IP_VERSION', 'CFST_ARGS', 'UPLOAD_MAX_NODES']
    for k in keys:
        v = config.get(k, '')
        content += f'{k}="{v}"\n'
    with open(CONFIG_FILE, 'w') as f:
        f.write(content)
    os.chmod(CONFIG_FILE, 0o600)

# ==================== Cron 管理 ====================

def get_cron():
    try:
        result = subprocess.run(['crontab', '-l'], capture_output=True, text=True)
        for line in result.stdout.splitlines():
            if 'cf-ip-speed' in line:
                parts = line.strip().split()
                if len(parts) >= 6:
                    return ' '.join(parts[:5])
    except:
        pass
    return ''

def set_cron(expr):
    # 先移除旧的
    try:
        result = subprocess.run(['crontab', '-l'], capture_output=True, text=True)
        lines = [l for l in result.stdout.splitlines() if 'cf-ip-speed' not in l]
    except:
        lines = []
    
    if expr.strip():
        lines.append(f'{expr} {SCRIPT_PATH} run >> {LOG_FILE} 2>&1 # cf-ip-speed')
    
    proc = subprocess.run(['crontab', '-'], input='\n'.join(lines) + '\n',
                          capture_output=True, text=True)
    return proc.returncode == 0

# ==================== 状态 ====================

def is_running():
    if os.path.exists(LOCK_FILE):
        try:
            with open(LOCK_FILE) as f:
                pid = int(f.read().strip())
            os.kill(pid, 0)
            return True
        except:
            pass
    return False

def get_status():
    config = load_config()
    cron = get_cron()
    running = is_running()
    
    # 最近的日志
    recent_logs = ''
    if os.path.exists(LOG_FILE):
        with open(LOG_FILE) as f:
            lines = f.readlines()
            recent_logs = ''.join(lines[-20:])
    
    # 最近的 cfst 日志
    cfst_logs = ''
    if os.path.exists(CFST_LOG):
        with open(CFST_LOG) as f:
            lines = f.readlines()
            cfst_logs = ''.join(lines[-30:])
    
    # 测速结果
    result_data = []
    if os.path.exists(RESULT_CSV):
        with open(RESULT_CSV) as f:
            lines = f.readlines()
            for line in lines[1:51]:  # 跳过表头，最多50条
                parts = line.strip().split(',')
                if len(parts) >= 6:
                    result_data.append({
                        'ip': parts[0],
                        'port': parts[1],
                        'latency': parts[2],
                        'speed': parts[3],
                        'loss': parts[4],
                        'colo': parts[5] if len(parts) > 5 else ''
                    })
    
    return {
        'nickname': config.get('NICKNAME', ''),
        'device_id': config.get('DEVICE_ID', ''),
        'device_token': config.get('DEVICE_TOKEN', ''),
        'ip_version': config.get('IP_VERSION', 'v4'),
        'cfst_args': config.get('CFST_ARGS', '-n 60 -t 4 -dn 8 -dt 15 -tlr 0 -p 8'),
        'upload_max_nodes': config.get('UPLOAD_MAX_NODES', '50'),
        'cron': cron,
        'running': running,
        'recent_logs': recent_logs,
        'cfst_logs': cfst_logs,
        'result_data': result_data,
        'cfst_installed': os.path.exists('/usr/local/bin/cfst'),
        'registered': bool(config.get('DEVICE_ID', ''))
    }

# ==================== 运行测速 ====================

def run_speedtest():
    if is_running():
        return False, "测速正在运行中"
    def _run():
        subprocess.run(['bash', SCRIPT_PATH, 'run'],
                       capture_output=True, text=True)
    t = threading.Thread(target=_run, daemon=True)
    t.start()
    return True, "测速已启动"

def run_register(nickname):
    config = load_config()
    config['NICKNAME'] = nickname
    # 清除旧凭据重新注册
    config['DEVICE_ID'] = ''
    config['DEVICE_TOKEN'] = ''
    save_config(config)
    
    result = subprocess.run(['bash', SCRIPT_PATH, 'register'],
                           capture_output=True, text=True, timeout=30)
    return result.returncode == 0, result.stdout + result.stderr

# ==================== HTML ====================

HTML_TEMPLATE = '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Cloudflare IP 优选助手</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #e2e8f0; min-height: 100vh; }
.header { background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%); border-bottom: 1px solid #334155; padding: 16px 24px; display: flex; align-items: center; gap: 12px; }
.header img { width: 36px; height: 36px; }
.header h1 { font-size: 20px; font-weight: 600; color: #f8fafc; }
.header .badge { font-size: 11px; padding: 2px 8px; border-radius: 12px; font-weight: 500; }
.badge-ok { background: #065f46; color: #6ee7b7; }
.badge-err { background: #7f1d1d; color: #fca5a5; }
.badge-run { background: #1e40af; color: #93c5fd; animation: pulse 1.5s infinite; }
@keyframes pulse { 0%,100%{opacity:1} 50%{opacity:.5} }
.container { max-width: 1200px; margin: 0 auto; padding: 20px; }
.tabs { display: flex; gap: 4px; margin-bottom: 20px; border-bottom: 1px solid #334155; padding-bottom: 0; }
.tab { padding: 10px 20px; cursor: pointer; border-bottom: 2px solid transparent; color: #94a3b8; font-size: 14px; font-weight: 500; transition: all .2s; }
.tab:hover { color: #e2e8f0; }
.tab.active { color: #3b82f6; border-bottom-color: #3b82f6; }
.tab-content { display: none; }
.tab-content.active { display: block; }
.card { background: #1e293b; border: 1px solid #334155; border-radius: 12px; padding: 20px; margin-bottom: 16px; }
.card h3 { font-size: 14px; color: #94a3b8; margin-bottom: 12px; font-weight: 500; text-transform: uppercase; letter-spacing: .5px; }
.stat-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; }
.stat { text-align: center; padding: 16px; background: #0f172a; border-radius: 8px; }
.stat .value { font-size: 28px; font-weight: 700; color: #f8fafc; }
.stat .label { font-size: 12px; color: #64748b; margin-top: 4px; }
.form-group { margin-bottom: 16px; }
.form-group label { display: block; font-size: 13px; color: #94a3b8; margin-bottom: 6px; font-weight: 500; }
.form-group input, .form-group select, .form-group textarea {
    width: 100%; padding: 10px 12px; background: #0f172a; border: 1px solid #334155;
    border-radius: 8px; color: #e2e8f0; font-size: 14px; font-family: inherit;
}
.form-group input:focus, .form-group textarea:focus { outline: none; border-color: #3b82f6; }
.form-group textarea { resize: vertical; min-height: 80px; }
.btn { padding: 10px 20px; border: none; border-radius: 8px; font-size: 14px; font-weight: 600; cursor: pointer; transition: all .2s; }
.btn-primary { background: #3b82f6; color: white; }
.btn-primary:hover { background: #2563eb; }
.btn-danger { background: #ef4444; color: white; }
.btn-danger:hover { background: #dc2626; }
.btn-success { background: #10b981; color: white; }
.btn-success:hover { background: #059669; }
.btn:disabled { opacity: .5; cursor: not-allowed; }
.btn-row { display: flex; gap: 8px; flex-wrap: wrap; }
.log-box { background: #0f172a; border: 1px solid #334155; border-radius: 8px; padding: 16px; font-family: "JetBrains Mono", "Fira Code", monospace; font-size: 13px; line-height: 1.6; max-height: 500px; overflow-y: auto; white-space: pre-wrap; word-break: break-all; color: #94a3b8; }
table { width: 100%; border-collapse: collapse; font-size: 14px; }
th { text-align: left; padding: 10px 12px; background: #0f172a; color: #64748b; font-weight: 600; font-size: 12px; text-transform: uppercase; letter-spacing: .5px; border-bottom: 1px solid #334155; }
td { padding: 10px 12px; border-bottom: 1px solid #1e293b; color: #e2e8f0; }
tr:hover td { background: #1e293b; }
.speed-bar { display: inline-block; height: 6px; border-radius: 3px; background: #3b82f6; min-width: 4px; }
.toast { position: fixed; top: 20px; right: 20px; padding: 12px 20px; border-radius: 8px; font-size: 14px; font-weight: 500; z-index: 1000; animation: slideIn .3s ease; }
.toast-ok { background: #065f46; color: #6ee7b7; border: 1px solid #10b981; }
.toast-err { background: #7f1d1d; color: #fca5a5; border: 1px solid #ef4444; }
@keyframes slideIn { from{transform:translateX(100%);opacity:0} to{transform:translateX(0);opacity:1} }
.cron-preview { font-size: 12px; color: #64748b; margin-top: 4px; }
.two-col { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
@media (max-width: 768px) { .two-col { grid-template-columns: 1fr; } .stat-grid { grid-template-columns: repeat(2, 1fr); } }
</style>
</head>
<body>
<div class="header">
  <svg width="36" height="36" viewBox="0 0 36 36" fill="none"><circle cx="18" cy="18" r="18" fill="#3b82f6"/><path d="M18 8L24 14H20V22H16V14H12L18 8Z" fill="white" opacity=".9"/><path d="M10 26H26V28H10V26Z" fill="white" opacity=".7"/></svg>
  <h1>Cloudflare IP 优选助手</h1>
  <span id="statusBadge" class="badge"></span>
</div>

<div class="container">
  <div class="tabs">
    <div class="tab active" data-tab="dashboard">📊 仪表盘</div>
    <div class="tab" data-tab="results">🏆 测速结果</div>
    <div class="tab" data-tab="settings">⚙️ 设置</div>
    <div class="tab" data-tab="logs">📋 日志</div>
  </div>

  <!-- 仪表盘 -->
  <div id="dashboard" class="tab-content active">
    <div class="stat-grid" style="margin-bottom:16px">
      <div class="stat"><div class="value" id="s_nickname">-</div><div class="label">昵称</div></div>
      <div class="stat"><div class="value" id="s_status">-</div><div class="label">状态</div></div>
      <div class="stat"><div class="value" id="s_cfst">-</div><div class="label">cfst</div></div>
      <div class="stat"><div class="value" id="s_registered">-</div><div class="label">设备</div></div>
    </div>
    <div class="two-col">
      <div class="card">
        <h3>⏰ 定时任务</h3>
        <div id="cronDisplay" style="font-size:18px;color:#f8fafc;margin-bottom:12px">未设置</div>
        <div class="cron-preview" id="cronPreview"></div>
        <div style="margin-top:12px">
          <div class="btn-row">
            <button class="btn btn-primary" onclick="quickCron('0 3 * * *')">每天 3:00</button>
            <button class="btn btn-primary" onclick="quickCron('0 3,15 * * *')">每天 3:00 & 15:00</button>
            <button class="btn btn-primary" onclick="quickCron('0 */6 * * *')">每 6 小时</button>
            <button class="btn btn-danger" onclick="quickCron('')">移除</button>
          </div>
        </div>
      </div>
      <div class="card">
        <h3>🚀 操作</h3>
        <div class="btn-row" style="flex-direction:column">
          <button class="btn btn-success" id="btnRun" onclick="doRun()" style="width:100%;padding:14px;font-size:16px">▶ 立即测速</button>
          <button class="btn btn-primary" onclick="doRefresh()" style="width:100%">🔄 刷新状态</button>
        </div>
      </div>
    </div>
  </div>

  <!-- 测速结果 -->
  <div id="results" class="tab-content">
    <div class="card">
      <h3>🏆 最新测速结果 <span id="resultCount" style="color:#3b82f6"></span></h3>
      <div style="overflow-x:auto">
        <table>
          <thead><tr><th>#</th><th>IP</th><th>端口</th><th>延迟</th><th>速度</th><th>丢包</th><th>数据中心</th><th>速度图</th></tr></thead>
          <tbody id="resultTable"></tbody>
        </table>
      </div>
      <div id="noResult" style="text-align:center;padding:40px;color:#64748b;display:none">暂无测速结果</div>
    </div>
  </div>

  <!-- 设置 -->
  <div id="settings" class="tab-content">
    <div class="two-col">
      <div class="card">
        <h3>👤 设备设置</h3>
        <div class="form-group">
          <label>昵称</label>
          <input id="cfg_nickname" placeholder="输入你的昵称">
        </div>
        <div class="form-group">
          <label>IP 版本</label>
          <select id="cfg_ip_version">
            <option value="v4">IPv4</option>
            <option value="v6">IPv6</option>
          </select>
        </div>
        <div class="btn-row">
          <button class="btn btn-primary" onclick="doSave()">💾 保存配置</button>
          <button class="btn btn-success" onclick="doRegister()">📝 注册设备</button>
        </div>
      </div>
      <div class="card">
        <h3>⚡ 测速参数</h3>
        <div class="form-group">
          <label>cfst 参数</label>
          <input id="cfg_cfst_args" placeholder="-n 60 -t 4 -dn 8 -dt 15 -tlr 0 -p 8">
          <div class="cron-preview">-n 线程数 -t 测速次数 -dn 下载数量 -dt 下载时间 -tlr 丢包率上限 -p 显示数量</div>
        </div>
        <div class="form-group">
          <label>上传节点数上限</label>
          <input id="cfg_upload_max" type="number" min="1" max="100" value="50">
        </div>
        <div class="form-group">
          <label>自定义定时 (cron 表达式)</label>
          <input id="cfg_cron" placeholder="0 3 * * *">
          <div class="cron-preview">格式: 分 时 日 月 周 (例: 0 3 * * * = 每天凌晨3点)</div>
        </div>
        <div class="btn-row">
          <button class="btn btn-primary" onclick="doSaveAll()">💾 保存全部</button>
        </div>
      </div>
    </div>
    <div class="card">
      <h3>🔑 设备凭据</h3>
      <div class="form-group">
        <label>Device ID</label>
        <input id="cfg_device_id" readonly style="color:#64748b">
      </div>
      <div class="form-group">
        <label>Device Token</label>
        <input id="cfg_device_token" type="password" readonly style="color:#64748b">
      </div>
      <div class="cron-preview">设备凭据在注册后自动保存，无需手动修改</div>
    </div>
  </div>

  <!-- 日志 -->
  <div id="logs" class="tab-content">
    <div class="card">
      <h3>📋 上传日志</h3>
      <div class="log-box" id="uploadLog">加载中...</div>
    </div>
    <div class="card">
      <h3>⚡ cfst 测速日志</h3>
      <div class="log-box" id="cfstLog">加载中...</div>
    </div>
  </div>
</div>

<script>
let refreshing = false;

function showToast(msg, ok) {
  const d = document.createElement('div');
  d.className = 'toast ' + (ok ? 'toast-ok' : 'toast-err');
  d.textContent = msg;
  document.body.appendChild(d);
  setTimeout(() => d.remove(), 3000);
}

// Tab 切换
document.querySelectorAll('.tab').forEach(t => {
  t.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach(x => x.classList.remove('active'));
    document.querySelectorAll('.tab-content').forEach(x => x.classList.remove('active'));
    t.classList.add('active');
    document.getElementById(t.dataset.tab).classList.add('active');
  });
});

function refresh() {
  if (refreshing) return;
  refreshing = true;
  fetch('/api/status')
    .then(r => r.json())
    .then(d => {
      // 状态卡片
      document.getElementById('s_nickname').textContent = d.nickname || '未设置';
      document.getElementById('s_cfst').textContent = d.cfst_installed ? '✅ 已安装' : '❌ 未安装';
      document.getElementById('s_registered').textContent = d.registered ? '✅ 已注册' : '❌ 未注册';
      
      const badge = document.getElementById('statusBadge');
      if (d.running) {
        document.getElementById('s_status').textContent = '🔄 测速中';
        badge.textContent = '运行中';
        badge.className = 'badge badge-run';
        document.getElementById('btnRun').disabled = true;
      } else {
        document.getElementById('s_status').textContent = '🟢 就绪';
        badge.textContent = d.registered ? '就绪' : '未注册';
        badge.className = 'badge ' + (d.registered ? 'badge-ok' : 'badge-err');
        document.getElementById('btnRun').disabled = false;
      }

      // 定时任务
      document.getElementById('cronDisplay').textContent = d.cron || '未设置';
      document.getElementById('cronPreview').textContent = d.cron ? cronExplain(d.cron) : '';

      // 测速结果
      const tbody = document.getElementById('resultTable');
      const noResult = document.getElementById('noResult');
      if (d.result_data && d.result_data.length > 0) {
        tbody.innerHTML = '';
        noResult.style.display = 'none';
        document.getElementById('resultCount').textContent = `(${d.result_data.length} 个节点)`;
        const maxSpeed = Math.max(...d.result_data.map(r => parseFloat(r.speed) || 0));
        d.result_data.forEach((r, i) => {
          const speed = parseFloat(r.speed) || 0;
          const barW = maxSpeed > 0 ? (speed / maxSpeed * 120) : 0;
          tbody.innerHTML += `<tr>
            <td style="color:#64748b">${i+1}</td>
            <td style="font-family:monospace;color:#3b82f6">${r.ip}</td>
            <td>${r.port}</td>
            <td>${r.latency} ms</td>
            <td style="color:#10b981;font-weight:600">${r.speed} MB/s</td>
            <td>${r.loss}%</td>
            <td style="color:#f59e0b">${r.colo}</td>
            <td><span class="speed-bar" style="width:${barW}px"></span></td>
          </tr>`;
        });
      } else {
        tbody.innerHTML = '';
        noResult.style.display = 'block';
        document.getElementById('resultCount').textContent = '';
      }

      // 日志
      document.getElementById('uploadLog').textContent = d.recent_logs || '暂无日志';
      document.getElementById('cfstLog').textContent = d.cfst_logs || '暂无日志';

      // 设置表单
      document.getElementById('cfg_nickname').value = d.nickname || '';
      document.getElementById('cfg_ip_version').value = d.ip_version || 'v4';
      document.getElementById('cfg_cfst_args').value = d.cfst_args || '';
      document.getElementById('cfg_upload_max').value = d.upload_max_nodes || '50';
      document.getElementById('cfg_cron').value = d.cron || '';
      document.getElementById('cfg_device_id').value = d.device_id || '';
      document.getElementById('cfg_device_token').value = d.device_token || '';
    })
    .catch(e => showToast('刷新失败: ' + e, false))
    .finally(() => { refreshing = false; });
}

function cronExplain(expr) {
  const parts = expr.split(/\\s+/);
  if (parts.length < 5) return '';
  const [min, hour, dom, mon, dow] = parts;
  let desc = '';
  if (dom === '*' && mon === '*' && dow === '*') {
    if (hour.includes('*/')) desc = `每 ${hour.replace('*/','')} 小时执行`;
    else if (hour.includes(',')) desc = `每天 ${hour.replace(/,/g, ' 和 ')} 点的第 ${min} 分钟执行`;
    else desc = `每天 ${hour}:${min.padStart(2,'0')} 执行`;
  } else {
    desc = `${expr}`;
  }
  return desc;
}

function doRefresh() { refresh(); showToast('已刷新', true); }

function doRun() {
  fetch('/api/run', {method:'POST'})
    .then(r => r.json())
    .then(d => {
      showToast(d.message || (d.ok ? '测速已启动' : '启动失败'), d.ok);
      if (d.ok) { setTimeout(refresh, 2000); setTimeout(refresh, 5000); }
    })
    .catch(e => showToast('请求失败', false));
}

function doSave() {
  const data = {
    nickname: document.getElementById('cfg_nickname').value,
    ip_version: document.getElementById('cfg_ip_version').value,
  };
  fetch('/api/config', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(data)})
    .then(r => r.json())
    .then(d => { showToast(d.message || '已保存', d.ok); refresh(); })
    .catch(e => showToast('保存失败', false));
}

function doSaveAll() {
  const data = {
    nickname: document.getElementById('cfg_nickname').value,
    ip_version: document.getElementById('cfg_ip_version').value,
    cfst_args: document.getElementById('cfg_cfst_args').value,
    upload_max_nodes: document.getElementById('cfg_upload_max').value,
    cron: document.getElementById('cfg_cron').value,
  };
  fetch('/api/config', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(data)})
    .then(r => r.json())
    .then(d => { showToast(d.message || '已保存', d.ok); refresh(); })
    .catch(e => showToast('保存失败', false));
}

function doRegister() {
  const nickname = document.getElementById('cfg_nickname').value;
  if (!nickname) { showToast('请先填写昵称', false); return; }
  showToast('正在注册...', true);
  fetch('/api/register', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({nickname})})
    .then(r => r.json())
    .then(d => { showToast(d.message || (d.ok ? '注册成功' : '注册失败'), d.ok); refresh(); })
    .catch(e => showToast('注册失败', false));
}

function quickCron(expr) {
  fetch('/api/config', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({cron:expr})})
    .then(r => r.json())
    .then(d => { showToast(d.message || '已更新', d.ok); refresh(); })
    .catch(e => showToast('设置失败', false));
}

// 自动刷新
refresh();
setInterval(refresh, 10000);
</script>
</body>
</html>'''

# ==================== HTTP Handler ====================

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # 静默日志

    def _json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', len(body))
        self.end_headers()
        self.wfile.write(body)

    def _html(self, html, status=200):
        body = html.encode()
        self.send_response(status)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', len(body))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == '/' or path == '/index.html':
            self._html(HTML_TEMPLATE)
        elif path == '/api/status':
            self._json(get_status())
        else:
            self._json({'error': 'Not Found'}, 404)

    def do_POST(self):
        path = urlparse(self.path).path
        content_len = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_len).decode() if content_len else '{}'
        try:
            data = json.loads(body) if body else {}
        except:
            data = {}

        if path == '/api/run':
            ok, msg = run_speedtest()
            self._json({'ok': ok, 'message': msg})

        elif path == '/api/config':
            config = load_config()
            for k in ['nickname', 'ip_version', 'cfst_args', 'upload_max_nodes']:
                if k in data:
                    config[k.upper()] = data[k]
            # cron 单独处理
            if 'cron' in data:
                set_cron(data['cron'])
            save_config(config)
            self._json({'ok': True, 'message': '配置已保存'})

        elif path == '/api/register':
            nickname = data.get('nickname', '')
            if not nickname:
                self._json({'ok': False, 'message': '昵称不能为空'})
                return
            ok, msg = run_register(nickname)
            self._json({'ok': ok, 'message': msg})

        else:
            self._json({'error': 'Not Found'}, 404)


def main():
    import argparse
    parser = argparse.ArgumentParser(description='Cloudflare IP 优选助手 Web 面板')
    parser.add_argument('--host', default='0.0.0.0', help='监听地址 (默认 0.0.0.0)')
    parser.add_argument('--port', type=int, default=8899, help='监听端口 (默认 8899)')
    args = parser.parse_args()

    # 确保安装目录存在
    os.makedirs(INSTALL_DIR, exist_ok=True)

    server = HTTPServer((args.host, args.port), Handler)
    print(f'Cloudflare IP 优选助手 Web 面板')
    print(f'监听: http://{args.host}:{args.port}')
    print(f'按 Ctrl+C 退出')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n已停止')
        server.server_close()

if __name__ == '__main__':
    main()
