import SwiftUI

extension Binding {
    /// Collapses an optional-backed binding into the `Bool` shape SwiftUI's presentation
    /// modifiers take: presented while the wrapped value is non-nil, and setting `false`
    /// (dismissal) clears the value. Setting `true` is deliberately a no-op — presentation is
    /// driven only by assigning the optional itself.
    ///
    /// The shared home for the `alert` / `sheet` / `confirmationDialog` / `fullScreenCover`
    /// idiom previously inlined at every "present while this optional state is set" call site.
    /// Only for bindings whose presence check and dismissal are exactly this pure shape — sites
    /// whose getter is compound or whose setter has side effects keep their hand-rolled binding.
    public func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(
            get: { self.wrappedValue != nil },
            set: { if !$0 { self.wrappedValue = nil } }
        )
    }
}
