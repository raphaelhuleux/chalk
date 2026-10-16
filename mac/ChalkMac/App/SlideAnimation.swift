import AppKit

/// The one translation the sidebar slide moves things by (docs/motion.md
/// "Sidebar show/hide"): the Library column and the frozen editor content, on
/// one clock. The model value lands at once and the presentation glides, so a
/// reader of the layer sees the slide's end state the same turn it starts.
extension CALayer {
    static let chalkSlideKey = "chalk.sidebar.slide"

    /// Glide to a horizontal translation of `x` over `duration`, from wherever
    /// the layer is on screen right now (a cancelled slide continues from its
    /// presentation, not from its old model).
    func chalkSlide(toTranslationX x: CGFloat, over duration: TimeInterval) {
        let from = ((presentation() ?? self).value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0
        removeAnimation(forKey: Self.chalkSlideKey)
        transform = CATransform3DMakeTranslation(x, 0, 0)
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = from
        animation.toValue = x
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        // The presentation holds the end state until `chalkEndSlide`, whatever
        // the model says: AppKit resets a layer-backed view's layer transform
        // when it lays the view out, and the hide re-lays the editor column
        // out in the slide's completion. With a removed-on-completion
        // animation the content then snapped to the untranslated frame for
        // the frames before the settle's snapshot arrived.
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        add(animation, forKey: Self.chalkSlideKey)
    }

    /// Stop a slide where it is and land the identity: the cancel lane.
    func chalkEndSlide() {
        removeAnimation(forKey: Self.chalkSlideKey)
        transform = CATransform3DIdentity
    }
}
