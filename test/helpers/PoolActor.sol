// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HamsterToken} from "../../src/HamsterToken.sol";
import {HamsterHook} from "../../src/HamsterHook.sol";

/// @dev Test-only actor for a factory, LP, or trader. Settles exclusively from its own prefunded balance.
///      This is not a production router and is not deployed by the launch.
contract PoolActor is IUnlockCallback {
    enum Action {
        Modify,
        Swap,
        Donate
    }

    IPoolManager public immutable manager;
    address private immutable controller;

    constructor(IPoolManager manager_) {
        manager = manager_;
        controller = msg.sender;
    }

    modifier onlyController() {
        require(msg.sender == controller, "Not test controller");
        _;
    }

    function deployToken() external onlyController returns (HamsterToken) {
        return new HamsterToken();
    }

    function deployHook(bytes32 salt) external onlyController returns (HamsterHook) {
        return new HamsterHook{salt: salt}(manager);
    }

    function sendToken(IERC20 token, address recipient, uint256 amount) external onlyController {
        require(token.transfer(recipient, amount), "Token transfer failed");
    }

    function initialize(PoolKey memory key, uint160 price) external onlyController returns (int24) {
        return manager.initialize(key, price);
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        onlyController
        returns (BalanceDelta delta, BalanceDelta fees)
    {
        return abi.decode(
            manager.unlock(abi.encode(Action.Modify, key, abi.encode(params))), (BalanceDelta, BalanceDelta)
        );
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        external
        onlyController
        returns (BalanceDelta delta)
    {
        (delta,) = abi.decode(
            manager.unlock(abi.encode(Action.Swap, key, abi.encode(params, hookData))), (BalanceDelta, BalanceDelta)
        );
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1)
        external
        onlyController
        returns (BalanceDelta delta)
    {
        (delta,) = abi.decode(
            manager.unlock(abi.encode(Action.Donate, key, abi.encode(amount0, amount1))), (BalanceDelta, BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "Not PoolManager");
        (Action action, PoolKey memory key, bytes memory payload) = abi.decode(data, (Action, PoolKey, bytes));
        BalanceDelta delta;
        BalanceDelta fees;
        if (action == Action.Modify) {
            ModifyLiquidityParams memory params = abi.decode(payload, (ModifyLiquidityParams));
            (delta, fees) = manager.modifyLiquidity(key, params, "");
        } else if (action == Action.Swap) {
            (SwapParams memory params, bytes memory hookData) = abi.decode(payload, (SwapParams, bytes));
            delta = manager.swap(key, params, hookData);
        } else {
            (uint256 amount0, uint256 amount1) = abi.decode(payload, (uint256, uint256));
            delta = manager.donate(key, amount0, amount1, "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta, fees);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 owed = uint256(-int256(delta));
            manager.sync(currency);
            require(IERC20(Currency.unwrap(currency)).transfer(address(manager), owed), "Settlement transfer failed");
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(int256(delta)));
        }
    }
}

/// @dev Deliberately broken settlement, used to verify PoolManager rolls an unpaid swap back.
contract UnsettledActor is IUnlockCallback {
    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external {
        manager.unlock(abi.encode(key, params));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "Not PoolManager");
        (PoolKey memory key, SwapParams memory params) = abi.decode(data, (PoolKey, SwapParams));
        manager.swap(key, params, "");
        return "";
    }
}
