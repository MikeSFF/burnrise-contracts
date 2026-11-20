#!/usr/bin/env bash
# Downloads the exact library versions the contracts were built and tested with.
# Run once from this folder:  bash setup.sh   (needs git and Foundry: https://getfoundry.sh)
set -e
mkdir -p lib
clone() {
  [ -f "lib/$1/$4" ] && return
  rm -rf "lib/$1"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$3" "https://github.com/$2.git" "lib/$1"
}
clone forge-std              foundry-rs/forge-std                 v1.17.0 src/Test.sol
clone openzeppelin-contracts OpenZeppelin/openzeppelin-contracts  v5.7.0  contracts/token/ERC20/ERC20.sol
clone v4-core                Uniswap/v4-core                      v4.0.0  src/PoolManager.sol
# only needed to run the tests (the test PoolManager uses it); v4-core leaves an empty folder for it
if [ ! -f lib/v4-core/lib/solmate/src/auth/Owned.sol ]; then
  rm -rf lib/v4-core/lib/solmate
  git -c advice.detachedHead=false clone -q --depth 1 https://github.com/transmissions11/solmate.git lib/v4-core/lib/solmate
fi
echo "Libraries ready. Next: forge build && forge test"
