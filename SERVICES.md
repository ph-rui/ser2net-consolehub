# 服务与例程清单（Win / Linux 两端）

一页看全：两端各跑着什么、谁拉起的、每个脚本是干嘛的。
操作细节见 [README](README.md)，装第二台 Windows 见 [DEPLOY-NEW-BOX](DEPLOY-NEW-BOX.md)。

---

## 一、Windows 侧（172.16.66.163）

### 常驻（开机自动，无需登录）

| 名称 | 形态 | 谁拉起的 | 干什么 |
|---|---|---|---|
| `ser2net-consolehub` | 计划任务（Boot 触发，SYSTEM） | Windows 任务计划程序 | 开机即跑 `bin\autostart.ps1` 循环：等 USB 枚举（≤120s）→ 启动下面两个进程 → 每 15s `reconcile`（映射变了才重启 ser2net，不打断在用会话） |
| `ser2net-consolehub-watchdog` | 计划任务（每 3 分钟，SYSTEM） | Windows 任务计划程序 | 跑 `bin\watchdog.ps1`：只看不动——发现主循环没了才 `schtasks /Run` 拉起并写一行 `logs\watchdog.log`（只在动作时写，文件不增长=循环一直活着） |
| `ser2net.exe` | 进程（4.6.8） | autostart 循环 | 把每个已登记串口暴露成 TCP：4000–4003（+4004 起顺延），独占打开 COM 口，`trace-both` 全量收发落盘 `logs\dev-<别名>.log` |
| `query-server.ps1` | 进程（TCP 4099） | autostart 循环 | 实时回答"设备表"：别名 → 标签 → 端口 → 在位/可用。Linux 侧 `console.sh` 的唯一设备表来源，无快照文件 |

两道防线的关系、为什么必须独立任务，见 README「六、开机自启 → 循环死了谁来拉」。

### 端口

| 端口 | 用途 |
|---|---|
| 4000–4003 | 串口控制台（CH344 四路历史别名 a/b/c/d；新设备从 4004 顺延） |
| 4099 | 设备表实时查询（query-server）——**防火墙规则里两段都要放行** |

### 配置文件（仓库里入库的）

| 文件 | 角色 |
|---|---|
| `settings.json` | 全局设置：bindIp / advertiseIp / baud / maxConnections / trace… |
| `devices.json` | 设备注册表：PnP DeviceID 指纹 → 别名 + 固定端口（主要编辑入口） |
| `etc\ser2net\ser2net.template.yaml` | ser2net 配置模板（改端口/属性在这改） |

### 运行期生成（不入库，`.gitignore` 已排除）

`etc\ser2net\ser2net.yaml`（渲染产物）、`ports.json`、`ser2net.pid`、`logs\*`、`*.bak*`

---

## 二、Linux 侧（172.16.66.48）

**没有常驻服务，设计如此**（纯拉模型）：每次要用控制台时才连 hub，hub 不可达
就硬报错，绝不拿旧列表凑合。

| 名称 | 位置 | 干什么 |
|---|---|---|
| `/etc/ser2net-hub.conf` | 一行静态配置 | `QUERY_HOST=172.16.66.163`，问哪台 hub（唯一本地配置） |
| `console.sh` | `/usr/bin/` | 交互式控制台：按别名/标签/端口连设备，设备表实时查 4099。真终端走 `ptybridge.py`（Ctrl+C 到板子、断 banner 自动重连最多 3 次/间隔 2s）；非 tty 自动降级 socat 透传 |
| `ptybridge.py` | `/usr/bin/` | 终端 ↔ TCP 桥：termios 置 raw、Ctrl+] 自退出、`Device open failure` 重试 |
| `selftest.py` | `/usr/bin/` | 链路自检：不碰板子，区分网络问题还是板子没上电 |

---

## 三、例程与工具

### Windows（`bin\`）

| 脚本 | 用途 | 提权 |
|---|---|---|
| `serial-hub.ps1` | **主控**：discover / start / stop / restart / render / reconcile / status / doctor / probe / logs / prune | 普通（restart/stop 遇 SYSTEM 进程自动落 `restart.request` 由循环代执行） |
| `query-server.ps1` | 设备表查询服务（4099），autostart 自动拉起 | 由循环拉起 |
| `autostart.ps1` | 开机任务入口循环（见上） | SYSTEM |
| `install-boot-task.ps1` | 注册 `ser2net-consolehub` 开机任务（幂等） | 需 UAC |
| `harden-boot-task.ps1` | 写入/修复三道自愈防线 + 读回校验（`-ReportOnly` 只看不改） | 需 UAC |
| `verify-boot-task.ps1` | 开机任务体检；`-SelfHealTest` 实测自愈（杀循环→断言 60s 内被拉起） | 需 UAC |
| `watchdog.ps1` | 看门狗本体（由 watchdog 任务每 3 分钟跑） | SYSTEM |
| `fix-autostart-loop.ps1` | 改过 bin\ 脚本后让运行中的 SYSTEM 循环立即加载新版（杀旧重拉） | 需 UAC |
| `probe-all.ps1` | 一口气 banner 探测 4000 起所有活端口（只读，安全） | 普通 |
| `probe-port.ps1` | 单端口 banner 探测 | 普通 |
| `patient-probe.ps1` | 单端口长超时（15s）banner 读取 | 普通 |
| `direct-com-open.ps1` | 直接 .NET 打开 COM 口（不带 DTR/RTS），定位"口被谁占" | 普通 |
| `who-holds-com99.ps1` | handle64 全量 dump，查谁持有 COM99 | 需 UAC |
| `reset-ch344-ports.ps1` | PnP disable/enable CH344 串口，清僵尸驱动打开态（COM 口僵死的手动恢复手段） | 需 UAC |
| `reset-ch344-parent.ps1` | 整个 CH344 复合设备驱动重载 + 落标记让循环重启 | 需 UAC |
| `demo-2-readers.ps1` | 例程：证明 `maxConnections≥2` 时两个 TCP 读端可共存（当前配置保持 1） | 普通 |
| `package-deploy.ps1` | 打第二台 Windows 的部署包（剔除本机注册信息、改 bindIp） | 普通 |

### Linux（`linux\`）

见上表四个文件。`linux\t-*.sh/py` 是当年定位 termios/pty 问题的**本机调试脚本**，
不部署、不入库（`.gitignore` 已排除）。

### 部署（`deploy\`）

| 文件 | 用途 |
|---|---|
| `deploy-on-target.ps1` | 在第二台 Windows 上跑的一次性安装脚本（pscp 拉过去执行） |

---

## 四、不在仓库里的东西

`ser2net.exe` + 43 个依赖 DLL、`deploy\*.zip` 都**不入库**（约 21MB，且避免
GPLv2 二进制分发义务）。新机器怎么补齐见 README「一、安装」——简言之：
ser2net 4.6.8 安装包 + Gensio 3.0.4 的 DLL + MSYS2 的 `libpcre2-posix-3.dll`，
版本必须配套。
