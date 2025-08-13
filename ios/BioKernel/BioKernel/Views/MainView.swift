//
//  MainView.swift
//  BioKernel
//
//  Created by Sam King on 12/18/23.
//

import SwiftUI
import LoopKit
import LoopKitUI

struct MainView: View {
    @StateObject var deviceManagerObservable = getDeviceDataManager().observableObject()
    @StateObject var glucoseAlertsViewModel = getGlucoseAlertsService().viewModel()
    @State var navigateToSettings = false
    @State var navigateToAddCgm = false
    @State var navigateToCgmSettings = false
    @State var navigateToAddPump = false
    @State var navigateToPumpSettings = false
    @State var navigateToBolus = false
    @State var navigateToSettingsFromUrl = false
    @State var navigateToGlucoseAlerts = false
    @State var settingsFromUrl: CodableSettings? = nil
    
    let addButtonRadius = 30.0
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MainViewSummaryView()
                MainViewAlertView()
                Spacer()
                ZStack(alignment: .bottomTrailing) {
                    GlucoseChartView()
                    Button {
                        navigateToBolus = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .frame(width: 2 * addButtonRadius, height: 2 * addButtonRadius)
                    .background(AppColors.primary)
                    .foregroundColor(.white)
                    .clipShape(Circle())
                }
                .padding()
            }
            .modifier(NavigationModifier())
            .navigationTitle("BioKernel")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack {
                        Button {
                            if deviceManagerObservable.cgmManager == nil {
                                navigateToAddCgm = true
                            } else {
                                navigateToCgmSettings = true
                            }
                        } label: {
                            Image("g7")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 40, height: 40)
                        }
                        Button {
                            if deviceManagerObservable.pumpManager == nil {
                                navigateToAddPump = true
                            } else {
                                navigateToPumpSettings = true
                            }
                        } label: {
                            Image("omnipod")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 40, height: 40)
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button {
                            navigateToGlucoseAlerts = true
                        } label: {
                            if glucoseAlertsViewModel.enabled {
                                Image(systemName: "bell.fill").tint(.white)
                            } else {
                                Image(systemName: "bell.slash.fill").tint(.white)
                            }
                        }
                        Button {
                            navigateToSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .tint(.white)
                        }
                    }
                }
            }
            .navigationDestination(isPresented: $navigateToSettings) {
                SettingsView(settingsFromUrl: nil)
                    .modifier(NavigationModifier())
            }
            .navigationDestination(isPresented: $navigateToSettingsFromUrl) {
                SettingsView(settingsFromUrl: settingsFromUrl)
                    .modifier(NavigationModifier())
            }
            .navigationDestination(isPresented: $navigateToAddCgm) {
                AddCGMView()
            }
            .navigationDestination(isPresented: $navigateToCgmSettings) {
                if let cgmManager = deviceManagerObservable.cgmManager, let cgmManagerUI = cgmManager as? CGMManagerUI {
                    CGMManagerView(cgmManagerUI: cgmManagerUI)
                        .modifier(NavigationModifier())
                } else {
                    EmptyView()
                }
            }
            .navigationDestination(isPresented: $navigateToAddPump) {
                AddPumpView()
            }
            .navigationDestination(isPresented: $navigateToPumpSettings) {
                if let pumpManager = deviceManagerObservable.pumpManager {
                    PumpManagerView(pumpManagerUI: pumpManager)
                        .modifier(NavigationModifier())
                } else {
                    EmptyView()
                }
            }
            .navigationDestination(isPresented: $navigateToBolus) {
                BolusView()
            }
            .navigationDestination(isPresented: $navigateToGlucoseAlerts) {
                GlucoseAlertsView()
            }
            .onOpenURL { url in
                // we should check to make sure this is for settings
                guard let json = url.lastPathComponent.replacingOccurrences(of: "+", with: " ").removingPercentEncoding, let data = json.data(using: .utf8) else { return }
                
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                
                do {
                    let settings = try decoder.decode(CodableSettings.self, from: data)
                    
                    settingsFromUrl = settings
                    navigateToSettingsFromUrl = true
                } catch {
                    print(error)
                }
            }
        }
    }
}

#Preview {
    MainView()
}
