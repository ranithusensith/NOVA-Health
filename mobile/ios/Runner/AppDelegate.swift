import Flutter
import HealthKit
import MessageUI
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, MFMessageComposeViewControllerDelegate {
  private let healthStore = HKHealthStore()

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
    let reportCalendar = FlutterMethodChannel(name: "nova_health/report_calendar", binaryMessenger: messenger)
    reportCalendar.setMethodCallHandler { call, result in
      if call.method == "timeZone" {
        result(TimeZone.autoupdatingCurrent.identifier)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    let healthKit = FlutterMethodChannel(name: "nova_health/healthkit", binaryMessenger: messenger)
    healthKit.setMethodCallHandler { [weak self] call, result in
      if call.method == "isHealthDataAvailable" {
        result(HKHealthStore.isHealthDataAvailable())
        return
      }
      guard call.method == "readSteps" || call.method == "readAsleep" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self, HKHealthStore.isHealthDataAvailable(),
            let arguments = call.arguments as? [String: Any],
            let start = arguments["start"] as? NSNumber,
            let end = arguments["end"] as? NSNumber,
            start.doubleValue < end.doubleValue else {
        result(FlutterError(code: "HEALTH_READ_UNAVAILABLE", message: "Could not read Apple Health.", details: nil))
        return
      }
      let from = Date(timeIntervalSince1970: start.doubleValue / 1_000)
      let to = Date(timeIntervalSince1970: end.doubleValue / 1_000)
      if call.method == "readSteps" {
        self.readSteps(from: from, to: to, result: result)
      } else {
        self.readAsleep(from: from, to: to, result: result)
      }
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

  private func readSteps(from: Date, to: Date, result: @escaping FlutterResult) {
    guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
      result(FlutterError(code: "HEALTH_READ_UNAVAILABLE", message: "Steps unavailable.", details: nil))
      return
    }
    let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
    let query = HKStatisticsCollectionQuery(
      quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum,
      anchorDate: from, intervalComponents: DateComponents(day: 1)
    )
    query.initialResultsHandler = { _, collection, error in
      DispatchQueue.main.async {
        if error != nil {
          result(FlutterError(code: "HEALTH_READ_UNAVAILABLE", message: "Could not read steps.", details: nil))
        } else {
          let quantity = collection?.statistics(for: from)?.sumQuantity()
          let value = quantity?.doubleValue(for: HKUnit.count())
          result(value.flatMap { $0.isFinite && $0 >= 0 && $0 <= 1_000_000 ? Int($0.rounded()) : nil })
        }
      }
    }
    healthStore.execute(query)
  }

  private func readAsleep(from: Date, to: Date, result: @escaping FlutterResult) {
    guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
      result(FlutterError(code: "HEALTH_READ_UNAVAILABLE", message: "Sleep unavailable.", details: nil))
      return
    }
    let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
    let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 20_001, sortDescriptors: nil) {
      _, samples, error in
      DispatchQueue.main.async {
        guard error == nil, let samples = samples as? [HKCategorySample], samples.count <= 20_000 else {
          result(FlutterError(code: "HEALTH_READ_UNAVAILABLE", message: "Could not read sleep.", details: nil))
          return
        }
        let intervals: [[String: Int64]] = samples.compactMap { sample in
          let asleep: Bool
          if #available(iOS 16.0, *) {
            asleep = [HKCategoryValueSleepAnalysis.asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM]
              .contains { $0.rawValue == sample.value }
          } else {
            asleep = sample.value == HKCategoryValueSleepAnalysis.asleep.rawValue
          }
          guard asleep else { return nil }
          return [
            "start": Int64(sample.startDate.timeIntervalSince1970 * 1_000),
            "end": Int64(sample.endDate.timeIntervalSince1970 * 1_000),
          ]
        }
        result(intervals)
      }
    }
    healthStore.execute(query)
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
