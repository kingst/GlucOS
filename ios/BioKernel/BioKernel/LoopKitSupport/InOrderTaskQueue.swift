//
//  InOrderTaskQueue.swift
//  BioKernel
//
//  Created by Sam King on 11/19/23.
//
// This class helps create an order for async tasks. We use it as part of our bridge
// between traditional concurrency and async/await code. Basically, we use it to
// order events that come from delegates that run on the same DispatchQueue. By
// using this struct we can run the resulting state updates async but in order.
//
// Anything that runs on the queue itself should be short and consist of simple state
// updates. Any network requests or blocking calls should go to another context outside
// of the async function you pass in. If you have simple updates you should:
//
// InOrderTaskQueue.dispatchQueue.async { await simpleUpdate() }
//
// But if you have something more complex you can:
//
// Task {
//     await InOrderTaskQueue.dispatchQueue.waitForEventsToRun()
//     await myComplexTask()
// }

import Foundation

struct InOrderTaskQueue {
    static let dispatchQueue = InOrderTaskQueue(detectDeadlock: true)
    
    let queue = DispatchQueue(label: "InOrderTaskQueue")
    let detectDeadlock: Bool
    
    init(detectDeadlock: Bool) {
        self.detectDeadlock = detectDeadlock
    }
    
    func async(function: @escaping (() async -> Void)) {
        queue.async {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await function()
                semaphore.signal()
            }
            if debugEnabled && detectDeadlock {
                let result = semaphore.wait(timeout: .now() + 30.0)
                precondition(result == .success, "Deadlock for InOrderTaskQueue")
            } else {
                semaphore.wait()
            }
        }
    }
    
    func waitForEventsToRun() async {
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
