//
//  WatchAppDelegate.swift
//  BioKernelWatch Watch App
//
//  Created by Sam King on 12/10/24.
//

/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The delegate of the watchOS app.
*/

import WatchKit
import WatchConnectivity

class WatchAppDelegate: NSObject, WKApplicationDelegate {

    var sessionDelegator: SessionDelegator = SessionDelegator()

    // Hold the KVO observers to keep observing the change in the extension's lifetime.
    //
    private var activationStateObservation: NSKeyValueObservation?
    private var hasContentPendingObservation: NSKeyValueObservation?

    // An array to keep the background tasks.
    //
    private var wcBackgroundTasks = [WKWatchConnectivityRefreshBackgroundTask]()
    
    override init() {
        super.init()
        assert(WCSession.isSupported(), "This sample requires a platform supporting Watch Connectivity!")
                
        // Apps must complete WKWatchConnectivityRefreshBackgroundTask. Otherwise, tasks keep consuming
        // the background executing time and eventually cause a crash.
        // The timing to complete the tasks is when the current WCSession turns to a state other than .activated
        // or hasContentPending flips false (see completeBackgroundTasks), so use KVO to observe
        // the changes of the two properties.
        //
        activationStateObservation = WCSession.default.observe(\.activationState) { _, _ in
            DispatchQueue.main.async {
                self.completeBackgroundTasks()
            }
        }
        hasContentPendingObservation = WCSession.default.observe(\.hasContentPending) { _, _ in
            DispatchQueue.main.async {
                self.completeBackgroundTasks()
            }
        }

        // Activate the session asynchronously as early as possible.
        // When the system needs to launch the app to run a background task, this saves some background runtime budget.
        //
        WCSession.default.delegate = sessionDelegator
        WCSession.default.activate()
    }
    
    // Complete the background tasks, and schedule a snapshot refresh.
    //
    func completeBackgroundTasks() {
        guard !wcBackgroundTasks.isEmpty else { return }

        guard WCSession.default.activationState == .activated,
            WCSession.default.hasContentPending == false else { return }
        
        wcBackgroundTasks.forEach { $0.setTaskCompletedWithSnapshot(false) }
        
        // Use Logger to log tasks for debugging purposes.
        //
        print("WC: \(#function):\(wcBackgroundTasks) was completed!")

        // Schedule a snapshot refresh if the UI is updated by background tasks.
        //
        let date = Date(timeIntervalSinceNow: 1)
        WKApplication.shared().scheduleSnapshotRefresh(withPreferredDate: date, userInfo: nil) { error in
            
            if let error = error {
                print("WC: scheduleSnapshotRefresh error: \(error)!")
            }
        }
        wcBackgroundTasks.removeAll()
    }
    
    // Apps must complete WKWatchConnectivityRefreshBackgroundTask after the pending data is received.
    // This sample retains the tasks first, and complete them in the following cases:
    // 1. hasContentPending flips false, meaning no pending data waiting for processing. Pending data means
    //    the data the device receives prior to when the WCSession gets activated.
    //    More data might arrive, but it isn't pending when the session gets activated.
    // 2. The end of the handle method.
    //    This happens when hasContentPending flips to false before the app retains the tasks.
    //
    
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let wcTask = task as? WKWatchConnectivityRefreshBackgroundTask {
                wcBackgroundTasks.append(wcTask)
                print("WC: \(#function):\(wcTask.description) was appended!")
            } else {
                task.setTaskCompletedWithSnapshot(false)
                print("WC: \(#function):\(task.description) was completed!")
            }
        }
        completeBackgroundTasks()
    }
}
