# Life Mem 工程规范

Life Mem 是面向 iPhone 的路线记录 App，最低支持 iOS 17。日常开发使用仓库共享的 `LifeMem` scheme。本地构建、路线回归和真机配置见 [README](README.md)。

## 代码职责

| 路径 | 职责 |
| --- | --- |
| `LifeMem/LifeMemApp.swift`、`LifeMem/RouteStore.swift` | 应用入口、顶层导航和本机 SwiftData 容器 |
| `LifeMem/RouteModels.swift`、`LifeMem/LocationPoint.swift` | SwiftData 路线模型、值类型定位点和采样规则 |
| `LifeMem/SegmentBuilder.swift`、`LifeMem/TimelineSegment.swift`、`LifeMem/Routes.swift` | 活动分段、时间轴数据、按日投影与地点分组 |
| `LifeMem/SavedPlace.swift` | 本机地点别名及分类 |
| `LifeMem/RouteRecorder.swift` | 记录状态、系统定位与运动回调、保存和中断恢复 |
| `LifeMem/RecordView.swift`、`LifeMem/RouteViews.swift` | 记录、历史与地图界面 |
| `tests/RouteChecks.swift` | 可在 Mac 上运行的路线逻辑与持久化回归检查 |

- 视图调用记录器执行采集操作。采样和分段由 `LocationPoint.swift` 与 `SegmentBuilder.swift` 提供，按日投影和地点分组集中在 `Routes.swift`，保证界面和检查程序使用同一套逻辑。
- Swift 沿用现有风格。使用四空格缩进，类型用 `UpperCamelCase`，方法和属性用 `lowerCamelCase`。将仅供内部使用的成员和辅助类型标为 `private`。采样阈值变更时同步更新 README 中对应的说明。
- 优先使用已有实现和系统框架。引入新依赖、拆分模块或提高最低系统版本时，在变更说明里写明原因及影响。

## 记录状态和本机数据

- 由用户主动开始采集。暂停、定位权限撤销或写入失败时，沿用记录器的状态转换和停止采集路径。调整异步回调时，检查回调是否仍属于当前记录会话。
- 将路线点和对应的点数、距离一起保存。保存失败时回滚本次写入，保留之前已保存的轨迹，并给用户可操作的提示。用户重开 App 后应能找到中断的记录并从暂停状态继续。
- 修改 SwiftData 模型、路线关系或存储位置时，用旧版本生成的合成数据验证升级。确认历史路线仍可回看、未完成路线可恢复、删除路线会关联删除定位点。打开存储失败时保留原数据库。
- 路线原始数据保存在本机，维持现有的 iOS 文件保护、云备份排除和禁用 CloudKit 同步配置。新增数据传输或权限时，先确认用途和用户预期。测试和演示使用合成轨迹。分享日志、截图或提交 PR 前，移除真实坐标、行程时间和签名凭证。

## 变更验证

| 变更 | 验证方式 |
| --- | --- |
| Swift 或 Xcode 工程配置 | 运行 README 中的模拟器构建命令 |
| 采样、活动分类、分段、分组或持久化 | 运行 README 中的路线回归检查，并为变化的行为补充针对性断言 |
| 定位、运动权限、后台采集或记录状态 | 在 iPhone 上验证受影响的路径，例如权限拒绝或撤销、锁屏续录、暂停后停止采集、恢复后新开分段、重开后恢复未完成记录 |
| 记录、历史或地图界面 | 在模拟器或真机走一遍受影响的操作，用合成轨迹检查正常与空状态，按需检查失败提示 |
| 文档 | 检查链接，并核对描述和示例命令是否与当前项目一致 |

变更说明记录实际运行过的检查、结果和待验证场景。涉及后台定位或系统传感器的行为以真机结果为准。

## 开发、PR 与合并

1. 从最新的 `main` 建立独立分支。开发完成后运行适用的检查，用 `git diff --cached` 核对暂存范围，用 `git diff --cached --check` 检查空白错误，然后提交到开发分支。提交标题沿用 `feat:`、`fix:`、`refactor:`、`test:`、`docs:` 等前缀。提交中排除构建产物、本机 Xcode 状态、签名凭证和路线数据库。
2. 推送开发分支，向 `main` 提交 PR，说明改动原因、用户可见行为和实际验证结果。涉及权限、持久化数据或最低系统版本时，注明兼容性影响。
3. PR 创建后，review 最新的 PR 差异并在 PR 上记录结论。发现问题时更新分支，验证并复查最新版本。个人维护时可以记录作者自审。仓库要求的独立批准和状态检查按仓库规则执行。
4. PR review 及适用检查通过后，通过 GitHub 合并 PR，再同步本地 `main`。开发改动统一通过 PR 进入 `main`。
5. 每次 PR 合并后，从同步后的 `main` 构建最新版本，并更新配对的 iPhone。沿用现有 App 的 Bundle ID 和签名团队，用更高的构建号原位安装，以保留本机轨迹。安装后核对 iPhone 上的构建号，并在交付时报告结果。若设备暂时无法连接，报告真机更新待完成。
