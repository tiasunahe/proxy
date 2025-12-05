#!/bin/bash

# ==========================================
# Script Auto Create Proxy with 3proxy (Parameter Mode)
# Usage: bash proxy_param.sh [4|6] [COUNT] [START_PORT]
# Example: bash proxy_param.sh 4 50 10000
# ==========================================

WORKDIR="/root/proxy_setup"
PROXY_EXEC="/usr/local/bin/3proxy"
CFG_PATH="/usr/local/etc/3proxy"
OUTPUT_FILE="/root/proxy_list.txt"

# --- 1. Check Root & Parameters ---
if [ "$(id -u)" != "0" ]; then
   echo "Lỗi: Script này phải được chạy với quyền root!" 1>&2
   exit 1
fi

if [ "$#" -ne 3 ]; then
    echo "------------------------------------------------"
    echo "LỖI: Thiếu tham số!"
    echo "CÚ PHÁP: bash proxy_param.sh [IP_VERSION] [COUNT] [START_PORT]"
    echo "  [IP_VERSION]: 4 (IPv4) hoặc 6 (IPv6)"
    echo "  [COUNT]: Số lượng proxy cần tạo (Ví dụ: 50)"
    echo "  [START_PORT]: Port bắt đầu (Ví dụ: 10000)"
    echo "VÍ DỤ CHẠY: bash proxy_param.sh 4 50 10000"
    echo "------------------------------------------------"
    exit 1
fi

IP_TYPE=$1
PROXY_COUNT=$2
START_PORT=$3

if [ "$IP_TYPE" != "4" ] && [ "$IP_TYPE" != "6" ]; then
    echo "Lỗi: IP_VERSION phải là 4 hoặc 6."
    exit 1
fi
if ! [[ "$PROXY_COUNT" =~ ^[0-9]+$ ]] || [ "$PROXY_COUNT" -lt 1 ]; then
    echo "Lỗi: COUNT phải là số nguyên dương."
    exit 1
fi
if ! [[ "$START_PORT" =~ ^[0-9]+$ ]] || [ "$START_PORT" -lt 1024 ]; then
    echo "Lỗi: START_PORT phải là số nguyên và lớn hơn 1023."
    exit 1
fi

echo "------------------------------------------------"
echo "   SCRIPT TỰ ĐỘNG TẠO PROXY (DÙNG THAM SỐ)"
echo "------------------------------------------------"

# --- 2. Install Dependencies ---
echo "[+] Đang kiểm tra và cài đặt thư viện cần thiết..."
apt-get update -y > /dev/null 2>&1
apt-get install -y build-essential gcc make git wget curl net-tools jq ufw > /dev/null 2>&1

# --- 3. Get Network Info ---
echo "[+] Đang kiểm tra thông tin mạng..."
IPV4_ADDR=$(curl -s -4 ifconfig.me)
IPV6_ADDR=$(curl -s -6 ifconfig.me)

if [ "$IP_TYPE" == "4" ]; then
    SELECTED_IP=$IPV4_ADDR
    if [ -z "$SELECTED_IP" ]; then echo "Lỗi: Không tìm thấy IPv4!"; exit 1; fi
    echo "[*] Chọn IPv4: $SELECTED_IP"
else
    SELECTED_IP=$IPV6_ADDR
    if [ -z "$SELECTED_IP" ]; then echo "Lỗi: Không tìm thấy IPv6!"; exit 1; fi
    echo "[*] Chọn IPv6: $SELECTED_IP"
fi

# --- 4. Install 3proxy ---
if [ ! -f "$PROXY_EXEC" ]; then
    echo "[+] Đang tải và cài đặt 3proxy..."
    mkdir -p $WORKDIR && cd $WORKDIR
    wget https://github.com/z3APA3A/3proxy/archive/0.9.4.tar.gz > /dev/null 2>&1
    tar -xzvf 0.9.4.tar.gz > /dev/null 2>&1
    cd 3proxy-0.9.4
    make -f Makefile.Linux > /dev/null 2>&1
    make -f Makefile.Linux install > /dev/null 2>&1
    echo "[ok] Cài đặt 3proxy hoàn tất."
else
    echo "[!] 3proxy đã cài đặt. Đang reset cấu hình..."
    systemctl stop 3proxy 2>/dev/null
    killall 3proxy 2>/dev/null
fi

# --- 5. Generate Config ---
echo "[+] Đang tạo cấu hình ($PROXY_COUNT proxies từ port $START_PORT)..."
mkdir -p $CFG_PATH
cat > $CFG_PATH/3proxy.cfg <<CONFIG
daemon
maxconn 2000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
flush
auth strong
allow *
CONFIG

> $OUTPUT_FILE

for (( i=1; i<=PROXY_COUNT; i++ ))
do
    CURRENT_PORT=$((START_PORT + i - 1))
    RAND_USER="u$(tr -dc a-z0-9 </dev/urandom | head -c 6)"
    RAND_PASS="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 10)"
    
    echo "users $RAND_USER:CL:$RAND_PASS" >> $CFG_PATH/3proxy.cfg
    
    if [ "$IP_TYPE" == "6" ]; then
        echo "proxy -6 -n -a -p$CURRENT_PORT -i$SELECTED_IP -e$SELECTED_IP" >> $CFG_PATH/3proxy.cfg
    else
        echo "proxy -n -a -p$CURRENT_PORT -i$SELECTED_IP -e$SELECTED_IP" >> $CFG_PATH/3proxy.cfg
    fi
    
    echo "$SELECTED_IP:$CURRENT_PORT:$RAND_USER:$RAND_PASS" >> $OUTPUT_FILE
    
    ufw allow $CURRENT_PORT/tcp > /dev/null 2>&1
done

# --- 6. Systemd Service ---
echo "[+] Đang cấu hình tự động khởi chạy (Systemd)..."
cat > /etc/systemd/system/3proxy.service <<SERVICE
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
SERVICE

systemctl daemon-reload
systemctl enable 3proxy > /dev/null 2>&1
systemctl restart 3proxy

# --- 7. Finish ---
echo "------------------------------------------------"
echo "HOÀN TẤT! Đã tạo $PROXY_COUNT proxies ($IP_TYPE)."
echo "File lưu tại: $OUTPUT_FILE"
echo "------------------------------------------------"
head -n 5 $OUTPUT_FILE
echo "..."
