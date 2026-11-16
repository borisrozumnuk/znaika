import AVFoundation
import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

class MainFlutterWindow: NSWindow {
  private let player = MeetingAudioPlayer()

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // Уже 556 pt macos_ui прячет боковую панель — окно не даём сузить до этого.
    self.contentMinSize = NSSize(width: 640, height: 440)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerFilesChannel(messenger: flutterViewController.engine.binaryMessenger)
    player.register(messenger: flutterViewController.engine.binaryMessenger)
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
  /// - `saveCopy(name, source)` — то же для копии готового файла (звук встречи);
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
      case "saveCopy":
        guard let self, let name = args["name"] as? String, let source = args["source"] as? String else {
          result(FlutterError(code: "args", message: "нужны name и source", details: nil))
          return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: (name as NSString).pathExtension) {
          panel.allowedContentTypes = [type]
        }
        panel.beginSheetModal(for: self) { response in
          guard response == .OK, let url = panel.url else {
            result(nil)
            return
          }
          do {
            // Панель уже спросила про замену существующего файла.
            if FileManager.default.fileExists(atPath: url.path) {
              try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: url)
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

/// Канал `znaika/player`: прослушивание сжатого звука встречи (audio.m4a) через AVAudioPlayer.
/// Один плеер на окно — открытие другой встречи заменяет прежний.
/// - `open(path)` → длительность в секундах; `close`;
/// - `play`, `pause`, `seek(seconds)`, `rate(rate)` (0,5–2×);
/// - `state` → `{position, duration, playing}` — Dart опрашивает, пока идёт воспроизведение;
/// - `waveform(path, bars)` → громкость по [bars] равным отрезкам записи (RMS, 0…1 от самого
///   громкого) для дорожки-«волны»; считается в фоне, декодирует AAC сам macOS.
final class MeetingAudioPlayer {
  private var player: AVAudioPlayer?

  func register(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "znaika/player", binaryMessenger: messenger).setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "open":
        guard let path = args["path"] as? String else {
          return result(FlutterError(code: "args", message: "нужен path", details: nil))
        }
        self.player?.stop()
        do {
          let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
          player.enableRate = true
          player.prepareToPlay()
          self.player = player
          result(player.duration)
        } catch {
          self.player = nil
          result(FlutterError(code: "open", message: error.localizedDescription, details: nil))
        }
      case "close":
        self.player?.stop()
        self.player = nil
        result(nil)
      case "play":
        result(self.player?.play() ?? false)
      case "pause":
        self.player?.pause()
        result(nil)
      case "seek":
        if let player = self.player, let seconds = args["seconds"] as? Double {
          player.currentTime = max(0, min(seconds, player.duration))
        }
        result(nil)
      case "rate":
        if let rate = args["rate"] as? Double { self.player?.rate = Float(max(0.5, min(rate, 2))) }
        result(nil)
      case "waveform":
        guard let path = args["path"] as? String, let bars = args["bars"] as? Int, bars > 0 else {
          return result(FlutterError(code: "args", message: "нужны path и bars", details: nil))
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let levels = Self.waveform(URL(fileURLWithPath: path), bars: bars)
          DispatchQueue.main.async { result(levels) }
        }
      case "state":
        guard let player = self.player else { return result(nil) }
        result(["position": player.currentTime, "duration": player.duration, "playing": player.isPlaying])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// RMS громкости по [bars] отрезкам, нормированная к самому громкому; nil — не прочитать.
  private static func waveform(_ url: URL, bars: Int) -> [Double]? {
    guard let file = try? AVAudioFile(forReading: url), file.length > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16)
    else { return nil }
    let total = file.length
    var sums = [Double](repeating: 0, count: bars)
    var counts = [Int](repeating: 0, count: bars)
    var frame: Int64 = 0
    while file.framePosition < total {
      guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0,
            let samples = buffer.floatChannelData?[0] else { break }
      for i in 0..<Int(buffer.frameLength) {
        let bar = min(bars - 1, Int((frame + Int64(i)) * Int64(bars) / total))
        let x = Double(samples[i])
        sums[bar] += x * x
        counts[bar] += 1
      }
      frame += Int64(buffer.frameLength)
    }
    let rms = zip(sums, counts).map { $1 > 0 ? ($0 / Double($1)).squareRoot() : 0 }
    let peak = rms.max() ?? 0
    return peak > 0 ? rms.map { $0 / peak } : rms
  }
}
