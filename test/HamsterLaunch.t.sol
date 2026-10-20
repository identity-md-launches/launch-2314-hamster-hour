// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {HamsterToken} from "../src/HamsterToken.sol";
import {HamsterHook} from "../src/HamsterHook.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {HookMiner} from "./helpers/HookMiner.sol";

/// @dev Test-only stand-in for the launch factory's single transaction: token, hook, then the pool.
contract AtomicLauncher {
    IPoolManager public immutable manager;
    address public immutable pair;

    constructor(IPoolManager manager_, address pair_) {
        manager = manager_;
        pair = pair_;
    }

    function launch(bytes32 salt, uint24 fee, int24 spacing, uint160 price)
        external
        returns (HamsterToken token, HamsterHook hook, PoolKey memory key)
    {
        token = new HamsterToken();
        hook = new HamsterHook{salt: salt}(manager);
        key = keyFor(address(token), address(hook), fee, spacing);
        manager.initialize(key, price);
    }

    /// @dev Deploys only the contracts, leaving initialization to a later transaction.
    function deployOnly(bytes32 salt) external returns (HamsterToken token, HamsterHook hook) {
        token = new HamsterToken();
        hook = new HamsterHook{salt: salt}(manager);
    }

    function initialize(PoolKey memory key, uint160 price) external {
        manager.initialize(key, price);
    }

    function keyFor(address token, address hook, uint24 fee, int24 spacing) public view returns (PoolKey memory) {
        (address c0, address c1) = token < pair ? (token, pair) : (pair, token);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, IHooks(hook));
    }
}

contract HamsterLaunchTest is Test {
    using StateLibrary for IPoolManager;

    uint24 private constant LP_FEE = 12_500;
    int24 private constant SPACING = 60;
    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;

    IPoolManager private manager;
    MockERC20 private pair;
    AtomicLauncher private launcher;
    bytes32 private salt;
    address private predictedHook;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        pair = new MockERC20("Pair", "PAIR", 1e30);
        launcher = new AtomicLauncher(manager, address(pair));
        (predictedHook, salt) = HookMiner.find(address(launcher), initCodeHash(), 0);
    }

    function test_oneTransactionLaunchOpensThePoolWithTheHookAttached() public {
        (HamsterToken token, HamsterHook hook, PoolKey memory key) =
            launcher.launch(salt, LP_FEE, SPACING, SQRT_PRICE_1_1);
        assertEq(address(hook), predictedHook);
        assertEq(address(key.hooks), address(hook), "pool key does not carry the hook");
        assertEq(token.balanceOf(address(launcher)), token.totalSupply());
        assertEq(token.totalSupply(), 1e27);
        (uint160 price,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(price, SQRT_PRICE_1_1);
        assertEq(lpFee, LP_FEE);
    }

    /// @dev The same currencies and terms without the hook are a different pool: the hook is part of the id.
    function test_hookIsFixedInThePoolIdentity() public {
        (HamsterToken token, HamsterHook hook, PoolKey memory key) =
            launcher.launch(salt, LP_FEE, SPACING, SQRT_PRICE_1_1);
        PoolKey memory unhooked = launcher.keyFor(address(token), address(0), LP_FEE, SPACING);
        assertTrue(PoolId.unwrap(key.toId()) != PoolId.unwrap(unhooked.toId()));
        (uint160 unhookedPrice,,,) = manager.getSlot0(unhooked.toId());
        assertEq(unhookedPrice, 0, "an unhooked pool was opened too");
        // Re-opening the launch pool, with any price, cannot replace or detach its hook.
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        launcher.initialize(key, SQRT_PRICE_1_1 / 2);
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_launchWithAMisminedSaltRevertsEverything() public {
        bytes32 badSalt = salt;
        address badHook = predictedHook;
        while ((uint160(badHook) & Hooks.ALL_HOOK_MASK) == Hooks.BEFORE_INITIALIZE_FLAG) {
            badSalt = bytes32(uint256(badSalt) + 1);
            badHook = HookMiner.predict(address(launcher), badSalt, initCodeHash());
        }
        address tokenAt = vm.computeCreateAddress(address(launcher), vm.getNonce(address(launcher)));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, badHook));
        launcher.launch(badSalt, LP_FEE, SPACING, SQRT_PRICE_1_1);
        assertEq(tokenAt.code.length, 0, "a token survived a failed launch");
        assertEq(badHook.code.length, 0);
    }

    function test_launchRevertsAtomicallyWhenCoreRejectsThePoolTerms() public {
        address tokenAt = vm.computeCreateAddress(address(launcher), vm.getNonce(address(launcher)));
        vm.expectRevert(abi.encodeWithSelector(IPoolManager.TickSpacingTooSmall.selector, int24(0)));
        launcher.launch(salt, LP_FEE, 0, SQRT_PRICE_1_1);
        assertEq(tokenAt.code.length, 0);
        assertEq(predictedHook.code.length, 0);

        vm.expectRevert(abi.encodeWithSelector(LPFeeLibrary.LPFeeTooLarge.selector, uint24(1_000_001)));
        launcher.launch(salt, 1_000_001, SPACING, SQRT_PRICE_1_1);
        assertEq(predictedHook.code.length, 0);

        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, TickMath.MIN_SQRT_PRICE - 1));
        launcher.launch(salt, LP_FEE, SPACING, TickMath.MIN_SQRT_PRICE - 1);
        assertEq(predictedHook.code.length, 0);
    }

    function test_secondLaunchOnTheSameSaltReverts() public {
        launcher.launch(salt, LP_FEE, SPACING, SQRT_PRICE_1_1);
        // CREATE2 collision: the hook address is already taken.
        vm.expectRevert();
        launcher.launch(salt, LP_FEE, SPACING, SQRT_PRICE_1_1);
    }

    /// @dev Someone who predicts the token and hook addresses cannot open the launch pool first.
    function test_launchPoolCannotBeOpenedBeforeTheLaunchTransaction() public {
        address tokenAt = vm.computeCreateAddress(address(launcher), vm.getNonce(address(launcher)));
        PoolKey memory predictedKey = launcher.keyFor(tokenAt, predictedHook, LP_FEE, SPACING);
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        manager.initialize(predictedKey, TickMath.MIN_SQRT_PRICE);

        (,, PoolKey memory key) = launcher.launch(salt, LP_FEE, SPACING, SQRT_PRICE_1_1);
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(predictedKey.toId()));
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, SQRT_PRICE_1_1);
    }

    /// @dev Documents why the launch must be one transaction: once the hook has code it does not
    ///      restrict who opens pools, so a split launch lets anyone pick the opening price first.
    function test_splitLaunchLetsAnyoneOpenThePoolFirst() public {
        (HamsterToken token, HamsterHook hook) = launcher.deployOnly(salt);
        PoolKey memory key = launcher.keyFor(address(token), address(hook), LP_FEE, SPACING);
        vm.prank(makeAddr("attacker"));
        manager.initialize(key, TickMath.MIN_SQRT_PRICE);
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        launcher.initialize(key, SQRT_PRICE_1_1);
    }

    function testFuzz_callbackFromManagerIsStatelessForAnyInput(address sender, PoolKey memory key, uint160 price)
        public
    {
        (,, PoolKey memory launchKey) = launcher.launch(salt, LP_FEE, SPACING, SQRT_PRICE_1_1);
        HamsterHook hook = HamsterHook(address(launchKey.hooks));
        vm.prank(address(manager));
        assertEq(hook.beforeInitialize(sender, key, price), IHooks.beforeInitialize.selector);
        assertEq(vm.load(address(hook), bytes32(0)), bytes32(0));
        (uint160 stored,,,) = manager.getSlot0(launchKey.toId());
        assertEq(stored, SQRT_PRICE_1_1);
    }

    function test_runtimeCodeHasNoEscapeHatch() public {
        (HamsterToken token, HamsterHook hook,) = launcher.launch(salt, LP_FEE, SPACING, SQRT_PRICE_1_1);
        assertNoEscapeHatch(address(hook).code);
        assertNoEscapeHatch(address(token).code);
    }

    function assertNoEscapeHatch(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff, "SELFDESTRUCT");
            assertTrue(op != 0xf4, "DELEGATECALL");
            assertTrue(op != 0xf2, "CALLCODE");
        }
    }

    function initCodeHash() private view returns (bytes32) {
        return keccak256(abi.encodePacked(type(HamsterHook).creationCode, abi.encode(manager)));
    }
}
