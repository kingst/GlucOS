//
//  MainViewAlertView.swift
//  BioKernel
//
//  Created by Sam King on 7/16/24.
//

import SwiftUI

struct MainViewAlertView: View {
    @ObservedObject var doseProgress: DoseProgress = getDeviceDataManager().observableObject().doseProgress
    @ObservedObject var glucoseAlertsViewModel = getGlucoseAlertsService().viewModel()
    var body: some View {
        VStack {
            if !doseProgress.isComplete {
                BolusProgressView()
            } else if let alertString = glucoseAlertsViewModel.alertString {
                MainViewGlucoseAlertView(alertString: alertString)
            } else {
                EmptyView()
            }
        }
        .task {
            // FIXME: can we put this in the BolusProgressView? I don't think so, but it would be better there
            if let pumpManager = getDeviceDataManager().pumpManager, let bolusProgressReporter = pumpManager.createBolusProgressReporter(reportingOn: DispatchQueue.main) {
                let totalUnits =  await getInsulinStorage().activeBolus(at: Date())?.programmedUnits ?? bolusProgressReporter.progress.deliveredUnits / bolusProgressReporter.progress.percentComplete
                doseProgress.update(totalUnits: totalUnits, doseProgressReporter: bolusProgressReporter)
            }
        }
    }
}

#Preview {
    MainViewAlertView()
}
