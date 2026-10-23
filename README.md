# Sing-box
Sing-box一键四协议版本(vless/reality、Hy2、Tuic、Anytls精简版)

Run the ‘all-in-one initialization command’ by pasting the code and pressing Enter.

	apt update -y && apt upgrade -y

Install basic tools
	
	apt install -y curl wget sudo socat cron unzip

Set time zone
	
    apt install systemd-timesyncd -y
 
    timedatectl set-timezone Asia/Shanghai

Run the BBR acceleration script

    sudo bash -c 'echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf && echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf && sysctl -p'

Deploy a multi-protocol Sing-box instance with a one-click script
	
	bash <(wget -qO- https://raw.githubusercontent.com/kutnahola/sing-box/main/sb.sh)
	
Action Menu

	•进入后会列出4个协议的启用状态和端口。
	•输入编号即可：未启用的会被增加，已启用的会被删除，可以一次输入多个，例如 2 3 4。
	•确认后自动生效，并显示新增节点的分享链接。

The part that does not change

	•UUID、密码、Reality 密钥、订阅地址都保持不变，客户端点一下「更新订阅」就行。
	•已有协议的端口不变，新协议会自动分配空闲端口，不会和订阅端口撞上。
	•被删除协议的端口会自动从 ufw 或 firewalld 中关闭，新端口自动放行。

Safety Measures

	•新配置检查不通过，或 sing-box 启动失败，会自动回滚到修改前的配置，订阅内容也一起恢复。
	•不允许把协议全删光，至少要保留一个。

Test Results

	•新配置通过 sing-box 1.14.0 检查，新增的协议实际跑通了流量。
	•模拟启动失败时回滚正确，配置和订阅文件都恢复如初。

注意：增减协议需要安装时生成的状态文件。用之前版本脚本装的机器需要先用菜单 1 重新安装一次，之后就可以随意增减了。
