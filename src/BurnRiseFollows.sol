// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title BurnRise follows
/// @notice Any wallet can follow or unfollow any other wallet, shown as Followers and Following on the
///         BurnRise website. Holds no funds and has no owner: each wallet changes only who it follows.
/// @dev The counts are kept here so a profile reads them in one call; the lists come from the events.
contract BurnRiseFollows {
    /// When this contract was deployed (unix seconds), so readers know where to start looking for follows.
    uint256 public immutable deployedAt;

    /// follower => followed wallet => true while following
    mapping(address => mapping(address => bool)) public isFollowing;
    /// How many wallets follow this one.
    mapping(address => uint256) public followerCount;
    /// How many wallets this one follows.
    mapping(address => uint256) public followingCount;

    event Followed(address indexed follower, address indexed followed);
    event Unfollowed(address indexed follower, address indexed followed);

    error CantFollow();        // yourself, or the zero address
    error AlreadyFollowing();
    error NotFollowing();

    constructor() {
        deployedAt = block.timestamp;
    }

    /// @notice Follow a wallet.
    function follow(address who) external {
        if (who == msg.sender || who == address(0)) revert CantFollow();
        if (isFollowing[msg.sender][who]) revert AlreadyFollowing();
        isFollowing[msg.sender][who] = true;
        unchecked {
            ++followerCount[who];
            ++followingCount[msg.sender];
        }
        emit Followed(msg.sender, who);
    }

    /// @notice Stop following a wallet.
    function unfollow(address who) external {
        if (!isFollowing[msg.sender][who]) revert NotFollowing();
        isFollowing[msg.sender][who] = false;
        unchecked {
            --followerCount[who];
            --followingCount[msg.sender];
        }
        emit Unfollowed(msg.sender, who);
    }
}
