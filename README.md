# NetBall

> macOS 菜单栏实时流量监控：随时看上下行速率，需要排查时再展开进程排行，也可切换为桌面悬浮球。

<p align="center">
  <img src="shots/app-panel.png" width="420" alt="NetBall 展开面板：总流量曲线与进程排行（示例数据）">
  <img src="shots/app-ball.png" width="220" alt="NetBall 悬浮球样式（示例数据）">
</p>

<p align="center"><sub>界面预览来自仓库现有的 NetBall 程序渲染图，不是桌面截屏；图中速率为示例值，不代表当前实时流量。</sub></p>

[功能概览](#主要功能) · [快速开始](#快速开始) · [已知限制](#已知限制) · [开发与自检](#自检与开发)

## 主要功能

- **菜单栏实时速率**：上下行速率常驻显示，7 种紧凑样式可选。
- **总量累计统计**：展开主面板切到「统计」，查看自启动或上次重置以来的累计下行/上行字节数，并可一键重置统计周期。
- **按进程累计统计**：同一周期内按进程名分别汇总上下行流量；同名多 PID 合并，列表按总流量排序，可滚动查看全部进程。实时排行仍可切回查看 Top 5。
- **可选悬浮球**：毛玻璃球或曲线胶囊，置顶显示；单击即可展开面板。
- **轻量采样**：通过 `nettop` 单次快照计算速率，无需 `sudo` 或网络扩展；默认每 2 秒采样。
- **有限的代理识别**：仅使用固定的 mihomo / Clash Verge Rev 端点和进程名回退；不保证适配其他代理配置，详见下文。

<p align="center">
  <img src="shots/panel-stats.png" width="420" alt="统计面板：累计总流量及按进程分类的累计上下行字节数（示例数据）">
</p>
<p align="center"><sub>累计统计从应用启动或手动重置时开始；同名进程合并，滚动可查看完整进程列表。</sub></p>

## 快速开始

**要求：macOS 12+，以及可用的 Swift 编译器。**

```bash
./build.sh          # 编译并打包为 NetBall.app
open NetBall.app    # 启动，默认使用菜单栏模式
```

退出：点菜单栏图标 → **退出 NetBall**（悬浮球模式下也可右键球体）。首次构建在 macOS 上执行；本仓库没有提供 Windows/Linux 版本。

> **验证边界：** 1.1.0 在 macOS 上构建，并通过累计器自检与面板渲染检查；累计值来自 `nettop` 进程字节计数差分，不跨应用重启保存。

---

### 悬浮球样式（菜单栏图标 / 球体右键 → 悬浮球样式）

两款任选，切换会记住；窗口尺寸随样式自动变化。

| 样式 | 实际尺寸 | 说明 |
|---|---|---|
| **毛玻璃球（默认）** | 140×140 pt | 深色磨砂 + 磨砂颗粒；球心大字是总速率，下面一行 ↓/↑；**上弧＝下载量程、下弧＝上传量程**（弧长按对数伸缩：1KB/s≈0、1MB/s≈0.6、100MB/s≈1，淡色轨道显示满量程）；新值不是硬跳，而是用 **0.4s 缓动滑过去**；弧上还有一个**峰值刻度**＝最近 60 次采样的最高点，回落之后也留着 |
| 曲线胶囊 | 200×72 pt | 药丸显示 ↓/↑，右侧面积曲线是最近 12 次采样的下行趋势 |

> **不透明度**：菜单栏图标 / 球体右键 → 不透明度（60% / 70% / 80% / **85%（默认）** / 92% / 100%）。
> 三款都是「深色磨砂底 + 白色字」，所以在浅色壁纸上也看得清；嫌太透就调到 92%/100%。
>
> **展开面板会跟着样式换皮肤**：毛玻璃球 → 深色磨砂 + 磨砂颗粒 + 圆角行；曲线胶囊 → 大圆角胶囊面板 + 胶囊形行。

对照图：

```bash
./build/NetBall --snapshot-ball ball.png --demo            # 放大 2 倍
./build/NetBall --snapshot-ball ball.png --demo --scale 1  # 实际尺寸
./build/NetBall --snapshot-ball lv.png --levels --style glass --scale 1.6  # 各档速率下的弧长 + 峰值刻度对照
./build/NetBall --ball --style pill --quit-after 3         # 启动某一款试 3 秒
./build/NetBall --snapshot panel.png --demo --style glass  # 渲染对应样式的展开面板
```

浅色壁纸下的验证图（`--bg-white` 可以把自检图渲染成白底，专门用来查鬼影/对比度）：
`shots/white-bg-ball.png`、`shots/white-bg-pill.png`、`shots/white-bg-panel.png`

实现要点（踩过的坑都在这）：

- `NSGradient.draw(fromCenter:radius:toCenter:radius:)` 填充的是**当前裁剪区**而不是路径，必须先 `addClip`；
- 起始半径接近 0、或起点落在形状边缘时，径向渐变会烧出**暗斑/尖角伪影**——球面高光最后改成**多层同心椭圆叠加**（30 层平滑衰减）才干净；
- `NSGradient.draw(in:angle:)` 是填充路径，拿它画圆弧会变成扇形，弧线要分段描边；
- ~~阴影~~：**现在完全不画投影**（自绘的和系统窗口阴影都关掉了，`hasShadow = false`），
  平铺贴在桌面上最干净。留个教训：翻转视图里 `NSShadow` 的 y 偏移方向是反的，
  `offset (0, +8)` 会把阴影画到**上方**，叠上系统阴影就是"背后一层错位的鬼影"。
- **弧线缓动按"经过时间"取进度**（ease-out cubic，0.4s / 20fps），不是每帧累乘一个系数：
  定时器抖动或掉帧时手感不变，收敛即停表，数值没动就一次都不重绘。复现：`--ease-test`。
- **峰值刻度画在进度弧之外**：当前值回落到 0 时弧是空的，但峰值那点仍要留着，
  否则"刚才飙到过多少"就看不出来了（`--levels` 最后那格就是这个场景）。
- **静态底和文字层都缓存成位图**（`glassBackground` / `ballTextLayer`），动画每帧只重画两条细弧 + 贴两张缓存图，
  否则 20fps 重画 300 颗磨砂颗粒会贵得多。
- 两个量测上的坑：① `--snapshot --ball --demo` 原来直接塞 `totalRx/totalTx`，绕过了 `updateRates`，
  而弧线读的是缓动后的显示值 → 渲染出来是一条**空弧**，必须走 `updateRates`；
  ② 窗口在这个会话里没被真正合成时 `NSWindow.display()` 会被 AppKit 直接跳过，
  量出来是 0.005ms/帧 的假数——所以 `--draw-cost` 用 `cacheDisplay` 并拿 `drawCount` 对账。
- **对已测配置，过滤代理核心，而不是把流量“搬”给应用**：nettop 的归因与测试记录相符（直连下载 6,160,348 字节 → 给 curl 记 6,216,458）。混合端口下，核心与应用的同一流量可能被重复累计；在这些样本里过滤核心可减少重复计数。这不构成对其他代理或端点下总量准确性的保证。
- **root 服务模式的代理核心，`lsof` 和 `ps` 都拿不到**（普通用户看不到它的 socket），
  只有 `pgrep -x verge-mihomo` 稳定返回 PID —— 所以核心识别的主路径是名字，不是端口。

### 代理穿透（Clash / mihomo）

开了 Clash 之后，nettop 里会冒出一个吃掉所有流量的 `verge-mihomo`，把真实应用全压在下面。
原因是同一个字节最多被记了三次：

- **TUN 模式**下出站 socket 属于代理核心，这份流量记在它头上；
- **混合端口**（系统代理）的回环那一段，应用和代理核心**各持一端**，nettop 两边都算。

所以除了排行被污染，**总量也是虚的**。实测下载 14.1 MB/s 时：

| | 下行 | 上行 |
|---|---|---|
| nettop 原样 | 26.0 MB/s | **14.3 MB/s** |
| 剔除代理核心后 | 14.3 MB/s | **2.1 KB/s** |

上行那 14.3 MB/s 是**纯幽灵流量** —— curl 实际只发了 100 B/s，全都是代理核心那两条 socket 的重复计数。
（虚高幅度随代理流量占比变化，实测 1%~64%。）

**在这两组样本中，过滤代理核心后总量接近对应的 curl 测量值；这不保证其他代理配置也能完全校正。**
直连下载 6,160,348 字节（走 TUN）时，nettop 给 curl 记 6,216,458；混合端口下载 9,000,000 字节时，nettop 记 9,034,418。进一步打标时，程序会从 mihomo 连接表读取 `sourcePort`，再用 `lsof` 尝试映射到进程。

```
Google Chrome (代理)   1.4 MB/s    168 B/s
UURemote    (代理)    28.9 KB/s    1.6 KB/s
io.tailscale.ip        642 B/s     1.1 KB/s
QQ          (代理)     531 B/s       0 B/s
```

#### 识别范围与边界

这是针对部分 mihomo / Clash Verge Rev 部署方式的**尽力而为**集成，不是通用代理探测：

- 控制器只尝试固定位置：`/var/run/clash-verge-service/users/<uid>/verge-mihomo.sock`、`/tmp/clash-verge-service/users/<uid>/verge-mihomo.sock`、`${HOME}/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/verge-mihomo.sock`，以及裸 mihomo 常用的 `http://127.0.0.1:9090`。不会扫描任意端口或读取用户自定义端点。
- 端点探测和 `/configs`、`/connections` 请求通过 `curl` 发出，**没有附带 API secret、token 或 Authorization 请求头**。需要鉴权、使用其他端点或找不到这些固定路径时，连接识别可能不可用。
- 找不到控制器时，核心过滤会回退到固定进程名清单：`verge-mihomo`、`mihomo`、`clash-meta`、`clash-meta-alpha`、`sing-box`、`xray`、`v2ray`、`hysteria`、`tuic`。**清单中没有 Surge**；这不是对这些代理客户端或所有部署形态的完整支持声明。
- 控制器可访问时，会从 `/connections` 读取 `sourcePort`，再通过 `lsof` 尝试映射到本机 PID 并加「代理」标记；权限、进程可见性或端口映射失败都可能导致漏标。

因此，如果控制器未被固定端点探测到、代理核心名不在清单中，或连接无法映射，NetBall **不能保证**排除核心流量、标记代理进程或修正总速率；在这些配置下仍可能看到核心进程流量或重复计数。Clash Verge root 服务模式下，普通用户的 `lsof` / `ps` 可能看不到核心进程，程序会尝试用 `pgrep` 名称回退。

代价：`lsof` 一次约 0.02s CPU，所以**只在面板展开时**跑，并节流到 5s 一次；代理核心每 60s 复核一次。收起成球时不运行连接映射。自检：`./build/NetBall --proxy-test 8`（不用开 GUI，打印剔除前后的总量对比）。

### 菜单栏样式（菜单栏图标 → 菜单栏样式）

| 样式 | 实际尺寸 | 字号 | 适合 |
|---|---|---|---|
| 上下两行 · 小 | 29×19 pt | 8.0 | 最省地方 |
| **上下两行 · 大（默认）** | 34×20 pt | 9.5 | 两行里最大字号，仍比横排窄一半 |
| 横排一行 · 中 | 71×13 pt | 10.0 | 想一行看完 |
| 横排一行 · 大 | 83×15 pt | 12.0 | 字最大最清楚 |
| 只看下行 ↓ | 41×15 pt | 12.0 | 只关心下载 |
| 只看上行 ↑ | 41×15 pt | 12.0 | 只关心上传 |
| 只看总速率 ↕ | 38×15 pt | 12.0 | 只要一个数 |

对照图：`./build/NetBall --snapshot-tray styles.png --demo`（渲染成 PNG，不需要截屏权限）。
所有样式的图标宽度都按模板值固定，数字跳动时不会左右抖；深/浅菜单栏自动适配。

**数值格式保证最多 5 个字符**（含单位）：`0.0K` / `15.5K` / `155K` / `1000K` / `1.2M` / `155M` / `12.3G`——
三位整数时自动去掉小数位，所以任何量级都不会把图标撑爆或被裁掉。自检：

```bash
./build/NetBall --fmt-test          # 打印各量级的实际字符串与长度
./build/NetBall --snapshot-tray k.png --demo --values 155K,286K,441K   # 用指定数值渲染对照图
```

## 显示模式

在**菜单栏**或**菜单栏 + 悬浮球**模式下，把鼠标移到 NetBall 图标上会自动展开主面板；移出图标和面板后自动收起。点击图标仍打开原有设置菜单。

切换模式：菜单栏图标 → **显示模式** → `菜单栏（不显示悬浮球）` / `悬浮球` / `菜单栏 + 悬浮球`。选择会记住；退出时点菜单栏图标 → **退出 NetBall**（悬浮球模式下也可右键球体）。

## 资源占用（本机实测：Apple Silicon / macOS 26）

| 模式 | 采样间隔 | 自身 CPU | nettop CPU | 合计 CPU | 内存 |
|---|---|---|---|---|---|
| **菜单栏（默认）** | 2s | 1.0% | 1.9% | **~2.9%** | 12–13 MB |
| 菜单栏 | 1s | 1.3% | 3.9% | ~5.2% | 13 MB |
| 菜单栏 | 5s | 0.7% | 0.6% | **~1.3%** | 13 MB |
| 悬浮球（收起态，弧线缓动默认开） | 2s | 1.4% | 1.8% | ~3.2% | 12 MB |
| 悬浮球（面板展开时，含代理探测与累计统计） | 2s | 2.1% | 2.2% | ~4.3% | 峰值 86 MB |

复现命令：`./build/NetBall --benchmark 20 --freq 2 --tray`；悬浮球那行是 `--freq 2 --ball`。
面板展开时弧线不参与绘制、缓动也不跑，所以那一行不受影响。

**弧线缓动到底多花多少 CPU（A/B 实测，不是估算）**：同一台机器、同样的采样频率，只切缓动——

| 采样间隔 | 关缓动 `--anim-off --anim-demo` | 开缓动 `--anim-demo` | 实际重绘（关 → 开） |
|---|---|---|---|
| 1s | 1.0% | 2.3% | 1.4 → 5.4 次/秒 |
| 2s（默认） | 0.8% | 1.3% | 1.0 → 3.1 次/秒 |

也就是每多一次窗口重绘约 **0.25~0.35% CPU**；纯绘制本身只要 **0.18ms/帧**（`--draw-cost 400`），
大头在窗口合成那一层。按真正的 20fps 折算，默认 2s 档约 **+1%** 自身 CPU——
只有当初"多 12% CPU"估计的 1/5 左右，原因是静态底和文字层已经缓存成位图，
动画每帧只重画两条细弧 + 贴两张图。

> 这组数字出在**这台机器**上，而且本机定时器明显偏慢（20fps 档实测只跑到 ~5 次重绘/秒），
> 所以按"每次重绘 0.25~0.35%"外推，比直接看那个百分比更靠谱。

**代理穿透的开销**：只在面板展开时跑，每 5s 一次 `lsof`（约 0.02s CPU）+ 一次 `curl`（约 0），
折算 **+0.4%~0.6% 自身 CPU**；代理核心每 60s 复核一次（`pgrep` + `lsof`，约 0.04s）。
收起成球时只做核心复核，基本为零。上面"面板展开 1.9%"就是含这套逻辑的实测值。

## 关键设计取舍

**为什么不用 `nettop -l 0` 长驻流式采样**：实测它在两次采样之间忙等，**持续吃掉 1.0~1.4 个 CPU 核**，跟"低资源"完全冲突（`tools/nettop-cost.swift` 可复现：`nettop -l 0 -s 5` 六秒内没输出任何数据，却烧了 125% CPU）。

**实际做法**：按间隔跑一次 **`nettop -l 1` 单发快照**（打印一份就退出），与上一次快照做差分得到速率。单次只要 ~0.018s CPU / ~0.14s wall。

其它细节：

- **自适应频率**：面板展开时 1s，收起/托盘态回到空闲档（默认 2s，菜单可切 1/2/5s）
- **菜单栏图标是自绘的 template 图像**，7 种样式可选（两行/一行/单指标，字号 8~12pt）：`NSStatusItem` 的多行文本渲染不可靠，所以用 `NSImage(size:flipped:)` 手绘两行，`isTemplate = true` 交给系统染色（深/浅菜单栏、高亮态都自动适配）；宽度按模板串 `↓0.0M` 固定，数字变化不会让图标抖动
- **无毛玻璃、无 CoreAnimation 图层、无 XPC**，全部 AppKit 手绘；窗口用 `orderOut` 而不是销毁
- **零系统权限**：不需要屏幕录制、辅助功能、网络扩展；`nettop` 免 sudo 就能出每进程字节数
- **单实例保护**：重复启动会直接退出，不会出现两个菜单栏图标
- **自报开销**：展开面板底部会显示自身 CPU/内存和 nettop 的 CPU 均值，不靠嘴说

## 自检与开发

```bash
./build/NetBall --title-probe 10                     # 逐秒打印菜单栏标题，验证数据链路
./build/NetBall --snapshot-live out.png --after 8    # 用真实流量渲染面板 PNG（不需要截屏权限）
./build/NetBall --snapshot out.png --demo            # 用示例数据渲染实时面板 PNG
./build/NetBall --snapshot stats.png --demo --stats   # 用示例数据渲染累计统计页
./build/NetBall --snapshot ball.png --demo --ball    # 渲染悬浮球
./build/NetBall --snapshot-tray tray.png --demo      # 渲染全部菜单栏样式对照图
./build/NetBall --snapshot-ball ball.png --demo      # 渲染两种悬浮球样式对照图
./build/NetBall --fmt-test                           # 检查数值格式化长度（防止图标被裁）
./build/NetBall --ease-test                          # 弧线缓动自检：0.4s / 8 帧 / 单调不回跳 / 收敛停表
./build/NetBall --proxy-test 8                       # 代理穿透自检：剔除前后的总量对比 + 「代理」标
./build/NetBall --stats-test                         # 累计统计：合并、排序、重置与格式自检
./build/NetBall --draw-cost 400                      # 单帧纯绘制成本（drawCount 对账，防止量到假数）
./build/NetBall --benchmark 24 --freq 1 --ball --anim-demo [--anim-off]   # 缓动的端到端 A/B
./build/NetBall --benchmark 20 --freq 2 [--tray|--ball] [--paused] [--collapse-after 10]
./build/nettop-cost                                  # 对比 nettop 各参数组合的开销
```

源码结构：单文件 `main.swift`（采样器 / 手绘视图 / 控制器 / 自检模式）+ `Info.plist` + `build.sh`。

## 开机自启

```bash
./install-autostart.sh      # 写入 ~/Library/LaunchAgents/local.netball.plist 并加载
```

卸载自启项：

```bash
launchctl unload "$HOME/Library/LaunchAgents/local.netball.plist"
rm "$HOME/Library/LaunchAgents/local.netball.plist"
```

注意：自启 plist 里记的是 **当前这份 NetBall.app 的绝对路径**，移动目录后需要重新执行安装脚本。

## 已知限制

- 进程名沿用 nettop 的截断规则（例如 `Google Chrome H` 其实是 Chrome 的 Helper 进程）；周期统计按进程名合并同名 PID，列表可滚动查看
- 累计统计只在本次运行中保留，从启动或手动重置开始；退出/重启应用后不持久化
- 总速率 = 各进程增量之和；生命周期极短的进程可能漏计
- 菜单栏图标没出现？macOS 26 新增了「系统设置 → 菜单栏」隐私开关。程序启动 2.5 秒后会自检，若图标不可见会**自动回退成「菜单栏 + 悬浮球」**，避免变成一个看不见也关不掉的隐形进程
- 未做「鼠标穿透」：一旦开启就只能靠辅助功能权限或改配置文件关掉，风险大于收益，所以没做
- **代理识别不是通用适配**：控制器只探测上文列出的固定端点，API 请求不带 secret/token；进程名回退清单虽含 `sing-box`、`xray`、`v2ray`、`hysteria`、`tuic` 等名称，但不含 `Surge`。端点、鉴权或进程名不匹配时，可能无法剔除代理核心、标记连接或校正总速率；不要据此假设使用其他代理时总量一定准确。
- 悬浮球位置、模式、采样频率通过 `UserDefaults`（`local.netball`）持久化；若通过本仓库外的沙箱进程启动，写偏好可能被拦（正常用 `open` / Finder 启动不受影响）
