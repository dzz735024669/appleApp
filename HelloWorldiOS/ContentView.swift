//
//  ContentView.swift
//  HelloWorldiOS
//
//  主界面：显示一句 Hello World 和可点击的按钮
//

import SwiftUI

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

#Preview {
    ContentView()
}
