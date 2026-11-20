// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BurnRiseToken} from "./BurnRiseToken.sol";
import {BurnRiseHook} from "./BurnRiseHook.sol";

/// @title BurnRise factory
/// @notice Deploys tokens, and the hook once, for the launchpad that created it. Kept separate so the
///         launchpad stays under the contract size limit. Nobody else can use it.
contract BurnRiseFactory {
    address public immutable launchpad;

    error OnlyLaunchpad();

    constructor() {
        launchpad = msg.sender;
    }

    modifier onlyLaunchpad() {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        _;
    }

    function createToken(string calldata name_, string calldata symbol_, uint256 supply_)
        external
        onlyLaunchpad
        returns (address token)
    {
        token = address(new BurnRiseToken(name_, symbol_, supply_, msg.sender));
    }

    /// Init code hash of the hook, which this factory deploys with CREATE2 (used to find its salt).
    function hookInitCodeHash(IPoolManager poolManager) external view returns (bytes32) {
        return keccak256(abi.encodePacked(type(BurnRiseHook).creationCode, abi.encode(poolManager, launchpad)));
    }

    function deployHook(bytes32 salt, IPoolManager poolManager) external onlyLaunchpad returns (BurnRiseHook hook) {
        hook = new BurnRiseHook{salt: salt}(poolManager, launchpad);
    }
}
