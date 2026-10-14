import PDFKit
import UIKit

/// The preview an asset row opens (image or PDF), presented as a sheet.
/// In-process on purpose: `QLPreviewController`'s out-of-process scene tore itself down right
/// after appearing, leaving a black sheet. This also keeps the app's palette and is testable.
final class AssetPreviewViewController: UIViewController, UIScrollViewDelegate {
    let url: URL

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        title = url.lastPathComponent
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The sheet the shell presents: this controller under a nav bar with the file name and Done.
    static func inNavigationController(url: URL) -> UINavigationController {
        let preview = AssetPreviewViewController(url: url)
        let nav = UINavigationController(rootViewController: preview)
        nav.modalPresentationStyle = .pageSheet
        return nav
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .chalkEditorBackground
        let done = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.close() })
        done.tintColor = .chalkAccent // single-accent rule, not system blue
        navigationItem.rightBarButtonItem = done

        if url.pathExtension.lowercased() == "pdf" {
            installPDFView()
        } else {
            installImageView()
        }
    }

    /// Esc closes, matching the palettes.
    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [],
                                  action: #selector(close))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    @objc private func close() {
        presentingViewController?.dismiss(animated: true)
    }

    // MARK: - Content

    private func installPDFView() {
        // PDFKit is in-process and handles multi-page scrolling itself.
        let pdfView = PDFView()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.backgroundColor = .chalkEditorBackground
        pdfView.document = PDFDocument(url: url)
        view.addSubview(pdfView)
        pin(pdfView)
        if pdfView.document == nil { showUnreadableMessage() }
    }

    private func installImageView() {
        guard let image = UIImage(contentsOfFile: url.path) else {
            showUnreadableMessage()
            return
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.maximumZoomScale = 6
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.frame = CGRect(origin: .zero, size: image.size)
        scrollView.contentSize = image.size
        scrollView.addSubview(imageView)
        view.addSubview(scrollView)
        pin(scrollView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    private func showUnreadableMessage() {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Cannot preview this file."
        label.textColor = .chalkTextSecondary
        label.textAlignment = .center
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func pin(_ child: UIView) {
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Zoom

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard imageView.image != nil, scrollView.superview != nil,
              scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
        let size = imageView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        // The floor zoom is fit-to-bounds capped at 1, so a small image is never blown up.
        let fit = min(scrollView.bounds.width / size.width, scrollView.bounds.height / size.height)
        let floor = min(fit, 1)
        if scrollView.minimumZoomScale != floor {
            scrollView.minimumZoomScale = floor
            scrollView.zoomScale = floor
        }
        centerImage()
    }

    @objc private func toggleZoom(_ recognizer: UITapGestureRecognizer) {
        let target = scrollView.zoomScale > scrollView.minimumZoomScale
            ? scrollView.minimumZoomScale
            : min(scrollView.maximumZoomScale, scrollView.minimumZoomScale * 3)
        scrollView.setZoomScale(target, animated: true)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    // Keeps the image centered while smaller than the sheet; otherwise it pins top-left.
    private func centerImage() {
        let scaled = CGSize(width: imageView.bounds.width * scrollView.zoomScale,
                            height: imageView.bounds.height * scrollView.zoomScale)
        let x = max(0, (scrollView.bounds.width - scaled.width) / 2)
        let y = max(0, (scrollView.bounds.height - scaled.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }
}
