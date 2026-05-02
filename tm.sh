#!/usr/bin/env bash
set -e

run_quiet() {
  name="$1"
  shift

  log_file="/tmp/tm_install_${name}_$(date +%s).log"

  echo
  echo "安装/配置：${name} ..."

  if "$@" >"$log_file" 2>&1; then
    echo "✅ ${name} 成功"
    rm -f "$log_file"
  else
    echo "❌ ${name} 失败"
    echo "错误日志：$log_file"
    echo
    echo "最后 20 行错误："
    tail -n 20 "$log_file"
    exit 1
  fi
}

# 检查 FEISHU_WEBHOOK
if [ -z "$FEISHU_WEBHOOK" ]; then
  echo "错误：请先设置 FEISHU_WEBHOOK"
  echo
  echo "用法示例："
  echo "export FEISHU_WEBHOOK='https://open.feishu.cn/open-apis/bot/v2/hook/你的key'"
  echo "bash tm.sh"
  exit 1
fi

# 提取飞书 token
FEISHU_TOKEN="${FEISHU_WEBHOOK##*/}"

if [ -z "$FEISHU_TOKEN" ]; then
  echo "错误：FEISHU_WEBHOOK 格式不正确"
  exit 1
fi

# 安装 Apprise，不显示安装过程
run_quiet "Apprise" python3 -m pip install --user -U apprise

# 配置 PATH
echo
echo "配置 PATH ..."

export PATH="$HOME/.local/bin:$PATH"

add_path_line() {
  rc_file="$1"
  path_line="$2"

  touch "$rc_file"

  grep -qxF "$path_line" "$rc_file" || \
  echo "$path_line" >> "$rc_file"
}

add_path_line "$HOME/.bashrc" 'export PATH="$HOME/.local/bin:$PATH"'
add_path_line "$HOME/.zshrc" 'export PATH="$HOME/.local/bin:$PATH"'

echo "✅ PATH 配置完成"

# 检查 Apprise
echo
echo "检查 Apprise ..."

if ! command -v apprise >/dev/null 2>&1; then
  echo "❌ apprise 命令未找到"
  echo "当前 PATH：$PATH"
  exit 1
fi

echo "✅ Apprise 可用：$(apprise --version)"

# 配置飞书机器人
echo
echo "配置飞书机器人 ..."

mkdir -p "$HOME/.config"

cat > "$HOME/.config/apprise.conf" <<EOF
feishu://${FEISHU_TOKEN}
EOF

chmod 600 "$HOME/.config/apprise.conf"

echo "✅ 飞书机器人配置完成"

# 创建 tm / tma 命令
echo
echo "创建 tm / tma 命令 ..."

mkdir -p "$HOME/.local/bin"

cat > "$HOME/.local/bin/tm_core" <<'TM_EOF'
#!/usr/bin/env bash
set -o pipefail

PROJECT_NAME="TM"
PROJECT_URL="https://github.com/Peaceful-World-X/TM"
MODE="$(basename "$0")"

show_help() {
  cat <<HELP
TM - Terminal Messenger / Tell Me - 终端消息助手

A lightweight command wrapper that runs shell commands and sends the result
to your notification channel through Apprise, such as Feishu.
一个轻量级命令包装工具：执行任意终端命令，并在命令结束后通过 Apprise
将执行结果发送到飞书等通知渠道。
GitHub: ${PROJECT_URL}

Usage / 用法:
  tm  <command>   Send task info and last 20 lines
  tma <command>   Send task info first, then send full output separately

  tm  '<command with pipe or redirect>'
  tma '<command with pipe or redirect>'

Examples / 示例:
  tm echo hello
  tm 'sleep 10 && echo done'
  tm 'ip -c a'

  tma echo hello
  tma 'ip -c a'
  tma 'python train.py --epochs 10'

Features / 功能:
  - tm: send success/failure status and last 20 lines
  - tma: send success/failure status first, then full output as another message
  - Show command, time, user, IP, cost, log path
  - Save full log to /tmp/tm/
  - Strip ANSI color codes before sending to Feishu

Log format / 日志格式:
  /tmp/tm/<first_command_word>_<timestamp>.log

HELP
}

if [ "$#" -eq 0 ]; then
  show_help
  exit 0
fi

case "$1" in
  -h|--help)
    show_help
    exit 0
    ;;
esac

get_best_ip() {
  wired_ip="$(ip -o -4 addr show scope global up 2>/dev/null | awk '$2 ~ /^(eth|en|eno|ens|enp)/ {split($4,a,"/"); print a[1]; exit}')"
  if [ -n "$wired_ip" ]; then
    echo "$wired_ip"
    return
  fi

  wifi_ip="$(ip -o -4 addr show scope global up 2>/dev/null | awk '$2 ~ /^(wl|wlan)/ {split($4,a,"/"); print a[1]; exit}')"
  if [ -n "$wifi_ip" ]; then
    echo "$wifi_ip"
    return
  fi

  other_ip="$(ip -o -4 addr show scope global up 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
  if [ -n "$other_ip" ]; then
    echo "$other_ip"
    return
  fi

  hostname -I 2>/dev/null | awk '{print $1}'
}

strip_ansi() {
  if command -v perl >/dev/null 2>&1; then
    perl -pe 's/\e\[[0-?]*[ -\/]*[@-~]//g; s/\e\][^\a]*(\a|\e\\)//g; s/\r//g'
  else
    sed -E $'s/\x1b\\[[0-?]*[ -\\/]*[@-~]//g; s/\r//g'
  fi
}

send_msg() {
  apprise -b "$1"
}

cmd="$*"
start_time="$(date '+%m-%d %H:%M:%S')"
timestamp="$(date '+%Y%m%d_%H%M%S')"
user_host="$(whoami)@$(hostname)"
ip_addr="$(get_best_ip)"

if [ -z "$ip_addr" ]; then
  ip_addr="N/A"
fi

first_word="$(printf '%s' "$cmd" | awk '{print $1}')"
safe_first_word="$(printf '%s' "$first_word" | sed 's/[^a-zA-Z0-9._-]/_/g')"

if [ -z "$safe_first_word" ]; then
  safe_first_word="command"
fi

log_dir="/tmp/tm"
mkdir -p "$log_dir"

log_file="${log_dir}/${safe_first_word}_${timestamp}.log"
time_file="$(mktemp /tmp/tm_time.XXXXXX)"

if command -v /usr/bin/time >/dev/null 2>&1; then
  /usr/bin/time -p -o "$time_file" bash -lc "$cmd" 2>&1 | tee "$log_file"
  status=${PIPESTATUS[0]}

  real_time="$(awk '/^real / {print $2}' "$time_file")"
  user_time="$(awk '/^user / {print $2}' "$time_file")"
  sys_time="$(awk '/^sys / {print $2}' "$time_file")"

  time_cost="real ${real_time}，user ${user_time}，sys ${sys_time}"
else
  start_epoch="$(date +%s)"
  bash -lc "$cmd" 2>&1 | tee "$log_file"
  status=${PIPESTATUS[0]}
  end_epoch="$(date +%s)"
  elapsed="$((end_epoch - start_epoch))"
  time_cost="real ${elapsed}s，user N/A，sys N/A"
fi

end_time="$(date '+%m-%d %H:%M:%S')"
rm -f "$time_file"

if [ "$status" -eq 0 ]; then
  result="✅S(${status})"
else
  result="❌F(${status})"
fi

last_output="$(tail -n 20 "$log_file" | strip_ansi)"
full_output="$(cat "$log_file" | strip_ansi)"

info_body="$(cat <<MSG
${result}-${cmd}

🕘: ${start_time} → ${end_time}
👤: ${user_host}
🌐: ${ip_addr}
⏱️: ${time_cost}
📄: ${log_file}
MSG
)"

tm_body="$(cat <<MSG
${info_body}

📋 Last 20 lines:
${last_output}
MSG
)"

tma_output_body="$(cat <<MSG
📋 Full Output:

${full_output}
MSG
)"

case "$MODE" in
  tma)
    send_msg "$info_body"
    send_msg "$tma_output_body"
    ;;
  tm|*)
    send_msg "$tm_body"
    ;;
esac

exit "$status"
TM_EOF

chmod +x "$HOME/.local/bin/tm_core"

ln -sf "$HOME/.local/bin/tm_core" "$HOME/.local/bin/tm"
ln -sf "$HOME/.local/bin/tm_core" "$HOME/.local/bin/tma"

echo "✅ tm / tma 命令创建完成"

echo
echo "测试 tm ..."
tm echo hello

echo
echo "测试 tma ..."
tma echo hello