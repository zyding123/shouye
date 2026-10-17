<div align="center">

<img src="assets/icon-1024.png" width="128" alt="守夜 LidGuard">

# 守夜 · LidGuard

**合上盖子也不休眠** —— 并自动锁屏、延迟息屏。原生 Swift，无内核扩展、无守护进程、不联网。

</div>

> A tiny macOS menu-bar app that keeps your MacBook awake with the lid closed,
> with automatic lock screen, delayed display-off, and three independent safety nets.
> Native Swift · no kext · no daemon · no telemetry · Apple Silicon, macOS 13+

---

## 它解决什么问题

拿 Mac 当挂机机器时（跑长任务、给局域网其他设备提供代理），一合盖系统就睡眠，连接全断。

macOS 自带的「合盖模式」要求**外接显示器 + 电源 + 键鼠**，日常场景用不上；而手动敲 `pmset -a disablesleep 1`，既容易忘，也容易**忘了改回来**——机器就这么在包里亮着、热着、直到没电。

这个工具把这件事变成菜单栏上的一个开关，并且**把所有「忘记关」的情况都做了兜底**。

## 功能

| 功能 | 说明 |
|---|---|
| 合盖不休眠 | 菜单栏一键开关，基于系统自带 `pmset -a disablesleep` |
| **合盖自动锁屏** | 检测到合盖立刻进入真正的锁屏（密码登录界面，不是屏保） |
| **锁屏后延迟息屏** | 可选 立即 / 15 秒 / 30 秒 / 1 分钟 / 3 分钟 / 不自动 |
| **三重保险** | 正常退出 · 被强杀（看门狗兜底） · 低电量，三种情况都自动恢复系统默认 |
| **自愈巡检** | 每 15 秒核对一次系统状态，被外部改掉能自己修回来 |
| 电量兜底 | 未接电源且低于阈值时自动恢复，避免把电池跑干 |
| 不占 Dock | 只驻留菜单栏；**图标在 = 程序在跑** |

## 同类工具已经很多，为什么还做一个

这个品类**并不新**，社区里有上百个同类项目，商业产品也有好几个：

- **[Amphetamine](https://apps.apple.com/app/amphetamine/id937984704)**（App Store，免费）——最省事的选择
- **[Sleepless](https://github.com/Aboudjem/Sleepless)**（MIT）——思路与本项目最接近，源码很干净
- [Clamshell](https://clamshell.dev)（付费）、[KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake)、[Adrafinil](https://github.com/kageroumado/adrafinil)……

**如果你只需要「合盖不休眠」这一件事，直接用上面任意一个就好，不必装这个。**

这个项目的差异点只有三条，都很朴素：

1. **把「忘记关」当成主要风险来设计**——三重保险 + 每 15 秒自愈，而不是「设了就不管」；
2. **合盖 → 锁屏 → 息屏是一条完整链路**，不是三个彼此独立的开关；
3. **权限收窄到两条命令**，并且把「它到底能干什么」写清楚（见下方权限说明）。

## 系统要求

- **Apple Silicon** Mac（arm64）
- **macOS 13 Ventura** 及以上
- 编译需要 **Command Line Tools**（`xcode-select --install`）
- **不需要** Xcode 完整版，**不需要** Homebrew，没有任何第三方依赖

> 测试环境：MacBook Pro（M5 Pro）/ macOS 27.0.1。**未在 Intel Mac 上测试。**

## 安装

目前只提供源码构建（尚无预编译包）。

```bash
git clone https://github.com/zyding123/shouye.git
cd shouye
./build.sh
open build/守夜.app
```

`build.sh` 会调用系统自带的 Swift 编译器生成 `.app` 并做 ad-hoc 签名。

### 首次打开

因为未做 Apple 公证，首次打开会被 Gatekeeper 拦下：

- **在 Finder 里右键点 `守夜.app` → 打开 → 再点一次「打开」**，或
- 系统设置 → 隐私与安全性 → 找到被拦下的提示 → 「仍要打开」

## 使用

点菜单栏图标，菜单里依次是：

```
状态：守夜中 — 合盖不会休眠
────────────────
暂停（恢复合盖休眠）
────────────────
打开本工具时自动开启
登录时自动启动
电量低时自动恢复 ▸
────────────────
合盖时自动锁屏
合盖后息屏 ▸
立即测试：锁屏 + 息屏
────────────────
它是怎么做到安全的…
重新安装权限授权…（已授权时隐藏）
查看运行记录…
────────────────
退出（并恢复合盖休眠）
```

**菜单栏图标**：笔记本 + 实心圆点 = 守夜中；空心圈 = 已恢复系统默认（合盖会休眠）。

## 权限说明（重要）

这是唯一需要授权的动作：

```bash
sudo pmset -a disablesleep 1   # 开启
sudo pmset -a disablesleep 0   # 恢复
```

首次运行时，会通过**系统原生授权弹窗**写入一条范围极窄的规则：

```
/etc/sudoers.d/lidguard-disablesleep
<当前用户名> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

- 只允许这两条**完整命令**，**没有通配符**；其他任何 `pmset` 用法仍然需要密码
- 为什么需要：macOS 没有提供其他免特权的方式来改这个开关
- **如何撤销**：删除该文件即可（或在菜单里点「重新安装权限授权…」覆盖）

### 它不做什么

- ❌ 不联网，**没有任何网络代码**
- ❌ 不收集数据、没有遥测
- ❌ 不写内核扩展，不需要关闭 SIP
- ⚠️ 唯一的后台进程是一个**看门狗子进程**（`--watchdog`），随主程序生灭：
  主程序一旦消失（崩溃 / 强制退出），它把系统恢复成默认后自己退出

## 三重保险 + 自愈

| 场景 | 行为 |
|---|---|
| 点「退出」/ ⌘Q / 注销 | 立即执行 `disablesleep 0`，并清理看门狗 |
| **被强制退出（Force Quit）/ 崩溃** | 看门狗每 0.5 秒轮询，发现主进程消失 → 恢复默认 → 自己退出 |
| 未接电源且电量低于阈值 | 自动恢复默认，并弹出提示 |
| **系统状态被外部改回 0** | 每 15 秒巡检，发现不一致自动重设并记日志 |
| 重启电脑 | `disablesleep` 本身不跨重启保留，登录时由本工具重新设置（启动带 5 次重试） |

运行记录落盘在 `~/.lidguard/events.log`，菜单里也有「查看运行记录…」。

## 实现要点（含踩坑）

代码不多（单文件约 960 行），但有几处不太显然的地方：

1. **读合盖状态**：`IOKit` → `IOPMrootDomain` 的 `AppleClamshellState`。
   每 2 秒读一次，纯内存操作，不起子进程。

2. **真锁屏**：调用私有接口 `SACLockScreenImmediate`（来自 `login.framework`）。

   > ⚠️ **这是最容易踩的坑**：该框架的二进制**只存在于 dyld 共享缓存里，磁盘上并没有文件**。
   > `ls` 会显示一个断链，`nm` 也读不到符号，很容易误判成「接口已被移除」。
   > 正确的判断方式是**直接 `dlopen`**，让缓存来解析：
   > ```swift
   > let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_LAZY)
   > let sym = dlsym(h, "SACLockScreenImmediate")
   > ```
   > 附带一句：**在 macOS 上，永远不要用「文件是否存在」判断某个系统 API 有没有。**

3. **息屏**：`pmset displaysleepnow`，免管理员密码；且在 `disablesleep=1` 状态下**依然生效**
   （这一点用系统电源日志 `pmset -g log` 里的 `Display is turned off` 事件验证过）。

4. **`disablesleep` 不跨重启保留**：所以启动时带重试、运行中带巡检——这是本项目最核心的设计取舍。

5. **菜单栏图标**：`NSBezierPath` 直接画，`isTemplate = true` 自动适配深色/浅色菜单栏。

6. **构建绕开 Xcode 许可**：用 `/Library/Developer/CommandLineTools/usr/bin/swiftc`
   的绝对路径，并用 `MacOSX.sdk` 这个通用符号链接指向当前 SDK。
   （如果本机 Xcode 许可未接受，`/usr/bin/swiftc` 会拒绝工作，但 CLT 那份可以。）

### 诊断命令

```bash
./build/守夜.app/Contents/MacOS/LidGuard --lid          # 打印合盖状态
./build/守夜.app/Contents/MacOS/LidGuard --lockstate    # 打印是否已锁屏
./build/守夜.app/Contents/MacOS/LidGuard --lock-only    # 只锁屏、不息屏
./build/守夜.app/Contents/MacOS/LidGuard --test-lock    # 锁屏 + 息屏
./build/守夜.app/Contents/MacOS/LidGuard --events       # 打印运行记录
./build/守夜.app/Contents/MacOS/LidGuard --force-off    # 把开关强制改回 0（测自愈用）
```

`tools/probe-lock.swift` 是一个独立探针，用来验证锁屏接口在当前系统上是否可用：

```bash
/Library/Developer/CommandLineTools/usr/bin/swiftc -o /tmp/probe tools/probe-lock.swift && /tmp/probe
```

## 已知限制

- 使用了**私有 API**（`SACLockScreenImmediate`）来进入真正的锁屏界面，因此**不适合上架 Mac App Store**
- ad-hoc 签名、未公证，首次打开需要右键 → 打开
- **合盖时键盘面散热被遮挡**：适合挂机，不适合在包里跑重负载
- 只在 Apple Silicon + macOS 27 上实测过；更早系统理论上可用（目标 `macOS 13.0`），但未验证

## 卸载

1. 把 `守夜.app` 拖进废纸篓
2. 删除权限规则：`sudo rm /etc/sudoers.d/lidguard-disablesleep`
3. 若开过「登录时自动启动」：
   `launchctl bootout gui/$(id -u)/com.aries.lidguard && rm ~/Library/LaunchAgents/com.aries.lidguard.plist`
4. 可选：`rm -rf ~/.lidguard`（运行记录）

## 许可

[MIT](LICENSE) © 2026 zyding123

---

<sub>在 macOS 27.0.1 / Apple Silicon 上开发与测试。欢迎 issue，但不保证响应速度。</sub>
