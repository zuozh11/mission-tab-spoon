# MissionTab

**给 macOS 调度中心加上 `⌘Tab` 操作方式。**

MissionTab 是一个 [Hammerspoon](https://www.hammerspoon.org/) Spoon：短按保留应用切换，长按进入系统原生调度中心，用键盘选择窗口，松开 Command 确认。

## 操作方式

| 操作 | 行为 |
| --- | --- |
| 短按 `⌘Tab` | 原生应用切换 |
| 按 `⌘Tab`，松开 Tab，继续按住 Command | 进入调度中心，从鼠标指向的窗口开始选择 |
| Tab | 顺时针选择下一个窗口或应用组 |
| 反引号 / Shift+Tab | 按相反方向选择 |
| 松开 Command | 退出调度中心，激活选中窗口 |
| Esc | 取消并返回原窗口 |
| 移动鼠标 | 隐藏选中框，保留调度中心并改用鼠标选择；松开 Command 确认 |
| 再按导航键 | 恢复键盘选择与选中框 |
| 调度中心已打开、没有活动切换会话时按 `⌘Tab` | 直接退出调度中心 |

### 应用组与导航顺序

堆叠的同应用窗口作为一个整体参与顺时针循环。Tab 在组内按屏幕位置**从上到下**访问，走完再进入下一组；反引号完整反向。没有堆叠的窗口独立参与循环。

每次开始键盘选择时，只纳入鼠标所在屏幕的窗口，优先选中鼠标指向的调度中心缩略图；没有命中时，从最靠近布局左上角的应用组开始顺时针循环。首次导航键选中起点，后续按键继续循环；组内仍从上到下。鼠标移到另一屏后再按导航键，会重新选择当前屏幕和起点。

缩略图出现后就显示青色选中框，并在动画中跟随目标。布局稳定后固定本次导航顺序。松开 Command 后退出调度中心，再按窗口 ID 聚焦目标。

插件读取鼠标位置以确定屏幕和起点，但不改变位置、不发送鼠标事件。鼠标接管后保持 Command 释放监听，再按导航键从当前鼠标目标重新开始。自绘框不会把堆叠中的目标缩略图提到最前，退出后聚焦可能出现短暂过渡。

## 环境要求

- macOS 与已安装的 Hammerspoon；当前开发和使用环境为 **macOS 27.0、Hammerspoon 1.1.1**。
- 在系统设置中为 Hammerspoon 开启**辅助功能**权限。
- 退出同样绑定 `⌘Tab` 的 AltTab 等切换器，避免争抢输入。
- 自动安装脚本需要 Python 3；手动安装不需要。

MissionTab 使用 Hammerspoon 自带模块，不依赖额外 Lua 包。其他 macOS 版本和多显示器环境尚未实机确认，详见 [兼容性与限制](#兼容性与限制)。

## 安装

### 从仓库安装

取得仓库内容后，在项目目录执行：

```sh
./scripts/install.sh
```

脚本会：

1. 将 `MissionTab.spoon` 复制到 `~/.hammerspoon/Spoons/`。
2. 在已有安装和需要修改的配置旁创建 `.backup-时间戳` 备份。
3. 在 `~/.hammerspoon/init.lua` 中添加带标记的启动块；已有标记时不重复添加。

完成后，从 Hammerspoon 菜单选择 **Reload Config**。

### 手动安装

将本仓库中的 `MissionTab.spoon` 文件夹放入 `~/.hammerspoon/Spoons/`，再向 `~/.hammerspoon/init.lua` 添加：

```lua
hs.loadSpoon('MissionTab'):start()
```

然后选择 **Reload Config**。如果自行使用其他配置目录，请采用手动安装。

## 配置

需要调整手感时，用下面的内容替换原有启动块，不要重复添加多个启动块：

```lua
hs.loadSpoon('MissionTab')
spoon.MissionTab.holdDelay = 0.18
spoon.MissionTab.hoverDelay = 0.25
spoon.MissionTab:start()
```

| 设置 | 默认值 | 说明 |
| --- | --- | --- |
| `holdDelay` | `0.18` 秒 | 从第一次 Tab 按下开始计时；Tab 松开且 Command 仍按住后才进入调度中心 |
| `hoverDelay` | `0.25` 秒 | 选中框最后一次更新到确认之间的最短等待；沿用旧配置名，不依赖悬停 |
| `openTimeout` | `1.5` 秒 | 等待调度中心暴露稳定窗口布局的期限 |
| `closeTimeout` | `1.5` 秒 | 等待调度中心退出的期限 |
| `reverseKeyCode` | 当前布局的反引号键 | 可指定 Hammerspoon 虚拟键码；无法解析布局时使用键码 `50` |

配置文件修改后选择 **Reload Config**。若在控制台直接修改设置，可执行 `spoon.MissionTab:stop():start()`。

## 停用、卸载与排查

临时停用，在 Hammerspoon 控制台执行：

```lua
spoon.MissionTab:stop()
```

重新启用：

```lua
spoon.MissionTab:start()
```

永久卸载：先停用，删除 `init.lua` 中的启动块，再删除 `~/.hammerspoon/Spoons/MissionTab.spoon`，最后 Reload Config。自动安装生成的启动块位于 `-- MissionTab BEGIN` 和 `-- MissionTab END` 之间。

### 查看状态

在控制台执行：

```lua
hs.inspect(spoon.MissionTab:status())
```

返回运行状态、暂停原因及最近一次切换结果。键盘确认会记录目标窗口 ID 和实际焦点窗口 ID。

若调度中心结构不兼容或关闭超时，插件会暂停接管。解决问题后调用 `start()` 重试。Secure Input 开启时暂停，解除后自动恢复。

更多诊断方法和问题反馈所需信息见 [贡献与开发说明](CONTRIBUTING.md)。

## 兼容性与限制

- 只选择本次调度中心中展示的窗口，不遍历其他桌面，也不恢复最小化窗口。
- 使用系统内部的辅助功能结构和 `hs.spaces`，macOS 更新可能需要重新适配。
- 当前主要适配 macOS 27 的 WindowManager 结构；保留 Dock 旧结构的读取路径，但不宣称旧系统已实机通过。
- 窗口组通过应用/桌面标识及缩略图重叠关系识别。自绘框可以标记重叠目标，但不会改变系统缩略图层叠顺序。
- 早期版本进行过自动化和实机验证，后续交互迭代由用户试用验证；这些结果不代表当前版本已完成全量回归。具体范围见 [验证记录](docs/verification.md)。

## 项目文档

- [版本记录](CHANGELOG.md)
- [贡献与开发说明](CONTRIBUTING.md)
- [技术调研与设计演进](docs/research-and-plan.md)
- [验证记录](docs/verification.md)

## 许可证

[MIT](LICENSE)。
