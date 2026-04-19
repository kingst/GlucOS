//
//  MainViewAlertView.swift
//  BioKernel
//
//  Created by Sam King on 7/16/24.
//

import SwiftUI

struct MainViewAlertView: View {
    @EnvironmentObject var appState: AppObservableState
    @EnvironmentObject var glucoseAlertsViewModel: GlucoseAlertsViewModel
    @Environment(\.composition) var composition: AppComposition?
    var body: some View {
        VStack {
            if !appState.doseProgress.isComplete {
                BolusProgressView()
            } else if let alertString = glucoseAlertsViewModel.alertString {
                MainViewGlucoseAlertView(alertString: alertString)
            } else {
                EmptyView()
            }
        }
        .task {
            // FIXME: can we put this in the BolusProgressView? I don't think so, but it would be better there
            guard let composition else { return }
            if let pumpManager = composition.deviceDataManager.pumpManager, let bolusProgressReporter = pumpManager.createBolusProgressReporter(reportingOn: DispatchQueue.main) {
                let totalUnits =  await composition.insulinStorage.activeBolus(at: Date())?.programmedUnits ?? bolusProgressReporter.progress.deliveredUnits / bolusProgressReporter.progress.percentComplete
                appState.doseProgress.update(totalUnits: totalUnits, doseProgressReporter: bolusProgressReporter)
            }
        }
    }
}

#Preview {
    MainViewAlertView()
}
