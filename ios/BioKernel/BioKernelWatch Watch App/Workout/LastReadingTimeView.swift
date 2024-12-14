//
//  LastReadingTimeView.swift
//  Type Zero Watch Watch App
//
//  Created by Sam King on 4/6/23.
//

import SwiftUI

struct LastReadingTimeView: View {
    let updateTrigger: Date // just for updates
    @EnvironmentObject var stateViewModel: StateViewModel
    
    var body: some View {
        LastReadingTimeContent(minutesSinceLastReading: stateViewModel.appState?.minutesSinceLastUpdate() ?? 99)
    }
}

// Separate content view for better organization
private struct LastReadingTimeContent: View {
    let minutesSinceLastReading: Int
    
    var body: some View {
        let (backgroundColor, foregroundColor) = { () -> (Color, Color) in
            if minutesSinceLastReading < 6 {
                return (.green, .white)
            } else if minutesSinceLastReading < 11 {
                return (.yellow, .black)
            } else {
                return (.red, .white)
            }
        }()
        
        Text("\(minutesSinceLastReading)m")
            .frame(maxWidth: .infinity)
            .background(backgroundColor)
            .foregroundColor(foregroundColor)
            .bold()
    }
}

struct LastReadingTimeView_Previews: PreviewProvider {
    static var previews: some View {
        LastReadingTimeView(updateTrigger: Date())
            .environmentObject(StateViewModel())
    }
}
