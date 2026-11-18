# fork-gates

Invariant gates run against **real mainnet state** (a pinned fork block), for three
yield-bearing contracts:

| target | address | what is checked |
|---|---|---|
| steakUSDC (Morpho MetaMorpho) | `0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB` | allocator/curator/guardian ACL, reallocate accounting, supply-cap boundaries |
| sUSDe (Ethena) | `0x9D39A5DE30e57443BfF2A8307A4256c8797A3497` | `held == totalAssets + unvested`, round-trip never profits, cooldown→silo→unstake |
| sDAI (Sky) | `0x83F20F44975D03b1b09e64809B757c47f942BEeA` | baseline readings and share-price sanity |

Everything is pinned to **block 26,441,482** so the numbers are reproducible.

## Why this exists

Mock-layer gates prove a property of code you wrote. They do not prove anything
about a deployed contract: the ABI you assumed can be wrong, the source bundle can
be a different version than what is running, and a gate that passes because the
function does not exist is worse than no gate. These suites run against the chain.

Three false passes found while building them (all fixed, kept here as examples):

1. `setFee(uint96)` — the real signature is `uint256`; the wrong selector made a
   non-existent function look like a blocked one.
2. `setGuardian(address)` — no such function; the real flow is
   `submitGuardian` → `acceptGuardian`.
3. Asserting "any revert counts as blocked" — a missing function reverts too, so the
   assertion was always green. Fixed by matching an exact error selector, with the
   ABI fetched from Sourcify as ground truth.

## Reproducing

Three conditions, all required (missing any of them makes `forge` exit silently
with no output, which looks like a hang):

1. `export ETH_RPC=<archive-capable RPC URL>` — the setup reads it with
   `vm.envString`, so passing only `--fork-url` is not enough.
2. `--compute-units-per-second 1` — provider rate limits (HTTP 429 / -32005) on a
   shared key kill the run without an error message.
3. `--fork-block-number 26441482` — otherwise every run starts from a different
   state and the numbers move.

```bash
forge install foundry-rs/forge-std
./run_fork.sh                       # ForkSmoke
./run_fork.sh 26441482 ForkGates    # any other suite
```

## The 26 gates

| suite | gates | coverage |
|---|---|---|
| ForkSmoke | 2 | totalAssets / totalSupply / share price of the three targets |
| ForkGates | 10 | C-2 (held == TA + unvested, round-trip ≤ input, full redeem short by 1 wei) + Auth (exact error selectors, role boundaries) |
| ForkWriteGates | 5 | deposit == previewDeposit, cooldown→silo→unstake, share transfer leaves totals untouched, steak deposit/redeem, donation attack |
| ForkReallocateGates | 4 | non-allocator rejected, totalAssets == floor-sum over 11 markets, real 1,000 USDC move leaves totalAssets unchanged, mismatched amounts rejected |
| ForkBoundaryGates | 5 | supply-cap boundary, cap=0 behaviour, deposit into cap=0, timelock on cap increase, removal of a market that still holds assets |
| ForkACLDiag2 | — | ACL matrix, evidence rather than a gate |

All green; **0 submittable findings**.

## The one impact chain, and why it is not reported

`updateWithdrawQueue` accepts removing a market that still holds assets: the queue
drops 11→10, totalAssets falls by exactly that market's position
(35,796,687,448,255), share price −49.9%, and the market ends with
`enabled=false`. But the function is `onlyAllocatorRole`, so an outsider cannot
reach it. Recorded as a privileged-risk note with the numbers, not as a report.

## Scope and limits

- Single block, single user, small amounts, one reallocation.
- Not covered: removing several markets at once, concurrent users, cross-block
  reallocation, deployed-vs-audited bytecode comparison.
- None of this is a security conclusion about the protocols. It is a measurement of
  what the deployed contracts do at one block.

MIT licensed. Written as a reusable template: swap the addresses and the suite names
and the same shape works for another vault.
