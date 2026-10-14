import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // Уже 556 pt macos_ui прячет боковую панель — окно не даём сузить до этого.
    self.contentMinSize = NSSize(width: 640, height: 440)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerFilesChannel(messenger: flutterViewController.engine.binaryMessenger)
    // `znaika/system`:
    // - `physicalMemory` — объём памяти Mac в байтах (по нему выбирается рекомендованная
    //   модель для заметок);
    // - `showAbout` — стандартное окно «О приложении» с автором и ссылкой на LinkedIn;
    // - `fitHeight(height)` — высота окна под содержимое (экран первого запуска), если
    //   окно такой высоты помещается в рабочую область экрана; иначе размер не меняется.
    FlutterMethodChannel(name: "znaika/system", binaryMessenger: flutterViewController.engine.binaryMessenger)
      .setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "physicalMemory":
          result(Int(ProcessInfo.processInfo.physicalMemory))
        case "showAbout":
          MainFlutterWindow.showAbout()
          result(nil)
        case "fitHeight":
          guard let self, let height = (call.arguments as? [String: Any])?["height"] as? Double else {
            result(false)
            return
          }
          result(self.fitHeight(CGFloat(height)))
        default:
          result(FlutterMethodNotImplemented)
        }
      }

    super.awakeFromNib()
  }

  /// Окно «О приложении»: название, версия и копирайт — из Info.plist, ниже — автор.
  private static func showAbout() {
    let center = NSMutableParagraphStyle()
    center.alignment = .center
    let base: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: center,
    ]
    let credits = NSMutableAttributedString(string: "Автор: Boris Rozumniuk\n", attributes: base)
    var link = base
    link[.link] = URL(string: "https://www.linkedin.com/in/rozumnyuk/")!
    credits.append(NSAttributedString(string: "linkedin.com/in/rozumnyuk", attributes: link))
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Высота окна под содержимое: верхний край остаётся на месте, окно целиком
  /// в рабочей области экрана (без строки меню и Dock). Не помещается — false.
  private func fitHeight(_ height: CGFloat) -> Bool {
    guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return false }
    // Содержимое Flutter занимает всё окно, включая прозрачный заголовок.
    let target = max(height.rounded(.up), minSize.height)
    if target > visible.height { return false }
    var frame = self.frame
    frame.origin.y = frame.maxY - target
    frame.size.height = target
    if frame.minY < visible.minY { frame.origin.y = visible.minY }
    if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - target }
    setFrame(frame, display: true, animate: false)
    return true
  }

  /// Канал `znaika/files`: действия с файлами, которые в macOS делаются через AppKit.
  /// - `trash(path)` — переместить в Корзину (встречу можно вернуть, как в Finder);
  /// - `saveText(name, text)` — стандартная панель «Сохранить» листом на окне;
  ///   возвращает путь сохранённого файла или nil, если пользователь отменил.
  private func registerFilesChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "znaika/files", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "trash":
        guard let path = args["path"] as? String else {
          result(FlutterError(code: "args", message: "нужен path", details: nil))
          return
        }
        do {
          try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
          result(nil)
        } catch {
          result(FlutterError(code: "trash", message: error.localizedDescription, details: nil))
        }
      case "saveText":
        guard let self, let name = args["name"] as? String, let text = args["text"] as? String else {
          result(FlutterError(code: "args", message: "нужны name и text", details: nil))
          return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        if let markdown = UTType(filenameExtension: "md") {
          panel.allowedContentTypes = [markdown]
        }
        panel.beginSheetModal(for: self) { response in
          guard response == .OK, let url = panel.url else {
            result(nil)
            return
          }
          do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            result(url.path)
          } catch {
            result(FlutterError(code: "save", message: error.localizedDescription, details: nil))
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
