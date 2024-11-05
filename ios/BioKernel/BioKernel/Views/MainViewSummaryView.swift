//
//  MainViewSummaryView.swift
//  Type Zero
//
//  Created by Sam King on 4/4/23.
//

import SwiftUI

struct MainViewSummaryView: View {
    @StateObject var deviceManagerObservable = getDeviceDataManager().observableObject()
    @Environment(\.scenePhase) var scenePhase
    @State var timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    
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
            }.padding()
            
            Grid {
                GridRow {
                    Text("Acc Error").bold()
                    Text("IoB").bold()
                    Text("Insulin act").bold()
                }
                .frame(maxWidth: .infinity)
                GridRow {
                    let iob = deviceManagerObservable.insulinOnBoard
                    if let accumulatedError = deviceManagerObservable.accumulatedError() {
                        AccErrorGauge(current: accumulatedError.clamp(low: -240, high: 240))
                    } else {
                        Text("-")
                    }
                    IoBGauge(current: iob)
                    if let insulinAction = deviceManagerObservable.insulinActionPerHour() {
                        InsulinActionGauge(current: insulinAction.clamp(low: 0, high: 100))
                    } else {
                        Text("-")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding([.bottom])
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
            }
        }
        .task {
            await getDeviceDataManager().refreshCgmAndPumpDataFromUI()
            await getHealthKitStorage().removeDuplicateEntries()
        }
        .onReceive(timer) { _ in
            print("timer")
            deviceManagerObservable.objectWillChange.send()
        }
    }
}

struct MainViewSummaryView_Previews: PreviewProvider {
    static var previews: some View {
        MainViewSummaryView()
    }
}
