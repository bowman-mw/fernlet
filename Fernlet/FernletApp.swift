//
//  FernletApp.swift
//  Fernlet
//
//  Created by Michael Bowman on 5/16/26.
//

import SwiftUI
import CoreData

@main
struct FernletApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
