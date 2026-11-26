# Life Mem

Life Mem 是一个 iPhone 路线记录工具。点「开始记录」，锁屏后可以继续采集。点「暂停记录」即停止采集，并可以回看当前路线。继续记录会开启新的一段。已保存的轨迹可以在「回顾」中按天查看，重新打开 App 后也可以找回中断的记录。

项目的代码职责、数据保护和变更验收约定见 [工程规范](AGENTS.md)。

## 在 iPhone 上测试

1. 用 Xcode 打开 `LifeMem.xcodeproj`。在 **Signing & Capabilities** 为 `LifeMem` 目标选择自己的团队，并启用自动签名。需要时设置唯一的 Bundle ID。
2. 选中已配对且启用了开发者模式的 iPhone，运行 `LifeMem`。App 目标支持 iOS 17 或更新版本。
3. 点「开始记录」，授予使用期间的定位权限并保留精确位置。允许「运动与健身」可以更好地识别步行、骑行和乘车。
4. 锁屏步行一段并中途停留，再解锁、暂停、回看路线。另一次以乘客身份测试乘车，在抵达后比对两种模式和路线覆盖情况。恢复记录后应出现新路线段，关掉 App 再打开应能查到已保存的轨迹。

## 自适应采样

App 使用系统定位和运动识别，按运动状态设置定位精度与距离门槛。下表是本项目的初始参数。系统按可用的定位信号和设备状态决定何时交付坐标。

| 状态 | 距离门槛 | 记录行为 |
| --- | --- | --- |
| 步行 | 8 米 | 保留较短的移动和转弯 |
| 乘车 | 30 米 | 用较大的距离间隔记录快速移动 |
| 骑行 | 15 米 | 使用介于步行和乘车之间的间隔 |
| 静止 | 无 | 降低定位精度，停留期间最多每 30 秒保存一个有效定位点，用于显示时间范围 |
| 未识别 | 10 米 | 在运动信息不足时，根据连续且可靠的定位速度尝试分类 |

## 回顾

- 「时间线」按设备日历汇总已记录的日期，跨午夜的路线分日显示。点进某天可看到当天轨迹、行程和停留。点一趟行程可单独看它的路线、起终点和方向，展开「活动片段」可以查看具体的活动与时间。暂停恢复或有效坐标相隔超过 90 秒时，地图按原有分段留出断口。
- 「地点」只汇总有连续静止记录的停留。首版要求观测到至少 5 分钟，定位点与停留起点相距不超过 100 米。相距约 100 米以内的停留合并为一处，点进地点可查看历次到访并跳回对应日期。跨午夜的连续停留在两天的时间线上各显示当日观测到的部分，在地点里计为一次到访。

轨迹数据库保存在 App 的本机目录，禁用自动云同步和云备份。地图回看由 Apple MapKit 提供。可在「回顾」右上角打开「管理记录」，向左滑动删除一条已结束的原始记录及其各日轨迹。

## 本地检查

在装有完整 Xcode 的 Mac 上，从仓库根目录运行以下命令。如果当前开发者目录指向 Command Line Tools，可以先在当前终端运行 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，并按实际安装位置调整路径。

### 路线回归检查

覆盖自适应采样、活动分段、按日切分、中断、停留分组、重开数据库后的持久性及删除行为。

```sh
mkdir -p DerivedData
xcrun swiftc -parse-as-library LifeMem/Routes.swift tests/RouteChecks.swift -o DerivedData/route-checks
./DerivedData/route-checks
```

### 模拟器构建

使用共享的 `LifeMem` scheme 检查 iOS App 能否编译。此命令无需启动模拟器或配置签名。

```sh
xcodebuild -project LifeMem.xcodeproj -scheme LifeMem -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData/simulator CODE_SIGNING_ALLOWED=NO build
```
