# HelloWorldiOS

最简单的 iOS App —— 基于 SwiftUI，只有一个显示 "Hello, World!" 的页面和一个可点击的按钮。

## 环境要求

- macOS + Xcode 15 或更高版本
- iOS 16.0+ 模拟器或真机

## 运行方式

1. 双击 `HelloWorldiOS.xcodeproj` 用 Xcode 打开
2. 选择模拟器（如 iPhone 15）
3. 点击 ▶️ 运行（Command + R）

## 项目结构

```
HelloWorldiOS/
├── HelloWorldiOS.xcodeproj
│   └── project.pbxproj      # Xcode 工程配置
└── HelloWorldiOS/
    ├── HelloWorldiOSApp.swift   # @main 应用入口
    └── ContentView.swift        # 主界面
```

## 代码说明

```swift
@main
struct HelloWorldiOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

这是 SwiftUI 应用的入口，`@main` 标记程序起点，`WindowGroup` 承载根视图。

```swift
struct ContentView: View {
    @State private var message = "Hello, World! 👋"

    var body: some View {
        VStack(spacing: 20) {
            Text(message)
                .font(.largeTitle)
                .fontWeight(.bold)

            Button("点我一下") {
                message = "你点击了按钮 😄"
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
```

点击按钮会通过 `@State` 更新 `message`，界面自动刷新。

## CI/CD（Codemagic 自动构建）

仓库已包含 `codemagic.yaml`，在 Codemagic 中选中 `appleApp` 应用后即可触发构建：

1. 进入 Codemagic → Builds，选中 App 为 `appleApp`，点击 **Start new build**
2. 选择分支 `main`，工作流选择 **iOS Simulator Build (无需签名)**
3. 构建完成后，可在构建详情页下载 `HelloWorldiOS.app` 产物

> 说明：当前项目未配置签名证书，因此使用**模拟器构建**（`CODE_SIGNING_ALLOWED=NO`）验证代码可编译。如需打包真机 IPA 上架，需在 Codemagic 中配置 Apple Developer 证书与描述文件后调整 `codemagic.yaml`。
