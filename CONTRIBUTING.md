# 贡献与开发

欢迎反馈问题、改进交互或补充系统兼容性信息。

## 反馈问题

请尽量提供：

- macOS 版本及构建号、Hammerspoon 版本、MissionTab 版本。
- 显示器数量，是否开启“按应用程序分组窗口”。
- 是否同时使用其他窗口切换器或键盘映射工具。
- 可复现的按键顺序、预期行为和实际行为。
- `spoon.MissionTab:status()` 的输出，以及相关 Hammerspoon 日志。

窗口标题、截图和日志可能包含个人内容，分享前请自行删去无关信息。

## 项目结构

```text
MissionTab.spoon/
  init.lua             输入监听、鼠标定位、异步流程与生命周期
  session.lua          不依赖 Hammerspoon 的键盘状态机
  mission_control.lua  AX 窗口枚举、分组排序与可见区域计算
scripts/
  install.sh           安装并添加启动配置
  test.sh              自动化测试入口
  live-smoke.lua       桌面交互测试驱动
tests/                状态机、控制器及几何相关测试
docs/                 调研与验证记录
```

## 本地开发

安装脚本复制的是当前文件，不是符号链接。修改代码后再次执行 `./scripts/install.sh`，然后 Reload Config，才会载入新版本。

可以从 Hammerspoon 控制台读取版本：

```lua
spoon.MissionTab.version
```

### 自动化测试

项目保留了开发期间的测试，可在安装了 Python 3、运行中 Hammerspoon 和 `hs` CLI 的环境下手动执行：

```sh
./scripts/test.sh
```

CLI 可在 Hammerspoon 控制台中用 `hs.ipc.cliInstall()` 安装。测试通过 Hammerspoon 的 Lua 运行时执行；控制器测试使用模拟系统边界，不需要操作桌面。

**测试并未随所有交互迭代同步更新。** 测试中仍可能包含历史版本的行为预期，例如鼠标接管结束会话和逐窗口排序。修改相关功能时，应按 README 中的当前行为更新对应预期；不要把旧断言数量作为当前版本通过证明。

### 实机测试与 AX 诊断

桌面测试会移动指针、打开调度中心并切换窗口。先停用已加载的 MissionTab，避免两个实例同时监听：

```lua
spoon.MissionTab:stop()
```

将以下路径替换为项目的绝对路径，再从终端调用：

```sh
hs -c 'dofile("/absolute/path/to/mission-tab-spoon/scripts/live-smoke.lua")'
```

通过 `missionTabSmoke.results` 查看结果。该驱动也保留了部分历史行为判断，结果应结合当前版本人工判断。

要查看调度中心实际暴露的窗口，先手动打开调度中心，再从终端读取：

```sh
hs -c 'return hs.inspect(spoon.MissionTab:diagnose())'
```

该入口返回窗口 ID 和缩略图坐标，不输出窗口标题。

## 提交改动

让一个提交对应一项完整行为或修复，并更新受影响的使用说明。涉及操作顺序时说明清楚触发方式、选择规则、确认和取消行为；涉及兼容性时注明实际使用的系统环境与尚未覆盖的范围。

不要在事件监听回调中阻塞等待动画。Mission Control 的辅助功能元素只在显示期间有效；确认前需要使用当前元素和坐标。

## 版本与打包

版本号位于 `MissionTab.spoon/init.lua`。准备版本时，先更新代码、README 和 CHANGELOG，再提交并在该提交上创建对应版本标签。

安装包为包含 `MissionTab.spoon/` 目录的 ZIP。打包目录 `dist/` 不纳入 Git；需要发布时单独上传安装包，不把本地安装配置或备份加入仓库。

项目使用 [MIT 许可证](LICENSE)。
