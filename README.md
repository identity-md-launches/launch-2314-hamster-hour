# Hamster Hour (HAMSTER)

A Foundry project for an IMD **hook launch**, delivering `HamsterToken` and
`HamsterHook`. Trades remain unrestricted by these contracts.

The brief specifies no trading window, allowlist, tax, or other trading rule.
This implementation therefore enables only the initialization callback required
by the supplied launch checks. “Hour” is part of the token's name, not a schedule.
The hook does not intercept swaps, liquidity changes, or donations.

## Contracts

| Contract | Constructor | Behavior |
| --- | --- | --- |
| `src/HamsterToken.sol:HamsterToken` | No arguments | Standard OpenZeppelin ERC-20; name `Hamster Hour`, symbol `HAMSTER`, 18 decimals; exactly `1000000000000000000000000000` minor units minted once to its deployer |
| `src/HamsterHook.sol:HamsterHook` | `IPoolManager poolManager_` | Immutable manager; validates its own permission bits at construction; acknowledges `beforeInitialize` only from that manager |

The launch factory deploys the token, so it receives the entire supply. There
are no token mint, burn, owner, pause, blocklist, fee, or upgrade entry points.
Transfers and approvals retain standard ERC-20 behavior, including zero-value
transfers, allowance checks, and maximum-value allowances.

The hook has no owner, state-changing configuration, custody logic, or fee
recipient. It neither takes tokens nor creates ERC-6909 claims. It cannot change
the LP fee or return custom accounting deltas. The factory's zero-liquidity fee
collection is unaffected because neither removal callback is enabled.

## Hook permissions and assumptions

`getHookPermissions()` enables **only `beforeInitialize`**. All other thirteen
flags are false. Disabled callback selectors are absent and direct calls to
them revert.

- Required address flags: **8192 (`0x2000`)**.
- Exact mask condition: `uint160(hookAddress) & 0x3fff == 0x2000`.
- Constructor validation uses Uniswap's internal `Hooks.validateHookPermissions`.
- `beforeInitialize` checks `msg.sender == address(poolManager)` and returns
  `IHooks.beforeInitialize.selector`.
- Constructors make no external calls. A zero PoolManager argument is rejected;
  the deployer is responsible for supplying the correct nonzero manager.
- The initialization callback imposes no additional currency, price, fee, or
  initializer restrictions. Core validates the pool parameters; the launch
  factory enforces the launch policy.
- This hook is stateless and reusable. Initializing another pool with it cannot
  consume configuration or affect the launch pool.

The callback is included so initialization at the predicted hook address fails
while that address has no code: PoolManager requires a valid callback response.
The launch must deploy the hook and initialize its pool atomically. Once code
exists, this hook intentionally does not restrict who may initialize pools.

Unrestricted trading still follows Uniswap's liquidity, price-limit, and
settlement rules and incurs its configured LP fee. It does not promise liquidity,
execution at any price, or protection from MEV.

The design uses the general initialization-hook pattern directly against
v4-core interfaces; it needs no BaseHook inheritance, share token, settlement
utility, transient storage, or administrative framework. See Uniswap's
[hook lifecycle and permissions documentation](https://developers.uniswap.org/docs/protocols/v4/concepts/hooks).

## Deployment parameters

The separate IMD manifest step should describe these two production contracts.
This repository deliberately contains no `launch.json`, broadcaster, private-key
configuration, or third production contract.

| Parameter | Value / responsibility |
| --- | --- |
| Launch kind | Hook launch; attach this hook when the pool is created |
| Chain | Ethereum, chain ID `1` |
| Token constructor arguments | `[]` |
| Hook constructor arguments | `["$poolManager"]`, resolved by the deployer to the chain's actual PoolManager |
| Hook flags | `8192` |
| Paired currency | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, 18 decimals |
| Pool fee | `12500` = **1.25%** LP fee; hook fee is zero |
| Tick spacing | `60` |
| Manifest initial-price field | `"79228162514264337593543950336"`, as specified by the launch policy |
| Actual opening price | Factory derives it from the policy's 2,500 IMD opening market cap and token address ordering; the hook accepts any core-valid opening price |
| Owner/admin arguments | None: neither contract has administrative powers |

The policy's supplied owner, `0xbb85c1b7540d9e7b56f7a595fc1ff7dd07cb0823`,
does not receive an on-chain role in these contracts. No missing owner, treasury,
signer, or recipient value needs to be supplied.

The factory handles the policy's 70% pool allocation, 10% swarm distribution,
and remaining 20% payer/treasury allocation. The token performs no allocations
itself, and the hook receives no reserved supply.

The deployer must:

1. Build the exact sources with the pinned settings.
2. Encode the hook constructor with the actual `$poolManager`.
3. Mine a CREATE2 salt against the actual factory address and the full creation
   code plus constructor arguments until the low fourteen address bits equal
   `0x2000`. Any bytecode, constructor, or factory change requires recomputing
   the salt. `test/helpers/HookMiner.sol` demonstrates the formula locally.
4. Deploy the token and mined hook and initialize the sorted token/IMD PoolKey
   in the factory's atomic launch transaction.
5. Verify deployed sources, the manager immutable, flags, token supply, and
   pool key before release.

A pool's hook is fixed in its PoolKey at initialization. Deploying this hook
beside an already-open pool does not attach it. An existing pool opened with
IMD's other hook continues using that hook; attaching this implementation
requires a hook launch and a new pool.

## After launch

There are **no owner setters, external services, keepers, or fee redemption
operations** to configure or maintain. The normal launch factory remains
responsible for its position and LP fee collection. Traders use compatible v4
routers and choose their own slippage limits.

Neither contract can be upgraded or paused. Sending assets directly to the hook
is not a supported operation, and there is no recovery function for accidentally
sent assets. Operational monitoring and any future replacement launch are the
launch operator's responsibilities.

## Local verification

Foundry configuration is at the repository root:

- Solidity **0.8.26**, EVM **Cancun**, optimizer enabled at 200 runs, via IR.
- `bytecode_hash = "none"` for reproducible launch bytecode.
- No FFI, filesystem permissions, or external library linking.
- Dependencies are vendored as ordinary files under `lib/`; no submodules or
  package installation are needed to build or test.

```sh
forge build
forge test
forge fmt --check
```

The requested fuzz seed is pinned in `foundry.toml`:
`0xd24c194d4d95fb5e8ca54ef18b897bf06805ed2dbc055db29029db56259dc0c2`.
Tests use 256 runs per fuzz case and 128 invariant sequences of depth 64.
They do not read or mutate environment variables, depend on an RPC endpoint,
sleep, or broadcast transactions.

The 42 tests cover token metadata/supply, exact transfers, approvals and failure
rollback; actual CREATE2 hook deployment and permission validation; authenticated
initialization and rejection before deployment; and a real local PoolManager's
complete token-pair lifecycle. Trades in both directions and both exact-input
and exact-output modes are compared against an identical unhooked pool. Tests
also exercise fee collection, withdrawal, donations, arbitrary hook data,
passage of time, invalid limits, unpaid swaps, and conservation of funds.
Stateful token invariants exercise transfers and allowances across four holders.

The test PoolManager starts with ERC-20 balances only and zero native ETH.
The paired token is a local standard ERC-20, not a mainnet fork of IMD.
Test actors and mocks live only under `test/` and are not launch contracts.

## Dependencies and review

| Dependency | Pinned revision |
| --- | --- |
| [Uniswap v4-core](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75) | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` |
| [OpenZeppelin Contracts v5.2.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/acd4ff74de833399287ed6b31b4debf6b2b35527) | `acd4ff74de833399287ed6b31b4debf6b2b35527` |
| [forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` |
| [Solmate, PoolManager's Owned dependency](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | `4b47a19038b798b4a33d9749d25e570443520647` |

Vendored files retain upstream licenses and content. Archive and individual-file
SHA-256 digests are recorded in `lib/dependencies.json`. The optional maintenance
script `scripts/vendor_dependencies.py` can restore this exact selection over
the network; normal verification never runs it. Uniswap PoolManager code is
included for local testing, not as an additional production deployment.

See [SECURITY_REVIEW.md](SECURITY_REVIEW.md) for the local review and remaining
release checks. Local testing is not an independent security audit; the
network's independent review and mainnet fork rehearsal remain release steps.
