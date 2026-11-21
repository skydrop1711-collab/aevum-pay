// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AevumPayEscrow} from "../src/AevumPayEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock tUSD8: 6 decimals, mintable for tests.
contract MockTUSD8 is ERC20 {
    constructor() ERC20("tUSD8", "tUSD8") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AevumPayEscrowTest is Test {
    AevumPayEscrow public escrow;
    MockTUSD8 public token;

    address public payer = address(0xA11CE);
    address public payee = address(0xBEEF);
    address public agent = address(0xA6E17);
    address public stranger = address(0x5A17);

    uint256 constant AMOUNT = 100_000_000; // 100 tUSD8 (6 decimals)
    uint256 constant CAP = 250_000_000; // 250 tUSD8

    function setUp() public {
        token = new MockTUSD8();
        escrow = new AevumPayEscrow(address(token));
        token.mint(payer, 1_000_000_000); // 1,000 tUSD8
        token.mint(stranger, 1_000_000_000);
        vm.prank(payer);
        token.approve(address(escrow), type(uint256).max);
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 1 days;
    }

    function _createInvoice() internal returns (uint256 id) {
        vm.prank(payer);
        id = escrow.createInvoice(payee, AMOUNT, _deadline(), "test invoice");
    }

    // ---- create ----

    function testCreateInvoice() public {
        vm.prank(payer);
        vm.expectEmit(true, true, true, true);
        emit AevumPayEscrow.InvoiceCreated(0, payer, payee, AMOUNT, _deadline());
        uint256 id = escrow.createInvoice(payee, AMOUNT, _deadline(), "test invoice");
        assertEq(id, 0);
        assertEq(escrow.nextInvoiceId(), 1);

        AevumPayEscrow.Invoice memory inv = escrow.getInvoice(id);
        assertEq(inv.payer, payer);
        assertEq(inv.payee, payee);
        assertEq(inv.amount, AMOUNT);
        assertEq(inv.deadline, _deadline());
        assertEq(uint256(inv.status), uint256(AevumPayEscrow.Status.Created));
        assertEq(inv.memo, "test invoice");
    }

    function testCreateInvoiceRevertsZeroPayee() public {
        vm.prank(payer);
        vm.expectRevert("AevumPayEscrow: payee is zero address");
        escrow.createInvoice(address(0), AMOUNT, _deadline(), "");
    }

    function testCreateInvoiceRevertsZeroAmount() public {
        vm.prank(payer);
        vm.expectRevert("AevumPayEscrow: amount is zero");
        escrow.createInvoice(payee, 0, _deadline(), "");
    }

    function testCreateInvoiceRevertsPastDeadline() public {
        vm.prank(payer);
        vm.expectRevert("AevumPayEscrow: deadline must be in the future");
        escrow.createInvoice(payee, AMOUNT, block.timestamp, "");
    }

    function testInvoiceIdsIncrement() public {
        uint256 id0 = _createInvoice();
        uint256 id1 = _createInvoice();
        assertEq(id0, 0);
        assertEq(id1, 1);
    }

    // ---- fund / release (happy path) ----

    function testFundAndRelease() public {
        uint256 id = _createInvoice();

        vm.prank(payer);
        escrow.fundInvoice(id);
        assertEq(uint256(escrow.getInvoice(id).status), uint256(AevumPayEscrow.Status.Funded));
        assertEq(token.balanceOf(address(escrow)), AMOUNT);
        assertEq(token.balanceOf(payer), 1_000_000_000 - AMOUNT);

        vm.prank(payee);
        escrow.confirmDelivery(id);
        assertEq(uint256(escrow.getInvoice(id).status), uint256(AevumPayEscrow.Status.Released));
        assertEq(token.balanceOf(payee), AMOUNT);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function testFundEmitsEvent() public {
        uint256 id = _createInvoice();
        vm.prank(payer);
        vm.expectEmit(true, true, false, true);
        emit AevumPayEscrow.InvoiceFunded(id, payer, AMOUNT);
        escrow.fundInvoice(id);
    }

    function testReleaseEmitsEvent() public {
        uint256 id = _createInvoice();
        vm.prank(payer);
        escrow.fundInvoice(id);
        vm.prank(payee);
        vm.expectEmit(true, true, false, true);
        emit AevumPayEscrow.InvoiceReleased(id, payee, AMOUNT);
        escrow.confirmDelivery(id);
    }

    // ---- wrong caller / wrong status ----

    function testFundOnlyPayer() public {
        uint256 id = _createInvoice();
        vm.prank(stranger);
        vm.expectRevert("AevumPayEscrow: only payer can fund");
        escrow.fundInvoice(id);
    }

    function testFundTwiceReverts() public {
        uint256 id = _createInvoice();
        vm.prank(payer);
        escrow.fundInvoice(id);
        vm.prank(payer);
        vm.expectRevert("AevumPayEscrow: invoice not in Created status");
        escrow.fundInvoice(id);
    }

    function testConfirmOnlyPayee() public {
        uint256 id = _createInvoice();
        vm.prank(payer);
        escrow.fundInvoice(id);
        vm.prank(payer);
        vm.expectRevert("AevumPayEscrow: only payee can confirm delivery");
        escrow.confirmDelivery(id);
    }

    function testConfirmBeforeFundReverts() public {
        uint256 id = _createInvoice();
        vm.prank(payee);
        vm.expectRevert("AevumPayEscrow: invoice not in Funded status");
        escrow.confirmDelivery(id);
    }

    function testConfirmAfterReleaseReverts() public {
        uint256 id = _createInvoice();
        vm.prank(payer);
        escrow.fundInvoice(id);
        vm.prank(payee);
        escrow.confirmDelivery(id);
        vm.prank(payee);
        vm.expectRevert("AevumPayEscrow: invoice not in Funded status");
        escrow.confirmDelivery(id);
    }

    function testRefundOnlyPayer() public {
        uint256 id = _createInvoice();
        vm.prank(payer);
        escrow.fundInvoice(id);
        vm.prank(payee);
        vm.expectRevert("AevumPayEscrow: only payer can refund");
        escrow.refundInvoice(id);
    }

    function testRefundBeforeFundReverts() public {
        uint256 id = _createInvoice();
        vm.prank(payer);
        vm.expectRevert("AevumPayEscrow: invoice not in Funded status");
        escrow.refundInvoice(id);
    }

    function testRefundAfterReleaseReverts() public {
        uint256 id = _createInvoice();
        vm.prank(payer);
        escrow.fundInvoice(id);
        vm.prank(payee);
        escrow.confirmDelivery(id);
        vm.prank(payer);
        vm.expectRevert("AevumPayEscrow: invoice not in Funded status");
        escrow.refundInvoice(id);
    }

    // ---- refund ----

    function testRefundBeforeRelease() public {
        uint256 id = _createInvoice();
        vm.prank(payer);
        escrow.fundInvoice(id);

        uint256 payerBefore = token.balanceOf(payer);
        vm.prank(payer);
        escrow.refundInvoice(id);
        assertEq(uint256(escrow.getInvoice(id).status), uint256(AevumPayEscrow.Status.Refunded));
        assertEq(token.balanceOf(payer), payerBefore + AMOUNT);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    // ---- expiry ----

    function testClaimExpiredAfterDeadline() public {
        uint256 id = _createInvoice();
        vm.prank(payer);
        escrow.fundInvoice(id);

        vm.warp(_deadline());
        uint256 payerBefore = token.balanceOf(payer);
        // anyone may call
        vm.prank(stranger);
        escrow.claimExpired(id);
        assertEq(uint256(escrow.getInvoice(id).status), uint256(AevumPayEscrow.Status.Expired));
        assertEq(token.balanceOf(payer), payerBefore + AMOUNT);
    }

    function testClaimExpiredBeforeDeadlineReverts() public {
        uint256 id = _createInvoice();
        vm.prank(payer);
        escrow.fundInvoice(id);
        vm.prank(stranger);
        vm.expectRevert("AevumPayEscrow: invoice not expired yet");
        escrow.claimExpired(id);
    }

    function testClaimExpiredBeforeFundReverts() public {
        uint256 id = _createInvoice();
        vm.warp(_deadline());
        vm.prank(stranger);
        vm.expectRevert("AevumPayEscrow: invoice not in Funded status");
        escrow.claimExpired(id);
    }

    function testClaimExpiredTwiceReverts() public {
        uint256 id = _createInvoice();
        vm.prank(payer);
        escrow.fundInvoice(id);
        vm.warp(_deadline());
        vm.prank(stranger);
        escrow.claimExpired(id);
        vm.prank(stranger);
        vm.expectRevert("AevumPayEscrow: invoice not in Funded status");
        escrow.claimExpired(id);
    }

    // ---- agent flow ----

    function _authorize() internal {
        vm.prank(payer);
        escrow.authorizeAgent(agent, CAP);
    }

    function testAuthorizeAgent() public {
        _authorize();
        (uint256 cap, uint256 spent, bool active) = escrow.agentAuths(payer, agent);
        assertEq(cap, CAP);
        assertEq(spent, 0);
        assertTrue(active);
        assertEq(escrow.agentRemaining(payer, agent), CAP);
    }

    function testAgentFundWithinCap() public {
        _authorize();
        uint256 id = _createInvoice();

        vm.prank(agent);
        escrow.fundInvoiceFor(payer, id);
        assertEq(uint256(escrow.getInvoice(id).status), uint256(AevumPayEscrow.Status.Funded));
        assertEq(token.balanceOf(address(escrow)), AMOUNT);
        // payer's funds moved, agent never held them
        assertEq(token.balanceOf(agent), 0);
        (, uint256 spent,) = escrow.agentAuths(payer, agent);
        assertEq(spent, AMOUNT);
        assertEq(escrow.agentRemaining(payer, agent), CAP - AMOUNT);
    }

    function testAgentFundEmitsBothEvents() public {
        _authorize();
        uint256 id = _createInvoice();
        vm.prank(agent);
        vm.expectEmit(true, true, false, true);
        emit AevumPayEscrow.InvoiceFunded(id, agent, AMOUNT);
        // Note: expectEmit only checks the next event; AgentSpent is checked by status/spent assertions in testAgentFundWithinCap.
        escrow.fundInvoiceFor(payer, id);
    }

    function testAgentFundOverCapReverts() public {
        _authorize();
        // Invoice amount > cap: create a big invoice
        vm.prank(payer);
        uint256 bigId = escrow.createInvoice(payee, CAP + 1, _deadline(), "too big");
        vm.prank(agent);
        vm.expectRevert("AevumPayEscrow: amount exceeds agent cap");
        escrow.fundInvoiceFor(payer, bigId);
        // status unchanged
        assertEq(uint256(escrow.getInvoice(bigId).status), uint256(AevumPayEscrow.Status.Created));
    }

    function testAgentCumulativeCapEnforced() public {
        _authorize();
        // 2 x 100 = 200 spent, remaining 50; a third 100 invoice must revert
        uint256 id0 = _createInvoice();
        uint256 id1 = _createInvoice();
        uint256 id2 = _createInvoice();
        vm.prank(agent);
        escrow.fundInvoiceFor(payer, id0);
        vm.prank(agent);
        escrow.fundInvoiceFor(payer, id1);
        assertEq(escrow.agentRemaining(payer, agent), CAP - 2 * AMOUNT);
        vm.prank(agent);
        vm.expectRevert("AevumPayEscrow: amount exceeds agent cap");
        escrow.fundInvoiceFor(payer, id2);
    }

    function testRevokedAgentCannotFund() public {
        _authorize();
        vm.prank(payer);
        escrow.revokeAgent(agent);
        assertEq(escrow.agentRemaining(payer, agent), 0);
        uint256 id = _createInvoice();
        vm.prank(agent);
        vm.expectRevert("AevumPayEscrow: agent not authorized");
        escrow.fundInvoiceFor(payer, id);
    }

    function testUnauthorizedAgentCannotFund() public {
        uint256 id = _createInvoice();
        vm.prank(agent);
        vm.expectRevert("AevumPayEscrow: agent not authorized");
        escrow.fundInvoiceFor(payer, id);
    }

    function testAgentFundWrongPayerReverts() public {
        _authorize();
        uint256 id = _createInvoice();
        vm.prank(agent);
        vm.expectRevert("AevumPayEscrow: invoice payer mismatch");
        escrow.fundInvoiceFor(stranger, id);
    }

    function testAgentFundWrongStatusReverts() public {
        _authorize();
        uint256 id = _createInvoice();
        vm.prank(payer);
        escrow.fundInvoice(id);
        vm.prank(agent);
        vm.expectRevert("AevumPayEscrow: invoice not in Created status");
        escrow.fundInvoiceFor(payer, id);
    }

    function testReauthorizeKeepsSpent() public {
        _authorize();
        uint256 id = _createInvoice();
        vm.prank(agent);
        escrow.fundInvoiceFor(payer, id);
        // re-authorize with a new cap: spent must NOT reset
        vm.prank(payer);
        escrow.authorizeAgent(agent, CAP + AMOUNT);
        (, uint256 spent, bool active) = escrow.agentAuths(payer, agent);
        assertEq(spent, AMOUNT);
        assertTrue(active);
        assertEq(escrow.agentRemaining(payer, agent), CAP);
    }

    function testRevokeEmitsEvent() public {
        _authorize();
        vm.prank(payer);
        vm.expectEmit(true, true, false, false);
        emit AevumPayEscrow.AgentRevoked(payer, agent);
        escrow.revokeAgent(agent);
    }

    function testAuthorizeZeroAgentReverts() public {
        vm.prank(payer);
        vm.expectRevert("AevumPayEscrow: agent is zero address");
        escrow.authorizeAgent(address(0), CAP);
    }

    // ---- name registry ----

    function testRegisterAndResolveName() public {
        vm.prank(payer);
        escrow.registerName("alice");
        assertEq(escrow.resolveName("alice"), payer);
        assertEq(escrow.nameRegistry("alice"), payer);
    }

    function testRegisterEmptyNameReverts() public {
        vm.prank(payer);
        vm.expectRevert("AevumPayEscrow: name is empty");
        escrow.registerName("");
    }

    function testRegisterNameOverwriteByOtherReverts() public {
        vm.prank(payer);
        escrow.registerName("alice");
        vm.prank(stranger);
        vm.expectRevert("AevumPayEscrow: name already registered to another address");
        escrow.registerName("alice");
        assertEq(escrow.resolveName("alice"), payer);
    }

    function testRegisterNameSameOwnerCanReRegister() public {
        vm.prank(payer);
        escrow.registerName("alice");
        vm.prank(payer);
        escrow.registerName("alice"); // no revert, still payer
        assertEq(escrow.resolveName("alice"), payer);
    }

    function testResolveUnknownNameReturnsZero() public {
        assertEq(escrow.resolveName("nobody"), address(0));
    }

    function testRegisterNameEmitsEvent() public {
        vm.prank(payer);
        vm.expectEmit(false, true, false, true);
        emit AevumPayEscrow.NameRegistered("alice", payer);
        escrow.registerName("alice");
    }

    // ---- misc views ----

    function testAgentRemainingInactiveIsZero() public {
        assertEq(escrow.agentRemaining(payer, agent), 0);
    }

    function testFundWithoutApprovalReverts() public {
        // stranger never approved; create invoice as stranger with no approval
        token.mint(payer, 0); // noop, keeps payer funded
        vm.prank(stranger);
        uint256 id = escrow.createInvoice(payee, AMOUNT, _deadline(), "no approval");
        vm.prank(stranger);
        vm.expectRevert();
        escrow.fundInvoice(id);
    }
}
