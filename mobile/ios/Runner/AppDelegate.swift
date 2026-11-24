import Flutter
import HealthKit
import MessageUI
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, MFMessageComposeViewControllerDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Lets reminder notifications appear while NOVA Health is open.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    let healthKit = FlutterMethodChannel(name: "nova_health/healthkit", binaryMessenger: messenger)
    healthKit.setMethodCallHandler { call, result in
      guard call.method == "isHealthDataAvailable" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(HKHealthStore.isHealthDataAvailable())
    }
    let channel = FlutterMethodChannel(
      name: "nova_health/emergency",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "openSms" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self,
            let arguments = call.arguments as? [String: String],
            let phone = arguments["phone"],
            let body = arguments["body"] else {
        result(false)
        return
      }
      self.openSms(phone: phone, body: body, result: result)
    }
  }

  private func openSms(phone: String, body: String, result: @escaping FlutterResult) {
    guard phone.range(of: #"^\+?[0-9]{7,15}$"#, options: .regularExpression) != nil,
          MFMessageComposeViewController.canSendText(),
          let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?.keyWindow,
          var presenter = window.rootViewController else {
      result(false)
      return
    }
    while let next = presenter.presentedViewController {
      presenter = next
    }
    guard presenter.viewIfLoaded?.window != nil,
          !presenter.isBeingDismissed,
          !(presenter is MFMessageComposeViewController) else {
      result(false)
      return
    }
    let composer = MFMessageComposeViewController()
    composer.recipients = [phone]
    composer.body = body
    composer.messageComposeDelegate = self
    presenter.present(composer, animated: true) {
      result(composer.presentingViewController != nil)
    }
  }

  func messageComposeViewController(
    _ controller: MFMessageComposeViewController,
    didFinishWith result: MessageComposeResult
  ) {
    controller.dismiss(animated: true)
  }
}
