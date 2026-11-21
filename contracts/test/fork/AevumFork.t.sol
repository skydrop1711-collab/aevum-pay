// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {AevumPayEscrow} from "../../src/AevumPayEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Fork tests against the REAL tUSD8 on a local anvil fork of Aevum testnet.
/// @dev Run with an anvil fork live on 127.0.0.1:8555 (chain 440050, --hardfork shanghai):
///      forge test --match-path test/fork/AevumFork.t.sol --fork-url http://127.0.0.1:8555
///      (or --fork-url https://rpc-test.qday.info directly)
///      tUSD8 is funded to test accounts with `deal` (anvil cheatcode works on forked state).
contract AevumForkTest is Test {
    address public constant TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;

    AevumPayEscrow public escrow;
    IERC20 public token;

    address public payer = address(0xA11CE);
    address public payee = address(0xBEEF);
    address public agent = address(0xA6E17);

    uint256 constant AMOUNT = 100_000_000; // 100 tUSD8 (6 decimals)

    function setUp() public {
        // Skip gracefully when run without a fork (plain `forge test`): the real
        // tUSD8 contract only exists on forked Aevum state.
        if (TUSD8.code.length == 0) vm.skip(true);
        token = IERC20(TUSD8);
        escrow = new AevumPayEscrow(TUSD8);
        // Fund payer with real tUSD8 on the fork
        deal(TUSD8, payer, 1_000_000_000);
        vm.prank(payer);
        token.approve(address(escrow), type(uint256).max);
    }

    function testForkTokenIsRealTUSD8() public view {
        assertEq(IERC20Metadata(TUSD8).decimals(), 6);
        assertEq(IERC20Metadata(TUSD8).symbol(), "tUSD8");
    }

    function testForkEndToEndRelease() public {
        uint256 payeeBefore = token.balanceOf(payee);
        vm.prank(payer);
        uint256 id = escrow.createInvoice(payee, AMOUNT, block.timestamp + 1 days, "fork invoice");

        vm.prank(payer);
        escrow.fundInvoice(id);
        assertEq(token.balanceOf(address(escrow)), AMOUNT);

        vm.prank(payee);
        escrow.confirmDelivery(id);
        assertEq(uint256(escrow.getInvoice(id).status), uint256(AevumPayEscrow.Status.Released));
        assertEq(token.balanceOf(payee), payeeBefore + AMOUNT);
    }

    function testForkAgentFlow() public {
        uint256 cap = 250_000_000;
        uint256 payeeBefore = token.balanceOf(payee);
        vm.prank(payer);
        escrow.authorizeAgent(agent, cap);

        vm.prank(payer);
        uint256 id = escrow.createInvoice(payee, AMOUNT, block.timestamp + 1 days, "agent invoice");

        vm.prank(agent);
        escrow.fundInvoiceFor(payer, id);
        assertEq(uint256(escrow.getInvoice(id).status), uint256(AevumPayEscrow.Status.Funded));
        assertEq(escrow.agentRemaining(payer, agent), cap - AMOUNT);
        assertEq(token.balanceOf(agent), 0); // agent never holds payer funds

        vm.prank(payee);
        escrow.confirmDelivery(id);
        assertEq(token.balanceOf(payee), payeeBefore + AMOUNT);
    }

    function testForkAgentOverCapReverts() public {
        vm.prank(payer);
        escrow.authorizeAgent(agent, 50_000_000); // 50 tUSD8 cap < 100 tUSD8 invoice
        vm.prank(payer);
        uint256 id = escrow.createInvoice(payee, AMOUNT, block.timestamp + 1 days, "over cap");
        vm.prank(agent);
        vm.expectRevert("AevumPayEscrow: amount exceeds agent cap");
        escrow.fundInvoiceFor(payer, id);
    }

    function testForkRefundAndExpiry() public {
        // Refund path
        vm.prank(payer);
        uint256 refundId = escrow.createInvoice(payee, AMOUNT, block.timestamp + 1 days, "refund me");
        vm.prank(payer);
        escrow.fundInvoice(refundId);
        vm.prank(payer);
        escrow.refundInvoice(refundId);
        assertEq(uint256(escrow.getInvoice(refundId).status), uint256(AevumPayEscrow.Status.Refunded));
        assertEq(token.balanceOf(payer), 1_000_000_000);

        // Expiry path
        vm.prank(payer);
        uint256 expId = escrow.createInvoice(payee, AMOUNT, block.timestamp + 1 hours, "expire me");
        vm.prank(payer);
        escrow.fundInvoice(expId);
        vm.warp(block.timestamp + 2 hours);
        escrow.claimExpired(expId);
        assertEq(uint256(escrow.getInvoice(expId).status), uint256(AevumPayEscrow.Status.Expired));
        assertEq(token.balanceOf(payer), 1_000_000_000);
    }

    function testForkNameRegistry() public {
        vm.prank(payer);
        escrow.registerName("alice");
        assertEq(escrow.resolveName("alice"), payer);
    }
}
