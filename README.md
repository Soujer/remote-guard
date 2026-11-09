# remote-guard — Windows 远程控制监控告警

**本机被任何主流远控软件连接时，几秒内推送到你的手机**（Bark / 微信公众号，支持多通道）。

被控检测、无人值守、静默运行、零闪屏。适合"离开工位后想知道有没有人远程我的电脑"的场景。

## 检测能力

| 检测项 | 方式 |
|---|---|
| UU远程 (GameViewer) | 高端口直连 + 会话文件 + 串流 IO（GPU 编码 CPU≈0 也能抓） |
| ToDesk | 会话 xlog 文件 + 串流 IO + 服务突发启动 |
| 向日葵 / AweSun | 串流 IO（免疫 CPU 空转误报）+ 服务突发启动 |
| RustDesk / AnyDesk / TeamViewer / Parsec / Chrome 远程桌面 | 进程活动 + 串流 IO |
| VNC / 快速助手 / Windows 远程协助 (msra) | 连接 / 进程存在 |
| RDP | qwinsta 活动 rdp-tcp#N 会话 + 3389 已建立连接 + **fDenyTSConnections 开关被改**（远端恶意开 RDP 的关键动作） |
| 病毒性远程 / 未知远控 | 隧道进程（frpc/nps/cloudflared…）、可疑进程链、脚本宿主远程加载、PS Base64、Defender 1116/1117、未知端口监听 |
| 输入注入 | 锁屏/安全桌面下仍有键鼠注入 = 必然异地控制（**只统计输入时间戳，不记录按键内容**） |

## 双通道架构

- **即时进程**（常驻，2 秒轮询）：会话建立 **2~6 秒**内推送告警；直连消失后 30~60 秒推送解除
- **主任务**（计划任务每分钟）：深度检测、30 分钟持续提醒、看护即时进程（崩溃自动拉起）

## 快速开始

1. 下载发行版（或 clone 后运行 `remote-guard-setup.exe`）
2. 配置推送通道（二选一或都要）：
   - **Bark**（iOS）：App Store 装 Bark，复制你的 key 填入
   - **hayo**（微信公众号）：点"扫码获取"，微信扫码确认，token 自动填入
3. 点"测试通道"确认手机能收到
4. 点"一键部署"完成（自动注册计划任务 + 启动即时监控）

## 推送通道配置

`push-channels.json`：

```json
{
  "channels": [
    { "name": "bark", "type": "bark", "enabled": true, "key": "你的key", "base": "https://api.day.app", "group": "remote-guard", "ttl": 600 },
    { "name": "hayo", "type": "hayo", "enabled": true, "token": "你的token", "base": "https://hayo.svip8.vip" }
  ]
}
```

支持 `webhook` 自定义类型（GET `url?title=&content=`）。

## 文件说明

| 文件 | 用途 |
|---|---|
| `remote-guard.ps1` | 主检测脚本（计划任务每分钟） |
| `remote-guard-instant.ps1` | 即时通道常驻进程（2 秒轮询） |
| `remote-guard-launcher.vbs` | 隐藏启动器（零闪屏） |
| `remote-guard-instant-launcher.vbs` | 即时进程启动器 |
| `remote-guard-setup.ps1` / `.exe` | 配置 + 一键部署工具 |

## 设计原则

- **只读检测**：不注入任何进程、不做键盘记录、不修改远控软件
- **零闪屏**：wscript + VBS 隐藏启动，全程无窗口
- **免疫误报**：常驻信令客户端（443 心跳 + CPU 空转）不触发；会话开始/结束共用的文件动作需直连/IO 佐证
- **会话文件红线**：UU 的 ini 在会话开始**和**结束都会刷新，必须叠加"会话在场"证据才判定

## 已知限制

- UU 走纯中继无直连时，即时通道靠会话文件 + IO 兜底（延迟可能到分钟级）
- 解除消息有 30~60 秒保持期（防抖设计）
- 断开后 6 分钟内本机打字可能维持"受控"状态（保守设计）

## License

MIT
