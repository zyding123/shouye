# 守夜 · LidGuard

一个 macOS 菜单栏小工具：**让 MacBook 合上盖子也不休眠**，同时自动锁屏、延迟息屏，并为所有"忘记关掉"的情况准备了三重保险。

---

## 它解决什么问题

拿 Mac 当挂机机器时（跑长任务、给局域网其他设备提供代理），一合盖系统就睡眠，连接全断。macOS 自带的"合盖模式"要求外接显示器 + 电源 + 键鼠，日常场景用不上；而 `pmset` 那一行命令又容易忘、也忘了恢复。

这个小工具把这件事变成菜单栏上的一个开关。

## 功能

| 功能 | 说明 |
|---|---|
| 合盖不休眠 | 菜单栏一键开关，基于系统自带 `pmset -a disablesleep` |
| **合盖自动锁屏** | 检测到合盖立刻进入真正的锁屏（密码登录界面，不是屏保） |
| **锁屏后延迟息屏** | 可选 立即 / 15 秒 / 30 秒 / 1 分钟 / 3 分钟 / 不自动 |
| **三重保险** | 正常退出 · 被强杀（看门狗兜底） · 低电量，三种情况都会恢复系统默认 |
| **自愈巡检** | 每 15 秒核一次系统状态，被外部改掉能自己修回来 |
| 电量兜底 | 未接电源且低于阈值时自动恢复，避免把电池跑干 |
| 不占 Dock | 只驻留菜单栏；图标在 = 程序在跑 |

## 系统要求

- Apple Silicon Mac（arm64），macOS 13 及以上
- **不需要 Xcode**：使用系统自带的 Command Line Tools 编译
- 不需要 Homebrew，无第三方依赖

## 构建

```bash
./build.sh
# 产物：build/守夜.app
```

构建脚本用绝对路径调用 `/Library/Developer/CommandLineTools/usr/bin/swiftc`，因此**即使 Xcode 许可协议尚未接受也能编译**。

## 权限说明（重要）

这是唯一需要授权的动作：

```bash
sudo pmset -a disablesleep 1   # 开启
sudo pmset -a disablesleep 0   # 恢复
```

首次运行时会通过系统原生授权弹窗写入一条**范围极窄**的规则：

```
/etc/sudoers.d/lidguard-disablesleep
<当前用户名> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

- 只允许这两条**完整命令**，没有通配符，别的命令一律仍需密码
- 撤销方式：删除该文件即可（或在菜单里使用「重新安装权限授权…」覆盖）
- 为什么需要：macOS 没有提供其他免特权的方式来改这个开关

## 它不做什么

- **不联网**，不收集任何数据，没有遥测
- **不写内核扩展**，不需要关闭 SIP
- **不常驻后台守护进程**：只有一个看门狗子进程，随主程序生灭（主程序一退出，它把系统恢复默认后自己退出）

## 实现要点（含踩过的坑）

1. **合盖状态**：`IOKit` → `IOPMrootDomain` 的 `AppleClamshellState`，每 2 秒读一次，纯内存操作。
2. **真锁屏**：调用私有接口 `SACLockScreenImmediate`。
   ⚠️ 关键坑：该框架的二进制**只存在于 dyld 共享缓存里，磁盘上并没有文件**（`ls` 显示断链、`nm` 读不到符号）。
   **不能用"文件是否存在"判断接口有没有**，必须直接 `dlopen` 让缓存解析。
3. **息屏**：`pmset displaysleepnow`，免管理员密码，且在 `disablesleep=1` 状态下依然生效。
4. **`disablesleep` 不跨重启保留**：每次登录都必须重新设置，所以启动时带重试、运行中带巡检。
5. **菜单栏图标**：`NSBezierPath` 绘制，`isTemplate = true` 自动适配深浅色。

## 诊断开关

```bash
./build/守夜.app/Contents/MacOS/LidGuard --lid          # 打印合盖状态
./build/守夜.app/Contents/MacOS/LidGuard --lockstate    # 打印是否已锁屏
./build/守夜.app/Contents/MacOS/LidGuard --lock-only    # 只锁屏、不息屏
./build/守夜.app/Contents/MacOS/LidGuard --test-lock    # 锁屏 + 息屏
./build/守夜.app/Contents/MacOS/LidGuard --events       # 打印运行记录
./build/守夜.app/Contents/MacOS/LidGuard --force-off    # 把开关强制改回 0（测自愈用）
```

运行记录落盘在 `~/.lidguard/events.log`，菜单里也有「查看运行记录…」。

## 已知限制

- 使用了私有 API（`SACLockScreenImmediate`），因此**不适合上架 Mac App Store**
- ad-hoc 签名，未公证；首次打开需在 Finder 里右键 → 打开
- 合盖时键盘面散热被遮挡，**不要塞在包里跑重负载**

## 卸载

1. 把 `守夜.app` 拖进废纸篓
2. 删除 `/etc/sudoers.d/lidguard-disablesleep`
3. 若开过登录启动：删除 `~/Library/LaunchAgents/com.aries.lidguard.plist`

## 许可

私有项目，未授权。若将来公开，建议采用 MIT。
