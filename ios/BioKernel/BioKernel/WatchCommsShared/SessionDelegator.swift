/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Implements the WCSessionDelegate methods.
*/

import Foundation
import WatchConnectivity

// Custom notifications happen when Watch Connectivity activation or reachability status changes,
// or when receiving or sending data. Clients observe these notifications to update the UI.
//
extension Notification.Name {
    static let dataDidFlow = Notification.Name("DataDidFlow")
    static let activationDidComplete = Notification.Name("ActivationDidComplete")
    static let reachabilityDidChange = Notification.Name("ReachabilityDidChange")
}

// Implement WCSessionDelegate methods to receive Watch Connectivity data and notify clients.
// Handle WCSession status changes.
//

@MainActor
public protocol SessionUpdateDelegate: AnyObject {
    func contextDidUpdate(_ context: BioKernelState)
    func didRecieveMessage(at: Date, workoutMessage: WorkoutMessage)
}

class SessionDelegator: NSObject, WCSessionDelegate {
    weak var delegate: SessionUpdateDelegate?
    
    // Monitor WCSession activation state changes.
    //
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        postNotificationOnMainQueueAsync(name: .activationDidComplete)
    }
    
    // Monitor WCSession reachability state changes.
    //
    func sessionReachabilityDidChange(_ session: WCSession) {
        postNotificationOnMainQueueAsync(name: .reachabilityDidChange)
    }
    
    // Did receive an app context.
    //
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        var commandStatus = CommandStatus(command: .updateAppContext, phrase: .received)
        do {
            commandStatus.bioKernelState = try BioKernelState(applicationContext)
        } catch {
            assertionFailure("Error parsing app context: \(error)")
        }
        postNotificationOnMainQueueAsync(name: .dataDidFlow, object: commandStatus)
    }
    
    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        var commandStatus = CommandStatus(command: .sendMessageData, phrase: .received)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        commandStatus.workoutMessage = try? decoder.decode(WorkoutMessage.self, from: messageData)
        
        //commandStatus.timedColor = TimedColor(messageData)
        postNotificationOnMainQueueAsync(name: .dataDidFlow, object: commandStatus)
    }
    
    // WCSessionDelegate methods for iOS only.
    //
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {
        print("\(#function): activationState = \(session.activationState.rawValue)")
    }
    
    func sessionDidDeactivate(_ session: WCSession) {
        // Activate the new session after having switched to a new watch.
        session.activate()
    }
    
    func sessionWatchStateDidChange(_ session: WCSession) {
        print("\(#function): activationState = \(session.activationState.rawValue)")
    }
    #endif
    
    // Post a notification on the main thread asynchronously.
    //
    private func postNotificationOnMainQueueAsync(name: NSNotification.Name, object: CommandStatus? = nil) {
        DispatchQueue.main.async { [weak self] in
            print("WC: postNotification2 name: \(name) object: \(String(describing: object))")
            if let errorMessage = object?.errorMessage {
                print("WC:     errorMessage: \(errorMessage)")
            }
            
            print("WC: Checking context")
            if let bioKernelState = object?.bioKernelState, name == .dataDidFlow {
                print("WC: sending context")
                self?.delegate?.contextDidUpdate(bioKernelState)
            }
            print("WC: Done with context update")
            
            print("WC: Checking message")
            if let workoutMessage = object?.workoutMessage, name == .dataDidFlow {
                print("WC: got new message")
                self?.delegate?.didRecieveMessage(at: Date(), workoutMessage: workoutMessage)
            }
            print("WC: Done checking message")
        }
    }
}
