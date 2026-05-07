#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 交互式 QEMU 虚拟机创建脚本
# ============================================================

BASE_DIR="/data-sdb/fhk/docker-qemu"
BASE_IMAGE_DIR="${BASE_DIR}/base-dir"
COMPOSE_TEMPLATE="${BASE_IMAGE_DIR}/docker-compose.yaml"
DEFAULT_BASE_IMAGE="DAS-OS-M2.1.1-x86_64.img"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

prompt() {
  local var="$1" label="$2" default="${3:-}"
  local val
  if [ -n "$default" ]; then
    read -rp "$(printf "${CYAN}${BOLD}?${NC} ${label} [${default}]: ")" val
    val="${val:-$default}"
  else
    while [ -z "${val:-}" ]; do
      read -rp "$(printf "${CYAN}${BOLD}?${NC} ${label}: ")" val
    done
  fi
  printf -v "$var" '%s' "$val"
}

# ── 列出可用的基础镜像 ──────────────────────────────────────
list_base_images() {
  echo -e "\n${BOLD}可用基础镜像:${NC}"
  local i=1
  images=()
  for img in "${BASE_IMAGE_DIR}"/*.img; do
    [ -f "$img" ] || continue
    local name
    name=$(basename "$img")
    images+=("$name")
    echo -e "  ${CYAN}$i${NC}) $name"
    ((i++))
  done
  for img in "${BASE_IMAGE_DIR}"/*.qcow2; do
    [ -f "$img" ] || continue
    local name
    name=$(basename "$img")
    images+=("$name")
    echo -e "  ${CYAN}$i${NC}) $name"
    ((i++))
  done
}

# ── 收集所有已被占用的端口 ──────────────────────────────────
collect_used_ports() {
  local used=()

  while IFS= read -r line; do
    local p
    p=$(echo "$line" | grep -oP ':\K\d+' | head -1)
    [ -n "$p" ] && used+=("$p")
  done < <(ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null)

  local compose
  for compose in "${BASE_DIR}"/*/docker-compose.yaml; do
    [ -f "$compose" ] || continue
    while IFS= read -r p; do
      [ -n "$p" ] && used+=("$p")
    done < <(grep -oP '(?:WEB|VNC|WSS|WSD|MON)_PORT:\s*"?\K\d+' "$compose" 2>/dev/null)
  done

  printf '%s\n' "${used[@]}" | sort -u
}

USED_PORTS=""

is_port_used() {
  local port="$1"
  [ -z "$USED_PORTS" ] && USED_PORTS=$(collect_used_ports)
  grep -qx "$port" <<< "$USED_PORTS"
}

next_available_port() {
  local base="$1"
  while is_port_used "$base"; do
    ((base++))
  done
  echo "$base"
}

# ── IP 探测 ────────────────────────────────────────────────
IP_SUBNET="10.50.1"
IP_START=10
IP_END=254
PING_TIMEOUT=0.1
SCAN_CONCURRENCY=3

# 快速检查: VM 配置 + ARP (毫秒级, 不需要 ping)
collect_known_ips() {
  local subnet="$1"
  local known=()

  # VM 配置
  for compose in "${BASE_DIR}"/*/docker-compose.yaml; do
    [ -f "$compose" ] || continue
    local ip
    ip=$(grep -oP 'CLOUD_IP:\s*"?\K[\d.]+' "$compose" 2>/dev/null | head -1)
    [ -n "$ip" ] && known+=("$ip")
  done

  # ARP 表
  while IFS= read -r ip; do
    [ -n "$ip" ] && known+=("$ip")
  done < <(arp -an 2>/dev/null | grep -oP "\b${subnet}\.\K\d+" | sort -un | while read -r h; do echo "${subnet}.${h}"; done)

  printf '%s\n' "${known[@]}" | sort -u
}

# 并发探测: 每批 SCAN_CONCURRENCY 个, 实时输出结果
# 每发现一个未使用的 IP 就暂停询问用户
interactive_ip_scan() {
  local subnet="$1"

  # 先快速收集已知 IP
  local known_list
  known_list=$(collect_known_ips "$subnet")

  if [ -n "$known_list" ]; then
    echo -e "\n  ${BOLD}已知占用的 IP (来自 VM 配置 / ARP 表):${NC}"
    while IFS= read -r ip; do
      [ -n "$ip" ] || continue
      echo -e "    ${RED}● ${ip}  已占用${NC}"
    done <<< "$known_list"
  fi

  # 将已知 IP 写入临时文件供后续比对
  local known_file
  known_file=$(mktemp)
  [ -n "$known_list" ] && echo "$known_list" > "$known_file" || : > "$known_file"

  echo -e "\n  ${BOLD}开始并发探测 ${subnet}.${IP_START} ~ ${subnet}.${IP_END} (每批 ${SCAN_CONCURRENCY} 个)...${NC}"
  echo ""

  local h
  for ((h = IP_START; h <= IP_END; )); do
    # 取一批
    local batch=()
    local b
    for ((b = 0; b < SCAN_CONCURRENCY && h <= IP_END; b++, h++)); do
      batch+=("$h")
    done

    # 并发 ping 这一批
    local results=()
    local tmpdir
    tmpdir=$(mktemp -d)
    for host_num in "${batch[@]}"; do
      (
        if ping -c 1 -W "${PING_TIMEOUT}" "${subnet}.${host_num}" &>/dev/null; then
          echo "used" > "${tmpdir}/${host_num}"
        else
          echo "free" > "${tmpdir}/${host_num}"
        fi
      ) &
    done
    wait

    # 汇总这批结果
    for host_num in "${batch[@]}"; do
      local ip="${subnet}.${host_num}"
      local status
      status=$(cat "${tmpdir}/${host_num}" 2>/dev/null || echo "unknown")

      # 已知 IP 也要标记为 used
      if grep -qx "$ip" "$known_file" 2>/dev/null; then
        status="used"
      fi

      results+=("${ip}:${status}")
    done
    rm -rf "$tmpdir"

    # 输出这批结果, 发现可用 IP 立即询问
    for entry in "${results[@]}"; do
      local ip="${entry%%:*}"
      local st="${entry##*:}"

      if [ "$st" == "used" ]; then
        echo -e "    ${RED}● ${ip}  已占用${NC}"
      else
        echo -e "    ${GREEN}○ ${ip}  可用${NC}"
        echo ""
        echo -e "    ${GREEN}${BOLD}发现可用 IP: ${ip}${NC}"
        echo -e "    ${CYAN}y${NC}) 使用此 IP"
        echo -e "    ${CYAN}n${NC}) 跳过，继续扫描"
        echo -e "    ${CYAN}q${NC}) 停止扫描，手动输入"

        local choice
        read -rp "$(printf "    ${CYAN}${BOLD}?${NC} 请选择 [y/n/q]: ")" choice

        case "${choice,,}" in
          y|"" )
            rm -f "$known_file"
            SELECTED_IP="$ip"
            return 0
            ;;
          q )
            echo ""
            prompt CLOUD_IP_RAW "请输入 IP"
            rm -f "$known_file"
            SELECTED_IP="${CLOUD_IP_RAW%%/*}"
            return 0
            ;;
          * )
            # n / skip: 继续
            echo ""
            ;;
        esac
      fi
    done
  done

  # 全部扫完未选择
  rm -f "$known_file"
  warn "已扫描完 ${subnet}.${IP_START}~${subnet}.${IP_END}，未找到可用 IP"
  prompt CLOUD_IP_RAW "请手动输入 IP"
  SELECTED_IP="${CLOUD_IP_RAW%%/*}"
}

# ── 生成 docker-compose.yaml ───────────────────────────────
generate_compose() {
  cat > "${VM_DIR}/docker-compose.yaml" <<EOF
services:
  qemu:
    image: swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/qemux/qemu:7.29
    container_name: ${VM_NAME}
    network_mode: host
    devices:
      - /dev/kvm
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
    volumes:
      - ./qemu:/storage
      - ./boot.qcow2:/boot.qcow2
      - ${BASE_IMAGE_DIR}/network.sh:/run/network.sh
      - ${BASE_IMAGE_DIR}/disk.sh:/run/disk.sh
      - ${BASE_IMAGE_DIR}:${BASE_IMAGE_DIR}
    restart: always
    stop_grace_period: 2m
    environment:
      DEBUG: "Y"
      DISK_SIZE: "${DISK_SIZE}"
      RAM_SIZE: "${RAM_SIZE}"
      CPU_CORES: "${CPU_CORES}"
      NETWORK: "host"
      HOST_BRIDGE: "${HOST_BRIDGE}"
      CLOUD_USER: "${CLOUD_USER}"
      CLOUD_PASS: "${CLOUD_PASS}"
      CLOUD_IP: "${CLOUD_IP}"
      WEB_PORT: "${WEB_PORT}"
      VNC_PORT: "${VNC_PORT}"
      WSS_PORT: "${WSS_PORT}"
      WSD_PORT: "${WSD_PORT}"
      MON_PORT: "${MON_PORT}"
EOF
}

# ============================================================
# 主流程
# ============================================================

echo -e "\n${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║     QEMU 虚拟机创建向导                  ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}\n"

# ── 1. 虚拟机名称 ──────────────────────────────────────────
prompt VM_NAME "虚拟机名称 (英文，用作目录名和容器名)"
VM_DIR="${BASE_DIR}/${VM_NAME}"

if [ -d "$VM_DIR" ]; then
  error "目录 ${VM_DIR} 已存在！"
  read -rp "是否删除并重建？[y/N]: " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    info "已取消"
    exit 0
  fi
  rm -rf "$VM_DIR"
fi

# ── 2. 选择基础镜像 ───────────────────────────────────────
list_base_images
if [ ${#images[@]} -eq 0 ]; then
  error "未在 ${BASE_IMAGE_DIR} 中找到基础镜像 (*.img / *.qcow2)"
  exit 1
fi

prompt IMG_CHOICE "选择基础镜像编号" "1"
while ! [[ "${IMG_CHOICE}" =~ ^[0-9]+$ ]] || \
      (( IMG_CHOICE < 1 )) || (( IMG_CHOICE > ${#images[@]} )); do
  error "无效选择，请输入 1-${#images[@]}"
  prompt IMG_CHOICE "选择基础镜像编号" "1"
done
BASE_IMAGE="${images[$((IMG_CHOICE-1))]}"
BASE_IMAGE_PATH="${BASE_IMAGE_DIR}/${BASE_IMAGE}"

case "${BASE_IMAGE##*.}" in
  img)  BACKING_FMT="raw" ;;
  qcow2) BACKING_FMT="qcow2" ;;
  *)    BACKING_FMT="raw" ;;
esac

info "使用基础镜像: ${BASE_IMAGE} (格式: ${BACKING_FMT})"

# ── 3. 资源配置 ───────────────────────────────────────────
echo -e "\n${BOLD}── 资源配置 ──${NC}"
prompt DISK_SIZE  "磁盘大小"   "256G"
prompt RAM_SIZE   "内存大小"   "32G"
prompt CPU_CORES  "CPU 核心数" "8"

# ── 4. 网络配置 ───────────────────────────────────────────
echo -e "\n${BOLD}── 网络配置 ──${NC}"
prompt HOST_BRIDGE "网桥名称" "br0"

# IP 分配方式选择
echo ""
echo -e "  ${BOLD}IP 分配方式:${NC}"
echo -e "    ${CYAN}1${NC}) 自动探测 (${IP_SUBNET}.0/24, 每批 ${SCAN_CONCURRENCY} 个并发)"
echo -e "    ${CYAN}2${NC}) 手动输入 IP"

prompt IP_MODE "请选择 [1/2]" "1"

SELECTED_IP=""
case "$IP_MODE" in
  2)
    echo ""
    prompt CLOUD_IP_RAW "虚拟机 IP"
    SELECTED_IP="${CLOUD_IP_RAW%%/*}"
    ;;
  *)
    interactive_ip_scan "$IP_SUBNET"
    ;;
esac

CLOUD_IP="${SELECTED_IP%%/*}/24"

echo ""
info "使用 IP: ${CLOUD_IP}"

prompt CLOUD_USER  "登录用户" "root"
prompt CLOUD_PASS  "登录密码" "3edcBGT_"

# ── 5. 端口配置（自动分配）──────────────────────────────────
echo -e "\n${BOLD}── 端口配置 ──${NC}"
info "扫描已占用端口 (系统监听 + 已有 VM 配置)..."

WEB_PORT=$(next_available_port 8016)
VNC_PORT=$(next_available_port 5910)
WSS_PORT=$(next_available_port 5710)
WSD_PORT=$(next_available_port 8014)
MON_PORT=$(next_available_port 7110)

echo -e "  自动分配端口:"
echo -e "    WEB  : ${CYAN}${WEB_PORT}${NC}"
echo -e "    VNC  : ${CYAN}${VNC_PORT}${NC}"
echo -e "    WSS  : ${CYAN}${WSS_PORT}${NC}"
echo -e "    WSD  : ${CYAN}${WSD_PORT}${NC}"
echo -e "    MON  : ${CYAN}${MON_PORT}${NC}"

read -rp "$(printf "  ${CYAN}${BOLD}?${NC} 是否使用以上端口？[Y/手动输入]: ")" port_confirm
if [[ "${port_confirm,,}" == "n" || "${port_confirm,,}" == "manual" ]]; then
  prompt WEB_PORT "WEB 端口" "$WEB_PORT"
  prompt VNC_PORT "VNC 端口" "$VNC_PORT"
  prompt WSS_PORT "WSS 端口" "$WSS_PORT"
  prompt WSD_PORT "WSD 端口" "$WSD_PORT"
  prompt MON_PORT "MON 端口" "$MON_PORT"
fi

# ── 6. 确认信息 ───────────────────────────────────────────
echo -e "\n${BOLD}${GREEN}════════════════════════════════════════════${NC}"
echo -e "${BOLD} 请确认以下配置:${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════${NC}"
echo -e "  虚拟机名称 : ${CYAN}${VM_NAME}${NC}"
echo -e "  目录       : ${CYAN}${VM_DIR}${NC}"
echo -e "  基础镜像   : ${CYAN}${BASE_IMAGE}${NC}"
echo -e "  磁盘       : ${CYAN}${DISK_SIZE}${NC}"
echo -e "  内存       : ${CYAN}${RAM_SIZE}${NC}"
echo -e "  CPU        : ${CYAN}${CPU_CORES} 核${NC}"
echo -e "  网桥       : ${CYAN}${HOST_BRIDGE}${NC}"
echo -e "  IP         : ${CYAN}${CLOUD_IP}${NC}"
echo -e "  用户/密码  : ${CYAN}${CLOUD_USER} / ${CLOUD_PASS}${NC}"
echo -e "  WEB  端口  : ${CYAN}${WEB_PORT}${NC}"
echo -e "  VNC  端口  : ${CYAN}${VNC_PORT}${NC}"
echo -e "  WSS  端口  : ${CYAN}${WSS_PORT}${NC}"
echo -e "  WSD  端口  : ${CYAN}${WSD_PORT}${NC}"
echo -e "  MON  端口  : ${CYAN}${MON_PORT}${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════${NC}"

read -rp "$(printf "\n${CYAN}${BOLD}?${NC} 确认创建？[Y/n]: ")" confirm
[[ "${confirm,,}" == "n" ]] && info "已取消" && exit 0

# ── 7. 执行创建 ───────────────────────────────────────────
echo ""
info "创建目录: ${VM_DIR}"
mkdir -p "${VM_DIR}/qemu"

info "创建磁盘镜像 (backing file: ${BASE_IMAGE})"
qemu-img create -f qcow2 \
  -b "${BASE_IMAGE_PATH}" \
  -F "${BACKING_FMT}" \
  "${VM_DIR}/boot.qcow2"

info "生成 docker-compose.yaml"
generate_compose

# ── 完成 ──────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║     虚拟机创建成功！                      ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}启动虚拟机:${NC}"
echo -e "    cd ${VM_DIR} && docker-compose up -d"
echo ""
echo -e "  ${BOLD}查看日志:${NC}"
echo -e "    cd ${VM_DIR} && docker-compose logs -f"
echo ""
echo -e "  ${BOLD}停止虚拟机:${NC}"
echo -e "    cd ${VM_DIR} && docker-compose down"
echo ""
echo -e "  ${BOLD}访问 Web 界面:${NC}  http://<宿主机IP>:${WEB_PORT}"
echo ""
