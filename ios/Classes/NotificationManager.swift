//
//  NotificationManager.swift
//  
//
//  Created by Bilal Larose on 27/01/2024.
//
import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()

    var observerAdded = false

    private let center = UNUserNotificationCenter.current()

    private init() {}

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

    func notificationOnAppKill(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(identifier: "notification on app kill", content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { (error) in
            if let error = error {
                NSLog("SwiftAlarmPlugin: Failed to show notification on kill service => error: \(error.localizedDescription)")
            } else {
                NSLog("SwiftAlarmPlugin: Trigger notification on app kill")
            }
        }
    }

    func cancelNotification(id: Int) {
        center.removePendingNotificationRequests(withIdentifiers: ["alarm-\(id)"])
    }

    func registerForAppTerminationNotification(observer: AnyObject, selector: Selector) { // used 201 && 93
        guard !observerAdded else { return }
        observerAdded = true
        NotificationCenter.default.addObserver(observer, selector: selector, name: UIApplication.willTerminateNotification, object: nil)
    }

    func removeAppTerminationNotificationObserver(observer: AnyObject) { //use 316 && 385
        guard observerAdded else { return }
        observerAdded = false
        NotificationCenter.default.removeObserver(observer, name: UIApplication.willTerminateNotification, object: nil)
    }
}
