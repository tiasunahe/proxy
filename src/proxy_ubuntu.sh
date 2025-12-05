#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export LANG=C
umask 027

STATE_DIR="/opt/proxy-manager"
CONFIG_FILE="${STATE_DIR}/3proxy.cfg"
AUTH_FILE="${STATE_DIR}/.proxyauth"
STATE_ENV="${STATE_DIR}/state.env"
PROXY_CSV="${STATE_DIR}/proxies.csv"
OUTPUT_DIR="${STATE_DIR}/output"
LOG_DIR="${STATE_DIR}/logs"
DOCKER_DIR="${STATE_DIR}/docker"
DOCKERFILE="${DOCKER_DIR}/Dockerfile"
SERVICE_FILE="/etc/systemd/system/proxy-manager.service"

BASE_PORT_DEFAULT=24000
MAX_PORT_LIMIT=65000
RESERVED_FD=128

MODE="native"
IP_VERSION="ipv4"
ACTION="new"
BASE_PORT=${BASE_PORT_DEFAULT}
NEXT_PORT=${BASE_PORT_DEFAULT}
NEW_PROXY_COUNT=0
LAST_PORT=$((BASE_PORT_DEFAULT - 1))

PRIMARY_IPV4=""
PRIMARY_IPV6=""
PUBLIC_IPV4=""
PUBLIC_IPV6=""

declare -a PROXY_USERS=()
declare -a PROXY_PASSWORDS=()
declare -a PROXY_PORTS=()
declare -a PROXY_BIND_IPS=()
declare -a PROXY_PUBLIC_IPS=()
declare -a PROXY_VERSIONS=()

declare -A USED_PORT_MAP=()

log_info() {
  printf '[INFO] %s\n' "$1"
}

log_warn() {
  printf '[WARN] %s\n' "$1"
}

log_error() {
  printf '[ERROR] %s\n' "$1" >&2
}

fatal() {
  log_error "$1"
  exit 1
}

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    fatal "Vui lòng chạy script với quyền root (sudo)."
  fi
}

check_os() {
  if [[ ! -r /etc/os-release ]]; then
    fatal "Không xác định được phiên bản hệ điều hành."
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ ${ID,,} != "ubuntu" ]]; then
    fatal "Script chỉ hỗ trợ Ubuntu Server."
  fi
}

print_banner() {
  cat <<'EOF'
========================================
   Proxy Automation for Ubuntu + aaPanel
========================================
EOF
}

check_aapanel() {
  if [[ ! -d /www/server/panel ]]; then
    log_warn "Không tìm thấy aaPanel. Vẫn tiếp tục theo mặc định."
  else
    log_info "Đã phát hiện aaPanel."
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_directories() {
  mkdir -p "$STATE_DIR" "$OUTPUT_DIR" "$LOG_DIR" "$DOCKER_DIR"
}

ensure_system_user() {
  if ! id -u proxyctl >/dev/null 2>&1; then
    useradd --system --home-dir "$STATE_DIR" --shell /usr/sbin/nologin proxyctl >/dev/null 2>&1 || true
  fi
}

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  log_info "Cập nhật apt và cài đặt gói phụ thuộc..."
  apt-get update -y >/dev/null
  apt-get install -y curl wget jq pwgen uuid-runtime bc lsof net-tools iproute2 ca-certificates gnupg software-properties-common >/dev/null
}

ensure_3proxy() {
  if ! command_exists 3proxy; then
    log_info "Cài đặt 3proxy..."
    apt-get install -y 3proxy >/dev/null
  fi
}

ensure_docker() {
  if command_exists docker; then
    return
  fi
  log_info "Cài đặt Docker..."
  apt-get install -y docker.io >/dev/null
  systemctl enable --now docker >/dev/null
}

load_state_env() {
  if [[ -f "$STATE_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_ENV"
    ACTION="existing"
    NEXT_PORT=$((LAST_PORT + 1))
  else
    ACTION="new"
    BASE_PORT=${BASE_PORT_DEFAULT}
    NEXT_PORT=${BASE_PORT_DEFAULT}
    LAST_PORT=$((BASE_PORT_DEFAULT - 1))
  fi
}

clear_proxy_arrays() {
  PROXY_USERS=()
  PROXY_PASSWORDS=()
  PROXY_PORTS=()
  PROXY_BIND_IPS=()
  PROXY_PUBLIC_IPS=()
  PROXY_VERSIONS=()
}

load_existing_proxies() {
  if [[ ! -f "$PROXY_CSV" ]]; then
    return
  fi
  while IFS=',' read -r version bind_ip public_ip port user pass; do
    [[ -z "$port" ]] && continue
    PROXY_VERSIONS+=("$version")
    PROXY_BIND_IPS+=("$bind_ip")
    PROXY_PUBLIC_IPS+=("$public_ip")
    PROXY_PORTS+=("$port")
    PROXY_USERS+=("$user")
    PROXY_PASSWORDS+=("$pass")
  done < "$PROXY_CSV"
}

show_existing_summary() {
  local existing_count=${#PROXY_PORTS[@]}
  if [[ $existing_count -eq 0 ]]; then
    return
  fi
  log_info "Đang có $existing_count proxy được cấu hình (chế độ $MODE, IP $IP_VERSION)."
}

prompt_existing_action() {
  local existing_count=${#PROXY_PORTS[@]}
  if [[ $existing_count -eq 0 ]]; then
    return
  fi
  show_existing_summary
  cat <<'MENU'
Tùy chọn:
  1) Thêm proxy vào cấu hình hiện tại
  2) Ghi đè toàn bộ cấu hình bằng bộ mới
  3) Xuất danh sách proxy và thoát
  4) Thoát mà không thay đổi
MENU
  local choice=""
  while true; do
    read -rp "Chọn (1-4): " choice
    case "$choice" in
      1)
        ACTION="append"
        NEXT_PORT=$((LAST_PORT + 1))
        return
        ;;
      2)
        ACTION="overwrite"
        clear_proxy_arrays
        BASE_PORT=${BASE_PORT_DEFAULT}
        NEXT_PORT=${BASE_PORT_DEFAULT}
        LAST_PORT=$((BASE_PORT_DEFAULT - 1))
        return
        ;;
      3)
        emit_proxy_output only_stdout
        exit 0
        ;;
      4)
        log_warn "Không thay đổi gì." && exit 0
        ;;
      *)
        log_warn "Lựa chọn không hợp lệ."
        ;;
    esac
  done
}

save_state_env() {
  cat > "$STATE_ENV" <<EOF
MODE=$MODE
IP_VERSION=$IP_VERSION
BASE_PORT=$BASE_PORT
LAST_PORT=$LAST_PORT
EOF
}

write_proxy_csv() {
  : > "$PROXY_CSV"
  local idx
  for idx in "${!PROXY_PORTS[@]}"; do
    printf '%s,%s,%s,%s,%s,%s\n' \
      "${PROXY_VERSIONS[$idx]}" \
      "${PROXY_BIND_IPS[$idx]}" \
      "${PROXY_PUBLIC_IPS[$idx]}" \
      "${PROXY_PORTS[$idx]}" \
      "${PROXY_USERS[$idx]}" \
      "${PROXY_PASSWORDS[$idx]}" >> "$PROXY_CSV"
  done
}

# Thu thập toàn bộ port đã dùng (dịch vụ khác + proxy cũ)
refresh_port_map() {
  USED_PORT_MAP=()
  local port
  while read -r port; do
    [[ -z "$port" ]] && continue
    USED_PORT_MAP[$port]=1
  done < <(ss -Htan 2>/dev/null | awk '{print $4}' | sed -nE 's/.*:([0-9]+)$/\1/p')
  for port in "${PROXY_PORTS[@]}"; do
    USED_PORT_MAP[$port]=1
  done
}

calculate_max_proxies() {
  local start_port=$1
  local end_port=$2
  refresh_port_map
  local available=0
  local port
  for ((port=start_port; port<=end_port; port++)); do
    if [[ -z "${USED_PORT_MAP[$port]:-}" ]]; then
      ((available++))
    fi
  done
  local fd_limit
  fd_limit=$(ulimit -n)
  local safe_limit=$((fd_limit - RESERVED_FD))
  if ((safe_limit < 1)); then
    safe_limit=1
  fi
  if ((available > safe_limit)); then
    available=$safe_limit
  fi
  echo "$available"
}

find_next_free_port() {
  local candidate=$1
  while ((candidate <= MAX_PORT_LIMIT)); do
    if [[ -z "${USED_PORT_MAP[$candidate]:-}" ]]; then
      USED_PORT_MAP[$candidate]=1
      echo "$candidate"
      return
    fi
    candidate=$((candidate + 1))
  done
  echo ""
}

prompt_mode() {
  if [[ "$ACTION" == "append" ]]; then
    log_info "Giữ nguyên chế độ hiện tại: $MODE."
    return
  fi
  local selection=""
  while true; do
    read -rp "Chọn chế độ triển khai [1-native / 2-docker] (mặc định 1): " selection
    selection=${selection:-1}
    case "$selection" in
      1)
        MODE="native"
        return
        ;;
      2)
        MODE="docker"
        return
        ;;
      *)
        log_warn "Vui lòng chọn 1 hoặc 2."
        ;;
    esac
  done
}

prompt_ip_version() {
  if [[ "$ACTION" == "append" ]]; then
    log_info "Giữ nguyên phiên bản IP: $IP_VERSION."
    return
  fi
  local has_ipv6=0
  if [[ -n "$PRIMARY_IPV6" ]]; then
    has_ipv6=1
  fi
  local selection=""
  while true; do
    if ((has_ipv6)); then
      read -rp "Chọn loại proxy [4-IPv4 / 6-IPv6] (mặc định 4): " selection
      selection=${selection:-4}
      case "$selection" in
        4)
          IP_VERSION="ipv4"
          return
          ;;
        6)
          IP_VERSION="ipv6"
          return
          ;;
        *)
          log_warn "Lựa chọn không hợp lệ."
          ;;
      esac
    else
      log_warn "Không phát hiện IPv6 global. Sử dụng IPv4."
      IP_VERSION="ipv4"
      return
    fi
  done
}

prompt_base_port() {
  if [[ "$ACTION" == "append" ]]; then
    log_info "Port bắt đầu giữ nguyên ở $BASE_PORT."
    return
  fi
  local input
  while true; do
    read -rp "Nhập port bắt đầu [$BASE_PORT]: " input
    input=${input:-$BASE_PORT}
    if [[ "$input" =~ ^[0-9]+$ ]] && ((input >= 1024 && input <= MAX_PORT_LIMIT)); then
      BASE_PORT=$input
      NEXT_PORT=$input
      LAST_PORT=$((input - 1))
      return
    fi
    log_warn "Port không hợp lệ."
  done
}

prompt_proxy_count() {
  local available=$1
  if ((available <= 0)); then
    fatal "Không còn port trống để tạo proxy mới."
  fi
  local input
  while true; do
    read -rp "Nhập số lượng proxy muốn tạo (1-$available): " input
    if [[ "$input" =~ ^[0-9]+$ ]] && ((input >= 1 && input <= available)); then
      NEW_PROXY_COUNT=$input
      return
    fi
    log_warn "Số lượng không hợp lệ."
  done
}

# Lấy IP public từ nhiều nguồn, tránh lỗi dịch vụ ngoài
fetch_public_ip() {
  local curl_flag=$1
  shift
  local endpoint
  local ip=""
  for endpoint in "$@"; do
    if ip=$(curl "$curl_flag" -fsS --max-time 5 "$endpoint" 2>/dev/null); then
      ip=$(echo "$ip" | tr -d '\r' | tr -d '\n')
      if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
      fi
    fi
  done
  echo ""
  return 1
}

collect_network_info() {
  PRIMARY_IPV4=$(ip -4 addr show scope global up | awk '/inet / {print $2}' | cut -d'/' -f1 | head -n1)
  PRIMARY_IPV6=$(ip -6 addr show scope global up | awk '/inet6 / && $2 !~ /fe80/ {print $2}' | cut -d'/' -f1 | head -n1)
  if [[ -z "$PRIMARY_IPV4" ]]; then
    fatal "Không tìm thấy IPv4 public."
  fi
  local ipv4_sources=(https://ifconfig.io https://api.ipify.org https://ipv4.icanhazip.com)
  PUBLIC_IPV4=$(fetch_public_ip -4 "${ipv4_sources[@]}")
  if [[ -z "$PUBLIC_IPV4" ]]; then
    PUBLIC_IPV4="$PRIMARY_IPV4"
    log_warn "Không truy vấn được IPv4 public qua dịch vụ ngoài, dùng IP cục bộ."
  fi
  if [[ -n "$PRIMARY_IPV6" ]]; then
    local ipv6_sources=(https://ifconfig.io https://api64.ipify.org https://ipv6.icanhazip.com)
    PUBLIC_IPV6=$(fetch_public_ip -6 "${ipv6_sources[@]}")
    if [[ -z "$PUBLIC_IPV6" ]]; then
      PUBLIC_IPV6="$PRIMARY_IPV6"
        log_warn "Không truy vấn được IPv6 public qua dịch vụ ngoài, dùng IP cục bộ."
      fi
    else
      PUBLIC_IPV6=""
      log_warn "Không tìm thấy IPv6 global."
    fi
  }

generate_token() {
  if command_exists openssl; then
    openssl rand -hex 6
  else
    uuidgen | tr -d '-' | cut -c1-12
  fi
}

# Random hoá thông tin đăng nhập và phân bổ port sạch
generate_proxy_batch() {
  local count=$1
  local bind_ip=""
  local public_ip=""
  if [[ "$IP_VERSION" == "ipv6" ]]; then
    if [[ -z "$PRIMARY_IPV6" ]]; then
      fatal "Không có IPv6 để cấp phát."
    fi
    bind_ip="$PRIMARY_IPV6"
    public_ip="$PUBLIC_IPV6"
  else
    bind_ip="$PRIMARY_IPV4"
    public_ip="$PUBLIC_IPV4"
  fi
  [[ -z "$public_ip" ]] && public_ip="$bind_ip"
  refresh_port_map
  local created=0
  local candidate=$NEXT_PORT
  while ((created < count)); do
    local port
    port=$(find_next_free_port "$candidate")
    if [[ -z "$port" ]]; then
      fatal "Hết port trong khoảng cho phép."
    fi
    local user="usr$(generate_token)"
    local pass="pwd$(generate_token)"
    PROXY_PORTS+=("$port")
    PROXY_USERS+=("$user")
    PROXY_PASSWORDS+=("$pass")
    PROXY_BIND_IPS+=("$bind_ip")
    PROXY_PUBLIC_IPS+=("$public_ip")
    PROXY_VERSIONS+=("$IP_VERSION")
    candidate=$((port + 1))
    ((created++))
  done
  local last_index=$(( ${#PROXY_PORTS[@]} - 1 ))
  LAST_PORT=${PROXY_PORTS[$last_index]}
  NEXT_PORT=$((LAST_PORT + 1))
}

build_auth_file() {
  umask 077
  : > "$AUTH_FILE"
  local idx
  for idx in "${!PROXY_USERS[@]}"; do
    printf '%s:CL:%s\n' "${PROXY_USERS[$idx]}" "${PROXY_PASSWORDS[$idx]}" >> "$AUTH_FILE"
  done
}

# Tạo file cấu hình 3proxy và danh sách user/password
build_3proxy_config() {
  log_info "Đang sinh cấu hình 3proxy..."
  build_auth_file
  cat > "$CONFIG_FILE" <<EOF
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 60 120
setgid 65534
setuid 65534
stacksize 65536
log ${LOG_DIR}/3proxy.log D
rotate 30
users \$${AUTH_FILE}
auth strong
EOF
  local idx
  for idx in "${!PROXY_PORTS[@]}"; do
    echo "allow ${PROXY_USERS[$idx]}" >> "$CONFIG_FILE"
    if [[ "${PROXY_VERSIONS[$idx]}" == "ipv6" ]]; then
      echo "proxy -6 -n -a -p${PROXY_PORTS[$idx]} -i${PROXY_BIND_IPS[$idx]} -e${PROXY_BIND_IPS[$idx]}" >> "$CONFIG_FILE"
    else
      echo "proxy -n -a -p${PROXY_PORTS[$idx]} -i${PROXY_BIND_IPS[$idx]} -e${PROXY_BIND_IPS[$idx]}" >> "$CONFIG_FILE"
    fi
    echo "flush" >> "$CONFIG_FILE"
  done
}

stop_native_service() {
  if [[ -f "$SERVICE_FILE" ]]; then
    systemctl stop proxy-manager.service >/dev/null 2>&1 || true
  fi
}

disable_native_service() {
  if [[ -f "$SERVICE_FILE" ]]; then
    systemctl disable proxy-manager.service >/dev/null 2>&1 || true
  fi
}

stop_docker_container() {
  if command_exists docker && docker inspect proxy-manager >/dev/null 2>&1; then
    docker rm -f proxy-manager >/dev/null
  fi
}

deploy_native() {
  ensure_3proxy
  stop_native_service
  stop_docker_container
  build_3proxy_config
  chown -R proxyctl:proxyctl "$STATE_DIR"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Proxy Manager (3proxy)
After=network-online.target
Wants=network-online.target

[Service]
User=proxyctl
Group=proxyctl
ExecStart=/usr/bin/3proxy $CONFIG_FILE
Restart=always
RestartSec=3
LimitNOFILE=65536
WorkingDirectory=$STATE_DIR
Environment=HOME=$STATE_DIR

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now proxy-manager.service
}

deploy_docker() {
  ensure_docker
  stop_native_service
  disable_native_service
  build_3proxy_config
  cat > "$DOCKERFILE" <<'EOF'
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends 3proxy ca-certificates && rm -rf /var/lib/apt/lists/*
CMD ["/usr/bin/3proxy", "/opt/proxy-manager/3proxy.cfg"]
EOF
  docker build -t proxy-manager:latest "$DOCKER_DIR" >/dev/null
  if docker inspect proxy-manager >/dev/null 2>&1; then
    docker rm -f proxy-manager >/dev/null
  fi
  docker run -d --name proxy-manager --restart unless-stopped --network host \
    -v "$STATE_DIR":"$STATE_DIR" \
    proxy-manager:latest >/dev/null
}

emit_proxy_output() {
  local mode=${1:-full}
  local ts
  ts=$(date +%Y%m%d_%H%M%S)
  local output_file="${OUTPUT_DIR}/proxies_${ts}.txt"
  local latest_file="${OUTPUT_DIR}/proxies_latest.txt"
  local idx
  local lines=()
  for idx in "${!PROXY_PORTS[@]}"; do
    lines+=("${PROXY_PUBLIC_IPS[$idx]}:${PROXY_PORTS[$idx]}:${PROXY_USERS[$idx]}:${PROXY_PASSWORDS[$idx]}")
  done
  if [[ "$mode" == "full" ]]; then
    if ((${#lines[@]} == 0)); then
      log_warn "Chưa có proxy nào để xuất."
      return
    fi
    printf '%s\n' "${lines[@]}" | tee "$output_file" | tee "$latest_file"
    log_info "Đã lưu danh sách proxy tại $output_file"
  else
    if ((${#lines[@]} == 0)); then
      log_warn "Chưa có proxy nào trong hệ thống."
    else
      printf '%s\n' "${lines[@]}"
    fi
  fi
}

main() {
  require_root
  check_os
  print_banner
  check_aapanel
  ensure_directories
  ensure_system_user
  install_base_packages
  collect_network_info
  load_state_env
  load_existing_proxies
  prompt_existing_action
  prompt_mode
  prompt_ip_version
  prompt_base_port
  local start_port=$NEXT_PORT
  local max_new
  max_new=$(calculate_max_proxies "$start_port" "$MAX_PORT_LIMIT")
  log_info "Có thể tạo tối đa $max_new proxy mới trong phiên này."
  prompt_proxy_count "$max_new"
  generate_proxy_batch "$NEW_PROXY_COUNT"
  write_proxy_csv
  save_state_env
  if [[ "$MODE" == "docker" ]]; then
    deploy_docker
  else
    deploy_native
  fi
  emit_proxy_output full
  log_info "Hoàn tất."
}

main "$@"
