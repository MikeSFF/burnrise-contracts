// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BurnRiseLaunchpad} from "../src/BurnRiseLaunchpad.sol";

/// Deploys BurnRise on Robinhood Chain (mainnet 4663 or testnet 46630).
///
///   FINAL_OWNER=0xYourSafe \
///   forge script script/Deploy.s.sol --rpc-url <RPC> --broadcast --account <keystore name>
///
/// It deploys the launchpad (which deploys the token factory), finds the hook salt and deploys the hook,
/// enables USDG and NVDA pairs on mainnet, and leaves launches PAUSED so you can test first.
/// When you're happy, the owner calls setLaunchesPaused(false).
contract Deploy is Script {
    /// Uniswap v4 PoolManager, same address on Robinhood Chain mainnet and testnet.
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    /// BurnRise dev wallet: gets the 0.3% platform fee of every trade (override with PLATFORM_WALLET).
    address constant DEV_WALLET = 0xeD980C614724B732352055DD40F23EcD9E32a7bc;
    /// BurnRise weekly contest wallet: gets 0.1% of every trade.
    address constant CONTEST_WALLET = 0xd86600CC30c59d3052bd33F3C54e9325D4a46D91;
    /// Pair assets on Robinhood Chain mainnet (check them on the explorer before deploying).
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6 decimals
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; // 18 decimals

    function run() external returns (BurnRiseLaunchpad pad) {
        require(block.chainid == 4663 || block.chainid == 46630, "not Robinhood Chain");
        address poolManager = vm.envOr("POOL_MANAGER", POOL_MANAGER); // only override for local rehearsals
        require(poolManager.code.length > 0, "no Uniswap v4 PoolManager at this address");
        address platformWallet = vm.envOr("PLATFORM_WALLET", DEV_WALLET);
        address finalOwner = vm.envOr("FINAL_OWNER", address(0));

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        pad = new BurnRiseLaunchpad(IPoolManager(poolManager), deployer, platformWallet, CONTEST_WALLET);

        (bytes32 salt, address hookAddress, bool found) = pad.findHookSalt(0, 500_000);
        require(found, "no hook salt found");
        pad.deployHook(salt);
        require(address(pad.hook()) == hookAddress, "hook address mismatch");

        if (block.chainid == 4663) {
            pad.setPair(USDG, true, 9_000e6); // graduates at 9,000 USDG
            pad.setPair(NVDA, true, 48e18);   // graduates at 48 NVDA
            // also enabled on mainnet: TSLA 0x322F0929c4625eD5bAd873c95208D54E1c003b2d (25e18) and
            // SPCX 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa (67e18), with pad.setPair(<address>, true, <target>)
        }
        pad.setLaunchesPaused(true);

        if (finalOwner != address(0)) pad.transferOwnership(finalOwner); // the Safe must then call acceptOwnership()
        vm.stopBroadcast();

        console.log("BurnRiseLaunchpad:", address(pad));
        console.log("BurnRiseHook:     ", address(pad.hook()));
        console.log("Factory:          ", address(pad.factory()));
        console.log("Launches are paused. Test each pair, then call setLaunchesPaused(false).");
    }
}
