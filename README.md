# remote-guard — Windows / macOS 远程控制监控告警

**本机被任何主流远控软件连接时，几秒内推送到你的手机**（Bark / 微信公众号，支持多通道）。

被控检测、无人值守、静默运行、零闪屏。适合"离开工位后想知道有没有人远程我的电脑"的场景。

## 下载

到 [Gitee 发行版](https://gitee.com/Soujer/remote-guard/releases) 或 [GitHub Releases](https://github.com/Soujer/remote-guard/releases/latest) 下载对应平台发行版。当前版本：**v1.2.0**。

| 平台 | 发行包 | 使用 |
|---|---|---|
| Windows | `remote-guard-windows-vX.X.zip` | 解压 → 运行 `remote-guard-setup.exe` |
| macOS | `remote-guard-macos-vX.X.tar.gz` | 解压 → `bash install-macos.sh` |

## 支持平台

| 平台 | 实现 | 入口 |
|---|---|---|
| **Windows** | PowerShell 5.1，计划任务 + 常驻即时进程 | `remote-guard-setup.exe`（扫码配置 + 一键部署） |
| **macOS** | 纯 bash（零依赖），launchd 每分钟 + 常驻即时通道 | `macos/install-macos.sh` |

## 检测能力（Windows）

| 检测项 | 方式 |
|---|---|
| UU远程 (GameViewer) | 同一对端至少 3 个被控监听端口连续确认，或新鲜会话文件 + 连续 IO；已确认的连接无流量时也保持 |
| ToDesk | 同一进程连续流量 + 直连/新鲜 xlog；常驻 443 心跳不单独续期 |
| 向日葵 / AweSun | 同一进程的远程连接、IO 与直连/会话佐证，连续两轮确认 |
| RustDesk / AnyDesk / TeamViewer / Parsec / Chrome 远程桌面 | 同一进程连续两轮连接 + IO + 直连/CPU 佐证 |
| VNC / 快速助手 / Windows 远程协助 (msra) | VNC 检查连接；快速助手、msra 需连接与活动佐证，打开窗口不告警 |
| RDP | qwinsta 明确处于 Active/活动状态的 rdp-tcp#N 会话，或 3389 已建立连接；开关变化仅写诊断日志 |
| 病毒性远程 / 未知远控 | 隧道进程（frpc/nps/cloudflared…）、可疑进程链、脚本宿主远程加载、PS Base64、Defender 1116/1117、未知端口监听 |
| 输入诊断 | `-DryRun` 只统计输入时间戳和桌面状态，不记录按键；本机输入不建立或延长受控状态 |

## 检测能力（macOS）

| 检测项 | 方式 |
|---|---|
| 内置屏幕共享 / ARD | screensharingd + 5900 已建立连接 |
| RustDesk / AnyDesk / TeamViewer / ToDesk / 向日葵(AweSun) / Parsec / Chrome 远程桌面 | 非 80/443 高端口直连（单次即告警）+ CPU 持续占用 |
| 未知 VNC 监听 | 5900-5902 被未知进程监听 |
| 输入注入 | 锁屏下 HIDIdleTime 持续小于阈值（不记录按键内容） |

## 快速开始（Windows）

1. 下载 `remote-guard-windows-vX.X.zip` 并解压（或 clone 仓库）
2. 运行 `windows/remote-guard-setup.exe`（首次使用 ps1 源码可自行用 ps2exe 打包）
3. 配置推送通道（二选一或都要）：
   - **Bark**（iOS）：App Store 装 Bark，复制你的 key 填入
   - **hayo**（微信公众号）：点"扫码获取"，微信扫码确认，token 自动填入
4. 点"测试通道"确认手机能收到
5. 点"一键部署"完成（自动注册计划任务 + 启动即时监控）

## 快速开始（macOS）

```bash
cd macos
cp push-channels.conf.example push-channels.conf
open -t push-channels.conf   # 填入 Bark key 和/或 hayo token
bash install-macos.sh         # 测试通道 + 注册 launchd + 启动即时监控
```

卸载：`bash install-macos.sh remove`

## 远程连接自动加密录屏（Windows）

在配置程序中点击 **“加密录屏设置 / 播放”**，选择录像目录和存储上限。首次启用需选择或下载 FFmpeg，设置至少 12 位密码，并另存一份 `.rgkey` 播放私钥。程序只保存公钥；密码不会保存。私钥请备份到其他安全位置，与密码分开保管。**私钥或密码丢失，录像无法恢复。** 配置成功后，已安装的新版监控程序会在下一次确认远程会话时开始录制。

- 只在确认的受控会话中录制，不因远控软件运行或可疑事件告警单独开始。多个远控同时连接只录一份；全部确认断开后停止。沿用检测器约 3 分钟的断开观察期，因此实际断开后可能继续录制这段时间。录屏从确认时开始，不能回溯之前的操作。
- 默认捕获当前用户桌面（包含桌面上的显示器），缩放到最大 1280×720，5 帧/秒、H.264、约 400 kbps，无音频。参考大小约 **3 MB/分钟、15 MB/5 分钟、180 MB/小时**，实际随画面与编码开销变化。多显示器画面缩小后文字可能不清晰，帧率不适合游戏录像。
- 每 5 分钟独立保存一份 `.rgrec` 加密片段，片段切换可能有短暂间隙。默认总上限 **2 GB**，预留下一段空间时自动删除最旧片段；另留至少 **512 MB** 磁盘空间，空间不足时停止并记录错误。请及时备份要保留的录像。容量上限包含本程序遗留的 `.partial` 文件，不清理其他文件。
- MP4 压缩流经内存管道直接加密写盘，自动录屏不产生明文临时视频。采用 RSA-3072 OAEP-SHA256 包装随机 AES-256-CBC/HMAC-SHA256 密钥，每段独立随机密钥和 IV；播放先验证完整性，再解密到 FFplay 的内存管道。`.rgkey` 私钥以 PBKDF2-HMAC-SHA256（210000 次迭代）派生密钥加密并校验完整性。
- 播放：点击 **“打开加密录像”**，依次选择 `.rgrec`、`.rgkey` 并输入密码。可把录屏脚本、`RecordingCrypto.cs`、FFplay、私钥和录像复制到另一台 Windows 电脑上播放。私钥和密码不通过命令行传递，也不会上传录像。
- 录屏故障与推送相互独立。异常断电或强杀进程可能留下当前片段的 `.partial`，该片段不能保证恢复，之前完成的分段仍可播放。日志见安装目录 `recording.log`。持续故障每分钟重试，避免反复拉起编码器。
- FFmpeg/FFplay 按需从 [Gyan Windows 构建](https://www.gyan.dev/ffmpeg/builds/) 下载并核对发布方 SHA-256，不随源码或安装包捆绑。编码器路径可自选，推荐 Windows 10/11。使用 [FFmpeg 的 gdigrab](https://ffmpeg.org/ffmpeg-devices.html#gdigrab) 和可通过管道输出的 [分片 MP4](https://ffmpeg.org/ffmpeg-formats.html#mov_002c-mp4_002c-ismv)。锁屏、安全桌面、受保护内容或断开后的 RDP 桌面可能无法捕获；只覆盖监控进程所在的交互用户会话。macOS 暂不提供录屏。

高级参数位于安装目录 `recording.json`，默认录像目录为 `<安装目录>\recordings`。可以手动调整 `segmentSeconds`（30–900）、`fps`（1–15）、`width`（640–1920，按 16:9 限制高度）、`bitrateKbps`（100–2000）、`maxStorageMB`（128 MB–1 TB）与 `minFreeMB`（至少 128 MB）。设置页保存时使用默认编码参数。单段有严格字节上限，超限不会写满磁盘；未完成片段保留为 `.partial`。禁用录屏会保存当前片段后停止。

验证录屏（不捕获真实桌面、不发送通知）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-RecordingRegression.ps1
# 可额外验证合成画面编码、加密和解密后的视频可解码性：
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-RecordingRegression.ps1 -FFmpeg C:\path\to\ffmpeg.exe
```

## 双通道架构

- **Windows 即时进程**（常驻，2 秒轮询）：UU/ToDesk 首次采样建立基线，连续两次有效流量增长后告警（通常约 4~8 秒，取决于系统采集耗时）；会话信号连续消失 3 分钟后解除。
- **Windows 主任务**（计划任务每分钟）：读取即时通道的会话状态，避免相反或重复通知；即时通道不可用时回退到连续两轮检测；负责深度检测和进程看护。
- **Windows 会话通知**：只显示工具名和“已连接”或“已断开”，每次状态变化通知一次；持续连接不重复提醒。检测细节保留在本地日志。
- **macOS** 仍采用独立的即时/分钟检测逻辑，本轮 Windows 会话确认与去重改动不适用于 macOS。

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
| `windows/remote-guard.ps1` | Windows 主检测脚本（计划任务每分钟） |
| `windows/remote-guard-instant.ps1` | Windows 即时通道常驻进程（2 秒轮询） |
| `windows/remote-guard-launcher.vbs` | 隐藏启动器（零闪屏） |
| `windows/remote-guard-instant-launcher.vbs` | 即时进程启动器 |
| `windows/remote-guard-setup.ps1` | Windows 配置 + 一键部署工具源码（发行版含编译好的 exe） |
| `macos/remote-guard-macos.sh` | macOS 主检测 + 即时通道（单脚本双模式，纯 bash 零依赖） |
| `macos/install-macos.sh` | macOS 一键部署/卸载（launchd） |
| `macos/push-channels.conf.example` | macOS 推送通道配置模板 |

## 设计原则

- **只读检测**：不注入任何进程、不做键盘记录、不修改远控软件
- **零闪屏**：wscript + VBS 隐藏启动，全程无窗口
- **减少误报**：Windows 不再用 CPU、进程存在、服务启动、RDP 开关或输入时间戳单独认定受控。IO 包含文件操作，需要同一进程的连接和活动佐证。
- **会话文件红线**：UU 的 ini 在会话开始**和**结束都会刷新，必须叠加"会话在场"证据才判定
- **建立与维持分开**：新会话需连续证据；已确认的同一进程、同一端点在静态画面下无需持续流量。短暂断流不立即解除，普通心跳也不无限续期。
- **UU 虚拟显示器只作诊断**：驱动的分辨率和启用状态不能证明有人正在远控，不能单独建立或延长会话。升级后废弃旧版仅凭显示器建立的即时状态，重新确认实际连接。
- **采集失败不等于断开**：网络或性能采集报错时保留状态；即时进程重启可恢复最近的已确认会话。
- **普通权限兼容**：计划任务优先通过 CIM 创建时间识别高权限的远控进程；不能读取进程启动时间或程序路径，不代表会话已结束。进程身份无法确认时保留状态。

## 验证与更新（Windows）

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Regression.ps1
```

回归覆盖握手、静态画面、网络抖动、心跳残留、采样失败、PID 复用、守护进程重启和双通道状态协调。测试使用模拟数据，不发送推送，不启动守护进程。

更新已安装的版本：把 `windows/` 中的新版脚本放在同一目录，运行 `remote-guard-setup.ps1`，选择原安装目录并点击“一键部署”，以替换脚本并重启即时进程。已有 `release/` 发行包不会随源码修改自动更新。

重新打包发行版（Windows，需要已安装 ps2exe）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1 -Version 1.2.0
```

产物写入 `release/`，包含 Windows ZIP、macOS TAR.GZ 和 SHA-256 校验文件；每个平台包内的 `VERSION` 记录版本及源码提交。

## 已知限制

- Windows 仍是基于连接和活动的启发式检测，无法保证所有版本远控软件零误报、零漏报。IO 不是专用的网络流量计数器。
- 纯中继会话依赖新鲜会话文件与 IO；若两者长时间静默且没有可确认直连，3 分钟观察期后仍可能解除，需结合真实会话日志进一步校准。
- UU 多通道规则根据本机正在连接的会话校准；其他版本或只建立少量 TCP/UDP 通道的连接可能无法命中，不能把未命中等同于确定无人连接。
- Windows 解除消息有约 3 分钟观察期；采集故障期间不会宣告解除。macOS 的检测规则和保持期保持原实现。

## License

MIT
