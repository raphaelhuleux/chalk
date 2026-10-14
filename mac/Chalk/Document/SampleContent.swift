import Foundation

/// Seeds a small sample tree on first launch and exposes the app's home folder. The Welcome files
/// are the whole onboarding, so every feature and shortcut they claim must match the engine. Raw
/// string literals keep LaTeX backslashes undoubled.
enum SampleContent {
    /// The app's home folder, in Application Support: ~/Documents is TCC-protected and reads fail
    /// silently until consent. `static let` so the mkdir runs once.
    static let documentsURL: URL = {
        // Under the bundle id: Application Support/Chalk may hold the retired desktop app's data.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.huleux.chalk", isDirectory: true)
        let home = base.appendingPathComponent("Chalk", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }()

    /// Gated on Welcome.md alone, so deleted samples never come back. Existing installs never see
    /// revised copy.
    @discardableResult
    static func ensureSeeded() -> URL {
        let docs = documentsURL
        let welcome = docs.appendingPathComponent("Welcome.md")
        guard !FileManager.default.fileExists(atPath: welcome.path) else { return welcome }

        try? Data(welcomeMarkdown.utf8).write(to: welcome)
        try? Data(welcomeTeX.utf8).write(to: docs.appendingPathComponent("Welcome.tex"))
        let notes = docs.appendingPathComponent("Notes")
        try? FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try? Data(scratchMarkdown.utf8).write(to: notes.appendingPathComponent("Scratch.md"))
        return welcome
    }

    private static let welcomeMarkdown = #"""
    # Welcome to Chalk

    Chalk renders your document where you wrote it. There is no preview pane and no compile step, so there is nothing to keep in sync and nothing to wait for.

    This file is a real document. Type in it, break it, save it with **Cmd S**. Chalk does not autosave: nothing reaches the disk until you ask.

    ## Maths

    Inline maths, like $e^{i\pi} + 1 = 0$, renders as you type. So does display maths:

    $$
    \int_{-\infty}^{\infty} e^{-x^2} \, dx = \sqrt{\pi}
    $$

    Now put the cursor inside that equation. It turns back into the LaTeX you wrote, ready to edit, and renders again when you move away. The source is always one click deep, and everything else here follows from that.

    ## Snippets

    Inside maths, short triggers expand as you type:

    - `//` becomes a fraction, with the cursor waiting in the numerator
    - `;a` becomes α, `;b` becomes β, `;t` becomes θ
    - `sq` a square root, `ooo` infinity, `->` an arrow
    - `sum`, `int` and `lim` arrive with their limits attached

    Anywhere in the document, `;$` opens a display maths block.

    Chalk reads `.hsnips` files, so the expansions you have built up elsewhere come across unchanged. Settings (**Cmd ,**) lists every snippet and lets you write your own.

    ## Callouts

    ::: {#thm-pythagoras name="Pythagoras"}
    For a right triangle with legs $a$ and $b$ and hypotenuse $c$:

    $$
    a^2 + b^2 = c^2
    $$
    :::

    Theorems, lemmas, definitions and proofs number themselves, and the numbers move when you insert something above them. A reference resolves to the number the result has right now, which is @thm-pythagoras.

    ::: {.callout-note}
    Notes, tips and warnings are written the same way, with `.callout-note` in place of the identifier, and carry no number.
    :::

    ## Shortcuts

    | Key | What it does |
    | --- | --- |
    | Cmd S | Save |
    | Cmd J | Show or hide the Library |
    | Cmd ; | Outline of this document |
    | Cmd O | Quick Open: fuzzy search across your folders |
    | Cmd F | Find and replace, including inside rendered maths |
    | Cmd N | New file. Cmd W closes the tab |
    | Ctrl Tab | Next tab. Add Shift for the previous one |
    | Cmd B, Cmd I | Bold, italic |
    | Cmd Shift M | Cycle Normal, Zen, Typewriter and Focus |
    | Cmd =, Cmd - | Bigger, smaller. Cmd 0 puts it back |
    | Cmd , | Settings |

    ## Your files stay yours

    The Library (**Cmd J**) points at folders you already have. Add one with **Shift Cmd O**. There is no import step, no library format and no database: the files stay where you left them, and Chalk reads and writes only the ones you open.

    Chalk makes no network connections, and there is no account and no telemetry.

    ## Next

    **Welcome.tex** is this same tour written in LaTeX. Open it from the Library, or press **Cmd O** and type a few letters of its name.

    Happy writing.

    """#

    private static let welcomeTeX = #"""
    % Welcome.tex — the same tour, in LaTeX.
    %
    % Chalk renders LaTeX, it does not compile it. No PDF pipeline and no
    % bibliography manager: you already have those, and they are better than
    % anything a text editor would bolt on.

    \documentclass{article}
    \usepackage{amsmath}
    \usepackage{amsthm}

    \newtheorem{theorem}{Theorem}
    \newtheorem{definition}{Definition}

    \title{Welcome to Chalk}

    \begin{document}
    \maketitle

    \section{Maths where you wrote it}

    Inline maths, \( \alpha \to \beta \), renders in the line it belongs to. Display maths gets its own:

    \[
      \sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}
    \]

    Put the cursor inside either one. It becomes the source you typed, ready to edit, and renders again when you move away.

    Environments render too, alignment and all:

    \begin{align}
      \nabla \cdot \mathbf{E} &= \frac{\rho}{\varepsilon_0} \\
      \nabla \times \mathbf{B} &= \mu_0 \mathbf{J} + \mu_0 \varepsilon_0 \frac{\partial \mathbf{E}}{\partial t}
    \end{align}

    \section{Theorems}

    \begin{definition}[Orthogonality]
    Two vectors $u$ and $v$ are orthogonal when $\langle u, v \rangle = 0$.
    \end{definition}

    \begin{theorem}[Pythagoras]
    If $u$ and $v$ are orthogonal, then $\|u + v\|^2 = \|u\|^2 + \|v\|^2$.
    \end{theorem}

    \begin{proof}
    Expand $\langle u + v, u + v \rangle$ and drop the cross term, which vanishes by orthogonality.
    \end{proof}

    These are the same boxes the Markdown tour draws, so a project written in both syntaxes looks like one project.

    \section{What stays as source}

    \ref{thm:pythagoras} and \cite{euclid} show the key you wrote, and never a number. LaTeX numbering depends on the whole compile, so a number guessed from a single file would sometimes be wrong, and a wrong number is worse than a visible key.

    \section{Snippets}

    Inside maths, short triggers expand as you type. Type // for a fraction, ;a for \( \alpha \), sq for a square root, and sum for a summation with its limits. Chalk reads your own .hsnips files unchanged — Settings, under Cmd-comma, lists every one of them.

    \section{Getting around}

    Cmd-semicolon opens the outline: the sections, theorems and figures of this document, filtered as you type. Cmd-O is Quick Open across every folder in your Library, which Cmd-J shows and hides. Cmd-S saves, and nothing else does.

    \end{document}

    """#

    private static let scratchMarkdown = #"""
    # Scratch

    A folder of your own, seeded so the Library has something to show.

    Rename it, move it, delete the lot: these are ordinary files in an ordinary folder, and Chalk will not put them back.

    """#
}
