//
//  NotificationManager.swift
//  
//
//  Created by Bilal Larose on 27/01/2024.
//
import UserNotifications

class NotificationManager {
    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()

    private init() {}

    func scheduleNotification(id: String, delayInSeconds: Int, title: String, body: String) {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = nil

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(delayInSeconds), repeats: false)
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

    func cancelNotification(id: String) {
        center.removePendingNotificationRequests(withIdentifiers: ["alarm-\(id)"])
    }

    func registerForAppTerminationNotification(observer: AnyObject, selector: Selector) { // used 201 && 93
        NotificationCenter.default.addObserver(observer, selector: selector, name: UIApplication.willTerminateNotification, object: nil)
    }

    func removeAppTerminationNotificationObserver(observer: AnyObject) { //use 316 && 385
        NotificationCenter.default.removeObserver(observer, name: UIApplication.willTerminateNotification, object: nil)
    }
}
