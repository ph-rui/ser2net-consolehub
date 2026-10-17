# USB 串口控制台桥 (ser2net on Win10) — 动态设备注册表版

把 Windows 上的 USB 转串口（CH344 四路 **以及任意独立 USB 串口**）暴露给 Linux 板子访问。
**开机即跑、无需登录**；底层 COM 号随便变，Linux 侧只认设备别名/标签。

```
 ┌─────────────────── Windows 10 (本机, 172.16.66.163) ────────────────────┐
 │                                                                          │
 │  autostart.ps1（开机任务 ser2net-consolehub, SYSTEM, 无需登录）            │
 │    │ 每 15s reconcile：COM/设备映射变了才重启，不打断在用会话                │
 │  USB 串口（CH344 四口 + 独立适配器）► COM15/COM42/COM97...（插拔会变）      │
 │                    │                                                     │
 │   devices.json     │ 设备注册表：指纹(PnP DeviceID) → 别名 + 固定 TCP 端口  │
 │   serial-hub.ps1   │ 每次 render/reconcile 重扫 WMI，把当前 COM 号填进配置 │
 │                    ▼                                                     │
 │              ser2net.yaml   (自动生成，永远不写死 COM 号)                  │
 │                    │                                                     │
 │              ser2net.exe                                                 │
 │                    │  TCP 4000/4001/...  绑 172.16.66.163                │
 └────────────────────┼─────────────────────────────────────────────────────┘
                      │  172.16.66.x 网段
 ┌────────────────────▼─────────────────────────────────────────────────────┐
 │  Linux (172.16.66.48)                                                    │
 │    console.sh 设备别名 / 标签  →  板子控制台（不关心 COM，也不用记端口号）   │
 │    selftest.py              →  链路自检                                  │
 └──────────────────────────────────────────────────────────────────────────┘
```

**别名（alias）是稳定的，COM 号不是。** Linux 侧只认设备别名/标签，运行时向
Windows 的 query-server 实时查；底层 COM 号由 Windows 决定、每次插拔都可能变
（同一根适配器今天 COM15、明天 COM42），Windows 每 15 秒自动重映射，
Linux 侧**完全不用知道 COM 号**。

**目录**

- [服务与例程清单（两端跑着什么）](SERVICES.md)
- [一、安装](#一安装含上游打包缺陷修复)
- [二、Windows 侧常用命令与配置文件](#二windows-侧常用命令与配置文件)
- [三、Linux 侧使用](#三linux-侧使用)
- [四、针对这套环境的设计决定](#四针对这套环境的设计决定)
- [五、安全](#五安全)
- [六、开机自启（无需登录）](#六开机自启无需登录)
- [七、日志](#七日志)
- [八、常见问题](#八常见问题)
- [附：改完怎么推 GitHub](#附改完怎么推-github)

当前已登记硬件：

| 别名 | 标签（可改） | TCP 端口 | COM 号（会变） |
|------|-------------|---------|---------------|
| a    | USB-Enhanced-SERIAL-A CH344 | 4000 | 99（本次实测） |
| b    | USB-Enhanced-SERIAL-B CH344 | 4001 | 97（本次实测） |
| c    | USB-Enhanced-SERIAL-C CH344 | 4002 | 100（本次实测）|
| d    | USB-Enhanced-SERIAL-D CH344 | 4003 | 98（本次实测）|

> CH344 四路保持历史 a/b/c/d→4000–4003 映射；之后插上的**独立 USB 串口**会自动进
> 注册表、顺延拿别名（e/f/g…或 1/2/3…）和端口（从 4004 起），无需手工登记。

---

## 一、安装（含上游打包缺陷修复）

> **仓库不含二进制**：`ser2net.exe` 与 43 个 DLL（约 21MB）不在 git 里，新克隆的
> 机器需按下表自己凑齐后放进 `bin\`；本机 `bin\` 是自包含目录，已实测运行。

`ser2net.exe` 和它的全部依赖现在都在 **`C:\Users\zhangrui\ser2net\bin\`（自包含目录）**，
本机已实测运行：

```
ser2net.exe  version 4.6.8   （ser2net -v 验证通过）
bin\  47 个文件 = ser2net.exe + serial-hub.ps1 + autostart.ps1 +
                  install-boot-task.ps1 + 43 个 DLL
```

部署包留在 `C:\Users\zhangrui\ser2net-deploy\`（安装包、校验、分析脚本）备查。

**为什么不用安装器装到 Program Files？** 上游 Windows 打包有两处缺陷（本次实测定位）：

| # | 缺陷 | 现象 | 修复 |
|---|------|------|------|
| 1 | ser2net 4.6.8 安装包**不含 gensio DLL** | 启动即报 `0xC0000135`（DLL_NOT_FOUND，缺 `libgensio-14.dll`） | 另装 Gensio 3.0.4，取其 42 个 DLL 放入 bin\ |
| 2 | gensio 安装包缺 **`libpcre2-posix-3.dll`**（`libgensiomdns-14.dll` 的静态依赖） | 装完 gensio 仍然 `0xC0000135` | 从 MSYS2 `mingw-w64-x86_64-pcre2` 包解出该 DLL（连同依赖 `libpcre2-8-0.dll`） |

另外 `libgensio_python_swig-14.dll` 依赖 libpython3.14，gensio 用不到，已从 bin\ 删除。

如果以后重装：保持 bin\ 里这 43 个 DLL 的版本配套（ser2net 4.6.8 ↔ gensio 3.0.4，
`libgensio-14.dll` 的 ABI 编号必须匹配），不能混用。

装完验证：

```powershell
cd C:\Users\zhangrui\ser2net\bin
.\serial-hub.ps1 doctor
```

### 文件都在哪

```
C:\Users\zhangrui\ser2net\
├─ bin\                ser2net.exe + 43 DLL + serial-hub.ps1() +
│                      autostart.ps1 + install-boot-task.ps1（自包含运行目录）
├─ etc\ser2net\        ser2net.template.yaml（模板，改端口/属性在这改）
│                      ser2net.yaml（生成的最终配置，别手改）
├─ linux\              Linux 侧 3 个文件（console.sh / ptybridge.py /
│                      selftest.py；t-* 是本机调试脚本，不用拷）
├─ logs\               dev-<别名>.log（收发记录）+ autostart.log
├─ devices.json        设备注册表（主要编辑入口）
├─ ports.json          （自动）端口分配表
├─ settings.json       全局设置（bindIp / baud / trace …）
└─ ser2net.pid         （自动）当前 ser2net 进程号
```

---

## 二、Windows 侧常用命令与配置文件

```powershell
cd C:\Users\zhangrui\ser2net\bin

.\serial-hub.ps1 discover      # 重扫 USB，把新设备登记进注册表，显示 别名→COM→端口
.\serial-hub.ps1 start         # 重新发现 + 重新渲染 + 启动（已在跑会拒绝，用 restart）
.\serial-hub.ps1 render        # 只重渲染 yaml（不重启/不动 ser2net）
.\serial-hub.ps1 status        # 进程 / 设备表 / 监听状态
.\serial-hub.ps1 probe         # 本机连一下每个端口，验证 banner（连的是 settings.json 的 bindIp）
.\serial-hub.ps1 reconcile     # 只在设备/COM 映射真的变了才重启（autostart 每 15s 跑）
.\serial-hub.ps1 logs -Port 4000 -Tail   # 看某个设备的收发记录
.\serial-hub.ps1 doctor        # 全套体检
.\serial-hub.ps1 stop
.\serial-hub.ps1 restart       # stop + start 一步到位
```

> **`restart` / `stop` 与开机任务(SYSTEM)权限**：ser2net 由开机任务以 SYSTEM 拉起后，
> 普通用户 shell 直接停不掉（拒绝访问）。`serial-hub.ps1 restart/stop` 会自动检测到
> 这种情况，落一个 `restart.request` 标记，由 autostart 循环（SYSTEM，每 15 s）代执行——
> **全程免管理员**（autostart.log 留痕）。如果改过 `autostart.ps1` / `serial-hub.ps1`
> 想让运行中的 SYSTEM 循环立刻加载新版，跑一次 `.\fix-autostart-loop.ps1`
> （需点一次 UAC）：杀旧循环 + 重拉开机任务。

改绑定 IP / 默认波特率 → 改 `settings.json`，然后 `restart`。
**加设备 / 改别名 / 改标签 / 改某个设备的 TCP 端口** → 改 `devices.json`，然后 `restart`。
**不要直接改 `etc\ser2net\ser2net.yaml`**，那是生成物。

`settings.json` 的 `maxConnections`（默认 `1`）：每端口最大 TCP 连接数。`1` = 配合
`kickolduser: true` 的"后连踢先连"。改成 `>1` 后同一串口可**并挂多个读端**（ser2net
把串口收到的数据广播给每个连接；写只有真正发字节的那个生效——多人各挂一个读端做
监控、一个人操作，是安全的；两个人都写则字节会交错）。代价：失去自动踢人、第三个
连接会被拒（`Port already in use`）。也可在 `devices.json` 给单个设备加
`"maxConnections": 2` 覆盖全局。实测脚本 `.\demo-2-readers.ps1`（两读端共存 + 第三
被拒 + 端口不中毒）；当前配置保持 `1`。

### devices.json（设备注册表，重要的编辑入口）

```json
{
  "generated": "2026-09-29 16:26:11",
  "devices": [
    {
      "fingerprint": "USB\\VID_1A86&PID_55D5&MI_00\\6&1a2b3c4d&0&0000",
      "alias": "a",
      "label": "USB-Enhanced-SERIAL-A CH344",
      "port": 4000,
      "baud": 0
    }
  ]
}
```

- `fingerprint` = Windows PnP DeviceID，**插拔不变**，是设备的稳定身份，别改
- `alias` = Linux 侧用来指定设备的短名（a/b/c/…、数字），唯一即可
- `label` = 人类可读的名字，Linux 也能按它（子串、不区分大小写）匹配
- `port` = 固定 TCP 端口，改完要 `restart`
- `baud` = `0` 表示用 `settings.json` 的 `baud`；非 0 则本设备单独用这个波特率

新插的 USB 串口**不需要手工登记**：`discover`/`start`/`reconcile` 会自动分配别名和
端口并写进 devices.json。`discover` 每次运行都会重扫 WMI，所以"今天 COM15、
明天 COM42"对注册表没有任何影响。

### 设备表：实时查询，没有快照文件

Linux 侧**不再有 `devices.conf`**。设备表由 Windows 侧的 `query-server.ps1`
（端口 4099）在**每次运行时**现场回答：

```
$ ./console.sh --list
alias  label                        endpoint
a      USB-Enhanced-SERIAL-A CH344  172.16.66.163:4000
(source: live (172.16.66.163:4099))
```

所以拔插立即可见，不需要任何"刷新/推送"动作，也就没有会过期的副本。
`serial-hub.ps1 push` 已随之移除（执行它会明确告诉你该命令已废弃）。
`console.sh` 找不到 hub 时会**直接报错退出**，不会拿旧列表凑合。

唯一需要的本地配置是 `/etc/ser2net-hub.conf`（一行，问哪台 hub）：

```
QUERY_HOST=172.16.66.163
```

这份是**静态配置**而非渲染产物：hub 主机名必须在查询之前就知道，不可能来自 hub 自己。

---

## 三、Linux 侧使用

```bash
# 1) 前提
sudo apt install socat          # 或 yum install socat（selftest/--pty 模式用）
#    python3 需可用（Ubuntu 一般自带）——交互式控制台用 python3 的 termios 置 raw

# 2) 拷文件（共 3 个，放同一目录；linux\ 里的 t-* 是本机调试脚本，不用拷）
#    console.sh  ptybridge.py  selftest.py
#    （没有 devices.conf 要拷了）
scp <linux-user>@172.16.66.163:C:/Users/zhangrui/ser2net/linux/console.sh \
    <linux-user>@172.16.66.163:C:/Users/zhangrui/ser2net/linux/ptybridge.py \
    <linux-user>@172.16.66.163:C:/Users/zhangrui/ser2net/linux/selftest.py .

# 2b) 装到 /usr/bin，并写死"问哪台 hub"
echo 'QUERY_HOST=172.16.66.163' | sudo tee /etc/ser2net-hub.conf
sudo install -m 755 console.sh ptybridge.py /usr/bin/

# 3) 交互式连设备（按别名 / 标签 / 端口都行）
./console.sh                   # 默认设备 a
./console.sh a                 # 按别名（CH344-A，端口 4000）
./console.sh d                 # 按别名（CH344-D，端口 4003）
./console.sh usb-enhanced      # 按标签（子串、不区分大小写）
./console.sh 4002              # 按端口直连
./console.sh --list            # 显示设备表（向 hub 实时查询）
./console.sh --ping            # hub 在不在？有多少设备？

# 4) 如果程序必须用 /dev/ttyXXX 设备节点（很多传感器 SDK 是这样）
./console.sh --pty /dev/ttyUSB9 a
```

自检（**先跑这个**，能区分是网络问题还是板子没上电）：

```bash
chmod +x console.sh selftest.py

./selftest.py            # 所有设备全测（按 4000 起的端口逐个测）
./selftest.py a          # 只测别名 a 对应的端口
./selftest.py a --rounds 20
```

输出示例：

```
  172.16.66.163:4000      LINK ok       banner: 'USB-Enhanced-SERIAL-A CH344 COM99 115200N81 -> 172.16.66.163:4000'
                          ALIVE ok       1024 bytes back: b'\r\nUbuntu 22.04 ... \r\nlogin: '
                          ECHO 8/8 intact
                          latency        min=3.1ms  med=3.4ms  max=4.8ms
```

三段含义：

| 阶段 | 失败说明什么 |
|------|-------------|
| **LINK** | ser2net 没监听 → 设备 `enable: off`（没插板子）、IP 写错、或 ser2net 没跑 |
| **ALIVE** | 板子没上电 / 接线错 / 波特率不匹配（网络没问题，且 ALIVE 无数据属正常——控制台空闲不发声） |
| **ECHO** | 字节在传输但控制台不回显 —— 罕见，若丢包说明链路有问题 |

> 交互原理：`console.sh` 走 `python3 ptybridge.py` —— 用 termios 把终端置 raw
> （与 `stty raw -echo` 同一机制，可靠）：字节全透传，Ctrl+C 直达板子（可打断
> u-boot / 内核启动）。退出和 picocom 一样：**Ctrl+A 再按 x**（Ctrl+`]` 也行），
> 自动恢复终端；要给板子发真正的 Ctrl+A（如 bash 行首）就**连按两次 Ctrl+A**。
>
> 不要用 socat 的 `-,raw,echo=0` 手动连：它会对 stdout 的副本做 tcsetattr，只要
> stdout 被任何东西捕获（`| tee`、`script` 等）就报
> "tcsetattr(...): Inappropriate ioctl for device" 直接退出。同理，别对
> `./console.sh` 的输出做 `| tee` —— 本地不转录会话；完整字节级记录在 Windows 侧
> `logs\dev-<别名>.log`（ser2net `trace-both`），`.\serial-hub.ps1 logs` 可列。

---

## 四、针对这套环境的设计决定

**为什么设备表改成"拉"而不是"推"**
以前 `devices.conf` 是 Windows 渲染出的快照，用 `push` 拷到 Linux。它有两个必然
的毛病：拔掉/新插的设备在下次 push 之前一直不对，而"该什么时候 push"没人会记；
更糟的是 Linux 只有在 hub 不可达时才读它，所以**快照过期这件事你永远看不到**。

现在 `query-server.ps1`（4099）在每次 `console.sh` 运行时现场回答设备表：拔插
立即可见，没有副本会过期。代价是 hub 不可达时 Linux 侧直接报错（没有兜底），
这是有意的 —— 拿旧列表悄悄连上，比明确失败危险得多。

`/etc/ser2net-hub.conf`（`QUERY_HOST=<ip>`）是唯一需要的本地配置：hub 的地址
必须在查询之前就知道，本身没法从 hub 问出来，所以它是静态配置而非渲染产物。

**为什么 `bindIp` 与 `advertiseIp` 分开**
`bindIp` 是监听地址，多网卡时必须写 `0.0.0.0` 才能全网卡收。但 `0.0.0.0` **不是
一个能连的地址**：banner 和 query-server 的回答都靠 `advertiseIp` 告诉客户端
"该连哪个 IP"，漏设的话 Linux 会拿到 `0.0.0.0:400x` 然后连到自己回环上。

**为什么用裸 TCP 而不是 telnet(rfc2217)**
socat / `TCP:` 连的是裸 TCP，不做 telnet 选项协商。用 telnet 封装会在数据流里
混入协商字节。所以配置里是 `accepter: tcp,...`。

**为什么 `timeout: 0`**
控制台登录后可能几小时没输入。默认的非零 timeout 会把这种空闲会话踢掉。
ser2net 仍然能识别真正死掉的连接：当有数据待发且对方不接收时，它判定该端口
"卡住"并断开。

**为什么 `local: true` + `hangup-when-done=false`**
`local`（CLOCAL）让 ser2net 忽略 DTR/RTS，避免客户端断开时板子看到
modem 控制线抖动；`hangup-when-done=false` 保证关闭会话时不会拉低 DTR/RTS
导致板子被复位。

**为什么 `kickolduser: true` + `max-connections: 1`**
在 A 工位连着忘了关，去 B 工位再连会把旧的踢掉，不会卡在"最多 1 个连接"。
反过来：用完记得断开，`max-connections: 1` 别的客户端连不上。
> 需要"一个写、多个读"时，可把该端口临时/长期改成 `max-connections: 2`
> （settings.json 全局或 devices.json 每设备），机制已实测可行，见第二节说明；
> 当前默认保持 `1`。

**COM 号怎么处理的（注册表模式）**
`Get-UsbSerialDevices` 每次重读 WMI，枚举**所有**名字带 `(COMn)` 的 USB 设备
（CH344 和独立适配器都算）。每台设备用 **PnP DeviceID（指纹）** 当稳定身份：
插拔不丢、COM 号随便变。`Merge-LiveDevices` 把没见过的指纹自动登记进
`devices.json`（CH344 四路保留历史 a/b/c/d→4000/4001/4002/4003 映射，
独立设备顺延 e/f/…）。渲染时把每个设备的**当前 COM 号**填进配置，
`enable: off` 表示这台设备当前不在（没插），ser2net 照样能启动 ——
"端口不通"最常见原因。

**为什么没有做"按 COM 号指定"的查询服务**
按你的选择，动态监测走"Windows 快速自动重映射"路线：不新增监听端口
（防火墙目前全关，少一个暴露面）。Linux 侧指定的是**设备**（别名/标签），
永远不需要知道当下 COM 号是多少。

**关于 `\\.\COMn`**
上游文档写的是 `//./COM<n>`，但实测 .NET 的 `SerialPort` 在构造函数里就拒绝
`\\.\COMn`（报 PortName 无效），而 `COM99`/`COM100` 这类两位以上的普通形式
能正常打开。脚本因此只生成 `COM<n>` 形式，并且这是**实测验证过**的。

---

## 五、安全

⚠️ **当前 Windows 防火墙三个配置文件（Domain / Private / Public）全部是关闭状态。**
ser2net 一旦启动，4000-4003（以及以后自动分配的 4004+）会对本机所有可达网段
开放（`192.168.90.x`、`172.16.66.x`、`192.168.247.x`），**没有任何过滤**；
query-server 的 4099 同样对外全开。

绑定网卡**不是访问控制** —— 同网段任何主机都能连。`bindIp: 0.0.0.0` 更是所有网卡都监听。

想收紧的话（需要管理员）。**注意 4099 必须一起放行**：设备表是实时查的，
漏掉它 Linux 侧会直接连不上（`hub ... did not answer`）。

```powershell
# 1) 建白名单规则（先只放行你的 Linux 板子）
#    4000-4015 串口控制台 + 4099 设备表查询
New-NetFirewallRule -DisplayName "ser2net console allow" `
  -Direction Inbound -Protocol TCP -LocalPort 4000-4015,4099 `
  -RemoteAddress 172.16.66.48 -Action Allow

# 2) 拒绝其他所有来源
New-NetFirewallRule -DisplayName "ser2net console deny" `
  -Direction Inbound -Protocol TCP -LocalPort 4000-4015,4099 `
  -RemoteAddress Any -Action Block

# 3) 确认规则无误后，再开防火墙
Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True
```

> 加了新设备（端口超 4003）要同步扩充规则的 `-LocalPort` 列表。

**第 3 步要谨慎** —— 这台机器上跑着 MobaXterm、RDP、SSH、Edge 等不少东西，
开防火墙可能中断现有连接。建议先在远程会话里做完 1、2 步并验证，
或者安排一次能重启/恢复的窗口再做第 3 步。

串口数据本身是明文 TCP，控制台登录密码会裸奔在网段里。
如果这段链路不可信，用 SSH 隧道：

```bash
# Linux 侧
ssh -N -L 4000:172.16.66.163:4000 user@windows-host
```

---

## 六、开机自启（无需登录）

**要求"开机就跑、不用登录"**，所以注册的是**开机计划任务**（LocalSystem）而不是
登录即可的 HKCU Run（旧方式已移除、单所有者）：

```
任务名:    \ser2net-consolehub
触发器:    MSFT_TaskBootTrigger（每次开机触发，登录前就起）
运行身份:  NT AUTHORITY\SYSTEM (ServiceAccount)   ← 不登录也跑
安装脚本:  bin\install-boot-task.ps1（幂等，重跑无害）
```

已注册好。换机/重装后恢复（会弹一次 UAC）：

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\zhangrui\ser2net\bin\install-boot-task.ps1"
```

取消自启（管理员）：

```powershell
schtasks /Delete /TN ser2net-consolehub /F
```

> 普通用户直接 `schtasks /Query /TN ser2net-consolehub` 可能被本机 EDR
> （edr_agent）拒读、报"拒绝访问"——这是可见性限制，不是故障；任务照常运行，
> 用上面安装脚本里的提权上下文才能看到权威状态（Running/Ready、上次运行时间）。

`autostart.ps1` 做四件事：
1. 开机后**等 USB 枚举完成**（最多 120 秒），否则首次渲染全是 `enable: off`
2. 启动 ser2net
3. 启动 `query-server.ps1`（4099）—— Linux 侧查设备表的唯一入口
4. 每 **15 秒**跑一次 `reconcile` —— **只在设备/COM 映射真的变了才重启**，
   不会打断正在用的控制台会话

> 改了 `bin\` 下的脚本或 `settings.json` 后，**跑一次 `verify-boot-task.ps1`**。
> 开机任务里的循环进程持有它启动时读到的脚本副本，你改完文件不重启循环的话，
> 旧代码会一直安静地跑着 —— 看起来一切正常，实际改动没生效。
> （改完 ser2net.yaml 想立即生效，也可以写一个 `restart.request` 文件，
> 循环会在 15 秒内接手重启。）

> 没有"暖开/warm-probe"这一步了：实测发现**任何"裸 TCP 连接即断开"的探测
> （`/dev/tcp`、`nc -z`、极短的 banner probe）会让下一个真实连接收到
> `Device open failure: Permission denied`**（ser2net/gensio + WCH 驱动配合的怪癖）。
> 暖开等于自断后路。控制台侧（`ptybridge.py`）现在自带自愈：收到该失败 banner
> 就 sleep 2 秒重连，最多 3 次，用户无感（实测会真的触发：日志里能看到
> `Device open failure` → `[console] port busy ... reconnecting` → 拿到 banner）。
> 注意这条自愈只在**真终端**路径上；`< /dev/null`、`ssh -T` 这类非 tty 输入走
> `console.sh` 的 socat 分支，没有重试，会把裸错误直接打出来。

### 循环死了谁来拉（自愈）

那次静默失联到最后也没查出死因（System / Application 日志无线索），所以按**双保险**
处理，不赌根因：

| 防线 | 是什么 | 实测结论 |
|---|---|---|
| **看门狗任务**（主防线） | 独立任务 `ser2net-consolehub-watchdog`，每 3 分钟以 SYSTEM 跑 `bin\watchdog.ps1` | **有效**，-SelfHealTest 通过 |
| RestartOnFailure | 主任务 `RestartInterval=PT1M` / `RestartCount=999` | 不触发：进程被外部杀**不算**任务 failure |
| boot 触发器上的 Repetition | 主任务 `PT10M`、不限次数 | **无效**：循环被确认杀掉后 165 秒内没有新实例 |

看门狗**只看不动**：找到 `autostart.ps1` 循环就立刻静默退出；找不到才
`schtasks /Run` 拉起主任务，并往 `logs\watchdog.log` 写一行 —— **只在动作时写**，
所以"文件不增长"就等于"循环一直没死"。它不碰 ser2net、不开 COM 口、也不渲染，
这些事循环回来自己会做。

为什么必须是**另一个任务**：挂在 boot 触发器上的重复触发，受主任务自身状态门控，
而主任务状态恰恰就是出问题的那一环。`schtasks /Run` 不管主任务自己怎么想，
在所有场景下都能拉起，是这里唯一被实测可靠的拉起路径。

```powershell
.\harden-boot-task.ps1 -ReportOnly            # 只报三道防线状态，不改任何东西
.\harden-boot-task.ps1                        # 幂等修复（需管理员）
.\harden-boot-task.ps1 -WatchdogEveryMinutes 1 # 调看门狗周期
.\verify-boot-task.ps1 -SelfHealTest          # 实测自愈（需管理员）
```

`-SelfHealTest` 会把看门狗临时缩到 1 分钟、杀掉循环、每 20 秒记录主任务与看门狗的
State / LastRunTime / LastTaskResult（用来区分"定时器没触发"和"触发了被挡住"），
断言 60 秒内循环被自己拉起，**测完把定时器恢复**成 3 分钟 / `PT10M`。
没被看着失败过的守卫不算守卫。

> `autostart.ps1` 里还有一把命名互斥锁（`Global\ser2net-consolehub-autostart`），
> 主任务的 `MultipleInstances` 保持默认 `IgnoreNew` —— 重复实例由互斥锁兜底。

验证是否生效：**重启 Windows 后不登录，直接在 Linux 上 `./console.sh a`**。
能连上即成功；`logs\autostart.log` 里也会多一条开机时间的运行记录。

日志：`logs\autostart.log`（SYSTEM 权限也能写，实测追加正常）。

---

## 七、日志

每个设备的**全部**收发数据都会落盘（`trace-both`），调试板子启动问题非常好用：

```
logs\dev-a.log      设备 a 的完整收发记录（trace-both，会话断开也会写）
logs\dev-b.log      ...
logs\autostart.log  开机任务运行记录
```

> 旧版叫 `ch344-a.log`，注册表化之后统一叫 `dev-<别名>.log`。

`ser2net-stdout.log` / `ser2net-stderr.log` 只在启动异常时临时生成（`start` 会先做
一次 2.5 秒的前台配置校验，配置错了它会现形），正常运行时不产生输出 —— 这是
故意的：PS 5.1 的 `Start-Process -Redirect*` 会留一个后台排空任务把调用卡住，
所以正式启动改成 ShellExecute 分离式，不接 stdout。

trace 不轮转，会一直涨。清理：

```powershell
.\serial-hub.ps1 prune       # 删掉超过 settings.json 里 traceKeepDays（默认 14）天的
```

不需要 trace 时把 `settings.json` 的 `"trace": false` 改掉 —— 注意改完要
`render` + `restart` 才会生效（模板里的 `trace-both` 是硬写的，需要同时删掉
模板里那几行）。

---

## 八、常见问题

**连接器收到 "Device open failure: Permission denied"**
已定位主凶：**tcp 建立后立即断开（零字节空连接）会毒掉下一个连接**——表现为
下一个真实连接收到这段失败 banner，再下一次又好了。谁会造成空连接：
- `<shell>/dev/tcp` 可达性检查（旧版 console.sh 的 preflight、`nc -z`）——已移除
- 极短的 banner 探测 / 反复快速 connect-close（旧 warm-probe）——已移除
- Windows 串口独占锁在暴力断连后短暂锁窗（次要因素）

现在 `ptybridge.py` 收到这段 banner 会**自动重连（最多 3 次、间隔 2s）**，用户无感（遇真故障时有
`[console] port busy ... reconnecting` 提示）。纯手测想复现就基本不用管了。

**console.sh 交互式连不上但 selftest 正常**
确认是在**真终端**里跑的（不是 `ssh xxx 'cmd'`、不是 `| tee`、不是 script 里）。
非终端场景 console.sh 会自动降级为纯透传（能连但 Ctrl+C 到不了板子）；要录会话请用
Windows 侧 trace（见"七、日志"），不要在命令行里给 console.sh 的输出接管道。

**端口不通**
```powershell
.\serial-hub.ps1 doctor
```
按输出逐项排查。最常见三种：
- 设备是 `enable: off` → 该设备当前没插 / 没接板子
- ser2net 没跑 → `start`（或确认开机任务没被停）
- Linux 侧问错了 hub → 查 `/etc/ser2net-hub.conf`（应为 `QUERY_HOST=172.16.66.163`）

**Linux 侧报 `hub ... did not answer`**
设备表现场查 hub，hub 不通就直接报错（没有兜底快照了，这是有意的）。
在 Linux 上跑 `./console.sh --ping` 确认 hub 状态；若 ping 通但设备表为空，
说明 hub 在跑、只是当前没插设备。

**COM 号在跑的过程中变了**
插拔板子、或 USB 供电波动导致串口重新枚举。autostart 每 15 秒 `reconcile` 一次，
会自动把新 COM 号渲染进去并重启。手动触发：`.\serial-hub.ps1 reconcile`

**新插的 USB 串口没在表里**
等最多 15 秒（下个 reconcile 周期），或手动 `.\serial-hub.ps1 discover`，
注册表会自动登记并分配别名/端口。之后 `discover`/`status` 就能看到；
Linux 侧下一次运行 `console.sh --list` 就能看到，无需任何刷新动作。

**拔掉的设备还在 Linux 的 --list 里**
不应该发生 —— 设备表是实时查的。若真发生，先看 `--list` 底部
`(source: live ...)` 是不是 live；若显示 live 却仍列出已拔设备，
说明 query-server 复用了旧结果，重启它（`verify-boot-task.ps1` 会顺带重启）。

**端口被占用**
ser2net 是独占打开串口的。开发时会看到 `busy-or-unavailable` 状态 ——
检查是不是 MobaXterm、PuTTY、SecureCRT 或另一个程序开着同一个口。
（`serial-hub.ps1 status` 的 `St` 列显示 `in-use-by-ser2net` 是正常现象，指其
.NET open-probe 被 ser2net 独占挡住。）

**板子没输出但 LINK/ALIVE 正常**
波特率不匹配。改 `settings.json` 的 `baud`（或给该设备单独指定
`devices.json` 里的 `baud`），`restart`。
注意 u-boot 的 `console=` 参数、kernel cmdline 的 `console=` 和板子上
getty 的设置得是同一个值。

**数据偶尔丢字节**
控制台场景通常不会。但如果跑的是持续高频输出：
- Windows 设备管理器 → 端口 → COM 属性 → 端口设置 → 高级，
  把**接收/传输缓冲区**都调到最大（默认只有 4KB）
- `settings.json` 里确认 `timeout` 不是非零

---

*2026-09-29 更新：自启从"当前用户 HKCU Run（需登录）"改为"开机计划任务
ser2net-consolehub（SYSTEM，无需登录）"，引入 install-boot-task.ps1。*

---

## 附：改完怎么推 GitHub（本机推不了）

仓库已开源：<https://github.com/ph-rui/ser2net-consolehub>（MIT，不含二进制）。

**这台 Windows 直连 github.com 是不通的**（公司网络；`.48:8869` 那个代理也只放行
`api.github.com` 等部分域名，gh 的设备码轮询正好走主站，所以在本机 `gh auth login`
会一直卡到 `context deadline exceeded`）。**别在本机折腾认证**，走 `.48`：那台有
gh 登录态（账号 `ph-rui`）和可用的 github 代理。

固定流程（本机只负责提交和打包，`.48` 负责推送）：

```powershell
# 1) 本机：提交
cd C:\Users\zhangrui\ser2net
git add -A; git commit -m "..."

# 2) 本机：打包成 bundle（比拷 .git 目录稳）
git bundle create "$env:TEMP\ser2net-consolehub.bundle" main

# 3) 本机：传过去（需要 .48 的登录密码）
& 'C:\Program Files\PuTTY\pscp.exe' -batch -pw '<.48密码>' `
    "$env:TEMP\ser2net-consolehub.bundle" <linux-user>@172.16.66.48:/tmp/

# 4) .48：拉进本地克隆再推（克隆在 ~/src/ser2net-consolehub）
"git -C /home/<linux-user>/src/ser2net-consolehub pull /tmp/ser2net-consolehub.bundle main --ff-only; ``
 git -C /home/<linux-user>/src/ser2net-consolehub push origin main"  # 用 plink 执行
```

> 不要在仓库里放任何带 `.48` 密码的脚本 —— 这仓库是公开的。
> `/tmp` 下的 bundle 用完删掉。

提交前自查：`git status --short` 里不该出现 `bin\*.exe`、`bin\*.dll`、
`logs\*`、`*.bak*`（`.gitignore` 已兜住，但换机后确认一次）。
