#!/bin/bash

# === OpenClaw Watchdog ===

# -------------------------------------- 用户配置区 --------------------------------------
TARGET_PORT=18789   # 如果你改了 OpenClaw 端口，只需要改这里
LOG_FILE="/tmp/openclaw_monitor.log"    # 日志文件路径
ERROR_KEYWORDS="channel exited|ECONNRESET|WebSocket Error|408 Request Time-out|ETIMEDOUT|getaddrinfo ENOTFOUND|Precondition Required|Connection Terminated"
# --------------------------------------------------------------------------------------

touch "$LOG_FILE"   # 确保日志文件存在，避免后续写入时出错。
set +m              # 关闭作业控制，避免脚本中断时进入交互式 shell 导致无法自动重启。



# === 精准猎杀函数 ===
kill_port_holder() {
    local PIDS
    PIDS=$(lsof -nP -t -iTCP:$TARGET_PORT -sTCP:LISTEN 2>/dev/null)

    if [ -n "$PIDS" ]; then
        kill -15 $PIDS 2>/dev/null
        sleep 0.3
        for pid in $PIDS; do
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        done
        sleep 0.2
    fi

    # 兜底：只从“进程名=openclaw”里挑出参数包含 gateway 的来杀（避免 pkill -f 宽匹配）
    local pid cmd
    for pid in $(pgrep -x openclaw 2>/dev/null); do
        cmd=$(ps -p "$pid" -o command= 2>/dev/null)
        if [[ "$cmd" == *" gateway "* ]] || [[ "$cmd" == *" gateway" ]]; then
            kill -15 "$pid" 2>/dev/null
            sleep 0.2
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        fi
    done
}







# === 清理并退出函数 ===
cleanup() {
    trap - EXIT SIGINT SIGTERM              # 移除 EXIT/SIGINT/SIGTERM 的 trap，避免重复触发；
    echo -e "\n🛑 正在停止服务..."    
    kill_port_holder                        # 调用精准猎杀函数，释放目标端口；
    echo "✅ 服务已彻底停止"
    exit 0                                  # 以状态码 0 优雅退出脚本；
}

trap cleanup EXIT SIGINT SIGTERM        # 在脚本正常结束、Ctrl+C 中断或终止信号到来时，自动执行清理逻辑。

LAST_LINE_COUNT=$(wc -l < "$LOG_FILE" | tr -d ' ')  #   读取 $LOG_FILE 当前总行数；
[[ -z "$LAST_LINE_COUNT" ]] && LAST_LINE_COUNT=0    #   为空时初始化为 0。



# === 网络检测函数 ===
check_network() {
    # 1. 第一道防线：物理检测
    # 检查系统网卡列表里有没有 "utun" (Clash 的 Tun 模式启动后一定有 utun 关键词)
    local interfaces=$(ifconfig -l)
    if [[ "$interfaces" != *"utun"* ]]; then
        return 1 # 没找到 utun 网卡，直接判死刑，不需要再 curl 了
    fi

    # 2. 第二道防线：强制直连检测
    # --noproxy "*": 告诉 curl 忽略终端里所有的 http_proxy 环境变量
    # 这样它就必须走系统路由表。如果 Tun 没开，这行命令就不会再误报 204 了。
    local code=$(curl --noproxy "*" -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 "http://www.google.com/generate_204")
    
    if [ "$code" == "204" ]; then
        return 0
    else
        return 1
    fi
}



# ====== 主循环区 ============================================================================
while true; do
    echo "----------------------------------------"
    
    # === 网络等待区 ===
    # 如果网络不通，死循环等待，每5秒测一次，直到网通了才往下走
    while ! check_network; do
        echo "🌐 [$(date +%T)] 网络未就绪，等待 Clash 恢复..."
        kill_port_holder # 网络不通时，确保服务是关闭的，省得瞎报错
        sleep 5
    done

    # === 启动区 ===
    echo "✅ [$(date +%T)] 网络正常，准备启动服务！"
    kill_port_holder
    echo "🚀 [$(date +%T)] 正在启动 Gateway...(Port: $TARGET_PORT)"     
    START_TIME=$(date +%s)                              # 记录启动时间戳，用于后续监控运行时长和冷却逻辑。
    echo "--- New Session $(date) ---" >> "$LOG_FILE"   # 每次启动都在日志里标记一个分割线，方便后续分析和排查历史记录。
    
    # === 日志处理与监控区 ===
    openclaw gateway 2>&1 |                             #  将标准错误重定向到标准输出，统一进入管道处理。
    perl -MPOSIX -ne 'BEGIN{$|=1} next if /MDNS/; s/\d{4}-\d{2}-\d{2}T(\d{2}:\d{2}:\d{2}).*?Z/strftime("[%H:%M:%S]", localtime)/e; print;' |    # 过滤掉包含 "MDNS" 的日志行，并将时间戳转换为本地时区的 [HH:MM:SS] 格式，便于阅读。
    tee -a "$LOG_FILE" &                                # 通过 tee 追加写入日志文件的同时保留终端输出。
    PIPE_PID=$!                                         # 后台运行整条管道（最后一个命令 tee 的 PID），用于后续管理（如停止/监控）。
    LAST_LINE_COUNT=$(wc -l < "$LOG_FILE" | tr -d ' ')  # 读取当前日志文件行数，作为后续增量输出或状态判断的基线。  




    HEARTBEAT_COUNT=0  # 初始化心跳计数器，用于周期性检查的触发控制。
    # === 运行时的监控逻辑 ===
    while true; do
        sleep 2


        # === 周期性检查 (每20秒) ===
        ((HEARTBEAT_COUNT++))
        if (( HEARTBEAT_COUNT % 10 == 0 )); then

            # [检查 1] 端口僵死检测 
            if ! nc -z -w 2 127.0.0.1 $TARGET_PORT >/dev/null 2>&1; then    # 使用 nc 命令检测目标端口是否有响应，如果没有响应则认为进程虽然存在但已僵死。
                echo "🧟 [$(date +%T)] 致命卡死：进程在但端口无响应 -> 重启!"
                kill_port_holder
                kill -9 $PIPE_PID 2>/dev/null
                break
            fi
            
            # [检查 2] 运行时掉线检测
            if ! check_network; then
                echo "📉 [$(date +%T)] 运行时检测到 Tun 断开/网络中断 -> 停止服务!"
                kill_port_holder
                break
            fi

            # [检查 3] 日志容量防爆检测 
            # macOS 使用 stat -f%z 获取文件大小(字节)，Linux 使用 stat -c%s
            # 设置阈值为 10MB (10485760 字节)
            LOG_SIZE=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
            if [ "$LOG_SIZE" -gt 10485760 ]; then
                echo "🧹 [$(date +%T)] 日志文件过大(${LOG_SIZE} bytes)，执行维护性重启..."
                kill_port_holder # 杀掉进程释放文件句柄
                # break 跳出循环后，会自动执行大循环末尾的日志轮转代码
                break 
            fi
        fi



        # 监控子进程与日志增长状态：
        # 通过 `kill -0 $PIPE_PID` 探测目标进程是否仍存活。

        if ! kill -0 $PIPE_PID 2>/dev/null; then
            echo "⚠️ [$(date +%T)] 进程意外退出，准备重启..."
            break
        fi


        # 统计日志文件当前总行数 `CURRENT_LINE_COUNT`，并与上次记录的 `LAST_LINE_COUNT` 比较。
        # 若行数为空或未增长，说明暂无新日志可处理：
        # 当日志被截断/轮转导致当前行数小于上次行数时，将 `LAST_LINE_COUNT` 重置为 0，然后继续下一轮循环等待新内容。
        CURRENT_LINE_COUNT=$(wc -l < "$LOG_FILE" | tr -d ' ')
        if [ -z "$CURRENT_LINE_COUNT" ] || [ "$CURRENT_LINE_COUNT" -le "$LAST_LINE_COUNT" ]; then
            [[ "$CURRENT_LINE_COUNT" -lt "$LAST_LINE_COUNT" ]] && LAST_LINE_COUNT=0
            continue
        fi
        NEW_LOG_CONTENT=$(tail -n $((CURRENT_LINE_COUNT - LAST_LINE_COUNT)) "$LOG_FILE")
        LAST_LINE_COUNT=$CURRENT_LINE_COUNT
        

        # 看门狗核心：在增量日志中搜索ERROR_KEYWORDS，如果匹配到任何一个关键词，就认为发生了不可恢复的错误。
        # 一旦命中，输出告警信息并触发强制重启流程：
        #    - 释放占用端口的进程
        #    - 强制终止当前管道/子进程（PIPE_PID）
        #    - 跳出循环，交由外层逻辑完成重启
        if echo "$NEW_LOG_CONTENT" | grep -E -q "$ERROR_KEYWORDS"; then
            
            if ! check_network; then
                # 情况 A：日志报错了，而且网络检测也挂了 -> 判定为网络中断
                echo -e "\n📉 [$(date +%T)] 运行时检测到网络中断，服务暂停"
            else
                # 情况 B：日志报错了，但网络居然是通的 -> 判定为程序崩溃/被服务端踢出
                echo -e "\n⚡️ [看门狗] 检测到致命错误 (网络正常) -> 执行强制重启!"
            fi

            # 无论哪种情况，都要杀进程并跳出循环
            kill_port_holder
            kill -9 $PIPE_PID 2>/dev/null
            break
        fi


    done

    # 冷却与轮转
    [[ $(wc -l < "$LOG_FILE") -gt 5000 ]] && tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE" && LAST_LINE_COUNT=$(wc -l < "$LOG_FILE" | tr -d ' ')
    
    RUN_DURATION=$(($(date +%s) - START_TIME))
    [[ $RUN_DURATION -lt 10 ]] && sleep 3 || sleep 1


done
