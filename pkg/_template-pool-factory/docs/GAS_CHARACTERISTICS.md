# ConstantSumPoolFactory — Gas Characteristics

No gas benchmark suite is included for the template. Qualitatively, the pool does one fixed-point multiply or
divide per swap and per invariant, so swap gas is dominated by the Vault (token transfers, fee accounting) rather
than the pool. A real factory should report measured numbers from a `test/gas/` benchmark (see
`stable-pool-factory` for the format).
