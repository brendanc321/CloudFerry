import AppKit

// 构建期图标生成：由已编译的二进制渲染 iconset（绕开 swift 解释器的 Xcode 许可限制）
if let iconDir = ProcessInfo.processInfo.environment["CLOUDFERRY_MAKEICON"] {
    writeIconset(to: iconDir)
    exit(0)
}

// 调试：把菜单栏模板图标的 4 种状态渲染成 PNG（36px），用于检查
if let dir = ProcessInfo.processInfo.environment["CLOUDFERRY_MAKEGLYPHS"] {
    MainActor.assumeIsolated {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, st) in [("idle", MenuBarState.idle), ("active", .active), ("paused", .paused), ("failed", .failed)] {
            guard let img = menuBarGlyph(st),
                  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            img.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
    exit(0)
}

// 可选：用环境变量覆盖启动语言（不写入偏好设置）
if let l = ProcessInfo.processInfo.environment["CLOUDFERRY_LANG"], let lang = Language(rawValue: l) {
    Loc.current = lang
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
