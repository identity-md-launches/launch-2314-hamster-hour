// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice An initialization-only v4 hook that leaves trading and liquidity operations unrestricted.
/// @dev Only beforeInitialize is implemented; all other callback selectors are intentionally absent.
///      No owner, mutable settings, external calls, custom deltas, or hook fees.
contract HamsterHook {
    error InvalidPoolManager();
    error NotPoolManager();

    IPoolManager public immutable poolManager;

    /// @param poolManager_ The launch chain's PoolManager, supplied by the launch as $poolManager.
    /// @dev Requires a CREATE2 address whose low 14 bits are exactly BEFORE_INITIALIZE_FLAG (0x2000).
    ///      Does not call the manager or require any external contract to exist during construction.
    constructor(IPoolManager poolManager_) {
        if (address(poolManager_) == address(0)) revert InvalidPoolManager();
        poolManager = poolManager_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
    }

    /// @notice Acknowledges initialization exclusively from this hook's PoolManager.
    /// @dev This callback makes initialization fail while the predicted hook address has no code.
    ///      The manager validates the pool and price; the launch factory supplies launch policy terms.
    ///      No pool is bound here: using this stateless hook on another pool cannot affect the launch.
    function beforeInitialize(address, PoolKey calldata, uint160) external view returns (bytes4) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        return IHooks.beforeInitialize.selector;
    }
}
