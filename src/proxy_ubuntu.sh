#!/bin/bash

# ==========================================
# Script Auto Create Proxy with 3proxy
# Environment: Ubuntu Server (aaPanel Compatible)
# ==========================================

WORKDIR="/root/proxy_setup"
PROXY_EXEC="/usr/local/bin/3proxy"
CFG_PATH="/usr/local/etc/3proxy"
OUTPUT_FILE="/root/proxy_list.txt"

# --- 1. Check Root ---
if [ "$(id -u)" != "0" ]; then
   echo "Lỗi: Script này phải được chạy với quyền root!" 1>&2
   exit 1
fi

echo "------------------------------------------------"
echo "   SCRIPT TỰ ĐỘNG TẠO PROXY (IPV4/IPV6)"
echo "------------------------------------------------"

# --- 2. Install Dependencies ---
echo "[+] Đang kiểm tra và cài đặt thư viện cần thiết..."
apt-get update -y > /dev/null 2>&1
apt-get install -y build-essential gcc make git wget curl net-tools jq ufw > /dev/null 2>&1

# --- 3. Get Network Info ---
echo "[+] Đang kiểm tra thông tin mạng..."
IPV4_ADDR=$(curl -s -4 ifconfig.me)
IPV6_ADDR=$(curl -s -6 ifconfig.me)

# --- 4. Install 3proxy (if not exists) ---
if [ ! -f "$PROXY_EXEC" ]; then
    echo "[+] Đang tải và cài đặt 3proxy..."
    mkdir -p $WORKDIR
    cd $WORKDIR
    # Download stable version
    wget https://github.com/z3APA3A/3proxy/archive/0.9.4.tar.gz > /dev/null 2>&1
    tar -xzvf 0.9.4.tar.gz > /dev/null 2>&1
    cd 3proxy-0.9.4
    make -f Makefile.Linux > /dev/null 2>&1
    make -f Makefile.Linux install > /dev/null 2>&1
    echo "[ok] Cài đặt 3proxy hoàn tất."
else
    echo "[!] 3proxy đã được cài đặt. Tiến hành cấu hình lại..."
    # Stop service if running
    systemctl stop 3proxy 2>/dev/null
    killall 3proxy 2>/dev/null
fi

# --- 5. User Inputs ---
echo "------------------------------------------------"
echo "THÔNG TIN MÁY CHỦ:"
echo "- IPv4 hiện tại: ${IPV4_ADDR:-"Không tìm thấy"}"
echo "- IPv6 hiện tại: ${IPV6_ADDR:-"Không tìm thấy"}"
echo "------------------------------------------------"

# Select IP Version
PS3='Chọn phiên bản IP để tạo Proxy: '
options=("IPv4" "IPv6" "Thoát")
select opt in "${options[@]}"
do
    case $opt in
        "IPv4")
            if [ -z "$IPV4_ADDR" ]; then echo "Lỗi: Không tìm thấy IPv4!"; exit 1; fi
            SELECTED_IP=$IPV4_ADDR
            IP_TYPE="4"
            break
            ;;
        "IPv6")
            if [ -z "$IPV6_ADDR" ]; then echo "Lỗi: Không tìm thấy IPv6!"; exit 1; fi
            SELECTED_IP=$IPV6_ADDR
            IP_TYPE="6"
            break
            ;;
        "Thoát")
            exit 0
            ;;
        *) echo "Lựa chọn không hợp lệ $REPLY";;
    esac
done

# Calculate Max Proxies (Based on generic port limits, not RAM)
# 65535 ports total, reserving first 10000 for system
MAX_PROXY=5000
echo "[*] Hệ thống cho phép tạo tối đa khoảng $MAX_PROXY proxy an toàn."

# Input Quantity
while true; do
    read -p "Nhập số lượng proxy cần tạo (Ví dụ: 10): " PROXY_COUNT
    if [[ "$PROXY_COUNT" =~ ^[0-9]+$ ]] && [ "$PROXY_COUNT" -gt 0 ] && [ "$PROXY_COUNT" -le "$MAX_PROXY" ]; then
        break
    else
        echo "Vui lòng nhập số hợp lệ (1 - $MAX_PROXY)."
    fi
done

# Input Starting Port
DEFAULT_PORT=10000
read -p "Nhập port bắt đầu (Enter để dùng mặc định $DEFAULT_PORT): " START_PORT
START_PORT=${START_PORT:-$DEFAULT_PORT}

# --- 6. Generate Config ---
echo "[+] Đang tạo cấu hình proxy..."
mkdir -p $CFG_PATH
cat > $CFG_PATH/3proxy.cfg <<EOF
daemon
maxconn 1000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
flush
auth strong
users $(awk -v count=$PROXY_COUNT 'BEGIN { for (i=1; i<=count; i++) printf "user" i ":CL:pass" i " " }')
allow *
EOF

# Clear old output file
> $OUTPUT_FILE

# Generate Users, Ports and append to config
# Loop to create config entries
for (( i=1; i<=PROXY_COUNT; i++ ))
do
    CURRENT_PORT=$((START_PORT + i - 1))
    RAND_USER="u$(tr -dc a-z0-9 </dev/urandom | head -c 6)"
    RAND_PASS="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 10)"
    
    # Add user to config (Append to top or create specific allow rule logic)
    # Re-writing config specific specifically for this logic to be simpler:
    
    # We add the user auth line
    echo "users $RAND_USER:CL:$RAND_PASS" >> $CFG_PATH/3proxy.cfg
    
    # Add proxy binding
    if [ "$IP_TYPE" == "6" ]; then
        echo "proxy -6 -n -a -p$CURRENT_PORT -i$SELECTED_IP -e$SELECTED_IP" >> $CFG_PATH/3proxy.cfg
    else
        echo "proxy -n -a -p$CURRENT_PORT -i$SELECTED_IP -e$SELECTED_IP" >> $CFG_PATH/3proxy.cfg
    fi
    
    # Save to output file
    echo "$SELECTED_IP:$CURRENT_PORT:$RAND_USER:$RAND_PASS" >> $OUTPUT_FILE
    
    # Open Firewall (UFW)
    ufw allow $CURRENT_PORT/tcp > /dev/null 2>&1
done

# --- 7. Create Systemd Service ---
echo "[+] Đang cấu hình tự động khởi chạy (Systemd)..."
cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
ExecStop=/bin/kill -SIGTERM \$MAINPID
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable 3proxy > /dev/null 2>&1
systemctl restart 3proxy

# --- 8. Finish ---
echo "------------------------------------------------"
echo "HOÀN TẤT!"
echo "Đã tạo thành công $PROXY_COUNT proxies."
echo "Danh sách đã được lưu tại: $OUTPUT_FILE"
echo "------------------------------------------------"
echo "Nội dung 10 dòng đầu tiên của file kết quả:"
head -n 10 $OUTPUT_FILE
echo "..."
