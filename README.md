# 个人工作台 iPhone App

独立 SwiftUI 应用，最低支持 iOS 17。使用已部署的 `https://dzz.mcdkf.top:7736/api/v1`。登录时输入自己的工作台账号和密码。凭据由设备钥匙串保存，每个请求通过 HTTPS 携带认证信息。

## 在 Mac 上运行

1. 用 Xcode 打开 `Workbench.xcodeproj`，选择 `Workbench` 方案。
2. 选择 iPhone 模拟器，运行 App 并登录。如果用真机，在目标的「Signing & Capabilities」中选择自己的 Team，然后选择已连接的 iPhone 运行。工程的 App ID 为 `top.mcdkf.dzz.workbench`。如需调整 App ID，请同步更新 Apple 开发者配置和服务端推送主题。[Apple 真机安装与签名说明](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices/)

在 `ios` 目录可运行构建和接口模型测试。

```sh
xcodebuild -project Workbench.xcodeproj -scheme Workbench -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
swift test
```

## 首次联调

- **首页与待办**。切换「全部 / 工作 / 生活」，快速记录一条问题，再从详情转为待办。设为「等待中」，分别加截止时间和跟进提醒。打开详情试用「稍后提醒」和「标记完成」。
- **倒计时**。从首页新建，分别填写目标时间和提前提醒，核对列表中的剩余时间和详情。
- **值班**。在值班日历选择「生成 9 天轮值」，预览 2026 年 11 月与 12 月。11 月日期应为 2、11、20、29 日，12 月日期应为 8、17、26 日。调动单次班次后，检查默认提醒是否改到新班次的前一天 20:00。日历按北京时间显示。
- **资料与附件**。在记录或待办详情试用从文件上传、选照片或拍照。点开附件可预览或经分享菜单保存原件。资料页可搜索项目、文档、记事、论文和奖项。

## 启用实际 iPhone 提醒

工程默认允许先构建和联调数据功能。启用锁屏推送时，在 Xcode 为目标开启 Push Notifications，用有该能力的 App ID 签名，并在目标的 Build Settings 设置：

| 设置 | 值 |
| --- | --- |
| `WORKBENCH_APNS_ENABLED` | `YES` |
| `WORKBENCH_PUSH_ENTITLEMENTS` | `Workbench/Workbench.entitlements` |
| `WORKBENCH_APNS_ENVIRONMENT` | 与签名配置一致，Debug 默认 `development`，Release 默认 `production` |

后端维护指南在 `../backend/README.md`。服务端需要为同一个 App ID 配置推送凭据并启动提醒进程。真机在「我的」中开启 iPhone 提醒后，点击通知应打开对应待办、倒计时或班次。验收时用移动数据和锁屏测试。[Apple 的 APNs 注册说明](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)
