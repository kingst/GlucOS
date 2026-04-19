//
//  MainViewSummaryView.swift
//  Type Zero
//
//  Created by Sam King on 4/4/23.
//

import SwiftUI

struct MainViewSummaryView: View {
    @EnvironmentObject var appState: AppObservableState
    @EnvironmentObject var glucoseAlertsViewModel: GlucoseAlertsViewModel
    @Environment(\.composition) var composition: AppComposition?
    @Environment(\.scenePhase) var scenePhase
    @State var timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @State var predictedGlucose: Double?
    
    var body: some View {
        VStack {
            VStack {
                if let glucose = appState.lastGlucoseReading {
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
                    let iob = appState.insulinOnBoard
                    if let digestion = appState.digestionCalibrated() {
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
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .background(AppColors.primary)
        .onAppear {
            composition?.deviceDataManager.pumpManager?.ensureCurrentPumpData(completion: nil)
            // Just to make sure that the ClosedLoopResults data is loaded
            let _ = composition?.closedLoopService
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .inactive || newPhase == .background {
                self.timer.upstream.connect().cancel()
            } else if newPhase == .active {
                self.timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
                Task {
                    await pollForNewValues()
                }
            }
        }
        .task {
            guard let composition else { return }
            predictedGlucose = await composition.physiologicalModels.predictGlucoseIn15Minutes(from: Date())
            await composition.deviceDataManager.refreshCgmAndPumpDataFromUI()
            await composition.healthKitStorage.removeDuplicateEntries()
        }
        .onReceive(timer) { _ in
            print("timer")
            appState.objectWillChange.send()
            Task {
                await pollForNewValues()
            }
        }
    }
    
    func pollForNewValues() async {
        guard let composition else { return }
        predictedGlucose = await composition.physiologicalModels.predictGlucoseIn15Minutes(from: Date())
        let iob = await composition.insulinStorage.insulinOnBoard(at: Date())
        await MainActor.run {
            appState.insulinOnBoard = iob
            appState.pumpAlarm = nil
        }
    }
}

struct MainViewSummaryView_Previews: PreviewProvider {
    static var previews: some View {
        MainViewSummaryView()
    }
}
