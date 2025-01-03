//
//  MainViewSummaryView.swift
//  Type Zero
//
//  Created by Sam King on 4/4/23.
//

import SwiftUI

struct MainViewSummaryView: View {
    @StateObject var deviceManagerObservable = getDeviceDataManager().observableObject()
    @ObservedObject var glucoseAlertsViewModel = getGlucoseAlertsService().viewModel()
    @ObservedObject var workoutStatus = getWorkoutStatusService().observableObject()
    @Environment(\.scenePhase) var scenePhase
    @State var timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @State var predictedGlucose: Double?
    
    var body: some View {
        VStack {
            VStack {
                if let glucose = deviceManagerObservable.lastGlucoseReading {
                    let value = glucose.quantity.doubleValue(for: .milligramsPerDeciliter, withRounding: true)
                    let time = Int(Date().timeIntervalSince(glucose.date) / 60.0)
                    let trend = glucose.trend?.symbol ?? ""
                    Text("Last reading: \(time)m")
                    Text("\(String(format: "%0.0f", value))\(trend)").font(.largeTitle).bold()
                } else {
                    Text("No recent data")
                    Text("N/A").font(.largeTitle).bold()
                }
                Text("mg/dL")
            }
            .padding()
            
            Grid {
                GridRow {
                    Text("Digestion").bold()
                    Text("Predicted").bold()
                    Text("IoB").bold()
                }
                .frame(maxWidth: .infinity)
                GridRow {
                    let iob = deviceManagerObservable.insulinOnBoard
                    if let digestion = deviceManagerObservable.digestionCalibrated() {
                        DigestionGauge(current: digestion)
                    } else {
                        Text("-")
                    }
                    if glucoseAlertsViewModel.alertString != nil {
                        if let predictedGlucose = glucoseAlertsViewModel.mostRecentPredictedGlucose {
                            Text(String(format: "%0.0f", predictedGlucose.clamp(low: 40, high: 400))).font(.title)
                        } else {
                            Text("-")
                        }
                    } else if let predictedGlucose = predictedGlucose {
                        VStack {
                            Text(String(format: "%0.0f", predictedGlucose.clamp(low: 40, high: 400))).font(.title)
                            Text("In 15m")
                        }
                    } else {
                        Text("-")
                    }
                    IoBGauge(current: iob)
                }
                .frame(maxWidth: .infinity)
            }
            .padding([.bottom])
            switch (getSettingsStorage().snapshot().isTargetGlucoseAdjustedDuringExerciseEnabled(),  workoutStatus.isExercising, workoutStatus.lastWorkoutMessage) {
            case (false, _, _):
                EmptyView()
            case (true, false, _):
                EmptyView()
            case (true, true, .none):
                EmptyView()
            case (true, true, .started(let at, let description, let imageName)):
                WorkoutStatusView(at: at, description: description, imageName: imageName)
                    .padding()
            case (true, true, .ended):
                EmptyView()
            }
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .background(AppColors.primary)
        .onAppear {
            getDeviceDataManager().pumpManager?.ensureCurrentPumpData(completion: nil)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .inactive || newPhase == .background {
                self.timer.upstream.connect().cancel()
            } else if newPhase == .active {
                self.timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
                Task {
                    predictedGlucose = await getPhysiologicalModels().predictGlucoseIn15Minutes(from: Date())
                }
            }
        }
        .task {
            predictedGlucose = await getPhysiologicalModels().predictGlucoseIn15Minutes(from: Date())
            await getDeviceDataManager().refreshCgmAndPumpDataFromUI()
            await getHealthKitStorage().removeDuplicateEntries()
        }
        .onReceive(timer) { _ in
            print("timer")
            deviceManagerObservable.objectWillChange.send()
            Task {
                predictedGlucose = await getPhysiologicalModels().predictGlucoseIn15Minutes(from: Date())
            }
        }
    }
}

struct MainViewSummaryView_Previews: PreviewProvider {
    static var previews: some View {
        MainViewSummaryView()
    }
}
