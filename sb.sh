#!/usr/bin/env bash
# =========================================================
#  sb.sh — sing-box 一键多协议脚本
#  协议: VLESS-Reality-Vision / Hysteria2 / TUIC v5 / AnyTLS
#  订阅: 通用 base64 / Clash(Mihomo) / sing-box, 带二维码
#  优化: UDP 缓冲区 + BBR, Hy2 端口跳跃 / Brutal 带宽
#  适配: sing-box 1.12+ 新配置格式 (不使用已移除的旧字段)
#  系统: Debian/Ubuntu/CentOS/Rocky/Alma/Fedora/Alpine
# =========================================================

WORK_DIR=/etc/sing-box
BIN=/usr/local/bin/sing-box
CONF=$WORK_DIR/config.json
LINKS=$WORK_DIR/links.txt
CERT=$WORK_DIR/cert.pem
KEY=$WORK_DIR/private.key
STATE=$WORK_DIR/state.env        # 密钥/端口等状态, 增删协议时复用
SUB_ENV=$WORK_DIR/sub.env
HOP_SH=$WORK_DIR/hop.sh           # Hy2 端口跳跃规则脚本
HOP_APPLIED=$WORK_DIR/hop.applied # 当前已生效的跳跃范围 (用于清理防火墙)
SYSCTL_FILE=/etc/sysctl.d/99-sing-box.conf
SUB_CONF=$WORK_DIR/sub-nginx.conf
SUB_WWW=/var/www/sb-sub          # 订阅文件目录 (由独立 nginx 实例提供)
CLIENT=$SUB_WWW/sing-box.json
TLS_SNI=www.bing.com             # 自签证书域名 (Hy2/TUIC/AnyTLS)
RULE_CDN=https://testingcf.jsdelivr.net/gh   # 规则文件镜像, 国内可直连

STATE_VER=2                      # 状态文件格式版本 (2 = 四协议编号)
PROTO_IDS="1 2 3 4"
PROTO_NAME=([1]="VLESS-Reality-Vision" [2]="Hysteria2" [3]="TUIC v5" [4]="AnyTLS")
PROTO_FN=([1]=proto_reality [2]=proto_hy2 [3]=proto_tuic [4]=proto_anytls)

red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
die()    { red "错误: $*"; exit 1; }
uri()    { jq -rn --arg s "$1" '$s|@uri'; }

# ---------------- 环境检测 ----------------
check_root() { [[ $EUID -eq 0 ]] || die "请用 root 运行"; }

check_sys() {
  if command -v apt-get >/dev/null; then
    PKG=apt; PM_UPDATE="apt-get update -y"; PM_INSTALL="apt-get install -y"
  elif command -v dnf >/dev/null; then
    PKG=dnf; PM_UPDATE=":"; PM_INSTALL="dnf install -y"
  elif command -v yum >/dev/null; then
    PKG=yum; PM_UPDATE=":"; PM_INSTALL="yum install -y"
  elif command -v apk >/dev/null; then
    PKG=apk; PM_UPDATE="apk update"; PM_INSTALL="apk add --no-cache"
  else
    die "不支持的包管理器"
  fi

  if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    INIT=systemd
  elif command -v rc-service >/dev/null; then
    INIT=openrc
  else
    die "仅支持 systemd 或 OpenRC"
  fi
}

install_deps() {
  local need=()
  for c in curl tar openssl jq; do command -v $c >/dev/null || need+=("$c"); done
  command -v ss >/dev/null || need+=("iproute2")
  if ((${#need[@]})); then
    yellow "安装依赖: ${need[*]}"
    $PM_UPDATE >/dev/null 2>&1
    [[ $PKG == dnf || $PKG == yum ]] && need=("${need[@]/iproute2/iproute}")
    $PM_INSTALL "${need[@]}" >/dev/null 2>&1 || die "依赖安装失败"
  fi
}

install_qrencode() {
  command -v qrencode >/dev/null && return 0
  yellow "安装 qrencode (终端二维码)"
  case $PKG in
    apt) $PM_INSTALL qrencode ;;
    apk) $PM_INSTALL libqrencode-tools ;;
    *)   $PM_INSTALL qrencode || { $PM_INSTALL epel-release && $PM_INSTALL qrencode; } ;;
  esac >/dev/null 2>&1
  command -v qrencode >/dev/null || yellow "qrencode 安装失败, 将跳过二维码"
}

install_nginx() {
  command -v nginx >/dev/null && return 0
  yellow "安装 nginx (仅作订阅服务的独立实例, 不改动系统 nginx 配置)"
  $PM_UPDATE >/dev/null 2>&1
  if [[ $PKG == apt ]]; then
    # 防止 apt 安装后自动启动默认站点抢占 80 端口
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d
    $PM_INSTALL nginx >/dev/null 2>&1; local rc=$?
    rm -f /usr/sbin/policy-rc.d
  else
    $PM_INSTALL nginx >/dev/null 2>&1; local rc=$?
  fi
  { ((rc == 0)) && command -v nginx >/dev/null; } || die "nginx 安装失败"
  # 系统默认 nginx 服务用不到, 关掉
  if [[ $INIT == systemd ]]; then systemctl disable --now nginx >/dev/null 2>&1
  else rc-update del nginx default >/dev/null 2>&1; fi
  touch "$WORK_DIR/.nginx_by_sb"
}

get_arch() {
  case $(uname -m) in
    x86_64|amd64)   ARCH=amd64 ;;
    aarch64|arm64)  ARCH=arm64 ;;
    armv7l|armv7)   ARCH=armv7 ;;
    i386|i686)      ARCH=386 ;;
    s390x)          ARCH=s390x ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

get_ip() {
  IP4=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 5 https://ip.sb 2>/dev/null)
  IP6=$(curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || curl -6 -fsS --max-time 5 https://ip.sb 2>/dev/null)
  if [[ -n $IP4 ]]; then
    SERVER_IP=$IP4; LINK_IP=$IP4
  elif [[ -n $IP6 ]]; then
    SERVER_IP=$IP6; LINK_IP="[$IP6]"
  else
    die "获取公网 IP 失败"
  fi
  # 内核未启用 IPv6 时不能监听 ::
  [[ -f /proc/net/if_inet6 ]] && LISTEN="::" || LISTEN="0.0.0.0"
}

port_used() { ss -tuln 2>/dev/null | awk '{print $5}' | grep -qE "[:.]$1\$"; }
next_port() { local p=$1; while port_used "$p"; do p=$((p + 1)); done; echo "$p"; }

# ---------------- 内核安装 ----------------
install_core() {
  get_arch
  # 可用 SB_VERSION=1.14.0 bash sb.sh 指定版本
  local ver=${SB_VERSION:-}
  [[ -z $ver ]] && ver=$(curl -fsSL --max-time 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r .tag_name 2>/dev/null | sed 's/^v//')
  # API 被限流时, 改从 releases/latest 跳转地址取版本号
  [[ -z $ver || $ver == null ]] && ver=$(curl -fsSIL --max-time 10 -o /dev/null -w '%{url_effective}' \
    https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null | sed -n 's#.*/tag/v\{0,1\}##p')
  [[ -z $ver || $ver == null ]] && die "获取 sing-box 最新版本失败, 可用 SB_VERSION=版本号 手动指定"
  local name="sing-box-${ver}-linux-${ARCH}"
  local tmp; tmp=$(mktemp -d)
  green "下载 sing-box v$ver ($ARCH) ..."
  curl -fL --retry 3 -o "$tmp/sb.tgz" \
    "https://github.com/SagerNet/sing-box/releases/download/v${ver}/${name}.tar.gz" || die "下载失败"
  tar xzf "$tmp/sb.tgz" -C "$tmp" || die "解压失败"
  install -m 755 "$tmp/$name/sing-box" "$BIN"
  rm -rf "$tmp"
  green "已安装: $($BIN version | head -1)"
}

# ---------------- 服务管理 ----------------
install_service() {
  if [[ $INIT == systemd ]]; then
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=$BIN run -c $CONF
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
  else
    cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
name="sing-box"
command="$BIN"
command_args="run -c $CONF"
command_background=true
pidfile="/run/sing-box.pid"
depend() { need net; }
EOF
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default >/dev/null 2>&1
  fi
}

install_sub_service() {
  local ngx; ngx=$(command -v nginx)
  if [[ $INIT == systemd ]]; then
    cat > /etc/systemd/system/sb-sub.service <<EOF
[Unit]
Description=sing-box subscription server (nginx)
After=network.target

[Service]
Type=simple
ExecStartPre=$ngx -t -q -c $SUB_CONF
ExecStart=$ngx -c $SUB_CONF -g 'daemon off;'
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sb-sub >/dev/null 2>&1
  else
    cat > /etc/init.d/sb-sub <<EOF
#!/sbin/openrc-run
name="sb-sub"
command="$ngx"
command_args="-c $SUB_CONF"
pidfile="/run/sb-sub.pid"
depend() { need net; }
EOF
    chmod +x /etc/init.d/sb-sub
    rc-update add sb-sub default >/dev/null 2>&1
  fi
  # RHEL 系 SELinux 默认禁止 nginx 监听非标准端口
  if command -v getenforce >/dev/null && [[ $(getenforce) == Enforcing ]]; then
    command -v semanage >/dev/null || $PM_INSTALL policycoreutils-python-utils >/dev/null 2>&1
    semanage port -a -t http_port_t -p tcp "$SUB_PORT" 2>/dev/null || semanage port -m -t http_port_t -p tcp "$SUB_PORT" 2>/dev/null
  fi
}

# svc <服务名> <start|stop|restart|enable|disable>
svc() {
  if [[ $INIT == systemd ]]; then
    systemctl "$2" "$1"
  else
    case $2 in
      enable)  rc-update add "$1" default ;;
      disable) rc-update del "$1" default ;;
      *)       rc-service "$1" "$2" ;;
    esac
  fi
}

svc_active() {
  if [[ $INIT == systemd ]]; then systemctl is-active --quiet "$1"; else rc-service "$1" status >/dev/null 2>&1; fi
}

# ---------------- 参数生成 ----------------
gen_secrets() {
  UUID=$($BIN generate uuid)
  PASS=$($BIN generate rand 16 --hex)
  local kp; kp=$($BIN generate reality-keypair)
  REALITY_PRIV=$(awk '/PrivateKey/{print $2}' <<<"$kp")
  REALITY_PUB=$(awk '/PublicKey/{print $2}' <<<"$kp")
  REALITY_SID=$($BIN generate rand 8 --hex)
  SUB_TOKEN=$($BIN generate rand 16 --hex)
}

gen_cert() {
  openssl ecparam -genkey -name prime256v1 -out "$KEY" 2>/dev/null
  openssl req -new -x509 -days 36500 -key "$KEY" -out "$CERT" -subj "/CN=$TLS_SNI" 2>/dev/null
  chmod 600 "$KEY"
  [[ -s $CERT ]] || die "证书生成失败"
}

# ---------------- 各协议 ----------------
# 每个协议同时生成: 服务端 inbound (IN) / sing-box 客户端 outbound (OUT) /
#                   Clash(Mihomo) 代理 (CLASH) / 分享链接 (LINK)
TLS_SRV() { echo "\"tls\":{\"enabled\":true,\"alpn\":[$1],\"certificate_path\":\"$CERT\",\"key_path\":\"$KEY\"}"; }
TLS_CLI() { echo "\"tls\":{\"enabled\":true,\"server_name\":\"$TLS_SNI\",\"insecure\":true,\"alpn\":[$1]}"; }

proto_reality() { # $1=port
  local n="$NAME-Reality"
  IN+=("{\"type\":\"vless\",\"tag\":\"reality-in\",\"listen\":\"$LISTEN\",\"listen_port\":$1,
    \"users\":[{\"uuid\":\"$UUID\",\"flow\":\"xtls-rprx-vision\"}],
    \"tls\":{\"enabled\":true,\"server_name\":\"$REALITY_SNI\",
      \"reality\":{\"enabled\":true,\"handshake\":{\"server\":\"$REALITY_SNI\",\"server_port\":443},
      \"private_key\":\"$REALITY_PRIV\",\"short_id\":[\"$REALITY_SID\"]}}}")
  OUT+=("{\"type\":\"vless\",\"tag\":\"$n\",\"server\":\"$SERVER_IP\",\"server_port\":$1,
    \"uuid\":\"$UUID\",\"flow\":\"xtls-rprx-vision\",
    \"tls\":{\"enabled\":true,\"server_name\":\"$REALITY_SNI\",\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"},
      \"reality\":{\"enabled\":true,\"public_key\":\"$REALITY_PUB\",\"short_id\":\"$REALITY_SID\"}}}")
  CLASH+=("{\"name\":\"$n\",\"type\":\"vless\",\"server\":\"$SERVER_IP\",\"port\":$1,\"uuid\":\"$UUID\",
    \"network\":\"tcp\",\"tls\":true,\"udp\":true,\"flow\":\"xtls-rprx-vision\",\"servername\":\"$REALITY_SNI\",
    \"client-fingerprint\":\"chrome\",\"reality-opts\":{\"public-key\":\"$REALITY_PUB\",\"short-id\":\"$REALITY_SID\"}}")
  LINK+=("vless://$UUID@$LINK_IP:$1?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$REALITY_PUB&sid=$REALITY_SID&type=tcp#$(uri "$n")")
  PORTS_TCP+=("$1")
}

proto_hy2() {
  local n="$NAME-Hy2" sp="\"server_port\":$1" hop_c="" hop_l="" bw_o="" bw_c=""
  if [[ -n $HOP_RANGE ]]; then
    # sing-box 中 server_ports 与 server_port 互斥
    sp="\"server_ports\":[\"$HOP_RANGE\"],\"hop_interval\":\"30s\""
    hop_c=",\"ports\":\"${HOP_RANGE/:/-}\",\"hop-interval\":30"
    hop_l="&mport=${HOP_RANGE/:/-}"
  fi
  if [[ -n $HY2_UP && -n $HY2_DOWN ]]; then
    bw_o=",\"up_mbps\":$HY2_UP,\"down_mbps\":$HY2_DOWN"
    bw_c=",\"up\":\"$HY2_UP Mbps\",\"down\":\"$HY2_DOWN Mbps\""
  fi
  IN+=("{\"type\":\"hysteria2\",\"tag\":\"hy2-in\",\"listen\":\"$LISTEN\",\"listen_port\":$1,
    \"users\":[{\"password\":\"$PASS\"}],$(TLS_SRV '"h3"')}")
  OUT+=("{\"type\":\"hysteria2\",\"tag\":\"$n\",\"server\":\"$SERVER_IP\",$sp,
    \"password\":\"$PASS\"$bw_o,$(TLS_CLI '"h3"')}")
  CLASH+=("{\"name\":\"$n\",\"type\":\"hysteria2\",\"server\":\"$SERVER_IP\",\"port\":$1$hop_c,\"password\":\"$PASS\"$bw_c,
    \"sni\":\"$TLS_SNI\",\"skip-cert-verify\":true,\"alpn\":[\"h3\"]}")
  LINK+=("hysteria2://$PASS@$LINK_IP:$1?sni=$TLS_SNI&alpn=h3&insecure=1$hop_l#$(uri "$n")")
  PORTS_UDP+=("$1")
}

proto_tuic() {
  local n="$NAME-TUIC"
  IN+=("{\"type\":\"tuic\",\"tag\":\"tuic-in\",\"listen\":\"$LISTEN\",\"listen_port\":$1,
    \"users\":[{\"uuid\":\"$UUID\",\"password\":\"$PASS\"}],\"congestion_control\":\"bbr\",$(TLS_SRV '"h3"')}")
  OUT+=("{\"type\":\"tuic\",\"tag\":\"$n\",\"server\":\"$SERVER_IP\",\"server_port\":$1,
    \"uuid\":\"$UUID\",\"password\":\"$PASS\",\"congestion_control\":\"bbr\",$(TLS_CLI '"h3"')}")
  CLASH+=("{\"name\":\"$n\",\"type\":\"tuic\",\"server\":\"$SERVER_IP\",\"port\":$1,\"uuid\":\"$UUID\",\"password\":\"$PASS\",
    \"congestion-controller\":\"bbr\",\"udp-relay-mode\":\"native\",\"alpn\":[\"h3\"],\"sni\":\"$TLS_SNI\",\"skip-cert-verify\":true}")
  LINK+=("tuic://$UUID:$PASS@$LINK_IP:$1?congestion_control=bbr&alpn=h3&sni=$TLS_SNI&udp_relay_mode=native&allow_insecure=1#$(uri "$n")")
  PORTS_UDP+=("$1")
}

proto_anytls() {
  local n="$NAME-AnyTLS"
  IN+=("{\"type\":\"anytls\",\"tag\":\"anytls-in\",\"listen\":\"$LISTEN\",\"listen_port\":$1,
    \"users\":[{\"name\":\"user\",\"password\":\"$PASS\"}],
    \"tls\":{\"enabled\":true,\"certificate_path\":\"$CERT\",\"key_path\":\"$KEY\"}}")
  OUT+=("{\"type\":\"anytls\",\"tag\":\"$n\",\"server\":\"$SERVER_IP\",\"server_port\":$1,
    \"password\":\"$PASS\",\"tls\":{\"enabled\":true,\"server_name\":\"$TLS_SNI\",\"insecure\":true}}")
  CLASH+=("{\"name\":\"$n\",\"type\":\"anytls\",\"server\":\"$SERVER_IP\",\"port\":$1,\"password\":\"$PASS\",
    \"sni\":\"$TLS_SNI\",\"skip-cert-verify\":true,\"client-fingerprint\":\"chrome\",\"udp\":true}")
  LINK+=("anytls://$PASS@$LINK_IP:$1?sni=$TLS_SNI&insecure=1#$(uri "$n")")
  PORTS_TCP+=("$1")
}

join() { local IFS=,; echo "$*"; }

# ---------------- 配置生成 ----------------
# 端口分配: 跳过系统已占用端口, 以及已分配给其他协议/订阅的端口
alloc_port() {
  local p=$1 id pv taken
  while :; do
    p=$(next_port "$p"); taken=0
    if [[ -n $HOP_RANGE ]] && ((p >= ${HOP_RANGE%:*} && p <= ${HOP_RANGE#*:})); then
      p=$((${HOP_RANGE#*:} + 1)); continue
    fi
    for id in $PROTO_IDS; do pv=PORT_$id; [[ ${!pv} == "$p" ]] && taken=1; done
    [[ $SUB_PORT == "$p" ]] && taken=1
    ((taken)) || break
    p=$((p + 1))
  done
  echo "$p"
}

# 安装时按选择顺序从 START_PORT 起连续分配
assign_ports() {
  local id p=$START_PORT seen=" "
  SUB_PORT=""
  for id in $PROTO_IDS; do printf -v "PORT_$id" '%s' ""; done
  for id in $PROTOS; do
    [[ $id =~ ^[1-4]$ && $seen != *" $id "* ]] || continue
    seen+="$id "
    p=$(alloc_port "$p"); printf -v "PORT_$id" '%s' "$p"; p=$((p + 1))
  done
  [[ $seen == " " ]] && die "未选择任何有效协议"
  SUB_PORT=$(alloc_port "$p")
}

max_port() {
  local id pv m=${SUB_PORT:-0}
  for id in $PROTO_IDS; do pv=PORT_$id; [[ -n ${!pv} ]] && ((${!pv} > m)) && m=${!pv}; done
  echo "$m"
}

save_state() {
  local v
  for v in STATE_VER UUID PASS REALITY_PRIV REALITY_PUB REALITY_SID SUB_TOKEN SUB_PORT \
           NAME REALITY_SNI SERVER_IP LINK_IP LISTEN PORT_1 PORT_2 PORT_3 PORT_4 \
           HOP_RANGE HY2_UP HY2_DOWN; do
    printf '%s=%q\n' "$v" "${!v}"
  done > "$STATE"
  chmod 600 "$STATE"
}

load_state() {
  [[ -f $STATE ]] || die "未找到节点状态文件, 请先用菜单 1 安装 (旧版脚本安装的需重新安装一次)"
  local want=$STATE_VER
  STATE_VER=1
  source "$STATE"
  OLD_PORTS=()
  if [[ $STATE_VER != "$want" ]]; then
    # 旧版七协议编号: 4=SS 5=Trojan 6=AnyTLS 7=VMess -> 新版 4=AnyTLS, 其余三个弃用
    local p
    for p in "$PORT_4" "$PORT_5" "$PORT_7"; do [[ -n $p ]] && OLD_PORTS+=("$p"); done
    PORT_4=$PORT_6
    unset PORT_5 PORT_6 PORT_7 SS_KEY WS_PATH
  fi
  STATE_VER=$want
}

# 旧版 (七协议) 升级: 去掉 SS/Trojan/VMess, 保留其余节点的密钥、端口和订阅地址
migrate_state() {
  [[ -f $STATE ]] || return 0
  grep -q "^STATE_VER=$STATE_VER\$" "$STATE" && return 0
  check_sys; load_state
  ((${#OLD_PORTS[@]})) || { save_state; return 0; }
  yellow "检测到旧版配置, 正在移除 Shadowsocks / Trojan / VMess ..."
  if [[ -z $PORT_1$PORT_2$PORT_3$PORT_4 ]]; then
    red "旧配置只包含已移除的协议, 请用菜单 1 重新安装"; return 0
  fi
  [[ -f $SUB_ENV ]] && source "$SUB_ENV"
  ENABLE_SUB=${SUB_ENABLED:-0}
  build_server
  $BIN check -c "$CONF" || die "迁移后配置检查未通过"
  build_subs; save_state
  svc sing-box restart >/dev/null 2>&1
  close_firewall "${OLD_PORTS[@]}"
  green "已完成迁移, 订阅地址不变, 客户端「更新订阅」即可。"
}

# 根据 PORT_1..PORT_4 生成服务端配置 (端口为空表示未启用)
build_server() {
  IN=(); OUT=(); CLASH=(); LINK=(); PORTS_TCP=(); PORTS_UDP=()
  local id pv
  for id in $PROTO_IDS; do
    pv=PORT_$id
    [[ -n ${!pv} ]] && ${PROTO_FN[$id]} "${!pv}"
  done
  ((${#IN[@]})) || die "未启用任何协议"

  echo "{\"log\":{\"level\":\"warn\",\"timestamp\":true},
    \"inbounds\":[$(join "${IN[@]}")],
    \"outbounds\":[{\"type\":\"direct\",\"tag\":\"direct\"}],
    \"route\":{\"final\":\"direct\"}}" | jq . > "$CONF" || die "服务端配置生成失败"
  printf '%s\n' "${LINK[@]}" > "$LINKS"
}

# sing-box 客户端完整配置: TUN + mixed(127.0.0.1:2080), 国内直连, 自动选优
build_singbox_client() {
  local nodes; nodes=$(printf '%s\n' "${OUT[@]}" | jq -s -c .) || die "sing-box 客户端节点生成失败"
  jq -n --argjson nodes "$nodes" --arg cdn "$RULE_CDN" '
  ($nodes | map(.tag)) as $tags |
  {
    log: {level: "info", timestamp: true},
    dns: {
      servers: [
        {type: "https", tag: "remote", server: "8.8.8.8", detour: "proxy"},
        {type: "udp",   tag: "local",  server: "223.5.5.5"}
      ],
      rules: [{rule_set: "geosite-cn", server: "local"}],
      final: "remote"
    },
    inbounds: [
      {type: "tun", tag: "tun-in", address: ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
       auto_route: true, strict_route: true},
      {type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 2080}
    ],
    outbounds: ([
      {type: "selector", tag: "proxy", outbounds: (["auto"] + $tags + ["direct"]), default: "auto"},
      {type: "urltest",  tag: "auto",  outbounds: $tags, url: "https://www.gstatic.com/generate_204", interval: "5m"}
    ] + $nodes + [{type: "direct", tag: "direct"}]),
    route: {
      rules: [
        {action: "sniff"},
        {protocol: "dns", action: "hijack-dns"},
        {ip_is_private: true, outbound: "direct"},
        {rule_set: ["geosite-cn", "geoip-cn"], outbound: "direct"}
      ],
      rule_set: [
        {type: "remote", tag: "geosite-cn", format: "binary",
         url: ($cdn + "/SagerNet/sing-geosite@rule-set/geosite-cn.srs")},
        {type: "remote", tag: "geoip-cn", format: "binary",
         url: ($cdn + "/SagerNet/sing-geoip@rule-set/geoip-cn.srs")}
      ],
      final: "proxy",
      auto_detect_interface: true,
      default_domain_resolver: "local"
    }
  }' > "$CLIENT" || die "sing-box 客户端配置生成失败"
}

# Clash / Mihomo 配置 (代理用 YAML flow 写法, 与 JSON 兼容)
build_clash() {
  local names sel
  names=$(printf '%s\n' "${CLASH[@]}" | jq -s -c 'map(.name)') || die "Clash 节点生成失败"
  sel=$(jq -c '["自动选择"] + . + ["DIRECT"]' <<<"$names")
  {
    cat <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true
unified-delay: true
geox-url:
  geoip: "$RULE_CDN/MetaCubeX/meta-rules-dat@release/geoip.dat"
  geosite: "$RULE_CDN/MetaCubeX/meta-rules-dat@release/geosite.dat"
  mmdb: "$RULE_CDN/MetaCubeX/meta-rules-dat@release/country.mmdb"
dns:
  enable: true
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-filter: ["*.lan", "+.local", "+.msftconnecttest.com", "+.msftncsi.com"]
  default-nameserver: [223.5.5.5, 119.29.29.29]
  nameserver: ["https://223.5.5.5/dns-query", "https://doh.pub/dns-query"]
proxies:
EOF
    for c in "${CLASH[@]}"; do echo "  - $(jq -c . <<<"$c")"; done
    cat <<EOF
proxy-groups:
  - {name: 节点选择, type: select, proxies: $sel}
  - {name: 自动选择, type: url-test, url: "https://www.gstatic.com/generate_204", interval: 300, tolerance: 50, proxies: $names}
rules:
  - GEOIP,LAN,DIRECT,no-resolve
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,节点选择
EOF
  } > "$SUB_WWW/clash.yaml"
}

build_subs() {
  mkdir -p "$SUB_WWW"; chmod 755 "$SUB_WWW"
  base64 -w0 "$LINKS" > "$SUB_WWW/base64.txt"
  build_clash
  build_singbox_client
  local base="http://$LINK_IP:$SUB_PORT/$SUB_TOKEN"
  SUB_AUTO="$base/sub"          # 按 User-Agent 自动返回对应格式
  SUB_BASE64="$base/base64"
  SUB_CLASH="$base/clash"
  SUB_SINGBOX="$base/sing-box"
  SUB_QR="$base/qr.png"
  command -v qrencode >/dev/null && qrencode -s 8 -m 2 -o "$SUB_WWW/qr.png" "$SUB_AUTO"
  chmod 644 "$SUB_WWW"/*
  {
    printf 'SUB_ENABLED=%q\n' "$ENABLE_SUB"
    printf 'SUB_PORT=%q\nSUB_NAME=%q\n' "$SUB_PORT" "$NAME"
    printf 'SUB_AUTO=%q\n' "$SUB_AUTO"
    printf 'SUB_BASE64=%q\nSUB_CLASH=%q\nSUB_SINGBOX=%q\nSUB_QR=%q\n' "$SUB_BASE64" "$SUB_CLASH" "$SUB_SINGBOX" "$SUB_QR"
  } > "$SUB_ENV"
}

build_sub_nginx() {
  local fname; fname=$(uri "$NAME")
  local v6=""; [[ $LISTEN == "::" ]] && v6="listen [::]:$SUB_PORT;"
  cat > "$SUB_CONF" <<EOF
worker_processes 1;
pid /run/sb-sub.pid;
error_log /var/log/sb-sub.log warn;
events { worker_connections 256; }
http {
  access_log off;
  server_tokens off;
  types {}
  charset utf-8;
  # 通用订阅 /sub: 按客户端 User-Agent 返回对应格式, 识别不了的返回 base64
  map \$http_user_agent \$sb_target {
    default base64;
    "~*(sing-box|singbox|SFI/|SFA/|SFM/|SFT/)" sing-box;
    "~*(clash|mihomo|stash|nyanpasu)" clash;
  }
  server {
    listen $SUB_PORT;
    $v6
    server_name _;
    root $SUB_WWW;
    location = /$SUB_TOKEN/sub      { rewrite ^ /$SUB_TOKEN/\$sb_target last; }
    location = /$SUB_TOKEN/base64   { default_type text/plain;  try_files /base64.txt =404; }
    location = /$SUB_TOKEN/clash    {
      default_type text/yaml;
      add_header Content-Disposition "attachment; filename*=UTF-8''$fname.yaml";
      add_header profile-update-interval 24;
      try_files /clash.yaml =404;
    }
    location = /$SUB_TOKEN/sing-box { default_type application/json; try_files /sing-box.json =404; }
    location = /$SUB_TOKEN/qr.png   { default_type image/png; try_files /qr.png =404; }
    location / { return 404; }
  }
}
EOF
}

open_firewall() {
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in "${PORTS_TCP[@]}"; do ufw allow "$p/tcp" >/dev/null; done
    for p in "${PORTS_UDP[@]}"; do ufw allow "$p/udp" >/dev/null; done
    green "已在 ufw 放行端口"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    for p in "${PORTS_TCP[@]}"; do firewall-cmd --permanent --add-port="$p/tcp" >/dev/null; done
    for p in "${PORTS_UDP[@]}"; do firewall-cmd --permanent --add-port="$p/udp" >/dev/null; done
    firewall-cmd --reload >/dev/null
    green "已在 firewalld 放行端口"
  fi
}

close_firewall() { # $@=端口
  local p
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in "$@"; do ufw delete allow "$p/tcp" >/dev/null 2>&1; ufw delete allow "$p/udp" >/dev/null 2>&1; done
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    for p in "$@"; do
      firewall-cmd --permanent --remove-port="$p/tcp" >/dev/null 2>&1
      firewall-cmd --permanent --remove-port="$p/udp" >/dev/null 2>&1
    done
    firewall-cmd --reload >/dev/null
  fi
}

# ---------------- 网络优化 ----------------
# QUIC (Hy2/TUIC) 吞吐量受 UDP 缓冲区限制, 默认值偏小时会限速; BBR+fq 优化 TCP 协议 (Reality/AnyTLS)
tune_net() {
  local bbr=0
  modprobe tcp_bbr >/dev/null 2>&1
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && bbr=1
  mkdir -p /etc/sysctl.d
  {
    echo "# sing-box 网络优化 (由 sb.sh 生成, 卸载时删除)"
    echo "net.core.rmem_max=16777216"
    echo "net.core.wmem_max=16777216"
    echo "net.core.netdev_max_backlog=16384"
    if ((bbr)); then
      echo "net.core.default_qdisc=fq"
      echo "net.ipv4.tcp_congestion_control=bbr"
    fi
  } > "$SYSCTL_FILE"
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1
  TUNE_RMEM=$(sysctl -n net.core.rmem_max 2>/dev/null)
  TUNE_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
}

net_optimize() {
  tune_net
  green "UDP 接收缓冲上限: ${TUNE_RMEM:-未知} (目标 16777216)"
  green "TCP 拥塞控制:     ${TUNE_CC:-未知}"
  ((${TUNE_RMEM:-0} >= 16777216)) || yellow "缓冲区未能调大, 可能是 LXC/OpenVZ 容器不允许修改 (sing-box 以 root 运行时仍会尝试强制调大)"
  [[ $TUNE_CC == bbr ]] || yellow "BBR 未启用 (内核可能 < 4.9 或为容器)"
}

# ---------------- Hy2 端口跳跃 ----------------
udp_ports() {
  ss -uln 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i ~ /:[0-9]+$/) { sub(/.*:/, "", $i); print $i; break }}' | sort -un
}

# 检查跳跃范围是否可用, 失败时原因写入 RANGE_ERR
range_ok() {
  RANGE_ERR=""
  [[ $1 =~ ^([0-9]+):([0-9]+)$ ]] || { RANGE_ERR="格式错误, 示例: 52000-53000"; return 1; }
  local s=${BASH_REMATCH[1]} e=${BASH_REMATCH[2]} p
  ((s >= 1024 && e <= 65535 && s < e)) || { RANGE_ERR="范围需在 1024-65535 之间, 且起始小于结束"; return 1; }
  for p in $PORT_1 $PORT_3 $PORT_4 $SUB_PORT; do
    ((p >= s && p <= e)) && { RANGE_ERR="范围包含本脚本其他协议或订阅使用的端口 $p"; return 1; }
  done
  for p in $(udp_ports); do
    [[ $p == "$PORT_2" ]] && continue
    ((p >= s && p <= e)) && { RANGE_ERR="范围内的 UDP 端口 $p 已被其他程序占用"; return 1; }
  done
  return 0
}

default_range() {
  local c
  for c in 52000:53000 42000:43000 32000:33000 22000:23000 62000:63000; do
    range_ok "$c" && { echo "$c"; return; }
  done
}

ask_hop() {
  local def r
  def=$(default_range)
  while :; do
    read -rp "跳跃端口范围 (回车=${def:-无可用默认值, 请手动输入}): " r
    r=${r:-$def}; r=${r//-/:}
    [[ -z $r ]] && return 1
    range_ok "$r" && break
    red "$RANGE_ERR"
  done
  HOP_RANGE=$r
}

ask_bw() {
  echo "填写你本地网络的实际带宽 (可用 speedtest 测), 建议填实测值的 80%~90%。"
  echo "填得过高会造成大量丢包反而变慢; 不确定就留空, 继续使用 BBR。"
  local u d
  read -rp "上行 Mbps (本地上传, 回车跳过): " u
  [[ -z $u ]] && return 1
  read -rp "下行 Mbps (本地下载): " d
  if [[ $u =~ ^[1-9][0-9]*$ && $d =~ ^[1-9][0-9]*$ ]]; then
    HY2_UP=$u; HY2_DOWN=$d
  else
    red "请输入正整数, 已跳过带宽设置"; return 1
  fi
}

fw_range() { # $1=open|close $2=起始:结束
  local r=$2
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    if [[ $1 == open ]]; then ufw allow "$r/udp" >/dev/null 2>&1; else ufw delete allow "$r/udp" >/dev/null 2>&1; fi
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    if [[ $1 == open ]]; then firewall-cmd --permanent --add-port="${r/:/-}/udp" >/dev/null 2>&1
    else firewall-cmd --permanent --remove-port="${r/:/-}/udp" >/dev/null 2>&1; fi
    firewall-cmd --reload >/dev/null 2>&1
  fi
}

write_hop_sh() {
  local s=${HOP_RANGE%:*} e=${HOP_RANGE#*:}
  cat > "$HOP_SH" <<EOF
#!/bin/sh
# Hysteria2 端口跳跃: UDP $s-$e -> $PORT_2 (由 sb.sh 生成, 请勿手动修改)
stop() {
  command -v nft >/dev/null 2>&1 && nft delete table inet sb_hop 2>/dev/null
  for t in iptables ip6tables; do
    command -v \$t >/dev/null 2>&1 || continue
    \$t -t nat -S PREROUTING 2>/dev/null | grep -- 'sb-hop' | sed 's/^-A /-D /' |
      while read -r r; do eval "\$t -t nat \$r"; done
  done
  return 0
}
start() {
  stop
  # 优先 nftables (需内核 5.2+), 失败则回退 iptables
  if command -v nft >/dev/null 2>&1; then
    nft -f - 2>/dev/null <<NFT && return 0
table inet sb_hop {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    udp dport $s-$e redirect to :$PORT_2
  }
}
NFT
  fi
  ok=1
  for t in iptables ip6tables; do
    command -v \$t >/dev/null 2>&1 || continue
    \$t -t nat -A PREROUTING -p udp --dport $s:$e -m comment --comment sb-hop -j REDIRECT --to-ports $PORT_2 2>/dev/null && ok=0
  done
  return \$ok
}
case "\$1" in
  start) start ;;
  stop)  stop ;;
  *) echo "usage: \$0 start|stop"; exit 1 ;;
esac
EOF
  chmod 755 "$HOP_SH"
}

install_hop_service() {
  if [[ $INIT == systemd ]]; then
    cat > /etc/systemd/system/sb-hop.service <<EOF
[Unit]
Description=sing-box Hysteria2 port hopping
After=network.target firewalld.service ufw.service
Before=sing-box.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$HOP_SH start
ExecStop=$HOP_SH stop

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sb-hop >/dev/null 2>&1
  else
    cat > /etc/init.d/sb-hop <<EOF
#!/sbin/openrc-run
name="sb-hop"
depend() { need net; after firewall iptables ip6tables nftables; }
start() { ebegin "Applying Hysteria2 port hopping"; $HOP_SH start; eend \$?; }
stop()  { ebegin "Removing Hysteria2 port hopping"; $HOP_SH stop; eend \$?; }
EOF
    chmod +x /etc/init.d/sb-hop
    rc-update add sb-hop default >/dev/null 2>&1
  fi
}

remove_hop_service() {
  [[ -f $HOP_SH ]] && "$HOP_SH" stop >/dev/null 2>&1
  svc sb-hop stop >/dev/null 2>&1; svc sb-hop disable >/dev/null 2>&1
  rm -f /etc/systemd/system/sb-hop.service /etc/init.d/sb-hop "$HOP_SH"
  [[ $INIT == systemd ]] && systemctl daemon-reload
}

# 根据当前 PORT_2 / HOP_RANGE 应用或清除端口跳跃规则
apply_hop() {
  local old=""; [[ -f $HOP_APPLIED ]] && old=$(<"$HOP_APPLIED")
  if [[ -n $PORT_2 && -n $HOP_RANGE ]]; then
    if ! command -v nft >/dev/null && ! command -v iptables >/dev/null; then
      yellow "安装 nftables (端口跳跃需要)"
      $PM_INSTALL nftables >/dev/null 2>&1 || $PM_INSTALL iptables >/dev/null 2>&1
    fi
    write_hop_sh; install_hop_service
    svc sb-hop restart >/dev/null 2>&1
    if "$HOP_SH" start; then
      green "Hy2 端口跳跃已生效: UDP ${HOP_RANGE/:/-} -> $PORT_2"
    else
      red "端口跳跃规则应用失败 (需要 nftables 或 iptables 的 NAT 支持), Hy2 主端口不受影响"
    fi
    [[ -n $old && $old != "$HOP_RANGE" ]] && fw_range close "$old"
    fw_range open "$HOP_RANGE"
    echo "$HOP_RANGE" > "$HOP_APPLIED"
  else
    [[ -f $HOP_SH || -f $HOP_APPLIED ]] && remove_hop_service
    [[ -n $old ]] && fw_range close "$old"
    rm -f "$HOP_APPLIED"
  fi
}

# ---------------- 菜单功能 ----------------
do_install() {
  check_sys; install_deps; install_qrencode
  [[ -x $BIN ]] || install_core
  mkdir -p "$WORK_DIR"
  get_ip

  echo
  echo "可选协议:"
  echo "  1. VLESS + Reality + Vision   2. Hysteria2"
  echo "  3. TUIC v5                    4. AnyTLS"
  read -rp "选择协议 (空格分隔, 回车=全部): " PROTOS
  [[ -z $PROTOS ]] && PROTOS="1 2 3 4"
  PROTOS=${PROTOS//,/ }

  read -rp "起始端口 (回车=随机): " START_PORT
  [[ $START_PORT =~ ^[0-9]+$ ]] && ((START_PORT > 0 && START_PORT < 65500)) || START_PORT=$((RANDOM % 30000 + 20000))
  HOP_RANGE=""; HY2_UP=""; HY2_DOWN=""
  assign_ports

  read -rp "Reality 伪装域名 (回车=addons.mozilla.org): " REALITY_SNI
  REALITY_SNI=${REALITY_SNI:-addons.mozilla.org}

  read -rp "节点名前缀 (回车=$(hostname)): " NAME
  NAME=${NAME:-$(hostname)}; NAME=$(tr -d '"\\#' <<<"$NAME" | tr ' ' '_')

  if [[ -n $PORT_2 ]]; then
    echo
    yellow "Hy2 端口跳跃: 客户端在一段 UDP 端口间轮换, 可缓解运营商对单个 UDP 端口的限速/阻断。"
    yellow "              开启后需在云服务商安全组放行该 UDP 端口范围。"
    read -rp "开启 Hy2 端口跳跃? [y/N]: " q
    [[ $q == [yY] ]] && ask_hop
    read -rp "设置 Hy2 带宽以启用 Brutal 拥塞控制 (高丢包线路更快)? [y/N]: " q
    [[ $q == [yY] ]] && ask_bw
  fi

  read -rp "开启在线订阅服务 (nginx)? [Y/n]: " q
  [[ $q == [nN] ]] && ENABLE_SUB=0 || ENABLE_SUB=1

  gen_secrets; gen_cert; build_server
  $BIN check -c "$CONF" || die "配置检查未通过, 见上方报错"
  build_subs; save_state
  install_service
  tune_net
  svc sing-box restart >/dev/null 2>&1
  apply_hop

  if ((ENABLE_SUB)); then
    install_nginx
    build_sub_nginx
    nginx -t -q -c "$SUB_CONF" || die "订阅服务 nginx 配置错误"
    install_sub_service
    PORTS_TCP+=("$SUB_PORT")
    svc sb-sub restart >/dev/null 2>&1
  elif [[ -f $SUB_CONF ]]; then
    svc sb-sub stop >/dev/null 2>&1; svc sb-sub disable >/dev/null 2>&1
  fi
  open_firewall

  sleep 1
  svc_active sing-box && green "sing-box 已启动" || { red "sing-box 启动失败, 查看日志: journalctl -u sing-box -e"; exit 1; }
  if ((ENABLE_SUB)); then
    svc_active sb-sub && green "订阅服务已启动 (端口 $SUB_PORT)" \
      || red "订阅服务启动失败, 查看 /var/log/sb-sub.log (RHEL 系可能是 SELinux 拦截)"
  fi
  show_nodes
}

print_qr() { # $1=标题 $2=内容
  command -v qrencode >/dev/null || return 0
  echo; yellow "$1"; qrencode -t ANSIUTF8 -m 1 "$2"
}

show_nodes() {
  [[ -s $LINKS ]] || die "尚未安装"
  [[ -f $SUB_ENV ]] && source "$SUB_ENV"
  [[ -f $STATE ]] && source "$STATE"

  echo; green "================ 节点分享链接 ================"
  cat "$LINKS"

  if [[ $SUB_ENABLED == 1 ]]; then
    echo; green "================ 在线订阅 ================"
    echo "通用订阅 (自动识别客户端, 推荐; 小火箭 / v2rayN / Clash / sing-box 等都可用):"
    echo "  ${SUB_AUTO:-$SUB_BASE64}"
    echo; echo "指定格式 (自动识别不准时使用):"
    echo "  base64:   $SUB_BASE64"
    echo "  Clash:    $SUB_CLASH"
    echo "  sing-box: $SUB_SINGBOX"
    echo; green "一键导入:"
    echo "  clash://install-config?url=$(uri "$SUB_CLASH")&name=$(uri "$SUB_NAME")"
    echo "  sing-box://import-remote-profile?url=$(uri "$SUB_SINGBOX")#$(uri "$SUB_NAME")"
    command -v qrencode >/dev/null && echo "  订阅二维码图片: $SUB_QR"
    print_qr "通用订阅二维码 (各类手机客户端扫码导入):" "${SUB_AUTO:-$SUB_BASE64}"
  else
    echo; yellow "未开启在线订阅, 订阅文件在 $SUB_WWW/ (base64.txt / clash.yaml / sing-box.json)"
  fi

  if command -v qrencode >/dev/null; then
    echo
    read -rp "显示每个节点的二维码? [y/N]: " q
    if [[ $q == [yY] ]]; then
      while read -r l; do print_qr "[${l%%://*}]" "$l"; done < "$LINKS"
    fi
  fi
  echo
  yellow "提示: Hy2/TUIC/AnyTLS 使用自签证书 (已开启跳过验证); 云服务商安全组需自行放行端口 (Hy2/TUIC 为 UDP)。"
  [[ -n $PORT_2 && -n $HOP_RANGE ]] && yellow "Hy2 端口跳跃范围 UDP ${HOP_RANGE/:/-}, 安全组也要放行; 端口跳跃仅 Clash/sing-box 订阅及支持 mport 的客户端生效。"
  [[ -n $PORT_2 && -n $HY2_UP ]] && yellow "Hy2 带宽: 上行 $HY2_UP / 下行 $HY2_DOWN Mbps (Brutal), 仅写入 Clash/sing-box 订阅。"
  [[ $SUB_ENABLED == 1 ]] && yellow "订阅地址含全部节点密钥且为明文 HTTP, 请勿公开分享; 不用时可在菜单中关闭订阅服务。"
}

proto_status() {
  local id pv
  for id in $PROTO_IDS; do
    pv=PORT_$id
    if [[ -n ${!pv} ]]; then
      printf '  %s. %-22s \033[32m已启用\033[0m  端口 %s\n' "$id" "${PROTO_NAME[$id]}" "${!pv}"
    else
      printf '  %s. %-22s 未启用\n' "$id" "${PROTO_NAME[$id]}"
    fi
  done
}

# 用当前变量重新生成配置并生效; 失败时按 $STATE.bak 回滚
rollback() {
  cp "$STATE.bak" "$STATE"; source "$STATE"
  build_server; build_subs
  svc sing-box restart >/dev/null 2>&1
  rm -f "$STATE.bak"
  die "$1, 已回滚到修改前的配置"
}

apply_changes() {
  build_server
  $BIN check -c "$CONF" || rollback "新配置检查未通过"
  build_subs; save_state
  svc sing-box restart >/dev/null 2>&1
  sleep 1
  svc_active sing-box || rollback "sing-box 启动失败"
  apply_hop
  open_firewall
  rm -f "$STATE.bak"
}

# 旧版订阅服务升级: 加入按客户端自动识别的通用订阅 /sub (令牌和端口不变)
upgrade_sub() {
  [[ -f $SUB_CONF && -f $STATE ]] || return 0
  grep -q 'sb_target' "$SUB_CONF" && return 0
  check_sys; load_state
  [[ -f $SUB_ENV ]] && source "$SUB_ENV"
  ENABLE_SUB=${SUB_ENABLED:-0}
  build_server; build_subs
  cp "$SUB_CONF" "$SUB_CONF.bak"
  build_sub_nginx
  if ! nginx -t -q -c "$SUB_CONF" 2>/dev/null; then
    mv "$SUB_CONF.bak" "$SUB_CONF"; yellow "订阅服务升级失败, 已保留旧配置"; return 0
  fi
  rm -f "$SUB_CONF.bak"
  svc_active sb-sub && svc sb-sub restart >/dev/null 2>&1
  green "订阅服务已升级: 新增自动识别客户端的通用订阅地址 (菜单 2 查看)"
}

# Hysteria2 优化: 端口跳跃 / Brutal 带宽
hy2_settings() {
  check_sys; load_state
  [[ -n $PORT_2 ]] || die "未启用 Hysteria2, 可在菜单 7 中增加"
  [[ -f $SUB_ENV ]] && source "$SUB_ENV"
  ENABLE_SUB=${SUB_ENABLED:-0}

  echo; green "Hysteria2 当前设置:"
  echo "  监听端口: $PORT_2"
  if [[ -n $HOP_RANGE ]]; then echo "  端口跳跃: UDP ${HOP_RANGE/:/-} -> $PORT_2"; else echo "  端口跳跃: 未开启"; fi
  if [[ -n $HY2_UP ]]; then echo "  拥塞控制: Brutal (上行 $HY2_UP / 下行 $HY2_DOWN Mbps)"; else echo "  拥塞控制: BBR"; fi
  echo
  echo " 1. 开启 / 修改端口跳跃"
  echo " 2. 关闭端口跳跃"
  echo " 3. 设置带宽 (Brutal)"
  echo " 4. 清除带宽 (改回 BBR)"
  read -rp "请选择 (回车取消): " c
  cp "$STATE" "$STATE.bak"
  case $c in
    1) ask_hop || { rm -f "$STATE.bak"; return; } ;;
    2) HOP_RANGE="" ;;
    3) ask_bw  || { rm -f "$STATE.bak"; return; } ;;
    4) HY2_UP=""; HY2_DOWN="" ;;
    *) rm -f "$STATE.bak"; return ;;
  esac
  apply_changes
  echo
  if [[ $SUB_ENABLED == 1 ]]; then
    green "已生效, 客户端「更新订阅」即可。"
  else
    yellow "已生效, 请用新的节点信息重新导入 (菜单 2 查看)。"
  fi
}

# 增加 / 删除协议: 复用原有密钥、端口和订阅地址, 客户端更新订阅即可
manage_protos() {
  check_sys; load_state
  [[ -f $SUB_ENV ]] && source "$SUB_ENV"
  ENABLE_SUB=${SUB_ENABLED:-0}

  echo; green "当前协议:"; proto_status; echo
  echo "输入编号: 未启用的会被增加, 已启用的会被删除"
  read -rp "协议编号 (空格分隔, 回车取消): " sel
  [[ -z $sel ]] && return

  local add=() del=() id pv seen=" " left=0
  for id in ${sel//,/ }; do
    [[ $id =~ ^[1-4]$ && $seen != *" $id "* ]] || continue
    seen+="$id "; pv=PORT_$id
    if [[ -n ${!pv} ]]; then del+=("$id"); else add+=("$id"); fi
  done
  ((${#add[@]} + ${#del[@]})) || { yellow "没有有效的编号"; return; }
  for id in $PROTO_IDS; do pv=PORT_$id; [[ -n ${!pv} ]] && left=$((left + 1)); done
  ((left - ${#del[@]} + ${#add[@]} > 0)) || die "至少要保留一个协议"

  echo
  for id in "${add[@]}"; do echo "  + 增加 ${PROTO_NAME[$id]}"; done
  for id in "${del[@]}"; do pv=PORT_$id; echo "  - 删除 ${PROTO_NAME[$id]} (端口 ${!pv})"; done
  read -rp "确认? [Y/n]: " q; [[ $q == [nN] ]] && return

  if [[ " ${add[*]} " == *" 1 "* ]]; then
    read -rp "Reality 伪装域名 (回车=$REALITY_SNI): " s
    REALITY_SNI=${s:-$REALITY_SNI}
  fi

  cp "$STATE" "$STATE.bak"   # 失败时回滚

  local freed=()
  for id in "${del[@]}"; do pv=PORT_$id; freed+=("${!pv}"); printf -v "$pv" '%s' ""; done
  local p=$(($(max_port) + 1))
  for id in "${add[@]}"; do p=$(alloc_port "$p"); printf -v "PORT_$id" '%s' "$p"; p=$((p + 1)); done

  apply_changes
  ((${#freed[@]})) && close_firewall "${freed[@]}"

  echo; green "修改完成, 当前协议:"; proto_status
  echo
  if [[ $SUB_ENABLED == 1 ]]; then
    green "订阅地址不变, 客户端「更新订阅」即可生效。"
  else
    yellow "未开启在线订阅, 请用新的分享链接重新导入 (菜单 2 查看)。"
  fi
  if ((${#add[@]})); then
    echo; green "新增节点链接:"
    for id in "${add[@]}"; do pv=PORT_$id; grep -E ":${!pv}([?#]|$)" "$LINKS"; done
  fi
}

toggle_sub() {
  check_sys
  [[ -f $SUB_CONF ]] || die "未配置订阅服务, 请先用菜单 1 重新安装并开启订阅"
  if svc_active sb-sub; then
    svc sb-sub stop >/dev/null 2>&1; svc sb-sub disable >/dev/null 2>&1
    sed -i 's/^SUB_ENABLED=.*/SUB_ENABLED=0/' "$SUB_ENV"
    green "订阅服务已关闭"
  else
    svc sb-sub enable >/dev/null 2>&1; svc sb-sub start >/dev/null 2>&1
    sed -i 's/^SUB_ENABLED=.*/SUB_ENABLED=1/' "$SUB_ENV"
    svc_active sb-sub && green "订阅服务已开启" || red "订阅服务启动失败, 查看 /var/log/sb-sub.log"
  fi
}

do_update() {
  check_sys; install_deps; install_core
  [[ -s $CONF ]] && svc sing-box restart && green "已更新并重启"
}

do_uninstall() {
  read -rp "确认卸载 sing-box 及全部配置? [y/N]: " q; [[ $q == [yY] ]] || return
  check_sys
  local by_sb=0; [[ -f $WORK_DIR/.nginx_by_sb ]] && by_sb=1
  [[ -f $HOP_APPLIED ]] && fw_range close "$(<"$HOP_APPLIED")"
  for s in sing-box sb-sub sb-hop; do
    svc $s stop >/dev/null 2>&1; svc $s disable >/dev/null 2>&1
    rm -f /etc/systemd/system/$s.service /etc/init.d/$s
  done
  [[ $INIT == systemd ]] && systemctl daemon-reload
  [[ -f $HOP_SH ]] && "$HOP_SH" stop >/dev/null 2>&1
  rm -rf "$WORK_DIR" "$BIN" "$SUB_WWW" /var/log/sb-sub.log "$SYSCTL_FILE"
  green "已卸载"
  ((by_sb)) && yellow "nginx 是本脚本安装的, 如不再需要可手动卸载 (如 apt remove nginx)"
}

menu() {
  clear
  green "=========== sing-box 一键多协议 ==========="
  if [[ -x $BIN ]]; then
    check_sys
    echo " 内核: $($BIN version 2>/dev/null | head -1)"
    svc_active sing-box && echo " 状态: 运行中" || echo " 状态: 未运行"
    [[ -f $SUB_CONF ]] && { svc_active sb-sub && echo " 订阅: 已开启" || echo " 订阅: 已关闭"; }
  else
    echo " 状态: 未安装"
  fi
  echo "-------------------------------------------"
  echo " 1. 安装 / 重新生成节点"
  echo " 2. 查看节点、订阅与二维码"
  echo " 3. 重启服务"
  echo " 4. 查看日志"
  echo " 5. 更新 sing-box 内核"
  echo " 6. 网络优化 (BBR + UDP 缓冲区)"
  echo " 7. 增加 / 删除协议"
  echo " 8. Hysteria2 优化 (端口跳跃 / 带宽)"
  echo " 9. 开启 / 关闭订阅服务"
  echo " 10. 卸载"
  echo " 0. 退出"
  read -rp "请选择: " n
  case $n in
    1) do_install ;;
    2) show_nodes ;;
    3) check_sys; svc sing-box restart && green "sing-box 已重启"
       [[ -f $SUB_CONF ]] && svc_active sb-sub && svc sb-sub restart && green "订阅服务已重启" ;;
    4) check_sys; if [[ $INIT == systemd ]]; then journalctl -u sing-box -n 50 --no-pager; else tail -n 50 /var/log/messages; fi ;;
    5) do_update ;;
    6) net_optimize ;;
    7) manage_protos ;;
    8) hy2_settings ;;
    9) toggle_sub ;;
    10) do_uninstall ;;
    *) exit 0 ;;
  esac
}

main() {
  check_root
  migrate_state
  upgrade_sub
  case $1 in
    install)   do_install ;;
    info)      show_nodes ;;
    proto)     manage_protos ;;
    hy2)       hy2_settings ;;
    tune)      check_sys; net_optimize ;;
    sub)       toggle_sub ;;
    update)    do_update ;;
    uninstall) do_uninstall ;;
    *)         menu ;;
  esac
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
