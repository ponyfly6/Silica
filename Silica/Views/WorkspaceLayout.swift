import Foundation

nonisolated enum WorkspaceLayout {
    /// Height of the title bar row that holds the traffic lights and the tabs.
    static let titleBarHeight: CGFloat = 36
    /// Room for the traffic lights when the sidebar is hidden.
    static let trafficLightsWidth: CGFloat = 78
    /// Smallest corner radius of the editor card; corners near the window's are concentric with it.
    static let cardCornerRadius: CGFloat = 10
    static let cardInset: CGFloat = 6
    /// How much of the sidebar list's built-in top inset to hide.
    static let sidebarListTopTrim: CGFloat = 8
    static let sidebarWidthRange: ClosedRange<Double> = 220...480
    static let defaultSidebarWidth = 260.0
    static let defaultPanelWidth = 360.0
    static let panelWidthRange = 300.0...820.0
    static let minimumEditorWidth = 420.0

    static func clampedSidebarWidth(_ width: Double) -> Double {
        min(max(width, sidebarWidthRange.lowerBound), sidebarWidthRange.upperBound)
    }

    static func panelWidth(preferred: Double, available: Double) -> Double {
        max(panelWidthRange.lowerBound, min(preferred, panelWidthRange.upperBound, available - minimumEditorWidth))
    }
}
