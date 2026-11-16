# ser2net 串口控制台部署步骤

Windows 主机接 USB 转串口，把串口暴露成 TCP；Linux 端用 `console.sh` 按设备别名连过去。
先装 Windows 端，再装 Linux 客户端，然后就能连设备了。

文档里的地址和账号用占位符代替，实际部署时换成自己的：

| 占位符 | 含义 | 示例 |
|---|---|---|
| `<WIN_IP>` | Windows 主机 IP | `192.168.1.10` |
| `<WIN_USER>` | Windows 登录账号 | `Administrator` |
| `C:\ser2net` | Windows 安装目录 | 不要带空格 |

---

## 一、Windows 端

### 1. 解压

把部署包解压到 `C:\ser2net\`：

```
C:\ser2net\
├─ bin\              ser2net.exe + 43 个 DLL + 全部 .ps1 脚本
├─ etc\ser2net\      ser2net.template.yaml（模板）、ser2net.yaml（自动生成，别手改）
├─ logs\             dev-<别名>.log、autostart.log、watchdog.log
├─ settings.json     全局设置
└─ devices.json      设备注册表
```

包里已经带了 `ser2net.exe` 和全部 DLL。如果手上没有现成的包，需要自己准备
ser2net 4.6.8 和 Gensio 3.0.4 的 DLL，两个版本的 ABI 必须对应，混版本起不来。

### 2. 修改 settings.json

只需要改两个地址：

```json
"bindIp": "192.168.1.10",
"advertiseIp": "192.168.1.10",
```

- 机器只有一块网卡：两行都填本机 IP。
- 有多块网卡：`bindIp` 填 `0.0.0.0`，`advertiseIp` 填 Linux 能访问到的那块网卡的地址。
  `advertiseIp` 漏了的话，Linux 会拿到 `0.0.0.0`，连到自己身上。

其余项保持默认：115200 8N1，端口从 4000 开始，每个串口允许一个连接。

### 3. 运行安装脚本

用管理员身份打开 PowerShell，执行：

```powershell
powershell -ExecutionPolicy Bypass -File C:\ser2net\bin\install-boot-task.ps1
```

脚本会注册两个开机任务（主服务和看门狗），并立即启动一次。以后开机自动运行，不用登录。
开机后大约 1–3 分钟服务就绪。

### 4. 接入串口设备

插上 USB 转串口，打开设备管理器，`端口(COM 和 LPT)` 下面能看到 COM 口就说明正常。
看不到，或者设备前面有黄色感叹号，是驱动没装好，按这根线用的芯片去厂商官网下载对应驱动安装。

然后确认设备是否已经登记：

```powershell
cd C:\ser2net\bin
.\serial-hub.ps1 status
```

输出里能看到 `别名 → COM → 端口` 的对应关系。想立刻刷新、不等后台扫描，可以手动执行
`.\serial-hub.ps1 discover`。

---

## 二、Linux 端

### 1. 安装依赖

```bash
sudo apt install socat        # 或 yum install socat
```

### 2. 拷贝文件

从 Windows 的 `linux\` 目录拷三个文件过来（`t-*` 开头的是调试脚本，不用拷）：

```bash
scp <WIN_USER>@<WIN_IP>:C:/ser2net/linux/console.sh     .
scp <WIN_USER>@<WIN_IP>:C:/ser2net/linux/ptybridge.py   .
scp <WIN_USER>@<WIN_IP>:C:/ser2net/linux/selftest.py    .
```

### 3. 安装

```bash
echo 'QUERY_HOST=192.168.1.10' | sudo tee /etc/ser2net-hub.conf
sudo install -m 755 console.sh ptybridge.py selftest.py /usr/bin/
```

`QUERY_HOST` 填 Windows 主机的地址，`console.sh` 靠它去查设备表。配置文件只有这一行，
以后换 Windows 机器只改这里。

---

## 三、console.sh 使用方法

### 查看设备

```bash
console.sh --list
# alias  label                        endpoint
# a      USB-Enhanced-SERIAL-A  <WIN_IP>:4000
```

设备表是每次向 Windows 端实时查询的，插拔后马上就能看到变化。

`console.sh --ping` 只看 Windows 端有没有响应，以及登记了几台设备、当前在线几台。

### 连接

参数可以写别名、标签的一部分，或者端口号：

```bash
console.sh a                  # 别名
console.sh usb-enhanced       # 标签子串，不区分大小写
console.sh 4002               # 端口
```

连上以后是透传的，Ctrl+C 会直接发给板子，可以打断 u-boot 或内核启动。

### 退出

先按 **Ctrl+A** 松开，再按 **x**；`Ctrl+]` 也可以。退出后终端恢复正常，对 Windows 端没有影响。
这段会话的收发记录在 Windows 的 `logs\dev-<别名>.log` 里。

如果板子上要发一个真正的 Ctrl+A（比如 bash 行首），连按两次 Ctrl+A。

不要在 `console.sh` 后面接 `| tee`。输出被接管以后 termios 会报
`tcsetattr(...): Inappropriate ioctl for device`，程序直接退出。

---

## 四、常见问题

| 现象 | 处理 |
|---|---|
| Linux 连不上 | 检查 `advertiseIp`；防火墙是否放行 4000-4100 和 4099；在 Windows 上跑 `serial-hub.ps1 status` 看进程在不在 |
| 某台设备连不上 | 先 `console.sh --list` 看它有没有登记且在线。没插的时候端口本来就不监听 |
| 报 `no hub to query` | 客户端不知道问哪台 Windows，检查 `/etc/ser2net-hub.conf`，应该是 `QUERY_HOST=<WIN_IP>` |
| 报 `hub did not answer` | 连不上 Windows 端。多半是 4099 没放行，或者 `advertiseIp` 填的不是客户端能访问的地址 |
| 第一次 `--list` 报 `did not answer`，马上重跑就正常 | 4099 是单线程查询，其他程序对 4099 做空连接探测时，下一次查询要排队到探测超时；现在读超时 0.8 秒，客户端超时 4 秒并自动重试一次。仍然频繁出现就查一下谁在探测 4099，连通性统一用 `console.sh --ping` |
| 报 `Device open failure: Permission denied` | 上一个连接还没释放，等几秒重连。一直不恢复就把串口线拔了重插；CH344 可以管理员跑 `bin\reset-ch344-ports.ps1` |
| 改了脚本不生效 | 开机任务里的循环还在跑旧代码，管理员执行一次 `bin\fix-autostart-loop.ps1` |
| 开机后几分钟才有端口 | 正常，看门狗每 3 分钟检查一次 |

探测端口不要用 `nc -z` 或 `/dev/tcp` 这种连上就断的方式。这类空连接会让下一个正常连接收到
`Device open failure: Permission denied`，要测就用 `console.sh --ping` 或 `selftest.py`。

日志都在 Windows 的 `C:\ser2net\logs\` 下：`dev-<别名>.log` 是收发记录，`autostart.log` 记启动
和重启，`watchdog.log` 只在看门狗真的拉起服务时才写一行。`dev-*.log` 不会自动清理，时间长了用
`serial-hub.ps1 prune` 删掉旧的。
