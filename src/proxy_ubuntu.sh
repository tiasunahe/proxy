#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ---- Paths ----
CONF_DIR="/etc/3proxy"
CONF_FILE="$CONF_DIR/3proxy.cfg"
USERS_FILE="$CONF_DIR/.proxyauth"   # lưu dạng user:CL:pass (dùng để rebuild users line)
PROXY_LIST="proxy_list.txt"

# ---- Defaults ----
DEFAULT_START_PORT=30000

# ---- Runtime collections ----
TEST_ENTRIES=()   # mỗi phần tử: host|port|user|pass (host đã gồm [] nếu IPv6)
OUTPUT_LINES=()   # dạng ip:port:user:pass để in/lưu file

# ---- Helper funcs ----
log(){ echo -e "[*] $*"; }
err(){ echo -e "[!] $*" >&2; }

# ensure conf dir
mkdir -p "$CONF_DIR"

# ---- Capability helpers ----
# Trả về danh sách port đang lắng nghe (để ước lượng số port trống)
get_used_ports(){
  ss -Htan 2>/dev/null | awk '{print $4}' | sed 's/.*://'
}

# Đếm số port trống từ START đến 65535 (giới hạn thực tế của máy)
calc_max_proxies(){
  local start_port=$1
  local used_ports
  used_ports=$(get_used_ports | sort -n | uniq)
  local max=0
  local p
  for p in $(seq "$start_port" 65535); do
    if grep -qx "$p" <<<"$used_ports"; then
      continue
    fi
    max=$((max+1))
  done
  echo "$max"
}

# ---- 1) Install deps + 3proxy .deb if not installed ----
log "Kiểm tra 3proxy..."
if ! command -v 3proxy >/dev/null 2>&1; then
  log "3proxy chưa cài. Tải và cài 3proxy-0.9.5.x86_64.deb..."
  wget -q -O /tmp/3proxy.deb "https://github.com/3proxy/3proxy/releases/download/0.9.5/3proxy-0.9.5.x86_64.deb"
  apt update -y
  apt install -y /tmp/3proxy.deb || { apt --fix-broken install -y && apt install -y /tmp/3proxy.deb; }
  log "3proxy đã được cài."
else
  VER="$(3proxy -v 2>&1 | head -n1 || true)"
  log "Tìm thấy 3proxy: $VER"
fi

# ensure basic tools exist
apt update -y >/dev/null
apt install -y wget curl iproute2 openssl || true

# ---- 2) Ask mode ----
echo
echo "Bạn muốn 'append' (thêm) hay 'reset' (tạo mới hoàn toàn)?"
read -rp "[append/reset] (mặc định reset): " MODE
MODE=${MODE:-reset}
if [[ "$MODE" != "append" && "$MODE" != "reset" ]]; then
  err "Lựa chọn không hợp lệ. Dừng."
  exit 1
fi

# ---- 3) Ask counts and ports and ip-mode ----
read -rp "Nhập số lượng proxy muốn tạo (mặc định 10): " COUNT_IN
COUNT=${COUNT_IN:-10}
# ensure integer
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -le 0 ]; then
  err "COUNT phải là số nguyên dương."
  exit 1
fi

read -rp "Nhập port bắt đầu (mặc định $DEFAULT_START_PORT): " START_PORT_IN
START_PORT_INPUT=${START_PORT_IN:-}
# If append -> calculate start port based on existing config
if [[ "$MODE" == "append" ]]; then
  if [[ -f "$CONF_FILE" ]]; then
    # find highest used -pNNNN or " -pNNNN"
    MAXPORT=$(grep -oP ' -p\K[0-9]+' "$CONF_FILE" 2>/dev/null | sort -n | tail -n1 || true)
    if [[ -n "$MAXPORT" ]]; then
      START_PORT=$((MAXPORT+1))
      log "Append mode: tìm thấy port cao nhất $MAXPORT -> START_PORT=$START_PORT"
    else
      START_PORT=${START_PORT_INPUT:-$DEFAULT_START_PORT}
      log "Append mode: không tìm port cũ, dùng START_PORT=$START_PORT"
    fi
  else
    START_PORT=${START_PORT_INPUT:-$DEFAULT_START_PORT}
    log "Append mode: không có config cũ, dùng START_PORT=$START_PORT"
  fi
else
  # reset mode
  START_PORT=${START_PORT_INPUT:-$DEFAULT_START_PORT}
fi

echo
echo "Chọn IP mode:"
echo " 1) IPv4"
echo " 2) IPv6"
echo " 3) Dual (IPv4 + IPv6)"
read -rp "Lựa chọn (mặc định 2 - IPv6): " IP_MODE
IP_MODE=${IP_MODE:-2}
if ! [[ "$IP_MODE" =~ ^[123]$ ]]; then
  err "IP_MODE không hợp lệ."
  exit 1
fi

echo
echo "Chọn loại proxy:"
echo " 1) HTTP"
echo " 2) SOCKS5"
echo " 3) HTTP + SOCKS5"
read -rp "Lựa chọn (mặc định 1 - HTTP): " PROTO
PROTO=${PROTO:-1}
if ! [[ "$PROTO" =~ ^[123]$ ]]; then
  err "Lựa chọn loại proxy không hợp lệ."
  exit 1
fi
PORTS_PER_PROXY=1
[[ "$PROTO" -eq 3 ]] && PORTS_PER_PROXY=2

# ---- 3b) Ước tính số proxy tối đa từ dải port còn trống ----
MAX_CAP_PORTS=$(calc_max_proxies "$START_PORT")
if [[ "$MAX_CAP_PORTS" -le 0 ]]; then
  err "Không còn port trống từ $START_PORT đến 65535."
  exit 1
fi
MAX_CAP=$((MAX_CAP_PORTS / PORTS_PER_PROXY))
if [[ "$MAX_CAP" -le 0 ]]; then
  err "Không đủ port trống cho loại proxy đã chọn (cần $PORTS_PER_PROXY port/proxy)."
  exit 1
fi
log "Ước tính máy có thể tạo tối đa $MAX_CAP proxy (dựa trên port khả dụng, $PORTS_PER_PROXY port/proxy)."

if [[ "$COUNT" -gt "$MAX_CAP" ]]; then
  echo "Bạn yêu cầu $COUNT proxy nhưng ước tính tối đa là $MAX_CAP."
  read -rp "Nhập lại số lượng (<= $MAX_CAP) hoặc 0 để thoát: " COUNT_NEW
  COUNT=${COUNT_NEW:-$MAX_CAP}
  if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -le 0 ] || [ "$COUNT" -gt "$MAX_CAP" ]; then
    err "Lựa chọn không hợp lệ. Dừng."
    exit 1
  fi
fi

# Detect IPv4
IP4=$(curl -4 -s ifconfig.me || hostname -I | awk '{print $1}')
log "Detected public IPv4: $IP4"

# If IPv6 needed: try detect prefix first, else ask user
if [[ "$IP_MODE" -eq 2 || "$IP_MODE" -eq 3 ]]; then
  # attempt get base prefix from first global IPv6 on default iface
  IFACE=$(ip -o -4 route show to default | awk '{print $5}' || true)
  PREFIX_DET=""
  if [[ -n "$IFACE" ]]; then
    PREFIX_DET=$(ip -6 addr show dev "$IFACE" | grep -oP 'inet6 \K[^/ ]+' | grep -v '^fe80' | head -n1 || true)
  fi
  if [[ -n "$PREFIX_DET" ]]; then
    # keep first 4 hextets
    PREFIX=$(echo "$PREFIX_DET" | cut -d: -f1-4)
    log "Phát hiện prefix IPv6: $PREFIX (tự động)"
  else
    read -rp "Nhập IPv6 prefix (ví dụ 2a01:4f8:123:abc) - bắt buộc nếu chọn IPv6: " PREFIX
    if [[ -z "$PREFIX" ]]; then
      err "Bạn phải cung cấp IPv6 prefix."
      exit 1
    fi
  fi
fi

# ---- 4) Prepare files ----
# backup existing if reset
if [[ "$MODE" == "reset" ]]; then
  ts=$(date +%s)
  if [[ -f "$CONF_FILE" ]]; then
    cp -a "$CONF_FILE" "${CONF_FILE}.${ts}.bak"
    log "Backup config tại ${CONF_FILE}.${ts}.bak"
  fi
  if [[ -f "$USERS_FILE" ]]; then
    cp -a "$USERS_FILE" "${USERS_FILE}.${ts}.bak"
  fi
  : > "$CONF_FILE"
  : > "$USERS_FILE"
  log "Reset $CONF_FILE và $USERS_FILE"
fi

# ensure proxy list file exists (append mode should append)
: > "$PROXY_LIST.tmp"

# ---- 5) Utility generators ----
rand_user(){ printf "u%s" "$(openssl rand -hex 3)"; }
rand_pass(){ printf "p%s" "$(openssl rand -hex 5)"; }
gen_ipv6() {
  # generate 4 random 16-bit blocks hex (4 hextets)
  local a b c d
  a=$(printf '%04x' $((RANDOM*RANDOM % 65536)))
  b=$(printf '%04x' $((RANDOM*RANDOM % 65536)))
  c=$(printf '%04x' $((RANDOM*RANDOM % 65536)))
  d=$(printf '%04x' $((RANDOM*RANDOM % 65536)))
  echo "${PREFIX}:${a}:${b}:${c}:${d}"
}

# ---- 6) Collect new users lines and config snippets ----
NEW_USERS=()
SNIPPETS=()
PORT=$START_PORT

for ((i=1;i<=COUNT;i++)); do
  U=$(rand_user)
  P=$(rand_pass)
  NEW_USERS+=("${U}:CL:${P}")

  HOST_OUT=""
  HOST_URL=""

  case "$IP_MODE" in
    1)
      # IPv4 only
      if [[ "$PROTO" -eq 1 || "$PROTO" -eq 3 ]]; then
        SNIPPETS+=("allow ${U}"$'\n'"proxy -n -a -p${PORT} -i${IP4} -e${IP4}")
        HOST_OUT="${IP4}"
        HOST_URL="${IP4}"
        OUTPUT_LINES+=("${HOST_OUT}:${PORT}:${U}:${P}")
        TEST_ENTRIES+=("${HOST_URL}|${PORT}|${U}|${P}|http")
      fi
      if [[ "$PROTO" -eq 2 || "$PROTO" -eq 3 ]]; then
        SOCKS_PORT=$PORT
        [[ "$PROTO" -eq 3 ]] && SOCKS_PORT=$((PORT+1))
        SNIPPETS+=("allow ${U}"$'\n'"socks -n -a -p${SOCKS_PORT} -i${IP4} -e${IP4}")
        OUTPUT_LINES+=("${IP4}:${SOCKS_PORT}:${U}:${P}")
        TEST_ENTRIES+=("${IP4}|${SOCKS_PORT}|${U}|${P}|socks")
      fi
      ;;
    2)
      # IPv6 only
      IPV6=$(gen_ipv6)
      # add IPv6 to interface ephemeral
      # choose default iface for IPv4 route if available; fallback to first non-loop6
      IFACE=${IFACE:-$(ip -o -6 addr show scope global | awk -F: '{print $2}' | awk '{$1=$1};1' | head -n1)}
      if [[ -n "$IFACE" ]]; then
        ip -6 addr add "${IPV6}/64" dev "$IFACE" 2>/dev/null || true
      fi
      if [[ "$PROTO" -eq 1 || "$PROTO" -eq 3 ]]; then
        SNIPPETS+=("allow ${U}"$'\n'"proxy -6 -n -a -p${PORT} -i:: -e${IPV6}")
        HOST_OUT="[${IPV6}]"
        HOST_URL="[${IPV6}]"
        OUTPUT_LINES+=("${HOST_OUT}:${PORT}:${U}:${P}")
        TEST_ENTRIES+=("${HOST_URL}|${PORT}|${U}|${P}|http")
      fi
      if [[ "$PROTO" -eq 2 || "$PROTO" -eq 3 ]]; then
        SOCKS_PORT=$PORT
        [[ "$PROTO" -eq 3 ]] && SOCKS_PORT=$((PORT+1))
        SNIPPETS+=("allow ${U}"$'\n'"socks -6 -n -a -p${SOCKS_PORT} -i:: -e${IPV6}")
        OUTPUT_LINES+=("[${IPV6}]:${SOCKS_PORT}:${U}:${P}")
        TEST_ENTRIES+=("[${IPV6}]|${SOCKS_PORT}|${U}|${P}|socks")
      fi
      ;;
    3)
      # Dual
      IPV6=$(gen_ipv6)
      IFACE=${IFACE:-$(ip -o -6 addr show scope global | awk -F: '{print $2}' | awk '{$1=$1};1' | head -n1)}
      if [[ -n "$IFACE" ]]; then
        ip -6 addr add "${IPV6}/64" dev "$IFACE" 2>/dev/null || true
      fi
      if [[ "$PROTO" -eq 1 || "$PROTO" -eq 3 ]]; then
        SNIPPETS+=("allow ${U}"$'\n'"proxy -6 -n -a -p${PORT} -i${IP4} -e${IPV6}")
        HOST_OUT="${IP4}"
        HOST_URL="${IP4}"
        OUTPUT_LINES+=("${HOST_OUT}:${PORT}:${U}:${P}")
        TEST_ENTRIES+=("${HOST_URL}|${PORT}|${U}|${P}|http")
      fi
      if [[ "$PROTO" -eq 2 || "$PROTO" -eq 3 ]]; then
        SOCKS_PORT=$PORT
        [[ "$PROTO" -eq 3 ]] && SOCKS_PORT=$((PORT+1))
        SNIPPETS+=("allow ${U}"$'\n'"socks -6 -n -a -p${SOCKS_PORT} -i${IP4} -e${IPV6}")
        OUTPUT_LINES+=("${IP4}:${SOCKS_PORT}:${U}:${P}")
        TEST_ENTRIES+=("${IP4}|${SOCKS_PORT}|${U}|${P}|socks")
      fi
      ;;
  esac

  PORT=$((PORT+PORTS_PER_PROXY))
done

# ghi tạm danh sách proxy để dùng cho lưu file
: > "$PROXY_LIST.tmp"
for line in "${OUTPUT_LINES[@]}"; do
  echo "$line" >> "$PROXY_LIST.tmp"
done

# ---- 7) Update users list in config
# 3proxy supports single "users ..." line with many users separated by space
# We will append new users to existing users line if present; else create new.
if grep -qE '^users ' "$CONF_FILE" 2>/dev/null; then
  # get existing remainder after 'users '
  EXISTING_USERS=$(sed -nE 's/^users[[:space:]]+//p' "$CONF_FILE" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')
  # append new users
  NEW_USERS_JOINED=$(printf " %s" "${NEW_USERS[@]}" | sed 's/^ //')
  # replace users line
  sed -i -E "s/^users[[:space:]]+.*/users ${EXISTING_USERS}${NEW_USERS_JOINED}/" "$CONF_FILE"
else
  # add users line near top of file
  NEW_USERS_JOINED=$(printf " %s" "${NEW_USERS[@]}" | sed 's/^ //')
  # insert at start
  tmpf=$(mktemp)
  {
    echo "users ${NEW_USERS_JOINED}"
    cat "$CONF_FILE"
  } > "$tmpf"
  mv "$tmpf" "$CONF_FILE"
fi

# ensure auth strong present
if ! grep -qE '^auth ' "$CONF_FILE" 2>/dev/null; then
  sed -i '1i auth strong' "$CONF_FILE"
fi

# ---- 8) Append allow/proxy lines ----
for s in "${SNIPPETS[@]}"; do
  echo -e "$s" >> "$CONF_FILE"
done

# ensure flush at EOF
if ! tail -n1 "$CONF_FILE" | grep -q '^flush'; then
  echo "flush" >> "$CONF_FILE"
fi

# ---- 9) Save proxy list
if [[ -f "$PROXY_LIST" && "$MODE" == "append" ]]; then
  # append
  cat "$PROXY_LIST.tmp" >> "$PROXY_LIST"
else
  # replace
  mv "$PROXY_LIST.tmp" "$PROXY_LIST"
fi

# ---- 10) Restart 3proxy and show status ----
log "Restarting 3proxy..."
systemctl daemon-reload || true
systemctl restart 3proxy

sleep 1
systemctl status 3proxy --no-pager || true

# ---- 11) Test thử proxy vừa tạo ----
log "Kiểm tra hoạt động proxy (curl https://api.ipify.org, timeout 5s)..."
FAIL=0
for entry in "${TEST_ENTRIES[@]}"; do
  IFS='|' read -r H PR U P PT <<<"$entry"
  if [[ "$PT" == "socks" ]]; then
    CURL_PROXY="socks5h://${U}:${P}@${H}:${PR}"
  else
    CURL_PROXY="http://${U}:${P}@${H}:${PR}"
  fi
  URL_TEST="https://api.ipify.org"
  [[ "$H" == [* ]] && URL_TEST="https://api64.ipify.org"
  if curl -x "$CURL_PROXY" -s --max-time 8 "$URL_TEST" >/dev/null; then
    echo "[OK] ${H}:${PR}:${U}:${P} (${PT})"
  else
    echo "[FAIL] ${H}:${PR}:${U}:${P} (${PT})"
    FAIL=$((FAIL+1))
  fi
done
if [[ "$FAIL" -gt 0 ]]; then
  err "$FAIL proxy không kiểm tra được."
else
  log "Tất cả proxy kiểm tra thành công."
fi

log "Hoàn tất. Danh sách proxy lưu: $PROXY_LIST"
echo "---- proxy list ----"
cat "$PROXY_LIST"
