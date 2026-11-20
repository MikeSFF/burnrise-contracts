// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title BurnRise token
/// @notice A plain ERC-20. No owner, no minting after creation, no taxes, no blocklist, no pause.
///         The whole supply is minted once to the BurnRise launchpad, which puts all of it into the
///         token's locked Uniswap v4 pool at launch.
contract BurnRiseToken is ERC20, ERC20Burnable, ERC20Permit {
    constructor(string memory name_, string memory symbol_, uint256 supply_, address to_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _mint(to_, supply_);
    }
}
