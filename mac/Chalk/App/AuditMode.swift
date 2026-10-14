#if DEBUG
import Foundation
import UIKit

/// Debug-only fixtures and named UI states, picked with CHALK_AUDIT_STATE
/// (usage in docs/ui-correctness.md).
enum AuditMode {
    static var requestedState: String? {
        ProcessInfo.processInfo.environment["CHALK_AUDIT_STATE"]
    }

    /// Writes the stress tree; idempotent. Returns the fixture root.
    @discardableResult
    static func seedFixtures() -> URL {
        let root = SampleContent.documentsURL.appendingPathComponent("AuditFixtures", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Deep tree: 6 levels, long names at every level.
        var dir = root.appendingPathComponent("deep")
        for level in 1...6 {
            dir = dir.appendingPathComponent("level-\(level)-a-deliberately-long-folder-name-for-truncation")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data("# L\(level)\n".utf8).write(to: dir.appendingPathComponent(
                "chapter-\(level)-notes-on-the-asymptotic-behavior-of-estimators.md"))
        }
        // Flat list for Quick Open volume (120 files, long names).
        let flat = root.appendingPathComponent("many")
        try? fm.createDirectory(at: flat, withIntermediateDirectories: true)
        for n in 1...120 {
            try? Data("# \(n)\n".utf8).write(to: flat.appendingPathComponent(
                String(format: "%03d-lecture-notes-with-a-very-long-descriptive-title.md", n)))
        }
        // Empty location.
        try? fm.createDirectory(at: root.appendingPathComponent("empty-location"),
                                withIntermediateDirectories: true)
        // Stress docs.
        try? Data(stressMarkdown.utf8).write(to: root.appendingPathComponent("stress.md"))
        try? Data(stressTex.utf8).write(to: root.appendingPathComponent("stress.tex"))
        // Outline palette: headings across levels (one Setext), numbered
        // callouts, an unnumbered proof (must NOT appear), standalone images.
        try? Data(outlineMarkdown.utf8).write(to: root.appendingPathComponent("outline.md"))
        // Asset rows: the Library lists images/PDFs, and clicking one opens the
        // preview sheet (state "preview"). Drawn rather than bundled so the
        // fixture tree stays self-contained.
        try? figurePNG().write(to: root.appendingPathComponent("figure.png"))
        // Tab-name fixtures: one 80-char name, plus short ones.
        try? Data("# long\n".utf8).write(to: root.appendingPathComponent(
            "an-extremely-long-file-name-that-should-truncate-in-the-tab-strip-not-overflow-it.md"))
        for name in ["alpha.md", "beta.md", "gamma.tex", "delta.md", "epsilon.md",
                     "zeta.md", "eta.md", "theta.tex", "iota.md", "kappa.md", "lambda.md"] {
            try? Data("# \(name)\n".utf8).write(to: root.appendingPathComponent(name))
        }
        return root
    }

    /// Content for the landing-page screenshots: a realistic folder, unlike the
    /// stress fixtures above, which exist to break the layout. Seeded by the
    /// harness so the shots can be regenerated from any build.
    @discardableResult
    static func seedPromoContent() -> URL {
        let root = SampleContent.documentsURL.appendingPathComponent("Research", isDirectory: true)
        let fm = FileManager.default
        for folder in ["Panel bias", "Seminar", "Reading"] {
            try? fm.createDirectory(at: root.appendingPathComponent(folder),
                                    withIntermediateDirectories: true)
        }
        let files: [(String, String)] = [
            ("Panel bias/estimator-bias.md", promoMarkdown),
            ("Panel bias/identification.tex", promoTex),
            ("Panel bias/simulation-notes.md", "# Simulation notes\n\nDraws per cell: 5,000.\n"),
            ("Seminar/slides-outline.md", "# Seminar\n\n## Motivation\n\n## The bias\n\n## Fixes\n"),
            ("Seminar/discussant-comments.md", "# Comments\n\n- Ask about weak instruments.\n"),
            ("Reading/nickell-1981.md", "# Nickell (1981)\n\nBiases in dynamic models with fixed effects.\n"),
            ("Reading/arellano-bond.md", "# Arellano and Bond (1991)\n\nGMM for panel data.\n"),
        ]
        for (path, body) in files {
            try? Data(body.utf8).write(to: root.appendingPathComponent(path))
        }
        return root
    }

    private static let promoMarkdown = """
    # Asymptotic bias of the within estimator

    Under fixed effects with $T$ small and $N \\to \\infty$, the within
    transformation induces a correlation between the demeaned regressor and the
    demeaned error. Nickell (1981) gives the leading term:

    $$
    \\operatorname{plim}_{N \\to \\infty} (\\hat{\\rho} - \\rho)
      = -\\frac{1 + \\rho}{T - 1}
        \\left[ 1 - \\frac{1}{T} \\frac{1 - \\rho^{T}}{1 - \\rho} \\right] \\Big/ \\Omega
    $$

    The bias is $O(1/T)$, so it does not vanish in $N$. Three consequences for
    the panel in Chapter 4:

    1. With $T = 6$ the downward bias on $\\rho$ is around 15%.
    2. Anderson-Hsiao instruments restore consistency but lose efficiency.
    3. System GMM is the better trade here, subject to the $\\chi^2$ test.

    ## What the simulation shows

    Let $\\varepsilon_{it} \\sim \\mathcal{N}(0, \\sigma^2)$ and draw 5,000 panels at
    each $(N, T)$ pair. Writing the estimator as

    $$\\hat{\\rho} = \\frac{\\sum_{i}\\sum_{t} \\tilde{y}_{i,t-1}\\tilde{y}_{it}}
                        {\\sum_{i}\\sum_{t} \\tilde{y}_{i,t-1}^{2}}$$

    the Monte Carlo mean tracks the analytic expression to within one standard
    error for every $T \\geq 4$.
    """

    private static let promoTex = """
    \\section{Identification}

    The moment condition is $\\mathbb{E}[z_i \\varepsilon_i] = 0$, which gives $k$
    restrictions for $\\ell$ parameters. Identification requires
    $\\operatorname{rank}(\\mathbb{E}[z_i x_i']) = \\ell$.
    """

    /// A plot-looking png (axes plus a rising line) for the asset-row and
    /// preview-sheet screenshots.
    private static func figurePNG() -> Data {
        let size = CGSize(width: 640, height: 400)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let axes = UIBezierPath()
            axes.move(to: CGPoint(x: 60, y: 40))
            axes.addLine(to: CGPoint(x: 60, y: 340))
            axes.addLine(to: CGPoint(x: 600, y: 340))
            UIColor.darkGray.setStroke()
            axes.lineWidth = 3
            axes.stroke()
            let curve = UIBezierPath()
            curve.move(to: CGPoint(x: 60, y: 320))
            curve.addCurve(to: CGPoint(x: 600, y: 70),
                           controlPoint1: CGPoint(x: 260, y: 300),
                           controlPoint2: CGPoint(x: 380, y: 90))
            UIColor.systemRed.setStroke()
            curve.lineWidth = 5
            curve.stroke()
        }
        return image.pngData() ?? Data()
    }

    /// ~400 lines: repeated section of headings, bold/italic, tables,
    /// inline + display math, lists — the render-comparison workload.
    static let stressMarkdown: String = {
        let section = """
        ## Convergence of the estimator

        Let $\\hat\\beta_n$ be the OLS estimator. **Bold claim** and *an italic aside*.

        | Estimator | Bias | Variance | Notes on a deliberately wide column |
        | --- | --- | --- | --- |
        | OLS | $0$ | $\\sigma^2 (X'X)^{-1}$ | classical, homoskedastic errors |
        | Ridge | $-\\lambda(X'X+\\lambda I)^{-1}\\beta$ | smaller | shrinkage toward zero |

        $$ \\sqrt{n}(\\hat\\beta_n - \\beta) \\xrightarrow{d} \\mathcal{N}\\left(0, \\sigma^2 Q^{-1}\\right) $$

        - first item with inline math $\\sum_{i=1}^n x_i \\varepsilon_i$
        - second item
        - third item

        - **Households**: budget constraint as a bullet continuation line
          $$c_t + \\frac{M_t}{p_t} + \\tau_t = y + \\frac{M_{t-1}}{p_t}$$
        - **Government**: the same shape again, indented under its bullet
          $$\\frac{B_t}{p_t} = \\sum_{s=0}^{\\infty} \\Big(\\prod_{j=0}^{s} \\pi_{t+j+1}\\Big)\\Big[\\tau_{t+s+1} - g\\Big]$$

        """
        // The indented `$$` bullets are load-bearing: display math as a
        // list-item continuation is the only shape in the repo that exercises
        // the mid-line block replace (`blockReplaceFrom`).
        return "# Stress document\n\n" + Array(repeating: section, count: 30).joined()
    }()

    static let outlineMarkdown: String = """
    Least squares as projection
    ===========================

    # Setup and notation {#sec-setup}

    We observe $n$ pairs and stack them into $y = X\\beta + \\varepsilon$.

    ## The two projectors

    ::: {#def-hat name="Hat matrix"}
    $P = X(X'X)^{-1}X'$ and $M = I - P$.
    :::

    ![Residual geometry](figures/residuals.png)

    # The projection theorem

    ::: {#thm-pythagoras name="Pythagoras"}
    $\\|y\\|^2 = \\|Py\\|^2 + \\|My\\|^2$.
    :::

    ::: {.proof}
    Orthogonality of $Py$ and $My$; expand the square.
    :::

    ## Consequences

    ::: {#lem-idempotent}
    $P^2 = P$ and $M^2 = M$.
    :::

    ![](figures/convergence.png)

    # Gauss-Markov

    ## Efficiency bound

    ## Robustness caveats
    """

    static let stressTex: String = """
    \\documentclass{article}
    \\begin{document}
    \\section{Integrals} The Gaussian integral \\( \\int_{-\\infty}^{\\infty} e^{-x^2}\\,dx = \\sqrt{\\pi} \\)
    and the display form: \\[ \\sum_{k=0}^{\\infty} \\frac{x^k}{k!} = e^x \\]
    \\end{document}
    """
}
#endif
