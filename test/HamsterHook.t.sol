// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {HookMiner} from "./helpers/HookMiner.sol";
import {HamsterHook} from "../src/HamsterHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract HamsterHookTest is HookFixture {
    using StateLibrary for IPoolManager;

    function test_onlyInitializationPermissionIsEnabledAndMatchesAddress() public view {
        Hooks.Permissions memory expected;
        expected.beforeInitialize = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_INITIALIZE_FLAG);
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_callbackReturnsCorrectSelectorToManager() public {
        vm.prank(address(manager));
        assertEq(hook.beforeInitialize(address(factory), key, SQRT_PRICE_1_1), IHooks.beforeInitialize.selector);
    }

    function testFuzz_callbackRejectsEveryOtherCaller(address caller) public {
        vm.assume(caller != address(manager));
        vm.prank(caller);
        vm.expectRevert(HamsterHook.NotPoolManager.selector);
        hook.beforeInitialize(address(factory), key, SQRT_PRICE_1_1);
    }

    function test_factoryOpensLaunchPolicyPool() public {
        assertEq(factory.initialize(key, SQRT_PRICE_1_1), 0);
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = IPoolManager(manager).getSlot0(key.toId());
        assertEq(price, SQRT_PRICE_1_1);
        assertEq(tick, 0);
        assertEq(protocolFee, 0);
        assertEq(lpFee, LP_FEE);
    }

    function testFuzz_initializerAndValidOpeningPriceAreNotRestricted(address initializer, uint160 priceSeed) public {
        vm.assume(initializer != address(hook));
        uint160 price = uint160(bound(priceSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        vm.prank(initializer);
        manager.initialize(key, price);
        (uint160 storedPrice,,,) = IPoolManager(manager).getSlot0(key.toId());
        assertEq(storedPrice, price);
    }

    function testFuzz_initializationAcceptsTokenInEitherCurrencySlot(address pairedCurrency) public {
        vm.assume(pairedCurrency != address(0) && pairedCurrency != address(token));
        PoolKey memory anotherKey = poolKey(address(token), pairedCurrency, address(hook));
        factory.initialize(anotherKey, SQRT_PRICE_1_1);
        (uint160 price,,,) = IPoolManager(manager).getSlot0(anotherKey.toId());
        assertEq(price, SQRT_PRICE_1_1);
    }

    function test_multiplePoolsCannotConsumeSharedInitializationState() public {
        factory.initialize(key, SQRT_PRICE_1_1);
        PoolKey memory anotherKey = key;
        anotherKey.tickSpacing = 120;
        factory.initialize(anotherKey, SQRT_PRICE_1_1 / 2);
        (uint160 originalPrice,,,) = IPoolManager(manager).getSlot0(key.toId());
        (uint160 anotherPrice,,,) = IPoolManager(manager).getSlot0(anotherKey.toId());
        assertEq(originalPrice, SQRT_PRICE_1_1);
        assertEq(anotherPrice, SQRT_PRICE_1_1 / 2);
    }

    function test_duplicateInitializationReverts() public {
        factory.initialize(key, SQRT_PRICE_1_1);
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        factory.initialize(key, SQRT_PRICE_1_1);
    }

    function test_initializationBeforeHookDeploymentFailsThenSucceedsAfterDeployment() public {
        (address futureHook, bytes32 salt) =
            HookMiner.find(address(factory), hookInitCodeHash(manager), uint256(hookSalt) + 1);
        PoolKey memory futureKey = key;
        futureKey.hooks = IHooks(futureHook);
        assertEq(futureHook.code.length, 0);
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        factory.initialize(futureKey, SQRT_PRICE_1_1);
        (uint160 emptyPrice,,,) = IPoolManager(manager).getSlot0(futureKey.toId());
        assertEq(emptyPrice, 0);
        assertEq(address(factory.deployHook(salt)), futureHook);
        factory.initialize(futureKey, SQRT_PRICE_1_1);
        (uint160 price,,,) = IPoolManager(manager).getSlot0(futureKey.toId());
        assertEq(price, SQRT_PRICE_1_1);
    }

    function test_anotherManagerCannotInitializeUsingThisHook() public {
        PoolManager anotherManager = new PoolManager(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(HamsterHook.NotPoolManager.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        anotherManager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_constructorRejectsZeroManager() public {
        vm.expectRevert(HamsterHook.InvalidPoolManager.selector);
        new HamsterHook(IPoolManager(address(0)));
    }

    function test_constructorRejectsWrongPermissionBits() public {
        bytes32 codeHash = hookInitCodeHash(manager);
        uint256 candidate;
        address predicted = HookMiner.predict(address(this), bytes32(candidate), codeHash);
        while ((uint160(predicted) & Hooks.ALL_HOOK_MASK) == Hooks.BEFORE_INITIALIZE_FLAG) {
            predicted = HookMiner.predict(address(this), bytes32(++candidate), codeHash);
        }
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new HamsterHook{salt: bytes32(candidate)}(manager);
    }

    function test_constructorDoesNotCallOrRequireCodeAtManager() public {
        IPoolManager futureManager = IPoolManager(makeAddr("future manager"));
        assertEq(address(futureManager).code.length, 0);
        (address predicted, bytes32 salt) = HookMiner.find(address(this), hookInitCodeHash(futureManager), 0);
        HamsterHook deployed = new HamsterHook{salt: salt}(futureManager);
        assertEq(address(deployed), predicted);
        assertEq(address(deployed.poolManager()), address(futureManager));
    }

    function test_allDisabledCallbacksRevertEvenFromManager() public {
        ModifyLiquidityParams memory liquidity = ModifyLiquidityParams(-60, 60, 0, bytes32(0));
        SwapParams memory swap = SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2);
        BalanceDelta zero = BalanceDelta.wrap(0);
        bytes[9] memory calls = [
            abi.encodeCall(IHooks.afterInitialize, (address(factory), key, SQRT_PRICE_1_1, 0)),
            abi.encodeCall(IHooks.beforeAddLiquidity, (address(factory), key, liquidity, "")),
            abi.encodeCall(IHooks.afterAddLiquidity, (address(factory), key, liquidity, zero, zero, "")),
            abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(factory), key, liquidity, "")),
            abi.encodeCall(IHooks.afterRemoveLiquidity, (address(factory), key, liquidity, zero, zero, "")),
            abi.encodeCall(IHooks.beforeSwap, (address(trader), key, swap, "")),
            abi.encodeCall(IHooks.afterSwap, (address(trader), key, swap, zero, "")),
            abi.encodeCall(IHooks.beforeDonate, (address(trader), key, 1, 1, "")),
            abi.encodeCall(IHooks.afterDonate, (address(trader), key, 1, 1, ""))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(address(manager));
            (bool ok,) = address(hook).call(calls[i]);
            assertFalse(ok, "Undeclared callback unexpectedly exists");
        }
    }

    function test_factoryHasNoOwnerPauseOrUpgradeControls() public {
        bytes[5] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("transferOwnership(address)", address(factory)),
            abi.encodeWithSignature("upgradeTo(address)", address(factory)),
            abi.encodeWithSignature("setPoolManager(address)", address(factory))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(address(factory));
            (bool ok,) = address(hook).call(calls[i]);
            assertFalse(ok, "Unexpected administrative entry point");
        }
    }
}
