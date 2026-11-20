// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title BurnRise profiles
/// @notice A username, a short bio and a picture for any wallet, shown on the BurnRise website.
///         Holds no funds and has no owner: each wallet edits only its own profile.
///         Usernames are 3 to 20 letters, digits or _, and unique whatever the letter case
///         ("Vaseto" and "vaseto" are the same name). A few names, such as "burnrise", are kept for the team.
/// @dev Only the username is stored. The bio is in the ProfileSet event, and a new picture rides at the end
///      of setProfile's calldata, after the arguments (the same way token pictures ride in launch
///      transactions); the contract ignores those bytes and the website reads them back from the transaction.
contract BurnRiseProfiles {
    uint256 public constant MIN_NAME = 3;
    uint256 public constant MAX_NAME = 20;
    uint256 public constant MAX_BIO_BYTES = 640; // 160 characters, even if every one is an emoji

    /// The team wallet: the only wallet that can use the kept names.
    address public immutable team;
    /// When this contract was deployed (unix seconds), so readers know where to start looking for profiles.
    uint256 public immutable deployedAt;

    /// Each wallet's username, as typed ('' = none).
    mapping(address => string) public nameOf;
    mapping(bytes32 => address) private _nameOwner; // lowercased username => wallet
    mapping(bytes32 => bool) public reserved;       // lowercased username => kept for the team

    /// picture: 0 = no picture, 1 = a new picture at the end of this transaction's calldata, 2 = keep the last one.
    event ProfileSet(address indexed user, string name, string bio, uint8 picture);

    error BadName();
    error NameTaken();
    error BioTooLong();
    error BadPicture();

    constructor(address team_) {
        team = team_;
        deployedAt = block.timestamp;
        string[12] memory kept = [
            "burnrise", "burnrisex", "burnrisefun", "burnrise_fun", "burnrise_official", "burnriseofficial",
            "official", "admin", "support", "team", "moderator", "robinhood"
        ];
        for (uint256 i; i < kept.length; ++i) {
            (bool ok, bytes32 k) = _key(kept[i]);
            if (ok) reserved[k] = true;
        }
    }

    /// @notice Set your username, bio and picture in one go. An empty name removes your username.
    ///         Changing your username frees the old one for others.
    function setProfile(string calldata name, string calldata bio, uint8 picture) external {
        if (picture > 2) revert BadPicture();
        if (bytes(bio).length > MAX_BIO_BYTES) revert BioTooLong();
        (bool ok, bytes32 newKey) = _key(name);
        if (!ok) revert BadName();
        (, bytes32 oldKey) = _key(nameOf[msg.sender]);
        if (newKey != oldKey) {
            if (newKey != bytes32(0)) {
                if (_nameOwner[newKey] != address(0) || (reserved[newKey] && msg.sender != team)) revert NameTaken();
                _nameOwner[newKey] = msg.sender;
            }
            if (oldKey != bytes32(0)) delete _nameOwner[oldKey];
        }
        nameOf[msg.sender] = name;
        emit ProfileSet(msg.sender, name, bio, picture);
    }

    /// @notice Who uses a username, whatever the letter case: the wallet, the team for a kept name nobody
    ///         uses yet, or address(0) when it's free (or not a valid name).
    function ownerOfName(string calldata name) external view returns (address) {
        (bool ok, bytes32 k) = _key(name);
        if (!ok || k == bytes32(0)) return address(0);
        address who = _nameOwner[k];
        if (who == address(0) && reserved[k]) return team;
        return who;
    }

    /// The lowercased name's hash; (true, 0) for '', (false, 0) for a name that breaks the rules.
    function _key(string memory name) private pure returns (bool, bytes32) {
        bytes memory b = bytes(name);
        if (b.length == 0) return (true, bytes32(0));
        if (b.length < MIN_NAME || b.length > MAX_NAME) return (false, bytes32(0));
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c >= "A" && c <= "Z") b[i] = bytes1(uint8(c) + 32);
            else if (!((c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "_")) return (false, bytes32(0));
        }
        return (true, keccak256(b));
    }
}
