# Aevum Pay — Interface Spec (single source of truth)

Project: "Aevum Pay" — escrow invoice payment with agent spend caps on Aevum testnet.
Challenge: Aevum Builder Challenge #1 (DoraHacks). Prize $1,500 USDT. Deadline 11 Dec 2026 15:00 WIB.
Workdir: `~/workspace/aevum/`
Foundry: installed at `~/.foundry/bin/` (forge/cast/anvil 1.10.0). Add to PATH: `export PATH="$PATH:/home/hatch/.foundry/bin"`.

## Network (Aevum testnet)
- Chain ID: 44005. RPC: https://rpc-test.qday.info (HTTPS only, NO WebSocket).
- Explorer: https://explorer-test.qday.info
- Gas token tQDAY (~1 gwei). EVM version Shanghai — MANDATORY: `evm_version = "shanghai"` in foundry.toml.
- tUSD8: `0x456569838f1d43009A91ebA4263147Afd7233483`, 6 decimals, EIP-2612 permit + EIP-3009.
  EIP-712 domain name "tUSD8", version "2".
- Multicall3: `0xcA11bde05977b3631167028862bE2a173976CA11`.
- Local fork: anvil fork of Aevum testnet on 127.0.0.1:8555, chain 440050. ALWAYS use `--hardfork shanghai` with anvil (plain anvil runs Cancun and hides bad bytecode).
- Legacy transactions only: `--legacy` in forge script, `type: "legacy"` in viem/ethers.
- 1,000-block `eth_getLogs` limit: poll in chunks, never a wide range in one call.
- Explorer contract verification does NOT work — share contract addresses + exact commit instead.
- ERC-8004 registry is NOT open — the name-to-address mapping lives in OUR contract.

## Contract: AevumPayEscrow (Solidity ^0.8.24, MIT)
File: `contracts/src/AevumPayEscrow.sol`. Use OpenZeppelin `IERC20` + `ReentrancyGuard` (NOT `*Transient` — Shanghai has no transient storage). No other OZ contracts needed.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract AevumPayEscrow is ReentrancyGuard {
    IERC20 public immutable token; // tUSD8

    enum Status { Created, Funded, Released, Refunded, Expired }

    struct Invoice {
        address payer;
        address payee;
        uint256 amount;   // tUSD8, 6 decimals
        uint256 deadline; // unix timestamp
        Status status;
        string memo;
    }

    struct AgentAuth {
        uint256 cap;    // max total the agent may spend for this payer
        uint256 spent;  // total spent so far
        bool active;
    }

    uint256 public nextInvoiceId;
    mapping(uint256 => Invoice) public invoices;
    mapping(address => mapping(address => AgentAuth)) public agentAuths; // payer => agent => auth
    mapping(string => address) public nameRegistry; // name => address

    event InvoiceCreated(uint256 indexed id, address indexed payer, address indexed payee, uint256 amount, uint256 deadline);
    event InvoiceFunded(uint256 indexed id, address indexed funder, uint256 amount);
    event InvoiceReleased(uint256 indexed id, address indexed payee, uint256 amount);
    event InvoiceRefunded(uint256 indexed id, address indexed payer, uint256 amount);
    event InvoiceExpired(uint256 indexed id, address indexed payer, uint256 amount);
    event AgentAuthorized(address indexed payer, address indexed agent, uint256 cap);
    event AgentRevoked(address indexed payer, address indexed agent);
    event AgentSpent(address indexed payer, address indexed agent, uint256 indexed invoiceId, uint256 amount);
    event NameRegistered(string name, address indexed addr);

    constructor(address token_) { token = IERC20(token_); }

    function createInvoice(address payee, uint256 amount, uint256 deadline, string calldata memo)
        external returns (uint256 id);
    function fundInvoice(uint256 id) external nonReentrant;
    function fundInvoiceFor(address payer, uint256 id) external nonReentrant;
    function confirmDelivery(uint256 id) external nonReentrant;
    function refundInvoice(uint256 id) external nonReentrant;
    function claimExpired(uint256 id) external nonReentrant;
    function authorizeAgent(address agent, uint256 cap) external;
    function revokeAgent(address agent) external;
    function registerName(string calldata name) external;
    function resolveName(string calldata name) external view returns (address);
    function getInvoice(uint256 id) external view returns (Invoice memory);
    function agentRemaining(address payer, address agent) external view returns (uint256);
}
```

### Semantics (implement exactly)
- `createInvoice`: payer = msg.sender. Require payee != address(0), amount > 0, deadline > block.timestamp. Status = Created. Emit InvoiceCreated. Return id = nextInvoiceId++.
- `fundInvoice`: msg.sender must be the invoice payer; status must be Created; pull `amount` tUSD8 from msg.sender via `transferFrom` (payer must have approved the escrow first); status = Funded; emit InvoiceFunded.
- `fundInvoiceFor(payer, id)`: msg.sender must be an authorized agent of `payer` (active, and `amount <= cap - spent`); the invoice's payer must equal `payer`; status must be Created; pull `amount` tUSD8 from `payer` via `transferFrom` (payer must have approved the escrow first); increment agent spent; status = Funded; emit InvoiceFunded AND AgentSpent.
- `confirmDelivery`: only the payee may call; status must be Funded; transfer `amount` tUSD8 to payee; status = Released; emit InvoiceReleased.
- `refundInvoice`: only the payer may call; status must be Funded; transfer `amount` tUSD8 back to payer; status = Refunded; emit InvoiceRefunded.
- `claimExpired`: anyone may call; status must be Funded AND block.timestamp >= deadline; transfer `amount` tUSD8 back to payer; status = Expired; emit InvoiceExpired.
- `authorizeAgent`: msg.sender is the payer; set cap + active = true, keep existing spent (do not reset spent on re-authorize); emit AgentAuthorized.
- `revokeAgent`: msg.sender is the payer; set active = false; emit AgentRevoked.
- `registerName`: register msg.sender under `name`; require name non-empty; emit NameRegistered. (First-come: do NOT allow overwriting an existing name unless it maps to msg.sender — i.e. require `nameRegistry[name] == address(0) || nameRegistry[name] == msg.sender`.)
- `agentRemaining(payer, agent)`: return active ? cap - spent : 0.
- All token transfers must use `transferFrom`/`transfer` return-value checks (use OpenZeppelin `SafeERC20` to be safe with non-standard returns).
- Reentrancy: `nonReentrant` on fund/release/refund/expired (they move tokens).

## Foundry project layout (~/workspace/aevum/)
```
contracts/            # forge project root
  foundry.toml        # evm_version = "shanghai", optimizer on
  src/AevumPayEscrow.sol
  test/AevumPayEscrow.t.sol      # unit tests (mock tUSD8, no network)
  test/fork/AevumFork.t.sol      # fork tests vs real tUSD8 on 127.0.0.1:8555
  script/Deploy.s.sol            # deploy to fork (440050) + testnet (44005), --legacy
  lib/ (forge install OpenZeppelin)
  README.md           # architecture flowchart, env vars, addresses, how to run
web/                  # static frontend (no framework)
  index.html
  app.js              # ethers.js v6 via CDN, MetaMask, chain 44005
agent/                # agent script
  agent.mjs           # Node.js + ethers v6: read invoice, check cap, pay as agent
  package.json
README.md             # top-level: problem, architecture, workflow, QDay integration, links
LICENSE (MIT)
```

## Frontend requirements (static page, ethers.js v6 via CDN)
- Connect MetaMask; auto-prompt to add/switch to Aevum testnet (chain 44005, RPC https://rpc-test.qday.info, explorer https://explorer-test.qday.info, symbol tQDAY).
- Show connected address + tUSD8 balance + tQDAY balance.
- Create invoice form (payee address OR registered name, amount in tUSD8, deadline in hours, memo).
- Approve tUSD8 once + Fund button per invoice; list all invoices (read from events, chunked log reads) with status; Confirm Delivery (payee), Refund (payer), Claim Expired (anyone) buttons, gated by status + caller role.
- Agent section: authorize agent (address + cap), revoke, show remaining cap; "pay as agent" is done by the agent script, but the page shows agent authorizations.
- Name registry: register a name for your address, resolve a name to an address.
- Every action shows the tx hash + explorer link. All contract addresses are configurable constants at the top of app.js (ESCROW_ADDRESS, TUSD8_ADDRESS). No build step; open index.html directly or serve statically.
- No private keys in the page. No real funds. Testnet only.

## Agent script (Node.js, ethers v6)
- `agent/agent.mjs`: loads payer + agent keypair from env (AGENT_PRIVATE_KEY is a FRESH testnet-only key; never the user's key), connects to RPC https://rpc-test.qday.info (legacy tx type), reads an invoice id from argv, checks the agent's remaining cap, and if the invoice amount fits, calls `fundInvoiceFor(payer, id)`. Prints the tx hash + explorer link. Exits non-zero with a clear message if the cap is insufficient or the invoice is not in Created status. README documents how to run it.
- The agent keypair is generated fresh for the demo; the payer authorizes it on-chain first (via the frontend or a cast call).

## Deployer keypair (testnet only, throwaway)
- Generate with `cast wallet new`. NEVER use the user's key. Keep the private key OUT of the repo, out of chat, out of committed files. Use Foundry keystore (`cast wallet import aevum-deployer --interactive`) for deploys, or a local .env that is gitignored (never commit it).
- Faucet order: test on the local fork FIRST (`make deal` equivalent: anvil fork + `cast` to set balances). For real testnet, try the web faucet https://faucet.qday.info with the fresh deployer address. If it needs a captcha or a human step, STOP and report the deployer address + exactly what is needed — do NOT invent a faucet claim.

## Judging criteria to hit
- UX/presentation; verifiable on-chain activity (tx hashes, explorer links, verified addresses); docs (README + architecture flowchart + env vars + testnet addresses); agentic mechanics (spend caps, agent authorization); technical quality (spend limits, session-style caps, revocation); real-world utility (invoice escrow); safety (least-privilege: agent never holds payer funds, caps, instant revocation); ecosystem (modular, reusable, open source, MIT).
