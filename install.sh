#!/bin/bash
set -euo pipefail

# ============================================================
#  Cloudflare IP 优选助手 - Linux 通用版
#  适配飞牛系统(fnOS)、Debian、Ubuntu、CentOS 等
#  基于原项目: https://github.com/10000ge10000/cf-ip-speed-panel
# ============================================================

WORKER_URL="https://cf.6610000.xyz"
CFST_REPO="XIU2/CloudflareSpeedTest"
CFST_TAG="${CFST_TAG:-v2.3.5}"
CFST_BASE_URL="https://github.com/${CFST_REPO}/releases/download/${CFST_TAG}"

INSTALL_DIR="/opt/cf-ip-speed"

# 检测飞牛系统，自动调整安装路径
if [ -d /vol1 ] && [ ! -d /opt/cf-ip-speed ]; then
    # 飞牛系统，优先使用数据卷
    if [ -d /vol1/docker ]; then
        INSTALL_DIR="/vol1/docker/cf-ip-speed"
    elif [ -d /vol1 ]; then
        INSTALL_DIR="/vol1/cf-ip-speed"
    fi
fi
CONFIG_FILE="${INSTALL_DIR}/config"
IP_FILE="${INSTALL_DIR}/ip.txt"
LOG_FILE="${INSTALL_DIR}/cf-ip-speed.log"
CFST_LOG="${INSTALL_DIR}/cfst.log"
LOCK_FILE="${INSTALL_DIR}/running.lock"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[cf-ip-speed]${NC} $*"; }
warn()  { echo -e "${YELLOW}[cf-ip-speed]${NC} $*"; }
error() { echo -e "${RED}[cf-ip-speed]${NC} $*" >&2; }
fail()  { error "$*"; exit 1; }

# ==================== 工具函数 ====================

has_cmd() { command -v "$1" >/dev/null 2>&1; }

need_cmd() {
    has_cmd "$1" || fail "缺少命令: $1，请先安装"
}

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)   echo "arm64" ;;
        armv7*|armhf)    echo "armv7" ;;
        mips*)           echo "mips" ;;
        *)               fail "不支持的架构: $arch" ;;
    esac
}

detect_cfst_asset() {
    local arch="$1"
    case "$arch" in
        amd64) echo "cfst_linux_amd64.tar.gz" ;;
        arm64) echo "cfst_linux_arm64.tar.gz" ;;
        armv7) echo "cfst_linux_armv7.tar.gz" ;;
        mips)  echo "cfst_linux_mips.tar.gz" ;;
        *)     fail "不支持的架构: $arch" ;;
    esac
}

download() {
    local url="$1" output="$2"
    if has_cmd curl; then
        curl -fL --connect-timeout 30 --retry 3 --retry-delay 3 -o "$output" "$url"
    elif has_cmd wget; then
        wget --no-check-certificate -O "$output" "$url"
    else
        fail "缺少下载工具: 需要 curl 或 wget"
    fi
}

json_escape() {
    # 使用 python3 处理 JSON 转义，兼容中文等多字节字符
    if has_cmd python3; then
        python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip())[1:-1])"
    else
        sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r'
    fi
}

# ==================== 配置管理 ====================

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
# Cloudflare IP 优选助手配置
NICKNAME="${NICKNAME:-}"
DEVICE_ID="${DEVICE_ID:-}"
DEVICE_TOKEN="${DEVICE_TOKEN:-}"
IP_VERSION="${IP_VERSION:-v4}"
# cfst 参数，可自定义
CFST_ARGS="${CFST_ARGS:--n 60 -t 4 -dn 8 -dt 15 -tlr 0 -p 8}"
# 上传后保留的节点数量
UPLOAD_MAX_NODES="${UPLOAD_MAX_NODES:-50}"
EOF
    chmod 600 "$CONFIG_FILE"
}

# ==================== IP 段文件 ====================

create_ip_file() {
    if [ ! -f "$IP_FILE" ]; then
        info "创建默认 Cloudflare IP 段文件..."
        cat > "$IP_FILE" <<'IPEOF'
173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/12
172.64.0.0/17
172.64.128.0/18
172.64.192.0/19
172.64.224.0/22
172.64.229.0/24
172.64.230.0/23
172.64.232.0/21
172.64.240.0/21
172.64.248.0/21
172.65.0.0/16
172.66.0.0/16
172.67.0.0/16
131.0.72.0/22
IPEOF
    fi
}

# ==================== 安装 cfst ====================

install_cfst() {
    if has_cmd cfst && [ "${CFST_FORCE_INSTALL:-0}" != "1" ]; then
        info "已检测到 cfst: $(command -v cfst)，跳过安装"
        return 0
    fi

    need_cmd tar
    local arch asset tmp_dir archive
    arch="$(detect_arch)"
    asset="$(detect_cfst_asset "$arch")"
    tmp_dir="/tmp/cfst-install-$$"
    archive="${tmp_dir}/cfst.tar.gz"

    info "安装 cfst ${CFST_TAG} / ${asset} ..."
    mkdir -p "$tmp_dir"
    download "${CFST_BASE_URL}/${asset}" "$archive"
    tar -xzf "$archive" -C "$tmp_dir"

    local cfst_bin=""
    if [ -f "$tmp_dir/cfst" ]; then
        cfst_bin="$tmp_dir/cfst"
    else
        cfst_bin="$(find "$tmp_dir" -type f -name cfst 2>/dev/null | head -n 1)"
    fi
    [ -n "$cfst_bin" ] || fail "cfst 压缩包中未找到 cfst 二进制文件"

    chmod 755 "$cfst_bin"
    cp "$cfst_bin" /usr/local/bin/cfst
    chmod 755 /usr/local/bin/cfst
    rm -rf "$tmp_dir"

    info "cfst 安装完成: $(command -v cfst)"
}

# ==================== 设备注册 ====================

register_device() {
    load_config
    local nickname="$NICKNAME"
    local device_name
    device_name="$(hostname 2>/dev/null || echo 'linux')"

    if [ -n "$DEVICE_ID" ] && [ -n "$DEVICE_TOKEN" ]; then
        info "设备已注册: $DEVICE_ID"
        return 0
    fi

    if [ -z "$nickname" ]; then
        read -rp "请输入昵称: " nickname
        [ -n "$nickname" ] || fail "昵称不能为空"
    fi

    info "正在注册设备..."
    local response http_code
    response="$(curl -s -w '\n%{http_code}' -X POST "${WORKER_URL}/api/public/register" \
        -H "Content-Type: application/json" \
        -d "{\"nickname\":\"$(printf '%s' "$nickname" | json_escape)\",\"device_name\":\"$(printf '%s' "$device_name" | json_escape)\"}")"
    local http_code
    http_code="$(echo "$response" | tail -1)"
    response="$(echo "$response" | sed '$d')"

    if [ "$http_code" != "200" ]; then
        fail "注册失败 (HTTP $http_code): $response"
    fi

    local did dtoken
    did="$(echo "$response" | grep -o '"device_id":"[^"]*"' | head -1 | cut -d'"' -f4)"
    dtoken="$(echo "$response" | grep -o '"device_token":"[^"]*"' | head -1 | cut -d'"' -f4)"

    if [ -z "$did" ] || [ -z "$dtoken" ]; then
        fail "注册失败: $response"
    fi

    DEVICE_ID="$did"
    DEVICE_TOKEN="$dtoken"
    NICKNAME="$nickname"
    save_config

    info "注册成功! device_id: $DEVICE_ID"
    info "配置已保存到: $CONFIG_FILE"
}

# ==================== 网络检测 ====================

detect_direct() {
    local egress_meta egress_ip egress_region egress_city egress_country egress_org egress_asn
    local route_interface default_if warnings proxy_suspected

    default_if="$(ip route show default 2>/dev/null | awk '{ for (i=1; i<=NF; i++) if ($i=="dev") { print $(i+1); exit } }')"
    route_interface="$(ip route get 1.1.1.1 2>/dev/null | awk '{ for (i=1; i<=NF; i++) if ($i=="dev") { print $(i+1); exit } }')"

    egress_meta="$(curl -4 -fsS --max-time 10 https://ipinfo.io/json 2>/dev/null || true)"
    egress_ip="$(echo "$egress_meta" | grep -o '"ip":"[^"]*"' | head -1 | cut -d'"' -f4)"
    egress_region="$(echo "$egress_meta" | grep -o '"region":"[^"]*"' | head -1 | cut -d'"' -f4)"
    egress_city="$(echo "$egress_meta" | grep -o '"city":"[^"]*"' | head -1 | cut -d'"' -f4)"
    egress_country="$(echo "$egress_meta" | grep -o '"country":"[^"]*"' | head -1 | cut -d'"' -f4)"
    egress_org="$(echo "$egress_meta" | grep -o '"org":"[^"]*"' | head -1 | cut -d'"' -f4)"
    egress_asn="$(echo "$egress_org" | sed -n 's/^AS\([0-9][0-9]*\).*/\1/p')"

    if [ -z "$egress_ip" ]; then
        egress_ip="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    fi

    warnings=""
    proxy_suspected="false"

    case "$route_interface" in
        tun*|utun*|clash*|mihomo*|sing-box*|wg*|tailscale*|zerotier*|nikki*)
            proxy_suspected="true"
            warnings="路由出口疑似代理接口"
            ;;
    esac

    if echo "$egress_org" | grep -Eiq 'alibaba|amazon|aws|google|microsoft|azure|cloudflare|tencent|huawei|oracle|digitalocean|linode|akamai|vultr|hetzner|ovh|cloud|hosting|data.?center'; then
        proxy_suspected="true"
        warnings="${warnings:+$warnings; }出口ASN疑似云服务或代理"
    fi

    if [ -n "$egress_country" ] && [ "$egress_country" != "CN" ]; then
        proxy_suspected="true"
        warnings="${warnings:+$warnings; }出口国家不是CN"
    fi

    local warnings_json="[]"
    if [ -n "$warnings" ]; then
        warnings_json="[\"$(printf '%s' "$warnings" | json_escape)\"]"
    fi

    cat <<JSON
{"proxy_suspected":${proxy_suspected},"route_interface":"$(printf '%s' "${route_interface:-}" | json_escape)","wan_interface":"$(printf '%s' "${default_if:-}" | json_escape)","egress_ip":"$(printf '%s' "${egress_ip:-}" | json_escape)","egress_asn":"$(printf '%s' "${egress_asn:-}" | json_escape)","egress_country":"$(printf '%s' "${egress_country:-}" | json_escape)","egress_org":"$(printf '%s' "${egress_org:-}" | json_escape)","egress_region":"$(printf '%s' "${egress_region:-}" | json_escape)","egress_city":"$(printf '%s' "${egress_city:-}" | json_escape)","warnings":${warnings_json}}
JSON
}

# ==================== 运行测速 ====================

run_speedtest() {
    load_config

    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            warn "上一次测速仍在运行 (PID: $lock_pid)，跳过"
            return 0
        fi
        rm -f "$LOCK_FILE"
    fi

    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT

    need_cmd cfst
    create_ip_file

    local ip_version="${IP_VERSION:-v4}"
    local result_file="${INSTALL_DIR}/result.csv"
    local cfst_args="${CFST_ARGS:--n 60 -t 4 -dn 8 -dt 15 -tlr 0 -p 8}"

    info "开始测速 (IPv${ip_version#v})..."
    info "cfst 参数: $cfst_args"

    # 运行 cfst
    if [ "$ip_version" = "v6" ]; then
        cfst $cfst_args -f "$IP_FILE" -o "$result_file" > "$CFST_LOG" 2>&1 || {
            warn "cfst 测速失败，查看日志: $CFST_LOG"
            rm -f "$LOCK_FILE"
            return 1
        }
    else
        cfst $cfst_args -f "$IP_FILE" -o "$result_file" > "$CFST_LOG" 2>&1 || {
            warn "cfst 测速失败，查看日志: $CFST_LOG"
            rm -f "$LOCK_FILE"
            return 1
        }
    fi

    if [ ! -f "$result_file" ] || [ ! -s "$result_file" ]; then
        warn "测速结果为空"
        rm -f "$LOCK_FILE"
        return 1
    fi

    info "测速完成，解析结果..."
    upload_results "$result_file" "$ip_version"
}

# ==================== 解析 CSV 并上传 ====================

parse_csv_nodes() {
    local result_file="$1"
    local max_nodes="${2:-50}"

    awk -F',' '
    NR == 1 {
        for (i = 1; i <= NF; i++) {
            gsub(/^\xef\xbb\xbf/, "", $i)
            h = tolower($i)
            if (h ~ /ip/) ip_col = i
            if (h ~ /port|端口/) port_col = i
            if (h ~ /latency|延迟/) lat_col = i
            if (h ~ /speed|速度/) speed_col = i
            if (h ~ /loss|丢包/) loss_col = i
            if (h ~ /colo|地区|data/) colo_col = i
        }
        if (!ip_col && NF >= 7) ip_col = 1
        if (!loss_col && NF >= 7) loss_col = 4
        if (!lat_col && NF >= 7) lat_col = 5
        if (!speed_col && NF >= 7) speed_col = 6
        if (!colo_col && NF >= 7) colo_col = 7
        next
    }
    ip_col && $ip_col != "" && count < max_nodes {
        ip = $ip_col
        port = port_col ? $port_col : 443
        lat = lat_col ? $lat_col : 0
        speed = speed_col ? $speed_col : 0
        loss = loss_col ? $loss_col : 0
        colo = colo_col ? $colo_col : ""
        gsub(/[^0-9.]/, "", port)
        gsub(/[^0-9.]/, "", lat)
        gsub(/[^0-9.]/, "", speed)
        gsub(/[^0-9.]/, "", loss)
        gsub(/"/, "\\\"", ip)
        gsub(/"/, "\\\"", colo)
        printf "%s{\"ip\":\"%s\",\"port\":%s,\"latency\":%s,\"speed\":%s,\"loss\":%s,\"tls\":true,\"colo\":\"%s\"}", sep, ip, port ? port : 443, lat ? lat : 0, speed ? speed : 0, loss ? loss : 0, colo
        sep = ","
        count++
    }' "$result_file"
}

upload_results() {
    load_config
    local result_file="$1"
    local ip_version="${2:-v4}"
    local max_nodes="${UPLOAD_MAX_NODES:-50}"

    if [ -z "$DEVICE_ID" ] || [ -z "$DEVICE_TOKEN" ]; then
        fail "设备未注册，请先运行: $0 register"
    fi

    local nodes_json
    nodes_json="$(parse_csv_nodes "$result_file" "$max_nodes")"

    if [ -z "$nodes_json" ]; then
        warn "没有有效的测速节点数据"
        return 1
    fi

    local direct_check
    direct_check="$(detect_direct 2>/dev/null || echo '{"proxy_suspected":false,"warnings":[]}')"

    local nickname
    nickname="$NICKNAME"

    local payload
    payload=$(cat <<JSON
{"nickname":"$(printf '%s' "$nickname" | json_escape)","device_id":"${DEVICE_ID}","device_token":"$(printf '%s' "$DEVICE_TOKEN" | json_escape)","ip_version":"${ip_version}","nodes":[${nodes_json}],"direct_check":${direct_check}}
JSON
    )

    info "上传测速结果到 ${WORKER_URL} ..."
    local response http_code
    response="$(curl -s -w '\n%{http_code}' -X POST "${WORKER_URL}/api/public/upload" \
        -H "Content-Type: application/json" \
        -d "$payload")"
    http_code="$(echo "$response" | tail -1)"
    response="$(echo "$response" | sed '$d')"

    if [ "$http_code" != "200" ]; then
        error "上传失败 (HTTP $http_code): $response"
        return 1
    fi

    local success
    success="$(echo "$response" | grep -o '"success":true' || true)"
    if [ -z "$success" ]; then
        error "上传返回错误: $response"
        return 1
    fi

    local upload_id
    upload_id="$(echo "$response" | grep -o '"upload_id":"[^"]*"' | head -1 | cut -d'"' -f4)"
    info "上传成功! upload_id: $upload_id"

    # 记录日志
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] upload_id=$upload_id nodes=$(echo "$nodes_json" | grep -c '"ip"' || echo 0)" >> "$LOG_FILE"
}

# ==================== 定时任务 ====================

setup_cron() {
    local cron_expr="${1:-0 3 * * *}"
    local script_path
    script_path="$(readlink -f "$0")"

    # 检查是否已有定时任务
    if crontab -l 2>/dev/null | grep -q "cf-ip-speed"; then
        warn "已存在 cf-ip-speed 定时任务，先移除旧的..."
        crontab -l 2>/dev/null | grep -v "cf-ip-speed" | crontab -
    fi

    # 添加新定时任务
    (crontab -l 2>/dev/null; echo "${cron_expr} ${script_path} run >> ${LOG_FILE} 2>&1 # cf-ip-speed") | crontab -
    info "定时任务已设置: ${cron_expr}"
    info "当前 crontab:"
    crontab -l 2>/dev/null | grep "cf-ip-speed"
}

remove_cron() {
    if crontab -l 2>/dev/null | grep -q "cf-ip-speed"; then
        crontab -l 2>/dev/null | grep -v "cf-ip-speed" | crontab -
        info "定时任务已移除"
    else
        info "没有找到 cf-ip-speed 定时任务"
    fi
}

# ==================== 状态查看 ====================

show_status() {
    load_config
    echo "=========================================="
    echo "  Cloudflare IP 优选助手 - 状态"
    echo "=========================================="
    echo "安装目录:   $INSTALL_DIR"
    echo "昵称:       ${NICKNAME:-未设置}"
    echo "设备ID:     ${DEVICE_ID:-未注册}"
    echo "IP版本:     ${IP_VERSION:-v4}"
    echo "cfst:       $(command -v cfst 2>/dev/null || echo '未安装')"
    echo "配置文件:   $CONFIG_FILE"
    echo "日志文件:   $LOG_FILE"
    echo "------------------------------------------"
    echo "定时任务:"
    crontab -l 2>/dev/null | grep "cf-ip-speed" || echo "  未设置"
    echo "------------------------------------------"
    echo "Web 面板:"
    web_status 2>/dev/null || echo "  未安装"
    echo "------------------------------------------"
    if [ -f "$LOG_FILE" ]; then
        echo "最近上传记录:"
        tail -5 "$LOG_FILE"
    else
        echo "暂无上传记录"
    fi
    echo "=========================================="
}

# ==================== 显示日志 ====================

show_logs() {
    if [ -f "$LOG_FILE" ]; then
        echo "===== 上传日志 ====="
        tail -20 "$LOG_FILE"
    fi
    if [ -f "$CFST_LOG" ]; then
        echo "===== cfst 日志 ====="
        tail -30 "$CFST_LOG"
    fi
}

# ==================== Web 面板 ====================

WEB_PORT="${WEB_PORT:-8899}"
WEB_PID_FILE="${INSTALL_DIR}/web.pid"
WEB_PY="${INSTALL_DIR}/web.py"

install_web() {
    info "安装 Web 管理面板..."
    # 检查 Python3
    if ! has_cmd python3; then
        warn "未找到 python3，尝试安装..."
        if has_cmd apt-get; then
            apt-get update -qq && apt-get install -y -qq python3
        elif has_cmd yum; then
            yum install -y -q python3
        elif has_cmd apk; then
            apk add --no-cache python3
        else
            fail "无法自动安装 python3，请手动安装"
        fi
    fi

    # 下载 web.py
    local web_py_url="https://raw.githubusercontent.com/xiaoxiaozhou-zcx/cf-ip-speed-linux/main/web.py"
    if [ ! -f "${WEB_PY}" ] || [ "${FORCE_WEB:-0}" = "1" ]; then
        info "下载 web.py..."
        download "${web_py_url}" "${WEB_PY}"
        chmod 755 "${WEB_PY}"
    else
        info "web.py 已存在，跳过下载 (使用 FORCE_WEB=1 强制更新)"
    fi

    # 创建 systemd 服务
    if has_cmd systemctl; then
        cat > /etc/systemd/system/cf-ip-speed-web.service <<SVCEOF
[Unit]
Description=Cloudflare IP Speed Panel Web UI
After=network.target

[Service]
Type=simple
ExecStart=$(command -v python3) ${WEB_PY} --host 0.0.0.0 --port ${WEB_PORT}
WorkingDirectory=${INSTALL_DIR}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
        systemctl daemon-reload
        systemctl enable cf-ip-speed-web.service 2>/dev/null || true
        info "systemd 服务已创建: cf-ip-speed-web"
    fi

    info "Web 面板安装完成"
}

web_start() {
    if [ -f "$WEB_PID_FILE" ]; then
        local pid
        pid="$(cat "$WEB_PID_FILE" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            warn "Web 面板已在运行 (PID: $pid)"
            return 0
        fi
        rm -f "$WEB_PID_FILE"
    fi

    if has_cmd systemctl && systemctl is-active cf-ip-speed-web >/dev/null 2>&1; then
        warn "Web 面板 systemd 服务已在运行"
        return 0
    fi

    if has_cmd systemctl; then
        systemctl start cf-ip-speed-web.service
        info "Web 面板已启动 (systemd)"
    else
        nohup python3 "${WEB_PY}" --host 0.0.0.0 --port "${WEB_PORT}" > "${INSTALL_DIR}/web.log" 2>&1 &
        echo $! > "$WEB_PID_FILE"
        info "Web 面板已启动 (PID: $!, 端口: ${WEB_PORT})"
    fi

    info "访问: http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost'):${WEB_PORT}"
}

web_stop() {
    if has_cmd systemctl && systemctl is-active cf-ip-speed-web >/dev/null 2>&1; then
        systemctl stop cf-ip-speed-web.service
        info "Web 面板已停止 (systemd)"
        return 0
    fi

    if [ -f "$WEB_PID_FILE" ]; then
        local pid
        pid="$(cat "$WEB_PID_FILE" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            info "Web 面板已停止 (PID: $pid)"
        fi
        rm -f "$WEB_PID_FILE"
    else
        warn "Web 面板未在运行"
    fi
}

web_status() {
    if has_cmd systemctl && systemctl is-active cf-ip-speed-web >/dev/null 2>&1; then
        info "Web 面板运行中 (systemd)"
        info "访问: http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost'):${WEB_PORT}"
        return 0
    fi

    if [ -f "$WEB_PID_FILE" ]; then
        local pid
        pid="$(cat "$WEB_PID_FILE" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            info "Web 面板运行中 (PID: $pid, 端口: ${WEB_PORT})"
            return 0
        fi
    fi
    info "Web 面板未运行"
}

# ==================== 帮助信息 ====================

show_help() {
    cat <<'EOF'
Cloudflare IP 优选助手 - Linux 通用版
基于 https://github.com/10000ge10000/cf-ip-speed-panel

用法:
  cf-ip-speed <命令> [参数]

命令:
  install           完整安装（安装cfst + 注册设备 + 设置定时任务）
  register          注册/重新注册设备
  run               立即运行一次测速并上传
  cron [表达式]     设置定时任务（默认: 每天凌晨3点）
  cron-remove       移除定时任务
  web [start|stop|status|install]  Web 管理面板
  status            查看当前状态
  logs              查看日志
  config            编辑配置文件
  uninstall         卸载（保留配置）

配置文件: /opt/cf-ip-speed/config

示例:
  cf-ip-speed install              # 一键安装
  cf-ip-speed run                  # 立即测速
  cf-ip-speed web start            # 启动 Web 面板
  cf-ip-speed cron "0 3,15 * * *"  # 每天3点和15点测速
  cf-ip-speed status               # 查看状态

环境变量:
  CFST_TAG            cfst 版本 (默认: v2.3.5)
  CFST_FORCE_INSTALL  强制重新安装 cfst (设为1)
EOF
}

# ==================== 完整安装 ====================

do_install() {
    info "开始完整安装..."
    echo ""

    # 检查必要工具
    need_cmd curl || need_cmd wget
    need_cmd awk
    need_cmd grep

    # 创建目录
    mkdir -p "$INSTALL_DIR"

    # 安装 cfst
    install_cfst

    # 创建 IP 文件
    create_ip_file

    # 设置默认配置
    load_config
    if [ -z "${IP_VERSION:-}" ]; then
        IP_VERSION="v4"
    fi
    if [ -z "${CFST_ARGS:-}" ]; then
        CFST_ARGS="-n 60 -t 4 -dn 8 -dt 15 -tlr 0 -p 8"
    fi
    if [ -z "${UPLOAD_MAX_NODES:-}" ]; then
        UPLOAD_MAX_NODES="50"
    fi
    save_config

    # 注册设备
    register_device

    # 设置定时任务
    setup_cron "0 3 * * *"

    # 安装 Web 面板
    install_web

    echo ""
    info "========================================="
    info "安装完成!"
    info "========================================="
    info ""
    info "常用命令:"
    info "  $0 run        # 立即测速"
    info "  $0 web start  # 启动 Web 面板"
    info "  $0 status     # 查看状态"
    info "  $0 logs       # 查看日志"
    info ""
    info "定时任务: 每天凌晨 3 点自动测速"
    info "可修改: $0 cron '0 3,15 * * *'"
    info "========================================="
}

# ==================== 卸载 ====================

do_uninstall() {
    info "开始卸载..."

    # 停止 Web 面板
    web_stop 2>/dev/null || true
    if has_cmd systemctl; then
        systemctl disable cf-ip-speed-web.service 2>/dev/null || true
        rm -f /etc/systemd/system/cf-ip-speed-web.service
        systemctl daemon-reload 2>/dev/null || true
        info "已移除 Web 面板服务"
    fi

    # 移除定时任务
    remove_cron

    # 移除 cfst
    if [ -f /usr/local/bin/cfst ]; then
        rm -f /usr/local/bin/cfst
        info "已移除 cfst"
    fi

    info "卸载完成。配置和日志保留在: $INSTALL_DIR"
    info "如需完全删除: rm -rf $INSTALL_DIR"
}

# ==================== 主入口 ====================

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        install)
            do_install
            ;;
        register)
            mkdir -p "$INSTALL_DIR"
            register_device
            ;;
        run)
            run_speedtest
            ;;
        cron)
            setup_cron "${1:-0 3 * * *}"
            ;;
        cron-remove)
            remove_cron
            ;;
        web)
            local web_cmd="${1:-start}"
            shift 2>/dev/null || true
            case "$web_cmd" in
                start)    web_start ;;
                stop)     web_stop ;;
                status)   web_status ;;
                install)  install_web ;;
                *)        error "未知 web 命令: $web_cmd (可用: start/stop/status/install)" ;;
            esac
            ;;
        status)
            show_status
            ;;
        logs)
            show_logs
            ;;
        config)
            ${EDITOR:-vi} "$CONFIG_FILE"
            ;;
        uninstall)
            do_uninstall
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "未知命令: $cmd"
            show_help
            exit 1
            ;;
    esac
}

# ==================== 自安装 ====================

self_install() {
    local script_src
    script_src="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    mkdir -p "$INSTALL_DIR"
    # 判断是否从文件运行（非 bash -c 管道）
    # 如果是管道运行，$0 会指向 bash 本身（可执行二进制，非文本脚本）
    if [ -f "$script_src" ] && file "$script_src" 2>/dev/null | grep -qi 'text'; then
        cp "$script_src" "${INSTALL_DIR}/cf-ip-speed.sh"
    else
        # 从 curl 管道运行，从 GitHub 下载一份落盘
        info "从 GitHub 下载脚本到 ${INSTALL_DIR}/cf-ip-speed.sh ..."
        download "https://raw.githubusercontent.com/xiaoxiaozhou-zcx/cf-ip-speed-linux/main/install.sh" "${INSTALL_DIR}/cf-ip-speed.sh"
    fi
    chmod 755 "${INSTALL_DIR}/cf-ip-speed.sh"
    # 创建全局命令链接
    if [ -d /usr/local/bin ]; then
        ln -sf "${INSTALL_DIR}/cf-ip-speed.sh" /usr/local/bin/cf-ip-speed
    fi
}

# 无参数时执行完整安装
if [ $# -eq 0 ]; then
    self_install
    do_install
    exit 0
fi

main "$@"
