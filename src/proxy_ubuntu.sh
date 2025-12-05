#!/bin/bash
clear
echo "================= PROXY AUTO INSTALLER ================="
echo "Hệ điều hành: Ubuntu (đã cài aaPanel)"
echo "Công cụ: 3proxy 0.9.4"
echo "========================================================="

# =========================
# 1. Cài thư viện cần thiết
# =========================
echo "[1] Cài đặt thư viện..."
apt update -y
apt install git make gcc wget unzip build-essential net-tools -y

# =========================
# 2. Build & cài 3proxy
# =========================
echo "[2] Tải & build 3proxy..."

cd /opt
rm -rf 3proxy.zip 3proxy-0.9.4

wget https://github.com/3proxy/3proxy/archive/0.9.4.zip -O 3proxy.zip
unzip 3proxy.zip
cd 3proxy-0.9.4

make -f Makefile.Linux
make -f Makefile.Linux install

mkdir -p /usr/local/etc/3proxy/
cp bin/3proxy /usr/local/bin/

# =========================
# 3. Lấy IP máy chủ
# =========================
IPV4=$(curl -4 -s ifconfig.me)
IPV6=$(curl -6 -s ifconfig.me)

echo "IPv4: $IPV4"
echo "IPv6: $IPV6"

# =========================
# 4. Chọn loại proxy
# =========================
echo ""
echo "Bạn muốn tạo proxy loại nào?"
echo "1) IPv4"
echo "2) IPv6"

read -p "Nhập lựa chọn: " PROXY_TYPE

# Nếu không có IPv6 thì ép về IPv4
if [[ "$PROXY_TYPE" == "2" && -z "$IPV6" ]]; then
    echo "⚠ VPS không có IPv6 → Chỉ có thể tạo IPv4."
    PROXY_TYPE=1
fi

# =========================
# 5. Nhập số lượng proxy
# =========================
read -p "Nhập số lượng proxy muốn tạo: " COUNT

# =========================
# 6. Tạo user/pass random
# =========================
USER=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 10)

echo ""
echo "User: $USER"
echo "Pass: $PASS"
echo ""

# =========================
# 7. Tạo danh sách port
# =========================
START_PORT=30000
END_PORT=$((START_PORT + COUNT))

# =========================
# 8. Tạo file cấu hình 3proxy
# =========================
echo "[3] Tạo file cấu hình..."

CONFIG_FILE="/usr/local/etc/3proxy/3proxy.cfg"

cat > $CONFIG_FILE <<EOF
daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.8.8
timeouts 1 5 30 60 180 1800 15 60
log /usr/local/etc/3proxy/3proxy.log
auth strong
users $USER:CL:$PASS
EOF

for ((PORT=$START_PORT; PORT<END_PORT; PORT++)); do
    if [[ "$PROXY_TYPE" == "1" ]]; then
        echo "proxy -n -a -p$PORT -i$IPV4 -e$IPV4" >> $CONFIG_FILE
    else
        echo "proxy -6 -n -a -p$PORT -i$IPV6 -e$IPV6" >> $CONFIG_FILE
    fi
done

# =========================
# 9. Restart 3proxy
# =========================
echo "[4] Khởi động 3proxy..."

pkill 3proxy >/dev/null 2>&1
sleep 1
/usr/local/bin/3proxy $CONFIG_FILE &

sleep 1

# =========================
# 10. Xuất file proxy_list.txt
# =========================
echo "[5] Xuất danh sách proxy..."

OUTPUT="proxy_list.txt"
rm -f $OUTPUT

for ((PORT=$START_PORT; PORT<END_PORT; PORT++)); do
    if [[ "$PROXY_TYPE" == "1" ]]; then
        echo "$IPV4:$PORT:$USER:$PASS" >> $OUTPUT
    else
        echo "[$IPV6]:$PORT:$USER:$PASS" >> $OUTPUT
    fi
done

echo ""
echo "=== HOÀN TẤT ==="
echo "Proxy được lưu tại: $OUTPUT"
echo ""
echo "Danh sách proxy:"
cat $OUTPUT
echo ""
