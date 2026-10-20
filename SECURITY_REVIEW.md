# Local security review

Scope: `HamsterToken` and `HamsterHook`, compiled with the repository's pinned
Solidity 0.8.26 settings. The supplied Ethereum and Uniswap v4 security references
and protected-check sources were read before implementation and considered
again against the completed code. This is the implementing contributor's review,
not an independent audit.

## Findings and evidence

| Area | Implementation and verification |
| --- | --- |
| Callback authorization | The sole enabled callback rejects every caller except the immutable PoolManager; fuzzed unauthorized callers and an actual second manager are rejected |
| Address permissions | Constructor uses v4-core's internal validation; tests deploy by real CREATE2 mining, check all fourteen flags, and reject incorrect bits |
| Initialization | Factory can initialize with fee 12500 and tick spacing 60; valid price fuzzing passes; a code-free predicted hook cannot initialize; duplicate initialization fails in core |
| Cross-pool interference | No initialization latch or per-pool mutable state; a second pool can initialize without changing the first |
| Router / sender identity | No per-user or router policy; callback sender data and hook data are not used as authority |
| Swap accounting / NoOp | All swap and delta-return flags are false; differential tests match an unhooked pool in both directions and both amount modes |
| Fee collection / exit | Removal callbacks are disabled; factory zero-change collection receives the full accrued fees; complete liquidity removal succeeds |
| Custody / native ETH | Hook performs no takes, settlements, claim minting, payments, or external calls; trades succeed on a token-only manager with no ETH |
| Reentrancy | Production hook makes no external calls and has no mutable accounting; production ERC-20 transfers do not invoke recipients; no custom reentrancy-sensitive operation exists |
| ERC-20 behavior | Unmodified OpenZeppelin ERC-20 implementation, with one constructor mint; failure paths and allowance rollback tested |
| Conservation | Pool lifecycle tests sum token balances; 128 stateful sequences totaling 8,192 handler actions preserve token supply and summed balances |
| Ownership | No owner, roles, pause, upgrade, or configuration authority in either contract; factory and holder calls to common administrative selectors fail |
| Constructor dependencies | Zero manager rejected; a nonzero manager with no code is accepted without a call; no token, owner, factory, or outside-service address is invented |
| Oracle / randomness / signatures | None are used |
| Gas / loops | Production hook has no loops or writes; no swap callback overhead; bounded salt searches exist only in test helpers |
| Runtime integrity | Artifact inspection found no unresolved library links or CALLCODE, DELEGATECALL, or SELFDESTRUCT opcodes in either production runtime |
| Reproducibility | Compiler and settings pinned, metadata hash disabled, dependencies vendored and hash-checked; tests use no environment or network |

The hook deliberately does not validate the launch policy's pair, fee, spacing,
opening price, or initializing factory. Those are factory/manifest
responsibilities. Unrestricted initialization after deployment cannot change
this hook's behavior or affect other pools. Deployment and launch-pool
initialization must remain atomic, as specified by the launch workflow.

## Checks run locally

- `forge build` with Solidity 0.8.26.
- `forge test`: 42 passing tests, zero failures or skips, including 256 runs for
  each fuzz test and the 8,192-action invariant campaign.
- Required seed:
  `0xd24c194d4d95fb5e8ca54ef18b897bf06805ed2dbc055db29029db56259dc0c2`.
- `forge fmt --check`.
- Production artifact inspection: token runtime 1,551 bytes; hook runtime 589
  bytes, both below EIP-170's 24,576-byte limit. No linked external libraries.
- Vendored-source hashes checked against `lib/dependencies.json`.

No unresolved issue was found within this narrow local review. The protected
admission harness is run separately by IMD against the eventual manifest and
creation code; this report does not claim to have executed that external harness.

## Release responsibilities and limits

The deployer supplies the correct `$poolManager`, mines the salt against actual
factory and constructor inputs, and follows the policy terms in the README.
It must validate the deployed code and pool key and complete the network's
independent adversarial review.

Mainnet fork rehearsal, production IMD behavior, explorer verification, and
operational monitoring were not exercised here. Slither, Mythril, and formal
verification were not run. No transactions were broadcast.

Trading remains exposed to normal AMM price impact, liquidity availability, and
MEV. The contracts provide no trading schedule, allowlist, emergency stop,
custodial withdrawal service, or administrator capable of later adding such a
policy. Assets accidentally sent to the hook have no recovery path.
