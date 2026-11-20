# BurnRise contracts

Smart contracts for the BurnRise meme-token launchpad on Robinhood Chain. Every token launches straight into its own Uniswap v4 pool, so it can be traded on Uniswap, DexScreener and any app that supports Uniswap v4 from its first trade.

> **Audit pending.** These contracts are tested (see Tests) but haven't had an independent audit yet.
> On mainnet, new launches stay paused until the audit is done.

## Deployed on Robinhood Chain mainnet (chain 4663)

| Contract | Address |
|---|---|
| `BurnRiseLaunchpad` | [`0x2173C7Bc46c3e222BDA86E079Fa10c92473D72F0`](https://robinhoodchain.blockscout.com/address/0x2173C7Bc46c3e222BDA86E079Fa10c92473D72F0?tab=contract) |
| `BurnRiseHook` | [`0x1e9A5eD566669FDE4D7d5fd48A2F077b41CEa8cC`](https://robinhoodchain.blockscout.com/address/0x1e9A5eD566669FDE4D7d5fd48A2F077b41CEa8cC?tab=contract) |
| `BurnRiseFactory` | [`0xC24aAb25198A8C76f9D4f575284Fc8767c566829`](https://robinhoodchain.blockscout.com/address/0xC24aAb25198A8C76f9D4f575284Fc8767c566829?tab=contract) |
| Uniswap v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |

- All three are verified on Blockscout (exact match), built from `BurnRise.flattened.sol` with solc 0.8.26, optimizer on with 200 runs, EVM cancun.
- The hook's permissions: `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta` and `afterSwapReturnDelta`. It has no owner and can't be upgraded.
- Pairs enabled, with their graduation targets: ETH 4.2, USDG 9,000, NVDA 48, TSLA 25, SPCX 67.

## What's in here

| File | What it does |
|---|---|
| `src/BurnRiseLaunchpad.sol` | Launches tokens into their locked Uniswap v4 pools, lets people buy and sell through those pools, splits the fees, pays creators, and marks graduation. This is the contract the website talks to. |
| `src/BurnRiseHook.sol` | Uniswap v4 hook on every BurnRise pool. It charges the fees and the burn on every trade, whichever app sends it, and spots graduation. |
| `src/BurnRiseToken.sol` | The token every launch creates: a plain ERC-20 with burn and permit, and no owner, minting, tax, blocklist or pause. |
| `src/BurnRiseFactory.sol` | Deploys the tokens, and the hook once, for the launchpad. The launchpad creates it itself. |
| `src/BurnRiseConfig.sol` | The fixed numbers: fees, supply, launch price, pool settings. |
| `src/BurnRiseProfiles.sol` | Usernames, bios and pictures for wallets, shown on the website. Holds no funds, has no owner, and is separate from the launchpad: deploy it any time (see Profiles). |
| `src/BurnRiseTokenInfo.sol` | Lets a token's creator update its picture, description and links after launch. Holds no funds, has no owner, and only reads the launchpad (see Token info updates). |
| `src/BurnRiseFollows.sol` | Lets any wallet follow other wallets, for Following and Followers on profiles. Holds no funds, has no owner, and is separate from the launchpad (see Follows). |
| `BurnRise.flattened.sol` | Everything above in one file, for Remix and explorer verification. |
| `BurnRiseTestRouter.flattened.sol` | **Testnet only.** A small router that trades BurnRise pools from outside the launchpad, the way other apps do. Not part of BurnRise. |
| `script/Deploy.s.sol` | Foundry deployment script. |
| `test/` | The tests. |

## How it works

1. **Launch.** Anyone calls `launch(name, ticker, metadataURI, pair, firstBuy, minTokensOut)`. One transaction:
   - creates the token, with 1,000,000,000 supply;
   - opens its Uniswap v4 pool (token/ETH, token/USDG or token/stock token);
   - puts the **whole supply** into that pool as a single position, from the launch price up. The launchpad owns the position and has no function to remove it, so the liquidity is **locked forever**;
   - if `firstBuy` is set, makes the creator's first buy before anyone else can.
2. **Price.** The locked position works as the bonding curve. The pool opens at a market cap of 2/5 of the graduation target (1.68 ETH on ETH pairs). After that the price follows a constant-product curve: each buy raises it, each sell lowers it.
3. **Trading.** People trade on the BurnRise website (the launchpad's `buy` and `sell`, which swap in the pool) or in any app that trades Uniswap v4 pools. The hook charges the same fees and burn everywhere.
4. **Graduation.** When the pool holds the graduation target of its pair asset (4.2 ETH on ETH pairs), the token graduates. By then 5/7 of the supply has been bought and the price is 12.25x the launch price. Graduation works like Pons: it's a milestone. Nothing moves, and the token keeps trading in the same pool.

Burned tokens never come back into the pool. So even if every holder sold everything, the price couldn't fall back to the launch price, and every burn raises that floor.

### Fees (fixed, nobody can change them)

On every trade, from any app:

| | | |
|---|---|---|
| 0.9% of the pair side | creator | collected with `claimCreatorFees` |
| 0.3% of the pair side | dev wallet `0xeD980C614724B732352055DD40F23EcD9E32a7bc` | sent after every BurnRise trade |
| 0.1% of the pair side | weekly contest wallet `0xd86600CC30c59d3052bd33F3C54e9325D4a46D91` | sent after every BurnRise trade |
| 0.5% of the token side | burned: sent to the dead wallet `0x000000000000000000000000000000000000dEaD` | nobody can ever move it; anyone can see each token's burned total as that wallet's balance |

The hook credits the 1.3% to the launchpad as Uniswap claims. That works even before the trader has paid in, which matters for a brand-new pool that holds none of the pair asset yet. Then:
- **Trades through the launchpad:** the dev and contest shares are sent straight after each trade, once the trader has paid.
- **Trades in other apps:** those fees go out with the next launchpad trade in the same pair asset, or when anyone calls `payOutFees(pair)`.
- **A wallet that can't receive** (for example a contract that rejects ETH): trading still works. Its balance waits in `pendingPayouts(wallet, pair)`, and the wallet can collect it with `withdrawPayout(pair, to)`, sent to any address it chooses.

### What the owner can and can't do

The owner **can**:
- turn pair assets on or off for new launches and set their graduation targets;
- change the platform and contest wallets;
- pause new launches (the owner can still launch while paused, to test);
- deploy the hook once.

The owner **can't**:
- touch anyone's tokens, the pools' liquidity or creators' fees;
- change the fees;
- mint tokens;
- pause trading.

## Addresses on Robinhood Chain

| | |
|---|---|
| Uniswap v4 PoolManager (mainnet 4663 and testnet 46630) | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Dev wallet (gets the 0.3% fee; the contracts call it the platform wallet) | `0xeD980C614724B732352055DD40F23EcD9E32a7bc` |
| Contest wallet | `0xd86600CC30c59d3052bd33F3C54e9325D4a46D91` |
| Burn address (fixed in the contracts) | `0x000000000000000000000000000000000000dEaD` |
| USDG (6 decimals) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| NVDA stock token (18 decimals) | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` |
| TSLA stock token (18 decimals) | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` |
| SPCX stock token (18 decimals) | `0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa` |

The mainnet PoolManager address is in Uniswap's official deployment list. The testnet address comes from another launchpad's configuration. Check every address on the explorer before deploying; the deploy script stops if there's no contract at the PoolManager address.

- **Mainnet:** RPC `https://rpc.mainnet.chain.robinhood.com`, explorer `https://robinhoodchain.blockscout.com`.
- **Testnet:** RPC `https://rpc.testnet.chain.robinhood.com`, explorer `https://explorer.testnet.chain.robinhood.com`.

Graduation targets used by the website: ETH 4.2, USDG 9,000, NVDA 48, TSLA 25, SPCX 67. Each pair launches at a market cap of 2/5 of its target. When you call `setPair`, targets are in the asset's smallest unit: 9,000 USDG is `9000000000` (6 decimals), and 48 NVDA is `48000000000000000000` (18 decimals).

## Before you go live

1. **Audit.** Have the contracts independently audited.
2. **Testnet.** Deploy to the Robinhood Chain testnet and run through launches, trades, a graduation and trades from another app.
3. **Wallets.**
   - Use a Safe multisig as the owner.
   - The dev wallet gets the 0.3% fee on every trade, so keep it safe too.
   - The contest wallet will hold the prize pool, so keep it on a hardware wallet or make it a Safe.
   - Use plain wallets (a normal address or a Safe) for the platform and contest wallets, not custom contracts.
4. **Test each pair on mainnet while launches are paused.** The Foundry script pauses launches for you. With Remix, launches start open, so call `setLaunchesPaused(true)` before `deployHook`: once the hook exists, anyone could launch. For each pair asset:
   - set a tiny target with `setPair(asset, true, smallTarget)`;
   - launch a test token and buy past the target;
   - trade it, including from another app;
   - then set the real target.

   Stock tokens and USDG are regular ERC-20s, but check that they work with these contracts before the public uses them.
5. **Open.** Call `setLaunchesPaused(false)`.

## Testnet walkthrough (Remix)

In current Remix, each deployed contract has its own **Value** field at the bottom of its function list, under "Low level interaction". The Value on the Deploy tab is only used when deploying. Values are whole numbers in wei.

Set Value back to 0 after each payment, or the next normal call fails gas estimation. If Remix says "Gas estimation failed", cancel; don't force-send.

1. **Wallet.** Use a fresh wallet just for testing. Add Robinhood Chain Testnet: RPC `https://rpc.testnet.chain.robinhood.com`, chain ID `46630`, currency ETH, explorer `https://explorer.testnet.chain.robinhood.com`.
2. **Test ETH.** Get it from one of these; 0.05 ETH is plenty:
   - the official faucet `https://faucet.testnet.chain.robinhood.com/`, which also gives simulated stock tokens;
   - the Alchemy faucet (0.1 ETH a day);
   - the Chainstack faucet (up to 1 ETH a day);
   - or Sepolia ETH bridged over with the Arbitrum bridge.
3. **Compile** in Remix. Upload `BurnRise.flattened.sol` in the File Explorer and open it. In the Solidity Compiler tab:
   - compiler **0.8.26**;
   - under Advanced Configurations keep **Compiler configuration** selected (not "Use configuration file", and don't paste anything into `remix.config.json`);
   - EVM version **cancun**;
   - tick **Optimization** and leave runs at **200**.

   Click **Compile**. You should get a green check and no warnings.
4. **Deploy** `BurnRiseLaunchpad`. Pick it in the CONTRACT list, use your wallet on chain 46630, and keep the Value at 0. Constructor arguments:
   - `poolManager_`: `0x8366a39CC670B4001A1121B8F6A443A643e40951`
   - `owner_`: your test wallet
   - `platformWallet_`: your dev wallet `0xeD980C614724B732352055DD40F23EcD9E32a7bc`
   - `contestWallet_`: `0xd86600CC30c59d3052bd33F3C54e9325D4a46D91`, or another wallet of yours to watch it fill up

   If the deployment fails with `NotAContract`, there's no PoolManager at that address on testnet.
5. **Hook.** Call `findHookSalt` with `start` 0 and `count` 50000 (it's free, no transaction), then `deployHook(salt)` with the salt it returns.
   - If `found` is false, call it again with `start` 50000, then 100000.
   - If the call itself fails, your RPC limits free calls: use `count` 20000 and step `start` by 20000.
6. **Make graduation cheap.** `setPair(0x0000000000000000000000000000000000000000, true, 10000000000000000)`: ETH tokens now graduate at 0.01 ETH.
7. **Launch.** Set the launchpad's Value to `1000000000000000` (0.001 ETH), then call `launch("Test Cat", "TCAT", "", 0x0000000000000000000000000000000000000000, 1000000000000000, 0)`. Afterwards:
   - `allTokens(0)` is the token's address;
   - `poolIdFor(token)` is its Uniswap pool id;
   - on the explorer, the token's holders are the PoolManager (the pool), you and the dead wallet.
8. **Trade.**
   - Buy: set Value to `2000000000000000`, then call `buy(<token>, 2000000000000000, 0, 9999999999)`.
   - Load the token in Remix: pick `BurnRiseToken` on the Deploy tab (don't deploy), then on Deployed Contracts click **Add Contract** and paste the token address.
   - Sell: on the token, `approve(<launchpad>, <amount>)`, then on the launchpad `sell(<token>, <amount>, 0, 9999999999)`.
   - Burns: the token's `balanceOf(0x000000000000000000000000000000000000dEaD)` grows with every trade, and `totalSupply` stays 1,000,000,000.
9. **Graduate.** Set Value to `10000000000000000`, then call `buy(<token>, 10000000000000000, 0, 9999999999)`. `tokenInfo(<token>)` now shows `graduated = true`, and `quotePaired(<token>)` is at least 0.01 ETH.
10. **Trade from another app (optional).** Compile `BurnRiseTestRouter.flattened.sol` with the same settings, and deploy `BurnRiseTestRouter` with the PoolManager and your launchpad address.
    - Buy: set the router's Value to `5000000000000000`, then call `buy(<token>, 5000000000000000, 0)`.
    - Sell: approve the router on the token, then call `sell(<token>, <amount>, 0)`.

    The same fees and burn apply. The 0.3% and 0.1% wait in `pendingPayouts` until the next launchpad trade, or until you call `payOutFees(0x0000000000000000000000000000000000000000)`.
11. **Fees.**
    - Check the dev and contest wallets' internal transactions on the explorer.
    - Call `creatorFees(<token>)`, then `claimCreatorFees(<token>)` from the creator wallet.
12. **Reset.** When you're done with cheap tests: `setPair(0x0000000000000000000000000000000000000000, true, 4200000000000000000)`.

## Deploy with Foundry

```bash
bash setup.sh                     # downloads the libraries at the tested versions
forge build && forge test         # 70 tests should pass
FINAL_OWNER=0xYourSafe \
forge script script/Deploy.s.sol --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast --account <your keystore>
```

The script:
- deploys the launchpad (which creates its factory);
- finds the hook salt and deploys the hook;
- enables USDG and NVDA on mainnet;
- pauses launches;
- hands ownership to `FINAL_OWNER`. Your Safe must then call `acceptOwnership()`.

## Deploy with Remix

1. Open `BurnRise.flattened.sol` in Remix.
2. Compiler tab:
   - version **0.8.26**;
   - **Compiler configuration** (not "Use configuration file");
   - EVM version **cancun**;
   - **Optimization** on with **200** runs.

   Compile, then pick `BurnRiseLaunchpad` in the CONTRACT list.
3. Deploy `BurnRiseLaunchpad` on Robinhood Chain with:
   - `poolManager_`: `0x8366a39CC670B4001A1121B8F6A443A643e40951`
   - `owner_`: your address (hand it to a Safe at the end)
   - `platformWallet_`: your dev wallet `0xeD980C614724B732352055DD40F23EcD9E32a7bc`
   - `contestWallet_`: `0xd86600CC30c59d3052bd33F3C54e9325D4a46D91`
4. Call `setLaunchesPaused(true)`.
5. Call `findHookSalt` with `start = 0`, `count = 50000`. It's free (no transaction).
   - If `found` is false, try `start = 50000`, then `100000`, and so on.
   - If the call itself fails, use `count = 20000` and step `start` by 20000.
6. Call `deployHook(salt)` with the salt it returned. Check that `hook()` equals the `hookAddress` it returned.
7. Add pairs:
   - USDG: `setPair(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, true, 9000000000)`;
   - NVDA: `setPair(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, true, 48000000000000000000)`;
   - TSLA: `setPair(0x322F0929c4625eD5bAd873c95208D54E1c003b2d, true, 25000000000000000000)`;
   - SPCX: `setPair(0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, true, 67000000000000000000)`.

   ETH is already on, at 4.2 ETH.
8. Verify the launchpad and the hook on the explorer with the same compiler settings (0.8.26, optimization 200 runs, EVM cancun, viaIR off). The hook's constructor arguments are the PoolManager and your launchpad's address. Uniswap's hook listing and your auditor both need the verified source.
9. Test each pair as described above.
10. Move ownership: `transferOwnership(<your Safe>)`, then `acceptOwnership()` from the Safe.
11. When the audit is done, open launches: `setLaunchesPaused(false)`, sent from the Safe.

In `BurnRise.flattened.sol`, one parameter in Uniswap's `SqrtPriceMath` is renamed from `add` to `isAdd`. In a one-file build it clashes with BalanceDelta's `add` and Remix warns about it. It compiles to the same code as the multi-file build.

## Connect the website

The website (`index.html`) talks to the launchpad directly: it needs no server. Near the top of its script:

1. In `NETWORKS`, put your `BurnRiseLaunchpad` address under the network you deployed to (`testnet` or `mainnet`).
2. Set `CONFIG.network` to that network, and keep `CONFIG.demo` at `false` (`true` shows the preview with sample tokens).

Everything else is read from the launchpad: its hook, the pool manager, the contest wallet, the pairs it has enabled and their graduation targets. On testnet a bar across the top says that tokens there have no value.

**What it reads.** The token list comes from `tokenCount` / `allTokens` and `tokenInfo`. Then the site reads every BurnRise event from just before the first launch: the launchpad's `Launched` (with the metadata), `Graduated`, `CreatorFeesClaimed` and `CreatorChanged`, the hook's `Trade`, the pools' `Initialize` and `Swap` (exact prices), and each token's `Transfer` (holders and burns). It checks for new blocks every few seconds. Prices, charts, the floor, holders, profit and loss, the leaderboard and the weekly contest are all worked out in the page from those events. The trader of each trade is the wallet the pool paid or took the tokens from (or the transaction's sender, for other apps' routes). Graduation progress is `quotePaired`, creator fees are `creatorFees` plus what was claimed.

**What it sends**, from the visitor's wallet, after a dry run that explains a failure before the wallet opens:

- **Launch:** `launch(name, symbol, metadataURI, quote, firstBuy, 0)`, with the first buy as value for ETH pairs (or a one-time approval of the pair token first). The first buy happens in the same transaction that creates the pool, so nobody can trade before it.
- **Buy / sell:** `buy` and `sell`, with `minOut` from `previewBuy` / `previewSell` and the slippage the trader picks (1%, 3%, 5%, 10% or any custom amount from 0.1% to 50%), and a 20-minute deadline. The first sell of a token asks for one unlimited approval, like other launchpads, so later sells need a single confirmation. The amounts shown while typing come from the same pool math as `previewBuy` / `previewSell`, to the last unit.
- **Claim:** `claimCreatorFeesMany(tokens)`, from the Claim button the creator sees on their own token page (with the amount waiting, in the pair asset and in $), or for all their tokens at once from their profile.

**Token images and links.** `metadataURI` holds a short JSON object, at most 512 bytes: `{"image": "tx", "description": "...", "website": "...", "x": "...", "telegram": "..."}`. A picture doesn't fit in 512 bytes, so the site shrinks the uploaded image (a 256 px square, at most 48 KB) and adds it to the end of the `launch` transaction's data, after the call's arguments. The contract ignores those extra bytes, but they stay on-chain, and the site reads the picture back from the launch transaction (`"image": "tx"` marks a token that has one). No image host is needed. An `https://` or `ipfs://` link in `image` also works, for tokens launched another way.

**Chart and listings.** The token chart uses TradingView Lightweight Charts (Apache-2.0, built into the page; the credit line under the chart is part of its license). On mainnet, the token page also shows whether DEX is paid (DexScreener's `orders/v1` and `tokens/v1`), whether the token is on CoinGecko (its free API: the platform with chain id 4663, then `simple/token_price` and `coins/{platform}/contract/{address}`) and the exchanges it trades on. A token without its own picture shows its DexScreener picture. Nothing to set up; on testnet those two sites have no data, so the page says the listings show on mainnet.

**Sign-up.** The first time a wallet connects, the site shows the risks (your wallet, your keys; how risky meme tokens are; anyone can launch; trades are final; the 1.8% fee). **Sign up** has the wallet sign a short message saying so, with `personal_sign` (free: no gas, and it can't move funds). It's remembered in that browser, for that wallet. "Not now" leaves the wallet unconnected. If you change the terms, raise `SIGNUP_VERSION` in the script and everyone signs again. **Risks and terms** in the footer opens the same text.

**Disconnect.** The power button joined to the wallet button in the header (on phones: **Disconnect** on your own profile) disconnects the wallet. The site stays disconnected in that browser until **Connect wallet** is clicked again, and it asks the wallet to drop the site too (`wallet_revokePermissions`, in wallets that support it). Connecting again doesn't ask for a new sign-up.

**Agent Burny.** The flame at the bottom right answers questions about BurnRise, its tokens and Uniswap v4. His answers are written into the script, in `BURNY_KB` (each entry has the question, the words that point to it and the answer), so to change one, edit its text there. Some answers are read live: a token's market cap and graduation (by `$TICKER` or name), the fees your wallet can claim, the contest, the hottest tokens. Anything off-topic gets "ask the team on X", and Telegram too once `CONFIG.links.telegram` is set. There's no AI or server behind him: what people type never leaves the page.

**The RPC.** The site uses the network's public RPC. If it can't be reached, it reads through the visitor's wallet instead, when the wallet is on the right network. It splits log queries into smaller block ranges when an RPC refuses big ones. To use another RPC (for example a paid one for mainnet), change `rpc` in `NETWORKS` and add its address to `connect-src` in the page's security policy (the meta tag at the top of `index.html`, and `_headers`).

**Busy sites.** Each visitor reads the logs since the first launch, which is fine for testnet and an early launch. With many tokens and trades, add an indexer that serves the token list, charts and the contest, and point `CONFIG.contest.api` at its contest endpoint (the reply format is above `loadContestFeed` in the script). Token chat needs a chat server, so on the live site the Chat tab says it's coming soon.

## Profiles

`BurnRiseProfiles` lets every wallet set a username, a bio and a picture. The website shows the username and picture instead of the address everywhere: trades, holders, creators, the leaderboard and the contest. A wallet without a username gets a made-up name made from its address, like "WittyAzureFox", and a matching animal picture, the same everywhere and on every visit; your own wallet button keeps showing your address. It holds no funds and has no owner; each wallet edits only its own profile, from **Edit profile** on its profile page.

- **Usernames:** 3 to 20 letters, numbers or `_`, unique whatever the letter case ("Vaseto" and "vaseto" are the same). Changing your username frees the old one.
- **Kept for the team:** burnrise, burnrisex, burnrisefun, burnrise_fun, burnrise_official, burnriseofficial, official, admin, support, team, moderator and robinhood. Only the `team` wallet can use them, so nobody can pose as BurnRise.
- **Bio:** up to 160 characters, kept in the `ProfileSet` event.
- **Picture:** like token pictures, the site shrinks it (a 256 px square, at most 48 KB) and adds it to the end of the `setProfile` transaction. The contract ignores those bytes and the site reads them back. `picture` is 0 (none), 1 (a new one in this transaction) or 2 (keep the last one).

Deploy it in Remix (one file, no imports):

1. Open `src/BurnRiseProfiles.sol` in Remix. Compiler **0.8.26**, EVM **cancun**, optimization on with **200** runs.
2. Deploy `BurnRiseProfiles` with `team_` = your dev wallet `0xeD980C614724B732352055DD40F23EcD9E32a7bc`.
3. Put its address in the website: `profiles` under the network in `NETWORKS` (testnet now, mainnet later). Empty means profiles are off.
4. Verify it on the explorer with the same settings.

To hide an abusive profile, add the wallet to `CONFIG.hiddenProfiles` in the website; the site then shows its made-up name instead. Profiles can't be deleted on-chain.

## Token info updates

`BurnRiseTokenInfo` lets a token's creator change its picture, description and website, X and Telegram links after launch, from **Update token info** on the token page (only the creator sees the button). The website shows the latest update instead of what was set at launch.

- **Only the creator:** the contract asks the launchpad who the token's creator is (`tokenInfo`) and refuses everyone else. If the creator hands the token on with `setCreator`, the new creator can update it.
- **Same format as at launch:** a short JSON text, at most 512 bytes, kept in the `TokenInfoSet` event. `"image": "tx"` means a new picture at the end of the transaction (added the same way as at launch), `"keep"` keeps the current picture, and no `image` means no picture.
- It holds no funds, has no owner, and doesn't change the launchpad.

Deploy it in Remix (one file, no imports):

1. Open `src/BurnRiseTokenInfo.sol` in Remix. Compiler **0.8.26**, EVM **cancun**, optimization on with **200** runs.
2. Deploy `BurnRiseTokenInfo` with `launchpad_` = your launchpad's address (testnet: `0xB0fDA78d9cf8DDff2DeDb27061e2a676E2E5278F`).
3. Put its address in the website: `tokenInfo` under the network in `NETWORKS`. The site checks that it was made for that launchpad; empty means updates are off.
4. Verify it on the explorer with the same settings.

## Follows

`BurnRiseFollows` lets any wallet follow any other wallet. Every profile on the website shows **Following** and **Followers** under the name (tap either for the list), and other people's profiles have a **Follow** button; following and unfollowing are transactions from your wallet, with a tiny network fee. It holds no funds, has no owner and doesn't touch the launchpad.

- `follow(wallet)` and `unfollow(wallet)`; you can't follow yourself or follow a wallet twice.
- `followerCount(wallet)`, `followingCount(wallet)` and `isFollowing(follower, wallet)` can be read by anyone. The website builds the lists from the `Followed` and `Unfollowed` events.

Deploy it in Remix (one file, no imports, no constructor arguments):

1. Open `src/BurnRiseFollows.sol` in Remix. Compiler **0.8.26**, EVM **cancun**, optimization on with **200** runs.
2. Deploy `BurnRiseFollows`.
3. Put its address in the website: `follows` under the network in `NETWORKS`. Empty means follows are off, and the profiles show no Follow button or counts.
4. Verify it on the explorer with the same settings.

## Tests

`forge test` runs 70 tests (52 of them against a real Uniswap v4 PoolManager, 8 for profiles, 4 for token info updates, 6 for follows):

- **Launch:**
  - the whole supply goes into the pool;
  - the launchpad owns the locked position;
  - the launch price is 2/5 of the target;
  - the creator's first buy works on a fresh PoolManager that holds no ETH;
  - input checks and pause.
- **Trading through the launchpad:** exact fee split, 0.5% burned to `0x…dEaD`, previews, the `Trade` event, slippage, deadline and value checks.
- **Trading from other apps:**
  - buys and sells, exact input and exact output, each with exact fees, burns and `Trade` events;
  - a big first buy on a fresh pool;
  - routers that sync before paying, and ones that don't.
- **Fees:**
  - paid to the wallets after every launchpad trade, and with the next trade or `payOutFees` for other apps;
  - creator claims and hand-over;
  - wallets that reject ETH, burn gas or have no receive function.
- **Graduation:** at the exact target, from any app, only once, and trading goes on in the same pool.
- **Locked liquidity:** nobody else can add liquidity or create hook pools, and the position never changes.
- **Pairs:**
  - ETH, 6-decimal and 18-decimal pairs, with the pair asset sorting below and above the token;
  - the smallest (1 USDG) and very large targets;
  - fee-on-transfer pair tokens can't trade.
- **Edge cases:** launching and buying from inside another Uniswap transaction, partial fills reverting, and the deploy script.
- **Random tests:**
  - launchpad trades against previews;
  - trades from other apps in every mode;
  - four tokens across three pair assets traded in random order, then sold back completely. Every token's supply is accounted for, and the launchpad always holds exactly what it owes.
- **Stateful fuzzing** (`test/Audit.t.sol`): random sequences of everything people can do: trades through the launchpad, through other apps in every mode and from inside another Uniswap transaction, claims, hand-overs, payouts, withdrawals, wallet changes, wallets that refuse ETH, donations to the pools. After every step:
  - the launchpad holds exactly what it owes, and what it owes is exactly the creators' unclaimed fees plus the wallets' unsent payouts;
  - every token is accounted for, and the PoolManager holds what every pool and fee claim needs;
  - hook and launchpad agree on graduation.

  After each run everyone sells everything back, every creator claims and every wallet collects, and the launchpad is left owing and holding nothing. The file also checks a creator contract that trades while being paid, a wallet that tries to (50,000 gas isn't enough for a swap), wallet changes and `renounceOwnership`.
- **Profiles, token info and follows:** usernames are unique whatever the case and kept names stay the team's; only the creator updates a token's info; follows count both sides, can't target yourself or repeat, and random sequences of follows and unfollows always leave the counts equal to the real follows.

The tests pass with the standard compiler, which is what Remix uses and the project default, and also with viaIR (`FOUNDRY_VIA_IR=true forge test`). Each random test also passed 3,000 runs, and the stateful fuzzing 1,000 runs of 100 random calls for each of its checks.

The testnet walkthrough above was rehearsed step by step on a local chain, with real transactions from deploy to creator claim, using the exact bytecode Remix builds from `BurnRise.flattened.sol`.

## Security review

An independent review of the earlier version found no critical or high issues. In that version, tokens started on a separate bonding curve and moved into a pool at graduation. Its fixes carry over and are covered by tests:
- pay-ins always sync first;
- pool swaps are all or nothing;
- deferred payouts can go to another address;
- everything works inside another Uniswap transaction;
- fee-on-transfer pair tokens are rejected.

The contracts have since been **redesigned**: tokens now launch straight into their Uniswap pool, and the hook now collects fees as Uniswap claims. A pre-audit self-review of the redesign (line-by-line reading, Slither, the stateful fuzzing above) found nothing that needs a code change. It doesn't replace a professional audit: have it audited before mainnet.

## Known limits

- **All-or-nothing swaps.** Pool swaps are all or nothing: a swap that a price limit would stop early reverts instead of filling part of the way.
- **Previews are close, not exact.** `previewBuy` and `previewSell` match the real trade to within rounding (far below a millionth of a percent). Use the `minOut` arguments for slippage.
- **Snipers.** Tokens trade from the first block, so bots can buy right after a launch. There's no launch tax against that; the creator's first buy happens in the launch transaction itself, so it always comes first.
- **Fee timing.** Fees from trades made in other apps reach the dev and contest wallets with the next launchpad trade in that pair asset, or when anyone calls `payOutFees`.
- **Plain wallets only.** A platform or contest wallet that calls Uniswap while being paid could break a router that pays ETH without syncing first in the same transaction. Use plain wallets.
- **Plain ERC-20 pair assets.** Pair assets must be plain ERC-20s. Tokens that take a fee on transfer can't trade, and rebasing tokens aren't supported. Robinhood's stock tokens don't rebase.
- **Uncapped first buy.** The creator's first buy isn't capped: a creator can buy most of the supply in the launch transaction.
- **Very large sells.** A sell whose 0.5% burn is more than the pool's whole token reserve would revert. That only happens when the pool holds under 0.5% of the supply, at a market cap roughly 40,000x the launch market cap. Splitting the sale works.
- **Uniswap limit on exact-output swaps.** An exact-output swap asking for nearly all of one side of a pool reverts. That's a Uniswap v4 limit, not specific to BurnRise.
- **Frozen pair assets.** If a pair asset ever blocks transfers to the launchpad or the PoolManager (for example a frozen stablecoin), trading in that pair stops. Only enable pair assets you trust.
- **Contest prizes.** Contest prizes build up in the contest wallet in each pair asset (ETH, USDG, stock tokens). Paying the winners is done from that wallet.
- **DexScreener.** Whether a pool appears on DexScreener is up to DexScreener. BurnRise pools are ordinary Uniswap v4 pools with a hook, which it indexes on Robinhood Chain.
- **Uniswap protocol fees.** Uniswap governance has turned on protocol fees on Robinhood Chain (Proposal #99, July 2026), with v4 pools handled separately. If Uniswap ever applies its protocol fee to BurnRise pools, traders pay that small extra fee to Uniswap on top of BurnRise's 1.8%. The contracts keep working either way.
