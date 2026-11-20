// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title BurnRise fixed settings
/// @notice The fees and the launch shape are constants: nobody can change them after deployment.
///         Every trade in a BurnRise pool, from any app, pays:
///           - 1.3% of the pair side (0.9% creator, 0.3% platform, 0.1% weekly contest)
///           - 0.5% of the token side, which is burned: sent to 0x...dEaD, where nobody can ever move it
///         That's the 1.8% shown on the website.
library BurnRiseConfig {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant CREATOR_BPS = 90;   // 0.9%
    uint256 internal constant PLATFORM_BPS = 30;  // 0.3%
    uint256 internal constant CONTEST_BPS = 10;   // 0.1%
    uint256 internal constant QUOTE_FEE_BPS = CREATOR_BPS + PLATFORM_BPS + CONTEST_BPS; // 1.3%
    uint256 internal constant BURN_BPS = 50;      // 0.5%

    /// Burned tokens are sent here. Nobody has the key to this address, so they can never move again,
    /// and anyone can see each token's burned total as this address's balance on the explorer.
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// Every token has 1,000,000,000 tokens with 18 decimals, all put into its Uniswap v4 pool at launch.
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    /// Market cap at launch: 2/5 of the pair's graduation target (1.68 ETH for a 4.2 ETH target).
    /// The whole supply sits in the token's pool as one locked position from the launch price on, so the
    /// price follows the constant-product curve (V + paired) * (tokens in the pool) = V * SUPPLY, where V is
    /// this launch market cap and `paired` is the pair asset in the pool. The token graduates when `paired`
    /// reaches the target: by then 5/7 of the supply has been bought and the price is 12.25x the launch price.
    function launchMarketCap(uint256 target) internal pure returns (uint256) {
        return target * 2 / 5;
    }

    /// Uniswap v4 pool settings: the pool itself charges no fee, the hook takes the fees.
    uint24 internal constant POOL_FEE = 0;
    int24 internal constant TICK_SPACING = 200;
    int24 internal constant MIN_TICK = -887_200; // the widest range for tick spacing 200
    int24 internal constant MAX_TICK = 887_200;

    /// Fee taken out of `amount` (rounded down).
    function feeOn(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return FullMath.mulDiv(amount, bps, BPS);
    }

    /// Fee to add on top of `net` so that the fee is `bps` of the total (rounded up).
    function feeOnTop(uint256 net, uint256 bps) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(net, BPS, BPS - bps) - net;
    }
}
