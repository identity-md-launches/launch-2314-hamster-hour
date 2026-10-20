// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {HamsterToken} from "../../src/HamsterToken.sol";
import {HamsterHook} from "../../src/HamsterHook.sol";
import {MockERC20} from "./MockERC20.sol";
import {PoolActor} from "./PoolActor.sol";
import {HookMiner} from "./HookMiner.sol";

abstract contract HookFixture is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    uint24 internal constant LP_FEE = 12_500;
    int24 internal constant TICK_SPACING = 60;

    PoolManager internal manager;
    PoolActor internal factory;
    PoolActor internal trader;
    HamsterToken internal token;
    MockERC20 internal pair;
    HamsterHook internal hook;
    PoolKey internal key;
    bytes32 internal hookSalt;

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        factory = new PoolActor(manager);
        trader = new PoolActor(manager);
        token = factory.deployToken();
        pair = new MockERC20("Pair", "PAIR", 1e30);
        (address predicted, bytes32 salt) = HookMiner.find(address(factory), hookInitCodeHash(manager), 0);
        hookSalt = salt;
        hook = factory.deployHook(salt);
        assertEq(address(hook), predicted);
        key = poolKey(address(token), address(pair), address(hook));
    }

    function poolKey(address a, address b, address hook_) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), LP_FEE, TICK_SPACING, IHooks(hook_));
    }

    function hookInitCodeHash(IPoolManager manager_) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(type(HamsterHook).creationCode, abi.encode(manager_)));
    }
}
