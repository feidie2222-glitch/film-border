import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var server: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "胶片边框"
        window.center()
        window.delegate = self
        let text = NSTextField(wrappingLabelWithString: "胶片边框正在浏览器中运行。\n关闭此窗口即可退出程序。")
        text.frame = NSRect(x: 28, y: 72, width: 364, height: 54)
        window.contentView?.addSubview(text)
        let button = NSButton(title: "退出", target: self, action: #selector(quit))
        button.frame = NSRect(x: 308, y: 22, width: 80, height: 30)
        window.contentView?.addSubview(button)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        guard let resources = Bundle.main.resourceURL else { showError("无法找到程序资源"); return }
        let process = Process()
        process.executableURL = resources.appendingPathComponent("node")
        process.arguments = [resources.appendingPathComponent("app/server.js").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); server = process }
        catch { showError("无法启动程序：\(error.localizedDescription)") }
    }

    private func showError(_ message: String) {
        let alert = NSAlert(); alert.messageText = message; alert.runModal()
        NSApp.terminate(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { if server?.isRunning == true { server?.terminate() } }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
