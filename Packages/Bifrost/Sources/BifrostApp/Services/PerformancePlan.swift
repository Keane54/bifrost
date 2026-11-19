import Foundation

// What the Performance monitor takes from the start plan (StartPlan).
package struct PerformancePlan: Sendable, Equatable {
    // The folder of health.log (StartPlan.healthLogFolder).
    package let logFolder: URL
    // False in a test home: no response times and no GitHub points (StartPlan.measuresNetwork).
    package let measuresNetwork: Bool
    // The current folder of gh for the GitHub points: the support folder of the app, a folder of
    // Bifrost that is never a repository of the user.
    package let ghFolder: URL

    package init(logFolder: URL, measuresNetwork: Bool, ghFolder: URL) {
        self.logFolder = logFolder
        self.measuresNetwork = measuresNetwork
        self.ghFolder = ghFolder
    }

    // The values of the plan. The support folder is the folder of the store files.
    package init(_ plan: StartPlan) {
        self.init(
            logFolder: plan.healthLogFolder, measuresNetwork: plan.measuresNetwork,
            ghFolder: plan.settingsFile.deletingLastPathComponent())
    }
}
