#!/bin/bash

# proxy_ubuntu.sh - Tạo proxy tự động trên Ubuntu + aapanel
# Yêu cầu: Ubuntu Server, có aapanel (không ảnh hưởng)

set -e

PROXY_FILE="proxy_list.txt"
CONFIG_DIR="/etc/3proxy"
CONFIG_FILE="$CONFIG_DIR/3proxy.cfg"
SERVICE_FILE="/etc/systemd/system/3proxy.service"
LOG_FILE="/var/log/3proxy.log"

# Màu sắc cho output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
    error "Vui lòng chạy script với quyền root (sudo)."
fi

# === BƯỚC 1: Cài thư viện cần thiết ===
log "Đang cài đặt các gói cần thiết..."
apt update > /dev/null 2>&1
apt install -y wget net-tools iproute2 curl dnsutils > /dev/null 2>&1

# === Cài 3proxy (dùng bản pre-compiled từ GitHub release) ===
log "Đang cài 3proxy từ bản pre-compiled..."

if ! command -v 3proxy &> /dev/null; then
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        BIN_URL="https://github.com/z3APA3A/3proxy/releases/latest/download/3proxy-$(uname -s)-x86_64.tar.gz"
    elif [[ "$ARCH" == "aarch64" ]] || [[ "$ARCH" == "arm64" ]]; then
        error "3proxy chưa có bản pre-compiled chính thức cho ARM64. Vui lòng cài GCC để build từ source."
    else
        error "Kiến trúc $ARCH không được hỗ trợ."
    fi

    mkdir -p /tmp/3proxy-install
    cd /tmp/3proxy-install

    if ! wget -q "$BIN_URL" -O 3proxy.tar.gz; then
        error "Không thể tải 3proxy từ GitHub. Kiểm tra kết nối mạng hoặc firewall."
    fi

    tar -xzf 3proxy.tar.gz
    if [ ! -f 3proxy ]; then
        error "Giải nén thất bại: không tìm thấy file 3proxy trong tarball."
    fi

    chmod +x 3proxy
    cp 3proxy /usr/local/bin/
    mkdir -p "$CONFIG_DIR"
    cd /
    rm -rf /tmp/3proxy-install
    log "✅ Cài 3proxy thành công từ bản pre-compiled."
else
    log "3proxy đã được cài đặt."
fi

# === BƯỚC 2: Phát hiện IP khả dụng ===
log "Đang quét địa chỉ IP khả dụng..."

ipv4_list=()
for ip in $(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | grep -v '^172\.1[6-9]\.' | grep -v '^172\.2[0-9]\.' | grep -v '^172\.3[0-1]\.' | grep -v '^10\.' | grep -v '^192\.168\.'); do
    if [[ $ip != "0.0.0.0" ]]; then
        ipv4_list+=("$ip")
    fi
done

ipv6_list=()
for ip in $(ip -6 addr show | grep -oP '(?<=inet6\s)[0-9a-f:]+(?=/)' | grep -v '^::1$' | grep -v '^fe80:' | grep -v '^fd'); do
    if [[ -n "$ip" ]]; then
        ipv6_list+=("$ip")
    fi
done

total_ips=0
has_ipv4=false
has_ipv6=false

if [ ${#ipv4_list[@]} -gt 0 ]; then
    has_ipv4=true
    total_ips=$((total_ips + ${#ipv4_list[@]}))
    log "Phát hiện ${#ipv4_list[@]} địa chỉ IPv4 public."
fi

if [ ${#ipv6_list[@]} -gt 0 ]; then
    has_ipv6=true
    total_ips=$((total_ips + ${#ipv6_list[@]}))
    log "Phát hiện ${#ipv6_list[@]} địa chỉ IPv6 public."
fi

if [ $total_ips -eq 0 ]; then
    warn "Không tìm thấy IP public. Sẽ sử dụng 127.0.0.1 (IPv4) và ::1 (IPv6 nếu có)."
    ipv4_list=("127.0.0.1")
    has_ipv4=true
    total_ips=1
    if ip -6 addr show lo | grep -q 'inet6'; then
        ipv6_list=("::1")
        has_ipv6=true
        total_ips=2
    fi
fi

max_proxies=$((total_ips * 100))
log "Hệ thống có thể tạo tối đa khoảng $max_proxies proxy (dựa trên số IP và dải cổng)."

# === BƯỚC 3: Hỏi người dùng số lượng proxy muốn tạo ===
read -p "$(echo -e "${YELLOW}Nhập số lượng proxy cần tạo (tối đa $max_proxies): ${NC}")" proxy_count

if ! [[ "$proxy_count" =~ ^[0-9]+$ ]] || [ "$proxy_count" -le 0 ]; then
    error "Số lượng proxy không hợp lệ."
fi

if [ "$proxy_count" -gt "$max_proxies" ]; then
    error "Số lượng vượt quá giới hạn ($max_proxies)."
fi

# === BƯỚC 4: Chọn phiên bản IP ===
ip_version="ipv4"
if $has_ipv4 && $has_ipv6; then
    echo -e "${YELLOW}Chọn loại proxy:${NC}"
    echo "1) IPv4"
    echo "2) IPv6"
    echo "3) Cả hai (xen kẽ)"
    read -p "Lựa chọn (1/2/3): " ip_choice

    case $ip_choice in
        1) ip_version="ipv4" ;;
        2) ip_version="ipv6" ;;
        3) ip_version="both" ;;
        *) error "Lựa chọn không hợp lệ." ;;
    esac
elif $has_ipv6 && ! $has_ipv4; then
    ip_version="ipv6"
    log "Chỉ có IPv6 khả dụng → sử dụng IPv6."
else
    ip_version="ipv4"
    log "Chỉ có IPv4 khả dụng → sử dụng IPv4."
fi

# === BƯỚC 5: Tạo danh sách IP được dùng ===
usable_ips=()
if [[ "$ip_version" == "ipv4" || "$ip_version" == "both" ]] && $has_ipv4; then
    usable_ips+=("${ipv4_list[@]}")
fi
if [[ "$ip_version" == "ipv6" || "$ip_version" == "both" ]] && $has_ipv6; then
    usable_ips+=("${ipv6_list[@]}")
fi

if [ ${#usable_ips[@]} -eq 0 ]; then
    error "Không có IP khả dụng cho phiên bản đã chọn."
fi

# === BƯỚC 6: Tạo proxy config ===
log "Đang tạo cấu hình proxy..."

> "$CONFIG_FILE"
echo "daemon" >> "$CONFIG_FILE"
echo "maxconn 1000" >> "$CONFIG_FILE"
echo "nserver 8.8.8.8" >> "$CONFIG_FILE"
echo "nserver 1.1.1.1" >> "$CONFIG_FILE"
echo "nscache 65536" >> "$CONFIG_FILE"
echo "timeouts 1 5 30 60 180 1800 15 60" >> "$CONFIG_FILE"
echo "users $(printf 'user%03d:CL:pass%03d ' $(seq 1 $proxy_count))" >> "$CONFIG_FILE"
echo "log $LOG_FILE D" >> "$CONFIG_FILE"

> "$PROXY_FILE"

start_port=10000
port=$start_port
proxy_created=0
ip_index=0
total_usable_ips=${#usable_ips[@]}

while [ $proxy_created -lt $proxy_count ]; do
    ip="${usable_ips[$((ip_index % total_usable_ips))]}"
    ip_index=$((ip_index + 1))

    user="user$(printf "%03d" $((proxy_created + 1)))"
    pass="pass$(printf "%03d" $((proxy_created + 1)))"

    if [[ $ip == *:* ]]; then
        echo "proxy -6 -n -a -p$port -i[$ip] -e[$ip] -u$user -A$pass" >> "$CONFIG_FILE"
        echo "[$ip]:$port:$user:$pass" >> "$PROXY_FILE"
    else
        echo "proxy -n -a -p$port -i$ip -e$ip -u$user -A$pass" >> "$CONFIG_FILE"
        echo "$ip:$port:$user:$pass" >> "$PROXY_FILE"
    fi

    proxy_created=$((proxy_created + 1))
    port=$((port + 1))
done

# === BƯỚC 7: Cấu hình systemd service ===
log "Cấu hình dịch vụ 3proxy..."

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/3proxy $CONFIG_FILE
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable 3proxy > /dev/null 2>&1
systemctl stop 3proxy > /dev/null 2>&1 || true
systemctl start 3proxy

sleep 2

if systemctl is-active --quiet 3proxy; then
    log "✅ 3proxy đã khởi động thành công!"
else
    error "❌ 3proxy không khởi động được. Kiểm tra log: $LOG_FILE"
fi

# === BƯỚC 8: In kết quả ===
log "Đã tạo $proxy_count proxy. Danh sách lưu tại: $PROXY_FILE"
echo ""
echo "=== DANH SÁCH PROXY ==="
cat "$PROXY_FILE"
echo ""
log "💡 Ghi chú: Nếu chạy script lại, file $PROXY_FILE sẽ bị ghi đè và cấu hình 3proxy sẽ được tạo mới."

exit 0
