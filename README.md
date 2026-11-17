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
