// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AevumPayEscrow} from "../src/AevumPayEscrow.sol";

/// @notice Deploy AevumPayEscrow to the local fork (chain 440050) or Aevum testnet (chain 44005).
/// @dev Use --legacy transactions (Aevum testnet requires legacy tx type).
///      Fork:    forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8555 --broadcast --legacy
///      Testnet: forge script script/Deploy.s.sol --rpc-url https://rpc-test.qday.info --account aevum-deployer --broadcast --legacy
contract Deploy is Script {
    address public constant TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;

    function run() external returns (AevumPayEscrow escrow) {
        vm.startBroadcast();
        escrow = new AevumPayEscrow(TUSD8);
        vm.stopBroadcast();

        console.log("AevumPayEscrow deployed at:", address(escrow));
        console.log("tUSD8 token:", TUSD8);
        console.log("chainId:", block.chainid);
    }
}
