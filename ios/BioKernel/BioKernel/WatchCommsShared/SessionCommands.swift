/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Defines an interface to wrap Watch Connectivity APIs and bridge the UI.
*/

import WatchConnectivity

// Define an interface to wrap Watch Connectivity APIs and bridge the UI.
//
protocol SessionCommands {
    func updateAppContext(_ context: [String: Any])
}

// Implement the commands. Every command handles the communication and notifies clients
// when WCSession status changes or data flows.
//
extension SessionCommands {
    
    // Update the app context if the session is activated, and update UI with the command status.
    //
    func updateAppContext(_ context: [String: Any]) {
        var commandStatus = CommandStatus(command: .updateAppContext, phrase: .updated)
        do {
            commandStatus.bioKernelState = try BioKernelState(context)
        } catch {
            assertionFailure("Failed to parse context: \(error)")
        }
        
        guard WCSession.default.activationState == .activated else {
            return handleSessionUnactivated(with: commandStatus)
        }
        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            commandStatus.phrase = .failed
            commandStatus.errorMessage = error.localizedDescription
        }
        postNotificationOnMainQueueAsync(name: .dataDidFlow, object: commandStatus)
    }

    // Send a piece of message data if the session is activated, and update the UI with the command status.
    //
    func sendMessageData(workoutMessage: WorkoutMessage) {
        var commandStatus = CommandStatus(command: .sendMessageData, phrase: .sent)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let messageData: Data
        do {
            messageData = try encoder.encode(workoutMessage)
        } catch {
            commandStatus.phrase = .failed
            commandStatus.errorMessage = error.localizedDescription
            postNotificationOnMainQueueAsync(name: .dataDidFlow, object: commandStatus)
            return
        }
        
        guard WCSession.default.activationState == .activated else {
            return handleSessionUnactivated(with: commandStatus)
        }

        // A reply handler block runs asynchronously on a background thread and should return quickly.
        WCSession.default.sendMessageData(messageData, replyHandler: nil, errorHandler: { error in
            commandStatus.phrase = .failed
            commandStatus.errorMessage = error.localizedDescription
            self.postNotificationOnMainQueueAsync(name: .dataDidFlow, object: commandStatus)
        })
        postNotificationOnMainQueueAsync(name: .dataDidFlow, object: commandStatus)
    }
    
    // Post a notification from the main queue asynchronously.
    //
    private func postNotificationOnMainQueueAsync(name: NSNotification.Name, object: CommandStatus) {
        DispatchQueue.main.async {
            print("WC: postNotification name: \(name) object: \(String(describing: object))")
            if let errorMessage = object.errorMessage {
                print("WC:    errorMessage: \(errorMessage)")
            }
        }
    }

    // Handle unactivated session error. WCSession commands require an activated session.
    //
    private func handleSessionUnactivated(with commandStatus: CommandStatus) {
        var mutableStatus = commandStatus
        mutableStatus.phrase = .failed
        mutableStatus.errorMessage = "WCSession is not activated yet!"
        postNotificationOnMainQueueAsync(name: .dataDidFlow, object: commandStatus)
    }
}
