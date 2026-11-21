// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AevumPayEscrow
/// @notice Escrow invoice payments in tUSD8 with agent spend caps and a name registry.
/// @dev Aevum testnet (chain 44005), EVM Shanghai. Agent never holds payer funds:
///      it only triggers a transferFrom from the payer, bounded by a revocable cap.
contract AevumPayEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token; // tUSD8

    enum Status {
        Created,
        Funded,
        Released,
        Refunded,
        Expired
    }

    struct Invoice {
        address payer;
        address payee;
        uint256 amount; // tUSD8, 6 decimals
        uint256 deadline; // unix timestamp
        Status status;
        string memo;
    }

    struct AgentAuth {
        uint256 cap; // max total the agent may spend for this payer
        uint256 spent; // total spent so far
        bool active;
    }

    uint256 public nextInvoiceId;
    mapping(uint256 => Invoice) public invoices;
    mapping(address => mapping(address => AgentAuth)) public agentAuths; // payer => agent => auth
    mapping(string => address) public nameRegistry; // name => address

    event InvoiceCreated(
        uint256 indexed id, address indexed payer, address indexed payee, uint256 amount, uint256 deadline
    );
    event InvoiceFunded(uint256 indexed id, address indexed funder, uint256 amount);
    event InvoiceReleased(uint256 indexed id, address indexed payee, uint256 amount);
    event InvoiceRefunded(uint256 indexed id, address indexed payer, uint256 amount);
    event InvoiceExpired(uint256 indexed id, address indexed payer, uint256 amount);
    event AgentAuthorized(address indexed payer, address indexed agent, uint256 cap);
    event AgentRevoked(address indexed payer, address indexed agent);
    event AgentSpent(address indexed payer, address indexed agent, uint256 indexed invoiceId, uint256 amount);
    event NameRegistered(string name, address indexed addr);

    constructor(address token_) {
        require(token_ != address(0), "AevumPayEscrow: token is zero address");
        token = IERC20(token_);
    }

    function createInvoice(address payee, uint256 amount, uint256 deadline, string calldata memo)
        external
        returns (uint256 id)
    {
        require(payee != address(0), "AevumPayEscrow: payee is zero address");
        require(amount > 0, "AevumPayEscrow: amount is zero");
        require(deadline > block.timestamp, "AevumPayEscrow: deadline must be in the future");

        id = nextInvoiceId++;
        invoices[id] = Invoice({
            payer: msg.sender,
            payee: payee,
            amount: amount,
            deadline: deadline,
            status: Status.Created,
            memo: memo
        });
        emit InvoiceCreated(id, msg.sender, payee, amount, deadline);
    }

    function fundInvoice(uint256 id) external nonReentrant {
        Invoice storage inv = invoices[id];
        require(inv.payer == msg.sender, "AevumPayEscrow: only payer can fund");
        require(inv.status == Status.Created, "AevumPayEscrow: invoice not in Created status");
        _fund(inv, msg.sender);
        emit InvoiceFunded(id, msg.sender, inv.amount);
    }

    function fundInvoiceFor(address payer, uint256 id) external nonReentrant {
        Invoice storage inv = invoices[id];
        require(inv.payer == payer, "AevumPayEscrow: invoice payer mismatch");
        require(inv.status == Status.Created, "AevumPayEscrow: invoice not in Created status");
        AgentAuth storage auth = agentAuths[payer][msg.sender];
        require(auth.active, "AevumPayEscrow: agent not authorized");
        require(inv.amount <= auth.cap - auth.spent, "AevumPayEscrow: amount exceeds agent cap");
        auth.spent += inv.amount;
        _fund(inv, payer);
        emit InvoiceFunded(id, msg.sender, inv.amount);
        emit AgentSpent(payer, msg.sender, id, inv.amount);
    }

    /// @dev Shared funding logic: pull tokens from `from`, mark Funded.
    ///      Caller must have validated caller/status/cap first.
    function _fund(Invoice storage inv, address from) internal {
        token.safeTransferFrom(from, address(this), inv.amount);
        inv.status = Status.Funded;
    }

    function confirmDelivery(uint256 id) external nonReentrant {
        Invoice storage inv = invoices[id];
        require(msg.sender == inv.payee, "AevumPayEscrow: only payee can confirm delivery");
        require(inv.status == Status.Funded, "AevumPayEscrow: invoice not in Funded status");
        inv.status = Status.Released;
        token.safeTransfer(inv.payee, inv.amount);
        emit InvoiceReleased(id, inv.payee, inv.amount);
    }

    function refundInvoice(uint256 id) external nonReentrant {
        Invoice storage inv = invoices[id];
        require(msg.sender == inv.payer, "AevumPayEscrow: only payer can refund");
        require(inv.status == Status.Funded, "AevumPayEscrow: invoice not in Funded status");
        inv.status = Status.Refunded;
        token.safeTransfer(inv.payer, inv.amount);
        emit InvoiceRefunded(id, inv.payer, inv.amount);
    }

    function claimExpired(uint256 id) external nonReentrant {
        Invoice storage inv = invoices[id];
        require(inv.status == Status.Funded, "AevumPayEscrow: invoice not in Funded status");
        require(block.timestamp >= inv.deadline, "AevumPayEscrow: invoice not expired yet");
        inv.status = Status.Expired;
        token.safeTransfer(inv.payer, inv.amount);
        emit InvoiceExpired(id, inv.payer, inv.amount);
    }

    function authorizeAgent(address agent, uint256 cap) external {
        require(agent != address(0), "AevumPayEscrow: agent is zero address");
        AgentAuth storage auth = agentAuths[msg.sender][agent];
        auth.cap = cap;
        auth.active = true;
        // spent is intentionally preserved on re-authorize (spec).
        emit AgentAuthorized(msg.sender, agent, cap);
    }

    function revokeAgent(address agent) external {
        agentAuths[msg.sender][agent].active = false;
        emit AgentRevoked(msg.sender, agent);
    }

    function registerName(string calldata name) external {
        require(bytes(name).length > 0, "AevumPayEscrow: name is empty");
        address existing = nameRegistry[name];
        require(
            existing == address(0) || existing == msg.sender,
            "AevumPayEscrow: name already registered to another address"
        );
        nameRegistry[name] = msg.sender;
        emit NameRegistered(name, msg.sender);
    }

    function resolveName(string calldata name) external view returns (address) {
        return nameRegistry[name];
    }

    function getInvoice(uint256 id) external view returns (Invoice memory) {
        return invoices[id];
    }

    function agentRemaining(address payer, address agent) external view returns (uint256) {
        AgentAuth storage auth = agentAuths[payer][agent];
        if (!auth.active) return 0;
        return auth.cap - auth.spent;
    }
}
