# MissionTab.spoon

用 macOS 原生调度中心作为键盘窗口切换界面。

- **短按 `⌘Tab`**：保留原生应用切换。
- **松开 Tab，继续按住 Command**：180 ms 后打开调度中心。
- **Tab / 反引号**：按缩略图布局顺时针 / 逆时针选择窗口；Shift+Tab 也为逆时针。
- **松开 Command**：激活选中窗口。
- **Esc**：取消，返回原窗口。
- **移动鼠标或点击**：将调度中心交还给鼠标操作，随后松开 Command 不再自动确认。

长按选择当前调度中心展示的窗口；不会遍历其他桌面或恢复最小化窗口。初始选择优先为最近使用的其他窗口；随后围绕整个缩略图布局的中心按角度顺时针导航。首次用于打开的 Tab 不额外跳过初始窗口，导航顺序在本次切换中保持不变。

## 安装

需要 Hammerspoon 和辅助功能权限。**请先退出同样绑定 `⌘Tab` 的 AltTab 等切换器，避免两个程序争抢输入。**当前实机验证环境为 macOS 27.0（26A428）、Hammerspoon 1.1.1。

在项目目录执行：

```sh
./scripts/install.sh
```

脚本将 Spoon 复制到 `~/.hammerspoon/Spoons/`，为已有版本和配置创建备份，并在 `init.lua` 中加入一个带标记的启动块。随后在 Hammerspoon 菜单中点击 **Reload Config**，或在控制台执行：

```lua
hs.loadSpoon('MissionTab'):start()
```

安装只使用 Hammerspoon 自带模块，无额外 Lua 依赖。

## 调整手感

将安装脚本加入的启动块调整为：

```lua
hs.loadSpoon('MissionTab')
spoon.MissionTab.holdDelay = 0.18
spoon.MissionTab.hoverDelay = 0.25
spoon.MissionTab:start()
```

| 设置 | 默认值 | 含义 |
| --- | --- | --- |
| `holdDelay` | `0.18` 秒 | 从首次 Tab 按下计时的长按阈值；Tab 未松开时不进入 |
| `hoverDelay` | `0.25` 秒 | 指针悬停后至少等待多久再确认 |
| `openTimeout` | `1.5` 秒 | 打开调度中心并取得稳定窗口坐标的期限 |
| `closeTimeout` | `1.5` 秒 | 等待调度中心退出的期限 |
| `reverseKeyCode` | 当前键盘布局的反引号键 | 如键盘布局特殊，可指定 Hammerspoon 虚拟键码 |

重启 Spoon 后设置生效：`spoon.MissionTab:stop():start()`。

## 停用与诊断

立即停用：

```lua
spoon.MissionTab:stop()
```

查看状态与最近一次目标/实际窗口 ID：

```lua
hs.inspect(spoon.MissionTab:status())
```

手动打开调度中心后，从外部 CLI 读取窗口 ID 和缩略图坐标：

```sh
hs -c 'return hs.inspect(spoon.MissionTab:diagnose())'
```

Secure Input 开启时暂停接管，解除后自动恢复。调度中心结构不兼容或关闭超时会暂停接管；解决问题后调用 `start()` 重试。窗口焦点不符会记录日志，不自动补发点击。开启“按应用程序分组窗口”时，导航会使用缩略图露出的区域；没有足够可见区域的目标会取消本次切换，避免激活错误窗口。

永久卸载：删除 `~/.hammerspoon/init.lua` 中 `MissionTab BEGIN` 至 `MissionTab END` 的启动块，再删除 `~/.hammerspoon/Spoons/MissionTab.spoon` 并 Reload Config。备份保留在相邻的 `.backup-时间戳` 路径中。

## 验证

不影响桌面的自动化测试（通过 Hammerspoon 的 Lua 运行时）：

```sh
./scripts/test.sh
```

实机冒烟测试会临时接管 `⌘Tab`、打开调度中心并切换窗口；运行期间保持鼠标静止。已启用的 MissionTab 应先 `stop()`，避免两个实例同时监听。

```sh
hs -c 'dofile("/项目绝对路径/scripts/live-smoke.lua")'
```

结果：`hs.inspect(missionTabSmoke.results)`。扩展连续测试可用 `assert(loadfile("/项目绝对路径/scripts/live-smoke.lua"))({rounds=20})`。测试保留计时器引用，鼠标接管或调度中心未关闭时中止，正常完成后恢复原焦点和指针。

兼容性依据、设计取舍见 [调研与方案](docs/research-and-plan.md)；本轮验证范围见 [验证记录](docs/verification.md)。Dock 旧结构适配保留，但不宣称旧 macOS 已实机通过。
