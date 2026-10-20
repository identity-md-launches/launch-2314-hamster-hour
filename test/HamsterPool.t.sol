// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolActor, UnsettledActor} from "./helpers/PoolActor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract HamsterPoolTest is HookFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    int256 private constant LIQUIDITY = 1_000_000 ether;
    uint256 private constant TRADER_FUNDS = 100_000 ether;
    PoolKey private referenceKey;

    function setUp() public override {
        super.setUp();
        referenceKey = key;
        // Explicitly unhooked reference pool with identical AMM parameters.
        referenceKey.hooks = IHooks(address(0));
        factory.initialize(key, SQRT_PRICE_1_1);
        factory.initialize(referenceKey, SQRT_PRICE_1_1);
        assertTrue(pair.transfer(address(factory), 10_000_000 ether));
        factory.sendToken(token, address(trader), TRADER_FUNDS);
        assertTrue(pair.transfer(address(trader), TRADER_FUNDS));
        factory.modify(key, liquidityParams(LIQUIDITY));
        factory.modify(referenceKey, liquidityParams(LIQUIDITY));
    }

    function test_exactInputAndOutputBuysAndSellsMatchUnhookedPool() public {
        for (uint256 i; i < 4; ++i) {
            bool zeroForOne = i % 2 == 0;
            bool exactInput = i < 2;
            compareSwap(zeroForOne, exactInput, 1 ether, "");
        }
        assertEq(address(manager).balance, 0, "Token-only manager should need no ETH");
        assertConservation();
    }

    function testFuzz_swapsMatchUnhookedPool(
        bool zeroForOne,
        bool exactInput,
        uint96 amountSeed,
        bytes calldata arbitraryHookData
    ) public {
        uint256 amount = bound(amountSeed, 1e6, 10_000 ether);
        compareSwap(zeroForOne, exactInput, amount, arbitraryHookData);
        assertConservation();
    }

    function test_anotherTraderCanBuyAndSellWithArbitraryHookData() public {
        PoolActor anotherTrader = new PoolActor(manager);
        factory.sendToken(token, address(anotherTrader), 100 ether);
        assertTrue(pair.transfer(address(anotherTrader), 100 ether));
        BalanceDelta first = anotherTrader.swap(key, swapParams(true, -1 ether), hex"010203");
        BalanceDelta second = anotherTrader.swap(key, swapParams(false, -1 ether), abi.encode(address(this)));
        assertLt(first.amount0(), 0);
        assertGt(first.amount1(), 0);
        assertGt(second.amount0(), 0);
        assertLt(second.amount1(), 0);
        assertNoHookAssetsOrDebts();
    }

    function test_tradingRemainsOpenAcrossHourDayAndBlockChanges() public {
        uint256 startTime = vm.getBlockTimestamp();
        uint256 startBlock = vm.getBlockNumber();
        compareSwap(true, true, 1 ether, "");
        vm.warp(startTime + 1 hours);
        vm.roll(startBlock + 1);
        compareSwap(false, true, 1 ether, "");
        vm.warp(startTime + 1 days);
        vm.roll(startBlock + 100);
        compareSwap(true, false, 1 ether, "");
        vm.warp(startTime + 30 days);
        compareSwap(false, false, 1 ether, "");
    }

    function test_factoryCollectsBothCurrenciesWithZeroLiquidityChange() public {
        trader.swap(key, swapParams(true, -100 ether), "");
        trader.swap(key, swapParams(false, -100 ether), "");
        uint256 before0 = key.currency0.balanceOf(address(factory));
        uint256 before1 = key.currency1.balanceOf(address(factory));
        uint128 beforeLiquidity = IPoolManager(manager).getLiquidity(key.toId());

        (BalanceDelta delta, BalanceDelta fees) = factory.modify(key, liquidityParams(0));

        assertGt(fees.amount0(), 0);
        assertGt(fees.amount1(), 0);
        assertEq(BalanceDelta.unwrap(delta), BalanceDelta.unwrap(fees), "Hook must not deduct from fees");
        assertEq(key.currency0.balanceOf(address(factory)), before0 + uint128(fees.amount0()));
        assertEq(key.currency1.balanceOf(address(factory)), before1 + uint128(fees.amount1()));
        assertEq(IPoolManager(manager).getLiquidity(key.toId()), beforeLiquidity);
        (BalanceDelta again,) = factory.modify(key, liquidityParams(0));
        assertEq(BalanceDelta.unwrap(again), 0, "Already collected fees must not be paid twice");
        assertNoHookAssetsOrDebts();
        assertConservation();
    }

    function test_factoryCanRemoveAllItsLiquidityAfterTrading() public {
        trader.swap(key, swapParams(true, -1 ether), "");
        (BalanceDelta withdrawn,) = factory.modify(key, liquidityParams(-LIQUIDITY));
        assertGt(withdrawn.amount0(), 0);
        assertGt(withdrawn.amount1(), 0);
        assertEq(IPoolManager(manager).getLiquidity(key.toId()), 0);
        assertNoHookAssetsOrDebts();
        assertConservation();
    }

    function test_otherProvidersCanAddDonateCollectAndRemove() public {
        PoolActor provider = new PoolActor(manager);
        factory.sendToken(token, address(provider), 1_000 ether);
        assertTrue(pair.transfer(address(provider), 1_000 ether));
        provider.modify(key, liquidityParams(100 ether));
        BalanceDelta donated = trader.donate(key, 1 ether, 2 ether);
        assertEq(donated.amount0(), -1 ether);
        assertEq(donated.amount1(), -2 ether);
        (BalanceDelta collected, BalanceDelta fees) = provider.modify(key, liquidityParams(0));
        assertGt(collected.amount0(), 0);
        assertGt(collected.amount1(), 0);
        assertEq(BalanceDelta.unwrap(collected), BalanceDelta.unwrap(fees));
        (BalanceDelta withdrawn,) = provider.modify(key, liquidityParams(-100 ether));
        assertGt(withdrawn.amount0(), 0);
        assertGt(withdrawn.amount1(), 0);
        assertEq(IPoolManager(manager).getLiquidity(key.toId()), uint128(uint256(LIQUIDITY)));
        assertNoHookAssetsOrDebts();
    }

    function test_invalidPriceLimitRevertsWithoutChangingBalances() public {
        uint256 before0 = key.currency0.balanceOf(address(trader));
        uint256 before1 = key.currency1.balanceOf(address(trader));
        vm.expectRevert(abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, SQRT_PRICE_1_1, SQRT_PRICE_1_1));
        trader.swap(key, SwapParams(true, -1 ether, SQRT_PRICE_1_1), "");
        assertEq(key.currency0.balanceOf(address(trader)), before0);
        assertEq(key.currency1.balanceOf(address(trader)), before1);
        assertEq(price(key), SQRT_PRICE_1_1);
        assertNoHookAssetsOrDebts();
    }

    function test_swapStillRequiresAnUnlockedManager() public {
        vm.expectRevert(IPoolManager.ManagerLocked.selector);
        manager.swap(key, swapParams(true, -1 ether), "");
    }

    function test_zeroAmountSwapIsRejectedByCore() public {
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        trader.swap(key, swapParams(true, 0), "");
    }

    function test_failedPaymentRollsBackEntireSwap() public {
        PoolActor unfunded = new PoolActor(manager);
        uint256 managerBefore0 = key.currency0.balanceOf(address(manager));
        uint256 managerBefore1 = key.currency1.balanceOf(address(manager));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(unfunded), 0, 1 ether)
        );
        unfunded.swap(key, swapParams(true, -1 ether), "");
        assertEq(key.currency0.balanceOf(address(manager)), managerBefore0);
        assertEq(key.currency1.balanceOf(address(manager)), managerBefore1);
        assertEq(key.currency0.balanceOf(address(unfunded)), 0);
        assertEq(key.currency1.balanceOf(address(unfunded)), 0);
        assertEq(price(key), SQRT_PRICE_1_1);
        assertNoHookAssetsOrDebts();
    }

    function test_unsettledSwapCannotBypassCoreAccounting() public {
        UnsettledActor unsettled = new UnsettledActor(manager);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        unsettled.swap(key, swapParams(true, -1 ether));
        assertEq(price(key), SQRT_PRICE_1_1);
        assertNoHookAssetsOrDebts();
        assertConservation();
    }

    function compareSwap(bool zeroForOne, bool exactInput, uint256 amount, bytes memory hookData) private {
        SwapParams memory params = swapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount));
        BalanceDelta actual = trader.swap(key, params, hookData);
        BalanceDelta expected = trader.swap(referenceKey, params, hookData);
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(expected), "Hook changed the trader's amounts");
        assertEq(price(key), price(referenceKey), "Hook changed AMM price");
        int128 input = zeroForOne ? actual.amount0() : actual.amount1();
        int128 output = zeroForOne ? actual.amount1() : actual.amount0();
        assertLt(input, 0);
        assertGt(output, 0);
        if (exactInput) assertEq(-int256(input), int256(amount));
        else assertEq(int256(output), int256(amount));
        (,,, uint24 lpFee) = IPoolManager(manager).getSlot0(key.toId());
        assertEq(lpFee, LP_FEE);
        assertNoHookAssetsOrDebts();
    }

    function assertNoHookAssetsOrDebts() private view {
        assertEq(key.currency0.balanceOf(address(hook)), 0);
        assertEq(key.currency1.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(hook), key.currency0), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(hook), key.currency1), 0);
        assertEq(IPoolManager(manager).getNonzeroDeltaCount(), 0);
        assertFalse(IPoolManager(manager).isUnlocked());
    }

    function assertConservation() private view {
        assertEq(
            token.balanceOf(address(factory)) + token.balanceOf(address(trader)) + token.balanceOf(address(manager)),
            token.totalSupply()
        );
        assertEq(
            pair.balanceOf(address(this)) + pair.balanceOf(address(factory)) + pair.balanceOf(address(trader))
                + pair.balanceOf(address(manager)),
            pair.totalSupply()
        );
    }

    function price(PoolKey memory pool) private view returns (uint160 value) {
        (value,,,) = IPoolManager(manager).getSlot0(pool.toId());
    }

    function liquidityParams(int256 amount) private pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams(
            TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), amount, bytes32(0)
        );
    }

    function swapParams(bool zeroForOne, int256 amount) private pure returns (SwapParams memory) {
        return SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }
}
