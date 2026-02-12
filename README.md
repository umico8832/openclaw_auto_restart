> **专为 macOS & Clash 环境优化的 OpenClaw 智能守护脚本**
> 
> *不再担心 OpenClaw 假死、断网或日志爆炸。全自动托管，极致稳定。*
<img width="597" height="385" alt="image" src="https://github.com/user-attachments/assets/ea42cc58-7835-4969-8c1b-e53d3ea59c31" />
<img width="597" height="385" alt="image" src="https://github.com/user-attachments/assets/3e7f988f-8316-4721-bec1-e32ae214bff9" />


## 📖 简介 (Introduction)

**OpenClaw Watchdog** 是一个集成了**网络环境感知**、**日志实时分析**、**端口死锁检测**以及**自动日志轮转**的全能型守护进程。

它专为解决 OpenClaw 在网络环境不佳时，运行不稳定的痛点而生，确保你的服务永远在线，且日志清晰可读。

## ⚙️ 环境要求 (Requirements)

- **操作系统**: macOS (推荐) 或 Linux (需微调 `stat` 和 `ifconfig` 命令)。
  
- **依赖工具**: `curl`, `lsof`, `nc` (netcat), `perl` (macOS自带), `awk`.
  
- **网络环境**: 建议配合 Clash vergy 的 Tun 模式) 或其他创建 `utun` 接口的代理软件使用。
  

---

## 🚀 快速开始 (Quick Start)

### 1. 配置脚本

打开脚本文件，在顶部的“用户配置区”修改你的参数：

```bash
# === 用户配置区 ===
TARGET_PORT=18789            # OpenClaw 监听的端口（默认不用改）
```

### 2. 赋予权限

```bash
chmod +x ~/claw_start.sh
```

### 3. 启动

```bash
~/claw_start.sh
```

#### （可选）配置别名从而快速启动

```bash
echo "alias claw='~/claw_start.sh'" >> ~/.zshrc
source ~/.zshrc
```

终端输入` claw`即可直接启动

### 4. 停止

直接按 `Ctrl + C`。脚本会捕获中断信号，执行 `cleanup` 函数，杀掉后台进程并退出。

---

## ✨ 核心特性 (Key Features)

### 1. 🌐 智能网络感知 (Network Aware)

脚本内置两道网络防线，特别适配 中国大陆的 **Clash vergy** 用户：

- **物理层检测**：自动检测 `utun` 网卡是否存在。如果代理断开，脚本会暂停服务并等待，防止无效重连。
  
- **连通性检测**：强制绕过本地代理 (`--noproxy`) 检测 Google 连通性 (Generate_204)，确保只有在真正“翻墙”成功时才启动服务。
  

### 2. 👁️ 多维度看门狗 (Multi-Dimension Watchdog)

这不仅仅是监控 PID，而是从四个维度确保服务健康：

- **关键词猎杀**：实时分析日志流，一旦发现 `ECONNRESET`、`WebSocket Error` 等致命错误，毫秒级触发重启。
  
- **僵尸进程检测**：使用 `nc` 探测端口。如果进程还在但端口不响应（假死），立即执行“精准猎杀”。
  
- **进程存活监控**：传统的 PID 监控，防止程序意外崩溃退出。
  
- **网络运行时监控**：运行时若检测到 Tun 网卡消失或网络中断，自动停止服务等待恢复。
  

### 3. 🧹 优雅的日志处理 (Smart Logging)

- **时间戳转换**：利用 Perl 将 OpenClaw原本难读的 ISO 格式（UTC）实时转换为本地时间的 `[HH:MM:SS]` 格式。
  
- **噪音过滤**：自动屏蔽烦人的 `MDNS` 等无用日志。
  
- **防爆机制**：监控日志文件大小，超过 **10MB** 自动执行维护性重启和清理，防止硬盘被填满。
  
- **自动轮转**：每次重启或退出时，自动截取最后 1000 行保留，保持日志文件轻量。
  

### 4. 🔫 精准猎杀模式 (Precise Kill)

启动前和重启时执行 `kill_port_holder` 函数：

- 通过 `lsof` 精确查找占用 `TARGET_PORT` 的进程并击杀。
  
- 防止旧进程残留导致的 "Address already in use" 错误。
  

---

## 🛠️ 常见问题 (FAQ)

**Q: 为什么一直显示 "网络未就绪，等待 Clash 恢复..."？** A: 脚本检测到系统中没有 `utun` 网卡，或者无法直接连接 Google。请检查你的 Clash 是否开启了 "Tun Mode" (增强模式) 并且网络连接正常。

**Q: 我在 Linux 上运行报错？** A: 脚本默认针对 macOS 的 `ifconfig` 和 `stat` 命令优化。

- **Linux 用户请修改：**
  
  - 检测网卡部分：`ifconfig -l` 改为 `ls /sys/class/net` 或 `ip link`。
    
  - 文件大小检测：`stat -f%z` 改为 `stat -c%s`。
    

**Q: 日志里的 `⚡️ [看门狗] 检测到致命错误` 是什么意思？** A: 这意味着脚本在 OpenClaw 的输出中捕获到了你定义的 `ERROR_KEYWORDS`（如 WebSocket 断开、超时等）。脚本判定当前连接已失效，正在主动重启服务以恢复连接。
