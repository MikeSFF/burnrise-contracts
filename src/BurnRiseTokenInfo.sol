// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// The one launchpad function this contract reads: who the creator of a token is.
interface IBurnRiseLaunchpadCreators {
    function tokenInfo(address token)
        external
        view
        returns (
            address creator,
            uint64 launchedAt,
            bool graduated,
            address quote,
            uint128 target,
            uint128 liquidity,
            int24 tickLower,
            int24 tickUpper
        );
}

/// @title BurnRise token info
/// @notice Lets a token's creator update its picture, description and links after launch. The website shows the
///         latest update instead of what was set at launch. Holds no funds and has no owner.
/// @dev Only the creator the launchpad has on record can update (the creator can hand that role to another
///      wallet with the launchpad's setCreator). The info is the same short JSON text as at launch, at most
///      512 bytes, kept in the event; a new picture rides at the end of the calldata, after the arguments, the
///      same way it does at launch. The contract ignores those bytes and the website reads them back.
contract BurnRiseTokenInfo {
    uint256 public constant MAX_INFO_BYTES = 512;

    IBurnRiseLaunchpadCreators public immutable launchpad;
    /// When this contract was deployed (unix seconds), so readers know where to start looking for updates.
    uint256 public immutable deployedAt;

    /// `info`: {"image":"tx" | "keep", "description": ..., "website": ..., "x": ..., "telegram": ...}.
    /// "tx" = a new picture at the end of this transaction's calldata, "keep" = keep the current one, no image = none.
    event TokenInfoSet(address indexed token, address indexed creator, string info);

    error NotCreator();
    error InfoTooLong();

    constructor(address launchpad_) {
        launchpad = IBurnRiseLaunchpadCreators(launchpad_);
        deployedAt = block.timestamp;
    }

    /// @notice Update your token's picture, description and links.
    function setTokenInfo(address token, string calldata info) external {
        (address creator,,,,,,,) = launchpad.tokenInfo(token);
        if (creator == address(0) || creator != msg.sender) revert NotCreator();
        if (bytes(info).length > MAX_INFO_BYTES) revert InfoTooLong();
        emit TokenInfoSet(token, msg.sender, info);
    }
}
