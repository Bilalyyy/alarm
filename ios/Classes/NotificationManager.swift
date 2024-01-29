//
//  NotificationManager.swift
//  
//
//  Created by Bilal Larose on 27/01/2024.
//
import UserNotifications


/// A singleton class responsible for managing notifications in the application.
final class NotificationManager {

    /// The shared instance of NotificationManager.
    static let shared = NotificationManager()

    /// Indicates whether an observer for app termination notification has been added.
    var observerAdded = false

    /// The notification center instance for managing notifications.
    private let center = UNUserNotificationCenter.current()

    /// Private initializer to prevent direct instantiation of the class.
    private init() {}

    /// Schedules a notification with the specified parameters.
    /// - Parameters:
    ///   - id: The unique identifier for the notification..
    ///   - delayInSeconds: The delay time in seconds before displaying the notification.
    ///   - title: The title of the notification.
    ///   - body: The body content of the notification.
    func scheduleNotification(id: Int, delayInSeconds: Double, title: String?, body: String?) {
        guard let title && let body && delayInSeconds >= 1.0  else { return }

        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                let content = UNMutableNotificationContent()
                content.title = title ?? "Alarm"
                content.body = body ?? "Wake up!"
                content.sound = nil

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(Int(floor(delayInSeconds))),
                                                                repeats: false)
                let request = UNNotificationRequest(identifier: "alarm-\(id)", content: content, trigger: trigger)

                center.add(request) { error in
                    if let error = error {
                        NSLog("NotificationManager: Error scheduling notification: \(error.localizedDescription)")
                    }
                }
            } else {
                NSLog("NotificationManager: Notification permission denied")
            }
        }
    }
    
    /// Displays a notification when the app is terminated.
    /// - Parameters:
    ///   - title: The title of the notification.
    ///   - body: The body content of the notification.
    func notificationOnAppKill(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(identifier: "notification on app kill", content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { (error) in
            if let error {
                NSLog("SwiftAlarmPlugin: Failed to show notification on kill service => error: \(error.localizedDescription)")
            } else {
                NSLog("SwiftAlarmPlugin: Trigger notification on app kill")
            }
        }
    }

    /// Cancels the scheduled notification with the specified identifier.
    /// - Parameter id: The identifier of the notification to be canceled.
    func cancelNotification(id: Int) {
        center.removePendingNotificationRequests(withIdentifiers: ["alarm-\(id)"])
    }

    /// Registers an observer for app termination notification.
    /// - Parameters:
    ///  - observer: The object registering as an observer.
    ///  - selector: The selector to be called when the notification is received.
    func registerForAppTerminationNotification(observer: AnyObject, selector: Selector) {
        guard !observerAdded else { return }
        observerAdded = true
        NotificationCenter.default.addObserver(observer, selector: selector, name: UIApplication.willTerminateNotification, object: nil)
    }

    /// Removes the app termination notification observer.
    /// - Parameter observer: The object to be removed as an observer.
    func removeAppTerminationNotificationObserver(observer: AnyObject) {
        guard observerAdded else { return }
        observerAdded = false
        NotificationCenter.default.removeObserver(observer, name: UIApplication.willTerminateNotification, object: nil)
    }
}
