# remote-guard — Windows / macOS 远程控制监控告警

**本机被任何主流远控软件连接时，几秒内推送到你的手机**（Bark / 微信公众号，支持多通道）。

被控检测、无人值守、静默运行、零闪屏。适合"离开工位后想知道有没有人远程我的电脑"的场景。

## 下载

到 [Gitee 发行版](https://gitee.com/Soujer/remote-guard/releases) 或 [GitHub Releases](https://github.com/Soujer/remote-guard/releases) 下载对应平台发行版。Windows 当前版本 **v1.5.0**，macOS 原生桌面版 **v1.5.0**。

Windows 推荐直接下载 **`remote-guard-v1.5.0.exe`**。macOS 下载 **`remote-guard-macos-universal-v1.5.0.zip`**，同一个程序支持 Apple 芯片与 Intel，要求 macOS 13 或更新系统。两端均提供“监控、推送、加密录屏、录像播放、更新”，首次使用无需额外下载录屏组件；播放器支持全屏、双击切换、Esc 退出、暂停、前后跳转 10 秒、拖动进度及 0.5x～4x 倍速。`remote-guard-setup.exe` 保留为 Windows 兼容入口。

| 平台 | 发行包 | 使用 |
|---|---|---|
| Windows | `remote-guard-vX.X.X.exe` 或 Windows ZIP | 双击 exe；ZIP 中运行 `remote-guard.exe` |
| macOS 13+（Apple 芯片 / Intel） | `remote-guard-macos-universal-vX.X.X.zip` | 解压 → 将 `RemoteGuard.app` 放到应用程序文件夹并打开 |

## 支持平台

| 平台 | 实现 | 入口 |
|---|---|---|
| **Windows** | 统一桌面程序，计划任务 + 常驻即时进程 | `remote-guard.exe`（监控、推送、录屏、播放、自动更新） |
| **macOS** | 原生桌面软件，ScreenCaptureKit + 系统视频编码 / 播放 | `RemoteGuard.app`（监控、推送、录屏、播放、自动更新） |

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

原生桌面版每 2 秒采样，要求远控进程的已建立入站连接对应同一进程的监听端口，连续两次确认后建立会话；断开观察期为 3 分钟。支持识别屏幕共享、UU、ToDesk、向日葵、RustDesk、AnyDesk、TeamViewer、Chrome 远程桌面和 Parsec 的对应进程。进程存在、CPU 占用和 80/443 心跳不单独触发录屏；采样失败时保留之前的状态。纯出站中继连接、不同版本进程名或权限不足可能漏报，不能保证覆盖全部远控版本。

下面为保留的旧版 Bash 检测方式；旧脚本仅提供检测和推送：

| 检测项 | 方式 |
|---|---|
| 内置屏幕共享 / ARD | screensharingd + 5900 已建立连接 |
| RustDesk / AnyDesk / TeamViewer / ToDesk / 向日葵(AweSun) / Parsec / Chrome 远程桌面 | 非 80/443 高端口直连（单次即告警）+ CPU 持续占用 |
| 未知 VNC 监听 | 5900-5902 被未知进程监听 |
| 输入注入 | 锁屏下 HIDIdleTime 持续小于阈值（不记录按键内容） |

## 快速开始（Windows）

1. 下载 `remote-guard-vX.X.X.exe` 并运行；也可以下载 Windows ZIP 后运行 `remote-guard.exe`
2. 在“监控”页面选择安装目录。已有安装会自动从当前用户的计划任务读取目录；首次默认安装到 `%LOCALAPPDATA%\RemoteGuard\app`
3. 配置推送通道（二选一或都要）：
   - **Bark**（iOS）：App Store 装 Bark，复制你的 key 填入
   - **hayo**（微信公众号）：点"扫码获取"，微信扫码确认，token 自动填入
4. 点"测试通道"确认手机能收到
5. 点“启动 / 更新监控”完成。关闭主窗口后后台监控继续运行，在“监控”页面可以停止。无需管理员权限安装到自己的可写目录

## 快速开始（macOS）

1. 下载通用版 ZIP，解压后把 `RemoteGuard.app` 拖到 `/Applications` 或 `~/Applications`，双击打开。
2. 在“推送”页填写 Bark key 或 hayo token，保存后测试；在“监控”页启动监控，可勾选登录时后台运行。关闭窗口后菜单栏仍可打开软件。
3. 在“加密录屏”页点击“授权屏幕录制”，在系统设置中允许；系统要求时重启软件。只录主显示器画面，不录声音，且排除本软件窗口。
4. 勾选自动加密录屏，选择保存目录和容量上限，输入至少 12 位密码和确认密码，保存 `.rgkey` 私钥。已有 Windows 私钥可输入密码后“导入已有私钥”，无需重新生成。
5. 可点击“测试录屏（5 秒）”先验证本机权限与编码；在“录像播放”页选择片段、私钥、密码后播放。Windows / macOS 的密钥与录像格式兼容。

默认数据目录为 `~/Library/Application Support/RemoteGuard`，录像位于其中的 `recordings`，不存在时自动创建。原生程序使用系统录屏、H.264 编码和 AVKit 播放，组件随系统提供，不需要 FFmpeg、Python 或额外下载。登录启动与自动更新需要将应用放在可写的应用程序目录，推荐 `~/Applications`。

本项目当前使用本地签名，尚未做 Apple Developer ID 公证。首次打开若系统阻止，可在“系统设置 → 隐私与安全性”中允许打开。系统的屏幕录制权限仍需手动授予，更新后可能需要再次确认。

旧版命令行安装方式仍保留：

```bash
cd macos
cp push-channels.conf.example push-channels.conf
open -t push-channels.conf   # 填入 Bark key 和/或 hayo token
bash install-macos.sh         # 测试通道 + 注册 launchd + 启动即时监控
```

卸载：`bash install-macos.sh remove`

## 远程连接自动加密录屏（Windows / macOS）

在软件的 **“加密录屏”** 页面选择录像目录和存储上限。录屏组件已内置或由系统提供。首次启用需设置至少 12 位密码，并另存一份 `.rgkey` 播放私钥。程序只保存公钥；密码不会保存。私钥请备份到其他安全位置，与密码分开保管。**私钥或密码丢失，录像无法恢复。** 配置成功后，已启动的监控程序会在下一次确认远程会话时开始录制。

- 只在确认的受控会话中录制，不因远控软件运行或可疑事件告警单独开始。多个远控同时连接只录一份；全部确认断开后停止。沿用检测器约 3 分钟的断开观察期，因此实际断开后可能继续录制这段时间。录屏从确认时开始，不能回溯之前的操作。
- Windows 捕获当前用户桌面；macOS 捕获主显示器。录像最高 **1920×1080、5 帧/秒、H.264、约 1 Mbps、无音频**，低分辨率画面不放大，只缩放录像，不修改系统显示分辨率。每 5 分钟约 37.5 MB，2 GB（默认 2048 MB）约 4.5～4.8 小时，实际随画面与编码变化；静态画面通常可保存更久，帧率不适合游戏录像。
- 每 5 分钟独立保存一份 `.rgrec` 加密片段，片段切换可能有短暂间隙。默认总上限 **2 GB**，预留下一段空间时自动删除最旧片段；另留至少 **512 MB** 磁盘空间，空间不足时停止并记录错误。请及时备份要保留的录像。容量上限包含本程序遗留的 `.partial` 文件，不清理其他文件。
- MP4 压缩流经内存管道直接加密写盘，自动录屏不产生明文临时视频。采用 RSA-3072 OAEP-SHA256 包装随机 AES-256-CBC/HMAC-SHA256 密钥，每段独立随机密钥和 IV；播放先验证完整性，再通过内存管道解密和解码。`.rgkey` 私钥以 PBKDF2-HMAC-SHA256（210000 次迭代）派生密钥加密并校验完整性。
- 播放：在 **“录像播放”** 页面选择 `.rgrec`、`.rgkey` 并输入密码，在主窗口内播放；点击“全屏”或双击画面放大，Esc 返回。Windows 使用内置 FFmpeg，macOS 使用系统 AVKit；均先验证录像完整性，再在内存中解密和解码，不写出明文视频。另一台电脑只需软件、匹配的私钥和录像即可播放，无需启用自动录屏。密钥与录像格式跨平台兼容；私钥和密码不通过命令行传递，也不会上传录像。
- 录屏故障与推送相互独立。异常断电或强杀进程可能留下当前片段的 `.partial`，该片段不能保证恢复，之前完成的分段仍可播放。Windows 日志为安装目录 `recording.log`，macOS 为数据目录 `remote-guard.log`。持续故障每分钟重试。
- Windows 64 位发行版内置 [Gyan FFmpeg 9.0.2](https://www.gyan.dev/ffmpeg/builds/)，自动释放到安装目录 `ffmpeg` 并核对固定 SHA-256。密码与确认密码分别校验，恰好 12 位且两次一致即可创建私钥，空格和大小写按原样保留。编码器路径也可自选，支持 Windows 10/11。使用 [FFmpeg 的 gdigrab](https://ffmpeg.org/ffmpeg-devices.html#gdigrab) 和 [分片 MP4](https://ffmpeg.org/ffmpeg-formats.html#mov_002c-mp4_002c-ismv)。macOS 使用 ScreenCaptureKit 捕获主显示器、AVAssetWriter 在内存输出分片 MP4 后直接加密。锁屏、安全桌面、受保护内容或断开后的 RDP 桌面可能无法捕获。

录像列表显示时长。新片段完成时生成同名 `.rgrec.meta.json` 时长元数据（不含画面或密钥），容量清理会一起删除；旧录像解锁播放后补充实际时长，未读取的显示“待读取”。移动录像时可同时带上元数据，缺少元数据不影响播放。

Windows 高级参数位于安装目录 `recording.json`，默认录像目录为 `<安装目录>\recordings`。可以手动调整 `segmentSeconds`（30–900）、`fps`（1–15）、`width`（640–1920，按 16:9 限制高度）、`bitrateKbps`（100–2000）、`maxStorageMB`（128 MB–1 TB）与 `minFreeMB`（至少 128 MB）。设置页保存时使用默认编码参数。旧版 1280 / 400 kbps 默认组合会升级为 1920 / 1000 kbps，其他手动参数保持。单段有严格字节上限，超限不会写满磁盘；未完成片段保留为 `.partial`。禁用录屏会保存当前片段后停止。

## Gitee 自动更新（Windows）

“更新”页面默认启用自动更新。启动监控时会注册当前用户的 `remote-guard-update` 计划任务，每 6 小时检查 [Gitee 正式发行版](https://gitee.com/Soujer/remote-guard/releases)。主窗口也可手动检查；关闭窗口时会额外检查一次。

更新器只接受固定仓库的正式版本与指定名称的 Windows ZIP/SHA-256 清单，跳过预发行、缺少附件的版本与降级。下载后先核对 SHA-256，再检查压缩包文件白名单、大小、重复项、安全路径与内部版本。正在远程连接、录屏或主界面尚未关闭时延后安装。失败会记录在 `update.log`，下次检查重试。

文件替换前会备份程序；替换失败自动恢复旧文件并恢复原来的监控运行状态。更新只替换程序文件，保留 `push-channels.json`、`recording.json`、`updates.json`、私钥、录像与已释放的组件。备份放在安装目录 `backups`。v1.3.0 自动更新先安装小体积兼容补丁 v1.3.1，下次检查再安装内置组件版；也可直接下载最新单文件 EXE。旧的 v1.2.x 需要先下载一次新版，之后由软件自动更新。

macOS 原生版也每 6 小时从同一 Gitee 仓库检查正式版，使用独立的通用 ZIP 与 `SHA256SUMS-macos-vX.X.X.txt` 清单。下载有大小上限，核对 SHA-256、文件白名单、本地 / 中央 ZIP 路径、签名完整性、应用标识、版本及两种架构后才安装。远程连接、录屏、播放或窗口打开时延后自动安装；替换失败恢复旧应用。数据、私钥和录像位于应用包之外，更新保留；应用备份放到数据目录的 `backups`。旧版 Bash 用户需要先下载一次原生程序，新版启动监控时会备份并替换旧版 launchd 任务，避免重复告警。

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
- **macOS 原生版** 使用独立的保守会话确认与状态变化通知；旧版 Bash 仍保留自己的即时 / 分钟检测逻辑。

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

更新已安装的版本：通过软件的自动更新，或下载新版单文件 EXE，选择原安装目录并点击“启动 / 更新监控”。源码更改后必须重新执行构建脚本生成 EXE 与发行包。

重新打包发行版（Windows，需要已安装 ps2exe，以及经校验的 FFmpeg 9.0.2 essentials 离线文件 `ffmpeg.exe`、`LICENSE`、`SOURCE.txt`）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1 -Version 1.5.0 -EncoderDirectory C:\path\to\encoder
```

产物写入 `release/`，包含 Windows 单文件 EXE、Windows ZIP、macOS TAR.GZ 和 SHA-256 校验文件；每个平台包内的 `VERSION` 记录版本及源码提交。EXE 内置程序资源，首次打开时自动释放到当前用户的版本目录，后续启动校验并修复缺失或损坏的资源。

macOS 原生版在装有 Xcode 命令行工具的 Mac 上执行 `bash macos/build-macos.sh 1.5.0 release/macos`，生成包含 arm64 / x86_64 的通用 `.app`、ZIP 和独立校验清单。`.github/workflows/macos.yml` 在两种架构的 macOS runner 上分别构建、验证加密、合成画面编码、内存播放、更新校验与回滚。两端录像互通可用 `tests/Run-MacInteropRegression.ps1` 及 `macos/Tests/windows-interop.json` 公开测试样本验证。CI 验证不会捕获真实桌面或发送告警；真实屏幕授权与远控识别应在目标 Mac 上用测试录屏和实际会话核对。

## 已知限制

- Windows 仍是基于连接和活动的启发式检测，无法保证所有版本远控软件零误报、零漏报。IO 不是专用的网络流量计数器。
- 纯中继会话依赖新鲜会话文件与 IO；若两者长时间静默且没有可确认直连，3 分钟观察期后仍可能解除，需结合真实会话日志进一步校准。
- UU 多通道规则根据本机正在连接的会话校准；其他版本或只建立少量 TCP/UDP 通道的连接可能无法命中，不能把未命中等同于确定无人连接。
- Windows 解除消息有约 3 分钟观察期；采集故障期间不会宣告解除。macOS 的检测规则和保持期保持原实现。

## License

MIT

主项目使用 MIT。Windows 发行版包含独立的 GPLv3 FFmpeg 程序，其许可证与来源说明位于释放后的 `ffmpeg/LICENSE`、`ffmpeg/SOURCE.txt`。对应 FFmpeg 源码见 [946fcce07b](https://github.com/FFmpeg/FFmpeg/commit/946fcce07b)，构建配置可运行 `ffmpeg.exe -buildconf` 查看；第三方依赖及构建信息见 [Gyan 构建说明](https://www.gyan.dev/ffmpeg/builds/)。源码仓库不提交第三方二进制。
