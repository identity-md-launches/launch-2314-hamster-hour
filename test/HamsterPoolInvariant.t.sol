// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {HamsterToken} from "../src/HamsterToken.sol";
import {HamsterHook} from "../src/HamsterHook.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {PoolActor} from "./helpers/PoolActor.sol";
import {HookMiner} from "./helpers/HookMiner.sol";

/// @dev Drives the hooked launch pool and an identical unhooked pool with the same random actions.
///      Each hooked actor has a twin on the reference pool; any divergence means the hook changed trading.
contract PoolHandler is Test {
    using StateLibrary for IPoolManager;

    uint256 internal constant ACTORS = 3;
    uint256 internal constant ACTOR_FUNDS = 1e24;
    int256 internal constant SEED_LIQUIDITY = 1e24;
    int24 internal constant TICK_SPACING = 60;

    IPoolManager public immutable manager;
    HamsterToken public immutable token;
    MockERC20 public immutable pair;
    HamsterHook public immutable hook;
    PoolActor public immutable launcher;
    PoolKey internal hooked;
    PoolKey internal unhooked;

    PoolActor[ACTORS] public hookedActors;
    PoolActor[ACTORS] public referenceActors;
    uint256[ACTORS] public ghostLiquidity;
    uint256 public ghostSwaps;
    uint256 public ghostCollects;

    constructor(IPoolManager manager_) {
        manager = manager_;
        launcher = new PoolActor(manager_);
        token = launcher.deployToken();
        pair = new MockERC20("Pair", "PAIR", 1e30);
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(HamsterHook).creationCode, abi.encode(manager_)));
        (, bytes32 salt) = HookMiner.find(address(launcher), initCodeHash, 0);
        hook = launcher.deployHook(salt);

        (address c0, address c1) =
            address(token) < address(pair) ? (address(token), address(pair)) : (address(pair), address(token));
        hooked = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12_500, TICK_SPACING, IHooks(address(hook)));
        unhooked = hooked;
        unhooked.hooks = IHooks(address(0));

        launcher.initialize(hooked, 1 << 96);
        launcher.initialize(unhooked, 1 << 96);
        pair.transfer(address(launcher), 10 * ACTOR_FUNDS);
        launcher.modify(hooked, range(SEED_LIQUIDITY));
        launcher.modify(unhooked, range(SEED_LIQUIDITY));

        for (uint256 i; i < ACTORS; ++i) {
            hookedActors[i] = new PoolActor(manager_);
            referenceActors[i] = new PoolActor(manager_);
            fund(address(hookedActors[i]));
            fund(address(referenceActors[i]));
        }
    }

    function hookedKey() external view returns (PoolKey memory) {
        return hooked;
    }

    function referenceKey() external view returns (PoolKey memory) {
        return unhooked;
    }

    function swap(uint8 actorSeed, bool zeroForOne, bool exactInput, uint256 amountSeed, bytes calldata hookData)
        external
    {
        uint256 i = actorSeed % ACTORS;
        int256 amount = int256(bound(amountSeed, 1, 1e21));
        SwapParams memory params = SwapParams(
            zeroForOne,
            exactInput ? -amount : amount,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        BalanceDelta actual = hookedActors[i].swap(hooked, params, hookData);
        BalanceDelta expected = referenceActors[i].swap(unhooked, params, hookData);
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(expected), "hooked swap diverged");
        ++ghostSwaps;
    }

    function addLiquidity(uint8 actorSeed, uint256 liquiditySeed) external {
        uint256 i = actorSeed % ACTORS;
        uint256 liquidity = bound(liquiditySeed, 1e9, 1e21);
        (BalanceDelta actual,) = hookedActors[i].modify(hooked, range(int256(liquidity)));
        (BalanceDelta expected,) = referenceActors[i].modify(unhooked, range(int256(liquidity)));
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(expected), "hooked deposit diverged");
        ghostLiquidity[i] += liquidity;
    }

    function removeLiquidity(uint8 actorSeed, uint256 liquiditySeed) external {
        uint256 i = actorSeed % ACTORS;
        // Core refuses any update, even a zero collect, on a position that holds nothing.
        if (ghostLiquidity[i] == 0) return;
        uint256 liquidity = bound(liquiditySeed, 0, ghostLiquidity[i]);
        (BalanceDelta actual, BalanceDelta actualFees) = hookedActors[i].modify(hooked, range(-int256(liquidity)));
        (BalanceDelta expected, BalanceDelta expectedFees) =
            referenceActors[i].modify(unhooked, range(-int256(liquidity)));
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(expected), "hooked withdrawal diverged");
        assertEq(BalanceDelta.unwrap(actualFees), BalanceDelta.unwrap(expectedFees), "hooked fees diverged");
        // A withdrawal or zero-change collect never makes the position pay.
        assertGe(actual.amount0(), 0);
        assertGe(actual.amount1(), 0);
        ghostLiquidity[i] -= liquidity;
        if (liquidity == 0) ++ghostCollects;
    }

    /// @dev The launch factory's zero-liquidity fee collection, as the factory performs it.
    function factoryCollect() external {
        (BalanceDelta actual, BalanceDelta actualFees) = launcher.modify(hooked, range(0));
        (BalanceDelta expected,) = launcher.modify(unhooked, range(0));
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(expected), "factory collect diverged");
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(actualFees), "hook deducted from fees");
        assertGe(actual.amount0(), 0);
        assertGe(actual.amount1(), 0);
        ++ghostCollects;
    }

    function donate(uint8 actorSeed, uint256 amount0Seed, uint256 amount1Seed) external {
        uint256 i = actorSeed % ACTORS;
        uint256 amount0 = bound(amount0Seed, 0, 1e19);
        uint256 amount1 = bound(amount1Seed, 0, 1e19);
        BalanceDelta actual = hookedActors[i].donate(hooked, amount0, amount1);
        BalanceDelta expected = referenceActors[i].donate(unhooked, amount0, amount1);
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(expected), "hooked donation diverged");
    }

    function passTime(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 1, 7 days));
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev Exit for everyone: removes every position from both pools.
    function exitAll() external {
        for (uint256 i; i < ACTORS; ++i) {
            uint256 liquidity = ghostLiquidity[i];
            if (liquidity == 0) continue;
            hookedActors[i].modify(hooked, range(-int256(liquidity)));
            referenceActors[i].modify(unhooked, range(-int256(liquidity)));
            ghostLiquidity[i] = 0;
        }
        launcher.modify(hooked, range(-SEED_LIQUIDITY));
        launcher.modify(unhooked, range(-SEED_LIQUIDITY));
    }

    function totalTrackedLiquidity() external view returns (uint256 total) {
        total = uint256(SEED_LIQUIDITY);
        for (uint256 i; i < ACTORS; ++i) {
            total += ghostLiquidity[i];
        }
    }

    function fund(address actor) private {
        launcher.sendToken(token, actor, ACTOR_FUNDS);
        pair.transfer(actor, ACTOR_FUNDS);
    }

    function range(int256 liquidity) private pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams(
            TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), liquidity, bytes32(0)
        );
    }
}

contract HamsterPoolInvariantTest is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal manager;
    PoolHandler internal handler;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        handler = new PoolHandler(manager);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = PoolHandler.swap.selector;
        selectors[1] = PoolHandler.addLiquidity.selector;
        selectors[2] = PoolHandler.removeLiquidity.selector;
        selectors[3] = PoolHandler.factoryCollect.selector;
        selectors[4] = PoolHandler.donate.selector;
        selectors[5] = PoolHandler.passTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    function invariant_hookedPoolStateMatchesUnhookedPool() public view {
        PoolKey memory hooked = handler.hookedKey();
        PoolKey memory ref = handler.referenceKey();
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(hooked.toId());
        (uint160 refPrice, int24 refTick,, uint24 refLpFee) = manager.getSlot0(ref.toId());
        assertEq(price, refPrice, "price diverged");
        assertEq(tick, refTick, "tick diverged");
        assertEq(lpFee, 12_500, "LP fee changed");
        assertEq(lpFee, refLpFee);
        assertEq(protocolFee, 0);
        assertEq(manager.getLiquidity(hooked.toId()), manager.getLiquidity(ref.toId()), "liquidity diverged");
        assertEq(manager.getLiquidity(hooked.toId()), handler.totalTrackedLiquidity(), "untracked liquidity");
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(hooked.toId());
        (uint256 refGrowth0, uint256 refGrowth1) = manager.getFeeGrowthGlobals(ref.toId());
        assertEq(growth0, refGrowth0, "fee growth 0 diverged");
        assertEq(growth1, refGrowth1, "fee growth 1 diverged");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    function invariant_twinActorsHoldIdenticalBalances() public view {
        IERC20 token = IERC20(address(handler.token()));
        IERC20 pair = IERC20(address(handler.pair()));
        for (uint256 i; i < 3; ++i) {
            address a = address(handler.hookedActors(i));
            address b = address(handler.referenceActors(i));
            assertEq(token.balanceOf(a), token.balanceOf(b), "token balances diverged");
            assertEq(pair.balanceOf(a), pair.balanceOf(b), "pair balances diverged");
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    function invariant_hookNeverHoldsValueOrDebt() public view {
        PoolKey memory hooked = handler.hookedKey();
        address hook = address(handler.hook());
        assertEq(hooked.currency0.balanceOf(hook), 0);
        assertEq(hooked.currency1.balanceOf(hook), 0);
        assertEq(hook.balance, 0);
        assertEq(manager.balanceOf(hook, hooked.currency0.toId()), 0);
        assertEq(manager.balanceOf(hook, hooked.currency1.toId()), 0);
        assertEq(manager.currencyDelta(hook, hooked.currency0), 0);
        assertEq(manager.currencyDelta(hook, hooked.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertEq(address(manager).balance, 0, "token-only pools need no ETH");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    function invariant_fixedSupplyIsConservedAcrossHolders() public view {
        IERC20 token = IERC20(address(handler.token()));
        uint256 held = token.balanceOf(address(manager)) + token.balanceOf(address(handler.launcher()));
        for (uint256 i; i < 3; ++i) {
            held += token.balanceOf(address(handler.hookedActors(i)));
            held += token.balanceOf(address(handler.referenceActors(i)));
        }
        assertEq(held, 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    /// @dev After every sequence, every position can leave both pools; the pools stay solvent and identical.
    function afterInvariant() external {
        PoolKey memory hooked = handler.hookedKey();
        PoolKey memory ref = handler.referenceKey();
        handler.exitAll();
        assertEq(manager.getLiquidity(hooked.toId()), 0);
        assertEq(manager.getLiquidity(ref.toId()), 0);
        IERC20 token = IERC20(address(handler.token()));
        IERC20 pair = IERC20(address(handler.pair()));
        for (uint256 i; i < 3; ++i) {
            address a = address(handler.hookedActors(i));
            address b = address(handler.referenceActors(i));
            assertEq(token.balanceOf(a), token.balanceOf(b));
            assertEq(pair.balanceOf(a), pair.balanceOf(b));
        }
    }
}
