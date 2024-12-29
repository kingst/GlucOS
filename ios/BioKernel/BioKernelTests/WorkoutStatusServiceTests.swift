//
//  WorkoutStatusServiceTests.swift
//  BioKernelTests
//
//  Created by Sam King on 12/29/24.
//

import XCTest

@testable import BioKernel

final class WorkoutStatusServiceTests: XCTestCase {

    override func setUpWithError() throws {
        Dependency.useMockConstructors = true
        Dependency.mock { MockStoredObject.self as StoredObject.Type }
    }

    override func tearDownWithError() throws {
        Dependency.resetMocks()
        Dependency.useMockConstructors = false
    }

    func testWorkout() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let workoutStartMessage: WorkoutMessage = .started(at: startDate + 1, description: "Run", imageName: "figure.run")
        let workoutEndMessage: WorkoutMessage = .ended(at: startDate + 3)
        let workoutStatus = await LocalWorkoutStatusService()
        
        // no messages
        var isExercising = await workoutStatus.isExercising(at: startDate)
        XCTAssert(!isExercising)
        
        // started a workout
        await workoutStatus.didRecieveMessage(at: startDate + 1, workoutMessage: workoutStartMessage)
        isExercising = await workoutStatus.isExercising(at: startDate + 2)
        XCTAssert(isExercising)
        
        // ended a workout
        await workoutStatus.didRecieveMessage(at: startDate + 3, workoutMessage: workoutEndMessage)
        isExercising = await workoutStatus.isExercising(at: startDate + 4)
        XCTAssert(!isExercising)
    }
    
    func testWorkoutTimeout() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let workoutStartMessage: WorkoutMessage = .started(at: startDate, description: "Run", imageName: "figure.run")
        let workoutStatus = await LocalWorkoutStatusService()
                
        // test right before the timeout
        await workoutStatus.didRecieveMessage(at: startDate, workoutMessage: workoutStartMessage)
        var isExercising = await workoutStatus.isExercising(at: startDate + 59.minutesToSeconds())
        XCTAssert(isExercising)
        
        // right after the timeout
        isExercising = await workoutStatus.isExercising(at: startDate + 61.minutesToSeconds())
        XCTAssert(!isExercising)
        
        // get a new message and restart the timer
        await workoutStatus.didRecieveMessage(at: startDate + 59.minutesToSeconds(), workoutMessage: workoutStartMessage)
        isExercising = await workoutStatus.isExercising(at: startDate + 61.minutesToSeconds())
        XCTAssert(isExercising)
    }
}
