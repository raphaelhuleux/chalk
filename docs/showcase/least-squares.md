# Least squares as orthogonal projection

We observe $n$ pairs $(x_i, y_i)$, stack them into $y \in \mathbb{R}^n$ and
$X \in \mathbb{R}^{n \times k}$, and assume $X$ has **full column rank**:

$$
y = X\beta + \varepsilon, \qquad \mathbb{E}[\varepsilon \mid X] = 0 .
$$ {#eq-model}

::: {#thm-projection name="Orthogonal projection"}
Let $S \subseteq \mathbb{R}^n$ be a subspace. There is a unique $\hat y \in S$
minimising $\|y - s\|$ over $s \in S$, and it is the unique element of $S$
with $y - \hat y \perp S$.
:::

::: {.proof}
For any $s \in S$ the vector $\hat y - s$ lies in $S$, so Pythagoras gives

$$
\|y - s\|^2 = \|y - \hat y\|^2 + \|\hat y - s\|^2 \ge \|y - \hat y\|^2 .
$$ {#eq-pythagoras}
:::

Applying @thm-projection to @eq-model with $S = \operatorname{col}(X)$ gives
the normal equations:

$$
X^\top X \hat\beta = X^\top y
\quad\Longrightarrow\quad
\hat\beta = (X^\top X)^{-1} X^\top y .
$$ {#eq-normal}

::: {.callout-warning}
Without an intercept, @eq-normal still holds but $R^2$ can be negative.
:::


| Coefficient | Estimate | Std. error | t-statistic |
| :---------- | -------: | ---------: | ----------: |
| Intercept   |    1.043 |      0.284 |        3.67 |
| Slope       |    0.761 |      0.041 |       18.56 |

: Ordinary least squares, $n = 30$. {#tbl-estimates}
