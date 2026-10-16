import AppKit
import PDFKit
import ChalkKit

/// The preview an asset row opens (image or PDF), presented as a sheet on the
/// editor window. In-process on purpose, so it keeps the app's palette and is
/// testable; Quick Look would run out of process.
final class AssetPreviewViewController: NSViewController {
    let url: URL

    private let scrollView = NSScrollView()
    private let imageView = NSImageView()

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        title = url.lastPathComponent
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The sheet the shell presents: this controller in a titled window sized
    /// against `parent`, with the file name as its title.
    static func makeSheet(url: URL, over parent: NSWindow?) -> NSWindow {
        let preview = AssetPreviewViewController(url: url)
        let parentSize = parent?.frame.size ?? NSSize(width: 1100, height: 760)
        let size = NSSize(width: max(480, parentSize.width * 0.72),
                          height: max(360, parentSize.height * 0.78))
        return HelpSheet.makeWindow(for: preview, size: size)
    }

    override func loadView() {
        let root = FlippedView()
        root.wantsLayer = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.chalkSetLayerBackground(.chalkEditorBackground)

        let bar = FlippedView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        let done = NSButton(title: "Done", target: self, action: #selector(endChalkSheet))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(done)
        view.addSubview(bar)

        let content: NSView
        if url.pathExtension.lowercased() == "pdf" {
            content = makePDFView()
        } else {
            content = makeImageView()
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44),
            done.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            done.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            content.topAnchor.constraint(equalTo: bar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Esc closes, matching the palettes.
    override func cancelOperation(_ sender: Any?) { endChalkSheet() }

    // MARK: - Content

    private func makePDFView() -> NSView {
        // PDFKit is in-process and handles multi-page scrolling itself.
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.backgroundColor = .chalkEditorBackground
        pdfView.document = PDFDocument(url: url)
        if pdfView.document == nil { return unreadableMessage() }
        return pdfView
    }

    private func makeImageView() -> NSView {
        guard let image = NSImage(contentsOf: url) else { return unreadableMessage() }
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        imageView.frame = NSRect(origin: .zero, size: image.size)
        scrollView.documentView = imageView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.maxMagnification = 6
        scrollView.minMagnification = 0.1
        return scrollView
    }

    private func unreadableMessage() -> NSView {
        let wrap = FlippedView()
        let label = NSTextField(labelWithString: "Cannot preview this file.")
        label.textColor = .chalkTextSecondary
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
        ])
        return wrap
    }

    /// A small image sits centred in the sheet; a large one scrolls at its own size.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard let image = imageView.image, scrollView.superview != nil else { return }
        let clip = scrollView.contentView.bounds.size
        imageView.frame = NSRect(origin: .zero,
                                 size: NSSize(width: max(image.size.width, clip.width),
                                              height: max(image.size.height, clip.height)))
    }

    #if DEBUG
    var showsUnreadableMessageForTesting: Bool { imageView.image == nil && !(view.subviews.last is PDFView) }
    #endif
}
