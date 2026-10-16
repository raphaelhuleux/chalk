import XCTest
import ChalkKit
@testable import Chalk

/// The tab names share the traffic lights' line. Windowed, the band is the
/// unified titlebar (taller than the row) and the lights sit on its centre
/// line; the row must sit there too, not on the band's floor.
@MainActor
final class HeaderBandAlignmentTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { dismantleHostedSidebar(window) }
        windows = []
        super.tearDown()
    }

    private func band(height: CGFloat) -> HeaderBarView {
        let bar = HeaderBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        let window = NSWindow.hostedForTesting(frame: CGRect(x: 0, y: 0, width: 900, height: 400))
        windows.append(window)
        let host = FlippedView(frame: CGRect(x: 0, y: 0, width: 900, height: height))
        window.contentView?.addSubview(host)
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.topAnchor.constraint(equalTo: host.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: height),
        ])
        host.layoutSubtreeIfNeeded()
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    func testTheRowIsCentredOnATallerBand() {
        let bar = band(height: ChalkMetrics.tabStripHeight + 6)
        XCTAssertEqual(bar.tabStrip.frame.midY, bar.bounds.midY, accuracy: 0.5,
                       "the row's centre is the titlebar's centre, where the lights are")
        XCTAssertEqual(bar.tabStrip.frame.height, ChalkMetrics.tabStripHeight, accuracy: 0.5)
    }

    func testTheRowFillsABandOfItsOwnHeight() {
        let bar = band(height: ChalkMetrics.tabStripHeight)
        XCTAssertEqual(bar.tabStrip.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(bar.tabStrip.frame.maxY, bar.bounds.height, accuracy: 0.5)
    }
}
