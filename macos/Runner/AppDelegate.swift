import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Без этого macOS усыпляет Знайку (App Nap), когда её окно за другими — а во время созвона
  /// оно почти всегда за Zoom: расшифровка на лету отставала от записи на десятки секунд,
  /// медленнее писались и заметки. Работа идёт в фоне по команде пользователя, поэтому —
  /// userInitiated; системе засыпать не мешаем.
  private var activity: NSObjectProtocol?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    activity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "Запись и расшифровка встреч, заметки")
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
