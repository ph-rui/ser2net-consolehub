# 部署到第二台 Windows（目标机 IP：10.0.9.2）

本仓库已支持**任意路径、任意机器**运行（所有脚本都基于自身目录 `$PSScriptRoot`
定位文件，不再有写死的 `C:\Users\zhangrui\...`）。目标机只要：

1. 拿到部署包（`bin\package-deploy.ps1` 生成）
2. 改 `settings.json` 里的 `bindIp`
3. 管理员跑一次 `install-boot-task.ps1`
4. 插好 USB 转串口 → `serial-hub.ps1 discover` 自动登记

---

## 0. 部署包里有什么 / 故意不带什么

**带**（自包含，拷到任何目录都能跑）：

```
ser2net-deploy-<时间戳>.zip
├─ bin\                 ser2net.exe + 43 个 gensio DLL + 所有 .ps1 脚本
├─ etc\ser2net\         ser2net.template.yaml（模板）
├─ linux\               console.sh / ptybridge.py / selftest.py
├─ settings.json        （bindIp 已预填 10.0.9.2）
├─ README.md
└─ DEPLOY-NEW-BOX.md    本文件
```

**不带**（这些是本机的运行时状态 / 硬件指纹，带过去反而坏）：

| 文件 | 为什么不带 | 新机怎么来 |
|---|---|---|
| `devices.json` | 记录这台机器的 USB 硬件指纹（PnP DeviceID），拷过去会登记错设备 | 新机插上适配器后 `discover` 自动新建 |
| `ports.json` | COM→端口分配表 | 自动生成 |
| `ser2net.pid` / `restart.request` | 本机进程号 / 待处理标记 | 自动生成 |
| `logs\` | 本机运行日志 | 自动新建 |
| `etc\ser2net\ser2net.yaml` | 生成物 | `start`/`render` 时按新机 `bindIp` 重新生成 |
| `linux\t-*.py` | 本机调试脚本（README 同样注明不用拷） | — |

> 注：早年的部署包里还有一个 `linux\devices.conf`（设备表快照）。**该文件已彻底移除**，
> 新包不再包含它，也不需要再生成。Linux 侧改为每次运行时向本机的 query-server
> （`queryPort`，默认 4099）实时查询设备表，所以不存在"里面写着旧 IP"的问题。

---

## 1. 准备（一次性，目标机 10.0.9.2）

- Windows 10（或 Win11），管理员账号。
- **串口驱动**：插上 USB 转串口适配器（CH344 四口 / CH340 单口）后，打开设备管理器看
  有没有 `端口(COM 和 LPT)` 下的 COM 口。Windows 一般能自动装好；如果显示
  `USB 串行设备` 但不给 COM 号，或出现黄色感叹号，去 WCH 官网装 `CH34xSER` 驱动
  （CH344 的 VID/PID 是 `USB\VID_1A86&PID_55D5`，与驱动匹配）。
- 拿部署包的方式：U 盘 / 局域网共享 / 网盘均可；从 172.16.66.48 不一定到得了 10.x 网段，按实际网络情况来。

## 2. 解压

解压到任意路径，**建议不带空格**，例如 `C:\ser2net`：

```
C:\ser2net\
├─ bin\ etc\ linux\ settings.json README.md DEPLOY-NEW-BOX.md
```

路径随便放都行——开机任务注册的是解压后这个绝对路径，脚本自身会适配。

## 3. 改 settings.json（唯一必改项）

```
"bindIp":  "10.0.9.2"
```

- 打包脚本默认已替你改成 `10.0.9.2`，直接确认即可。
- 如果目标机有多张网卡、或 IP 可能变，可以写成 `"0.0.0.0"`（绑所有网卡）。
  **多网卡时必须同时设 `advertiseIp`**：`bindIp` 是监听地址（可以是 `0.0.0.0`），
  而 `advertiseIp` 是告诉客户端"该连哪个地址"——banner 和 query-server 的回答都用它。
  漏设的话客户端会拿到 `0.0.0.0:400x`，然后连到自己回环上去。
  单网卡机器不设也行，会自动回退到 `bindIp`。
- 其它默认值不用动：`baud 115200`、`ports a-d=4000-4003`、`maxConnections 1`。
- 早年的 `push` 段（以及里面的 `sudoPassword`）**已从 settings.json 删除**：
  设备表改成实时查询，没有快照需要推送。旧版脚本若报找不到该段，属正常。

## 4. 装开机任务（SYSTEM，无需登录）

管理员 PowerShell（会弹一次 UAC），路径换成你的实际解压目录：

```powershell
powershell -ExecutionPolicy Bypass -File C:\ser2net\bin\install-boot-task.ps1
```

脚本会：杀旧的 autostart 循环（如有）→ 用 `schtasks /Create` 注册
`ser2net-consolehub`（开机触发、以 SYSTEM 运行）→ 立即 `/Run` 一次验证 →
再调 `harden-boot-task.ps1` 把自愈参数写好并**读回校验**，其中包含注册
**看门狗任务 `ser2net-consolehub-watchdog`**：每 3 分钟以 SYSTEM 检查循环还在不在，
不在就 `schtasks /Run` 拉起；只在真动手拉起时才往 `logs\watchdog.log` 写一行。
安装日志写在 `logs\boottask-install.log`。

验证（需要管理员上下文，见 README 说明，普通查询可能被 EDR 挡住）：

```powershell
schtasks /Query /TN ser2net-consolehub /V /FO LIST
# 应看到 TaskName=ser2net-consolehub, Run As=NT AUTHORITY\SYSTEM, 最近一次结果 0

schtasks /Query /TN ser2net-consolehub-watchdog /V /FO LIST
# 看门狗：Run As=NT AUTHORITY\SYSTEM、触发器每 3 分钟。
# logs\watchdog.log 不增长 = 循环一直活着（它只在真的拉起时才写）

# 实测一次自愈：把看门狗临时缩到 1 分钟 → 杀循环 → 断言 60 秒内被拉起 → 恢复定时器
powershell -ExecutionPolicy Bypass -File C:\ser2net\bin\verify-boot-task.ps1 -SelfHealTest
```

## 5. 插适配器 → 首次登记 → 验证

```powershell
cd C:\ser2net\bin
.\serial-hub.ps1 discover      # 重扫 USB，登记新设备（自动建 devices.json）
.\serial-hub.ps1 status        # 看 进程 / 别名→COM→端口 表
.\serial-hub.ps1 doctor        # 全套体检（进程 / yaml / 监听 / 状态）
.\serial-hub.ps1 probe         # 连一遍每个端口读 banner（连的是 bindIp=10.0.9.2）
```

开机任务在**重启后不登录**也会自动把 ser2net 拉起来（`logs\autostart.log` 有留痕）。
当场想验证"不登录也能连"：`schtasks /Run /TN ser2net-consolehub` 后立刻从 Linux 侧连。

## 6. 防火墙

本机当初是三个配置文件（Domain/Private/Public）全关。新机**按你的安全策略**二选一：

```powershell
# 方案 A：放行入站 TCP（只需这次，重启仍有效）
#   4000-4015 是串口控制台端口
#   4099    是 query-server：Linux 侧每次查设备表都要用它，漏了会直接连不上
netsh advfirewall firewall add rule name="ser2net-console 4000-4015" dir=in action=allow protocol=TCP localport=4000-4015
netsh advfirewall firewall add rule name="ser2net-query 4099" dir=in action=allow protocol=TCP localport=4099

# 方案 B：像本机一样关防火墙（不推荐有外网的环境）
Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled False
```

如果新机防火墙是默认开着的且没放行，Linux 侧 TCP 会直接 connection refused。
（端口号以 `settings.json` 的 `ports` / `queryPort` 为准。）

## 7. Linux 侧（172.16.66.48）怎么连第二台 hub 的板子

设备表现在是**向 hub 实时查**的，Linux 侧不再有快照文件，也就没有"两张表互相
覆盖"这个老问题。要接第二台 hub，只需在 Linux 上多写一个 hub 配置：

```bash
# 显式指定问哪台（优先级最高）
QUERY_HOST=10.0.9.2 ./console.sh --list

# 或写进 hub 配置文件的别名约定
cat /etc/ser2net-hub.conf
QUERY_HOST=172.16.66.163
```

- **只接一台 hub**：`/etc/ser2net-hub.conf` 指向它即可。
- **同时接两台 hub**：仍然要注意**别名不能撞**。每台机器的 `a-d` 是在自己
  `devices.json` 里从零算起的（同一块 CH344 的 a-d 与 (2) 命名每台机各自独立），
  所以两台 hub 很可能都给出别名 `a`。要么把第二台的别名在它自己的 `devices.json`
  里改成 `k/l/m/n` 之类，要么在 Linux 侧认准 hub 地址（`QUERY_HOST`）并只在该
  hub 上使用不冲突的别名。端口号同理，两台的 `a` 可能都是 4000。

`console.sh` 问不到 hub 会直接报错退出，不会拿旧数据凑合 —— 这比静默连错机器安全。

## 常见问题

| 现象 | 处理 |
|---|---|
| `probe` 全失败 / Linux 侧连不上 | 检查 `settings.json` 的 `bindIp` 是否为目标机真实 IP、防火墙是否放行、ser2net 进程是否活着（`status`） |
| 开机后没端口 | 看 `logs\autostart.log`：适配器枚举慢的话它最多等 120 s；确认插着适配器 |
| 新机 COM 号与本机不一致 | 正常。设备身份 = PnP 指纹，双方各自登记，`devices.json` 互不影响 |
| 某口 `Permission denied`（瞬态） | 上一次会话在 ser2net 侧还没收干净（`netstat` 里能看到该口挂着 `CLOSE_WAIT`），端口被它占着。真终端下的 `ptybridge.py` 会自己 sleep 2 秒重连，用户无感；非 tty / `--pty` 路径没有重试，看到这个裸错误就等几秒重来 |
| 某口 `Permission denied`（一直不恢复） | 驱动僵尸锁：ser2net 进程被硬杀时占着的 COM 口可能几十分钟不释放。跑 `bin\reset-ch344-ports.ps1`（需管理员，disable/enable 对应 PnP 节点），或物理拔插适配器 |
| Linux 侧报 `hub ... did not answer` | 设备表现场查这台 hub，没有兜底快照（本意如此）。在 Linux 跑 `console.sh --ping` 确认 hub 状态；先确认 `advertiseIp` 设成了客户端能访问到的真实地址 |
| Linux 侧报 `no hub to query` | 客户端不知道问哪台。写 `/etc/ser2net-hub.conf`（`QUERY_HOST=<ip>`）或传 `QUERY_HOST=` |
| 两台 hub 的同名设备混淆 | 别名是各机 `devices.json` 从零算起的，跨机可能撞（`a`↔`a`）。见第 7 节 |

## 附：存证

- 打包：`bin\package-deploy.ps1`（生成 `deploy\ser2net-deploy-*.zip`）
- 装机：`bin\install-boot-task.ps1`（v3，自适应路径）
- 运行时日志：`logs\autostart.log`、`logs\boottask-install.log`、
  `logs\watchdog.log`（只在看门狗真的拉起循环时才写一行，不增长 = 没出过事）