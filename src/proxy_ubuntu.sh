#!/bin/bash

# ================================
#  AUTO PROXY BUILDER FOR UBUNTU
# ================================

clear
echo "==== AUTO PROXY BUILDER FOR UBUNTU ===="
echo "Script by ChatGPT"
echo

# Check root
if [[ $EUID -ne 0 ]]; then
    echo "Vui lòng chạy bằng quyền root!"
    exit 1
fi

# ----------------------------------------
# Cài đặt gói cần thiết
# ----------------------------------------
echo "[1] Cài đặt thư viện cần thiết..."
apt update -y
apt install -y gcc make wget git unzip iptables net-tools pwgen

# Cài 3proxy (nhẹ và ổn định)
if [ ! -f /usr/local/bin/3proxy ]; then
    echo "[2] Cài 3proxy..."
    cd /opt
    wget https://github.com/3proxy/3proxy/archive/0.9.4.zip -O 3proxy.zip
    unzip 3proxy.zip
    cd 3proxy-0.9.4
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy
    cp src/3proxy /usr/local/bin/
fi

# ----------------------------------------
# Kiểm tra khả năng tạo proxy
# ----------------------------------------
echo
echo "==== KIỂM TRA KHẢ NĂNG TẠO PROXY ===="

IPV4=$(curl -4 -s ifconfig.me)
IPV6=$(curl -6 -s ifconfig.me)

echo "IPv4 máy chủ: $IPV4"
echo "IPv6 máy chủ: $IPV6"
echo

echo "Bạn muốn tạo proxy loại nào?"
echo "1) IPv4"
echo "2) IPv6"
read -p "Chọn 1 hoặc 2: " PROXY_TYPE

if [[ $PROXY_TYPE == "1" ]]; then
    PROXY_VERSION="ipv4"
    SERVER_IP=$IPV4
else
    PROXY_VERSION="ipv6"
    SERVER_IP=$IPV6
fi

# ----------------------------------------
# Nhập số lượng proxy
# ----------------------------------------
echo
read -p "Nhập số lượng proxy cần tạo: " COUNT

# ----------------------------------------
# Tạo user/pass random
# ----------------------------------------
USER="u$(pwgen 6 1)"
PASS="p$(pwgen 8 1)"

echo
echo "User: $USER"
echo "Pass: $PASS"

# ----------------------------------------
# Tạo port không trùng (nếu chạy nhiều lần)
# ----------------------------------------
BASE_PORT=20000
PORT_FILE="/usr/local/etc/3proxy/lastport"

if [ -f "$PORT_FILE" ]; then
    START_PORT=$(cat $PORT_FILE)
else
    START_PORT=$BASE_PORT
fi

END_PORT=$((START_PORT + COUNT))
echo $END_PORT > $PORT_FILE

# ----------------------------------------
# Tạo config 3proxy
# ----------------------------------------
CONF="/usr/local/etc/3proxy/3proxy.cfg"
BACKUP="/usr/local/etc/3proxy/3proxy.cfg.bak"

cp $CONF $BACKUP 2>/dev/null

echo "daemon" > $CONF
echo "nserver 8.8.8.8" >> $CONF
echo "nserver 1.1.1.1" >> $CONF
echo "maxconn 2048" >> $CONF
echo "timeouts 1 5 30 60 180 1800 15 60" >> $CONF
echo "auth strong" >> $CONF
echo "users $USER:CL:$PASS" >> $CONF

echo >> $CONF
echo "allow $USER" >> $CONF

PROXY_LIST="proxy_list.txt"
rm -f $PROXY_LIST

# ----------------------------------------
# Tạo IPv6 prefix nếu cần
# ----------------------------------------
if [[ $PROXY_TYPE == "2" ]]; then
    echo "Đang tạo IPv6 ngẫu nhiên..."
    IPV6_PREFIX=$(echo $IPV6 | cut -d':' -f1-4)
fi

# ----------------------------------------
# Tạo proxy từng port
# ----------------------------------------
echo
echo "Đang tạo proxy..."

for ((port=$START_PORT; port<$END_PORT; port++)); do

    if [[ $PROXY_TYPE == "2" ]]; then
        RAND=$(printf "%x:%x:%x:%x" $RANDOM $RANDOM $RANDOM $RANDOM)
        IPV6_FULL="$IPV6_PREFIX:$RAND"

        ip -6 addr add $IPV6_FULL/64 dev ens3 2>/dev/null
        IP_USED=$IPV6_FULL
    else
        IP_USED=$SERVER_IP
    fi

    echo "proxy -6 -p$port -a -i$SERVER_IP -e$IP_USED" >> $CONF
    echo "$IP_USED:$port:$USER:$PASS" >> $PROXY_LIST
done

# ----------------------------------------
# Restart 3proxy service
# ----------------------------------------
echo
echo "Khởi động lại 3proxy..."

pkill 3proxy 2>/dev/null
/usr/local/bin/3proxy $CONF

echo
echo "=== HOÀN TẤT ==="
echo "Proxy được lưu tại: $PROXY_LIST"
echo

echo "Danh sách proxy:"
cat $PROXY_LIST
