// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/**
 * @title   Pegged
 * @author  Robert Leifke, @robertleifke
 * @notice  Constant sum automated market maker
 *
 *          A proof of concept Uniswap V4 hook that lets users swap 
 *          between stables and pegged tokens. The curve x * y = k 
 *          is implemented using the NoOp framework and therefore 
 *          several hook permissions have been overwritten.
 */

contract Pegged is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // ----- ERRRORS ----- //

    error AddLiquidityThroughHook(); // thrown when adding liquidity directly to PoolManager

    // ------------------- //

    mapping(PoolId => uint256 count) public beforeSwapCount;
    mapping(PoolId => uint256 count) public afterSwapCount;

    mapping(PoolId => uint256 count) public beforeAddLiquidityCount;
    mapping(PoolId => uint256 count) public beforeRemoveLiquidityCount;

    struct CallbackData {
        uint256 amountEach; // Amount of each token to add as liquidity
        Currency currency0;
        Currency currency1;
        address sender;
    }

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true, // Prevents V4 liquidity
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true, // Override deltas logic
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // Allow beforeSwap to return custom delta
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

    // Settle `amountEach` of each currency from the sender
    // i.e. Create a debit of `amountEach` of each currency with the Pool Manager
    callbackData.currency0.settle(
        poolManager,
        callbackData.sender,
        callbackData.amountEach,
        false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
    );
    callbackData.currency1.settle(
        poolManager,
        callbackData.sender,
        callbackData.amountEach,
        false
    );

    // Since we didn't go through the regular "modify liquidity" flow,
    // the PM just has a debit of `amountEach` of each currency from us
    // We can, in exchange, get back ERC-6909 claim tokens for `amountEach` of each currency
    // to create a credit of `amountEach` of each currency to us
    // that balances out the debit

    // We will store those claim tokens with the hook, so when swaps take place
    // liquidity from our CSMM can be used by minting/burning claim tokens the hook owns
    callbackData.currency0.take(
        poolManager,
        address(this),
        callbackData.amountEach,
        true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
    );
    callbackData.currency1.take(
        poolManager,
        address(this),
        callbackData.amountEach,
        true
    );

    return "";
}

    /*      There are four cases for swaps:

            Case (1):
            -> the user is specifying their swap amount in terms of ETH, so the `specifiedCurrency` is ETH
            -> the `unspecifiedCurrency` is USDC

            Case (2):
            -> the user is specifying their swap amount in terms of USDC, so the `specifiedCurrency` is USDC
            -> the `unspecifiedCurrency` is ETH

            Case (3):
            -> the user is specifying their swap amount in terms of USDC, so the `specifiedCurrency` is USDC
            -> the unspecifiedCurrency is ETH

            Case (4):
            -> the user is specifying their swap amount in terms of ETH, so the `specifiedCurrency` is ETH
            -> the `unspecifiedCurrency` is USDC

    */
    function beforeSwap(
                        address, 
                        PoolKey calldata key, 
                        IPoolManager.SwapParams calldata params, 
                        bytes calldata
        ) external override returns (bytes4, BeforeSwapDelta, uint24) {       
            uint256 amountInOutPositive = params.amountSpecified > 0 
            ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);
    if (params.zeroForOne) {

        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
        int128(-params.amountSpecified), // So `specifiedAmount` = +100
        int128(params.amountSpecified) // Unspecified amount (output delta) = -100
    );
        key.currency0.take(
                            poolManager,
                            address(this),
                            amountInOutPositive,
                            true
                        );
        key.currency1.take(
                            poolManager,
                            address(this),
                            amountInOutPositive,
                            true
        );
    } else {
        key.currency0.settle(
                            poolManager,
                            address(this),
                            amountInOutPositive,
                            true
        );
        key.currency1.settle(
                            poolManager,
                            address(this),
                            amountInOutPositive,
                            true
        );
    }
        return (this.beforeSwap.selector, BeforeSwapDelta, 0);
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        afterSwapCount[key.toId()]++;
        return (BaseHook.afterSwap.selector, 0);
    }

    // Disable adding liquidity to through Pool Manager
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        revert AddLiquidityThroughHook();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        beforeRemoveLiquidityCount[key.toId()]++;
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // Custom add liquidity function
    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
    poolManager.unlock(
        abi.encode(
            CallbackData(
                amountEach,
                key.currency0,
                key.currency1,
                msg.sender
            )
        )
    );
    }


}
