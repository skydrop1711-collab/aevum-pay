# Aevum Pay — Escrow Invoice Payments with Agent Spend Caps

> A stablecoin payment app for humans **and** AI agents on the Aevum testnet.
> Built for the **Aevum Builder Challenge #1** (DoraHacks). Prize $1,500 USDT.
> Deadline: **11 Dec 2026, 15:00 WIB** (16:00 HKT / 08:00 UTC).

## The problem

Paying a contractor, a freelancer, or an AI agent in stablecoin today is trust-on-a-prayer:
you send the money first and hope the work arrives, or the agent holds your funds and
you hope it does not overspend. Aevum Pay fixes both with one contract:

- **Escrow invoices** — the payer locks tUSD8 in escrow; the payee confirms delivery
  and the funds release; the payer can refund before release; an unconfirmed invoice
  auto-refunds after its deadline.
- **Agent spend caps** — the payer authorizes an AI agent address with a cap. The
  agent can pay invoices **from the payer's wallet** (via `transferFrom`) up to its
  remaining cap, but it never holds the payer's funds, and the payer can revoke it
  instantly. This is the agentic payment primitive: least-privilege, capped,
  revocable.
- **Name registry** — a name-to-address map inside the contract (QDay's ERC-8004
  registry is still in internal testing and not open for this challenge), so you can
  pay `alice` instead of pasting `0x…`.

## Architecture

```
                  ┌──────────────────────────────┐
                  │        Aevum testnet         │
                  │        chain 44005           │
                  │                              │
  payer ──approve─▶│  tUSD8  0x4565…3483 (6 dec) │
                  │                              │
  payer ──create──▶│  AevumPayEscrow              │
  agent ──fund────▶│   invoices, agent caps,      │
  payee ──confirm─▶│   name registry, events      │
                  │                              │
                  └──────────────┬───────────────┘
                                 │ events / reads
                    ┌────────────┴────────────┐
                    │                         │
              web/ (static)            agent/ (Node.js)
         MetaMask + ethers.js v6    ethers v6, legacy tx
         create / fund / confirm    reads invoice, checks
         / refund / claim-expired   cap, pays as agent
```

### Contracts (`contracts/`, Foundry, Solidity ^0.8.24, EVM Shanghai)

| File | What it is |
| --- | --- |
| `src/AevumPayEscrow.sol` | Escrow invoices + agent spend caps + name registry. `SafeERC20` + non-transient `ReentrancyGuard`. |
| `test/AevumPayEscrow.t.sol` | Unit tests with a mock tUSD8 (6 decimals). |
| `test/fork/AevumFork.t.sol` | Fork tests against the real tUSD8 on a local anvil fork of Aevum. |
| `script/Deploy.s.sol` | Deploy to fork (440050) and to Aevum testnet (44005). Legacy txs. |

**Invoice lifecycle:** `Created → Funded → Released` (payee confirms) or `Refunded`
(payer refunds) or `Expired` (anyone claims after the deadline; funds return to payer).
**Agent flow:** payer calls `authorizeAgent(agent, cap)` and approves the escrow once;
the agent calls `fundInvoiceFor(payer, id)` — the escrow pulls tUSD8 from the **payer**,
never from the agent, and only up to `cap - spent`. `revokeAgent` stops it instantly.

### Frontend (`web/`, static HTML/JS, no build step)

`index.html` + `app.js` (ethers.js v6 via CDN). Connects MetaMask to Aevum testnet
(chain 44005), shows tUSD8/tQDAY balances, creates invoices (payee address **or**
registered name), approves + funds, lists invoices from `InvoiceCreated` events
(chunked 900-block log reads — the RPC caps `eth_getLogs` at 1,000 blocks), and
exposes Confirm Delivery / Refund / Claim Expired gated by status and caller role,
plus the agent authorize/revoke/remaining-cap panel and the name registry.
Every action logs its tx hash + explorer link.

### Agent script (`agent/`, Node.js + ethers v6)

`agent.mjs <invoiceId> --payer <payerAddress>` reads the invoice, verifies the payer
and `Created` status, checks the agent's remaining cap, and — only if the amount fits —
calls `fundInvoiceFor(payer, id)` with a legacy transaction. Prints the tx hash +
explorer link. Refuses with a clear message when unauthorized, revoked, or over cap.
The agent key is a **fresh testnet-only throwaway** (never the user's key).

## QDay / Aevum integration

- Network: Aevum testnet, chain **44005**, RPC https://rpc-test.qday.info (HTTPS only,
  no WebSocket), explorer https://explorer-test.qday.info.
- Token: **tUSD8** `0x456569838f1d43009A91ebA4263147Afd7233483`, 6 decimals, EIP-2612
  permit + EIP-3009, EIP-712 domain name `"tUSD8"`, version `"2"`.
- EVM **Shanghai** (mandatory — Cancun opcodes do not exist on Aevum; the contract
  uses no transient storage). All transactions are **legacy (type 0)**.
- Local fork: anvil fork of Aevum on `127.0.0.1:8555`, chain **440050**, always
  `--hardfork shanghai`.
- Contract verification on the explorer does not work yet — this README links the
  contract addresses and the exact commit instead.

## Deployments

### Local fork (chain 440050) — LIVE, fully tested

| | |
| --- | --- |
| Escrow | `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9` |
| Deploy tx | `0x99dcdb47d16a91ad081a5ad7909cd4af6abc2dddb9689c7346b42ec8a597ee8e` |
| Explorer | https://explorer-test.qday.info/address/0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9 (testnet explorer; the fork is local) |

End-to-end on the fork (all verified on-chain): invoice #0 Released, #1 Released
(agent-funded), #2 Refunded, #3 Expired, escrow balance 0; plus a live agent-script
run funding invoice #4 (10 tUSD8, cap 50 → remaining 40), tx
`0x5e0dfeeeb78ce3f609d0ae52d6801189d56b9887de9081386962c58580919c5e`.
See `contracts/README.md` for the full tx table.

### Aevum testnet (chain 44005) — LIVE, end-to-end verified

| | |
| --- | --- |
| Escrow | `0x79c322BA58fdF1FDFE347d52D8f58D5F7708aD54` |
| Deploy tx | `0x10d67b83a9c9057e786faf83650af12fe86329cff61e6993a3ea0ba2641e3d4c` |
| Deploy block | 3765006 (status 1, gas 1,550,004 @ 1 gwei) |
| Explorer | https://explorer-test.qday.info/address/0x79c322BA58fdF1FDFE347d52D8f58D5F7708aD54 |
| Deployer | `0xFD79641A2016a66689ca68406be7be98918A74f3` (fresh testnet-only key; funded via QDay Discord `/faucet`: 1 tQDAY + 5 tUSD8) |
| Agent | `0x637d5EE87111b106D04a79A99D4A4728Fb2B5ca0` (fresh testnet-only key, cap 50 tUSD8) |

End-to-end on testnet (all verified on-chain, 22 Nov 2026):
- Payer approved 100 tUSD8 for the escrow and authorized the agent with a 50 tUSD8 cap.
- Invoice #1 (2 tUSD8, payee = agent) created — tx `0x439666f6f6b22b5874ed500eab3a7f51c3b69d72d7e8f469206e0c6b128a523a`.
- Agent funded it via `fundInvoiceFor` — tx `0x29b963ede97dc5367b811b1485748ab12b13ef54c404f1d955b5ab14dddf8fe8` ("Invoice #1 FUNDED — 2.0 tUSD8").
- Payee confirmed delivery — tx `0x796b0a2f45af2560e8280369f2c1a7d56d6b14cd4a4150b03c5fdd6bf85504c8` (Transfer 2 tUSD8 escrow → payee + `InvoiceReleased` event). Escrow tUSD8 balance: 2 → 0.
- (Invoice #0, 10 tUSD8, was left unfunded on purpose: the payer only held 5 tUSD8 at the time — a test-sizing mistake, not a contract issue.)

Note: contract verification on the Aevum explorer does not work yet — this README
links the contract addresses and the exact commit instead. See
`contracts/deployments/testnet.json` for the full deployment record.

## Test results

| Suite | Result |
| --- | --- |
| Unit tests (`forge test`, mock tUSD8) | **41 passed, 0 failed** |
| Fork tests (real tUSD8, anvil fork) | **6 passed, 0 failed** |
| Fork E2E (deploy + create/fund/confirm/refund/expire/agent) | **all succeeded**, statuses verified on-chain |
| Agent script vs fork (live run, invoice #4) | **FUNDED**, cap 50 → remaining 40, exit 0 |
| **Testnet E2E (chain 44005, live)** | **all succeeded**: invoice #1 (2 tUSD8) created → agent funded via `fundInvoiceFor` → payee confirmed → 2 tUSD8 released, escrow balance 0 |
| Frontend ABI vs built contract ABI | **match** (17 functions + 9 events; ERC20 helpers are the token's, not the escrow's) |
| Frontend serving + live RPC reads | chain 44005, block 3,763,273, tUSD8 name/symbol/decimals confirmed |

## Run it

### Contracts
```bash
export PATH="$PATH:$HOME/.foundry/bin"
cd contracts
forge test                          # unit tests (mock tUSD8)
# fork tests need a local fork running:
anvil --fork-url https://rpc-test.qday.info --hardfork shanghai --port 8555
forge test --fork-url http://127.0.0.1:8555
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8555 --broadcast --legacy
```

### Frontend
```bash
cd web
python3 -m http.server 8000
# open http://localhost:8000, connect MetaMask (Aevum testnet, chain 44005)
# set ESCROW_ADDRESS at the top of app.js to the deployed contract first
```

### Agent script
```bash
cd agent
npm install
# cp .env.example .env  (set AGENT_PRIVATE_KEY to a FRESH testnet-only key + ESCROW_ADDRESS)
node agent.mjs 4 --payer 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
```

## Env vars

| Var | Where | Notes |
| --- | --- | --- |
| `ESCROW_ADDRESS` | `web/app.js`, `agent/.env` | Deployed AevumPayEscrow address. |
| `DEPLOYMENT_BLOCK` | `web/app.js` | Block the escrow was deployed at (log reads start here). |
| `AGENT_PRIVATE_KEY` | `agent/.env` | Fresh testnet-only agent key. Never the user's key. Never committed (gitignored). |
| `RPC_URL` | `agent/.env` (optional) | Defaults to https://rpc-test.qday.info. |
| `ALLOW_CHAIN_IDS` | `agent/.env` (optional) | Defaults to `44005`. Add `440050` only for local-fork testing. |

## Demo video

`video/aevum-pay-demo.mp4` (1–5 min, English narration) — walkthrough of the contract,
the frontend, and the agent paying an invoice on the fork, plus the testnet status.

## Credits & license

MIT. Built on the [Aevum starter kit](https://github.com/qday-io/aevum-starter-kit)
(MIT) for network details, the fork setup, and the Shanghai/legacy-transaction notes.
OpenZeppelin contracts (MIT) for `IERC20` / `SafeERC20` / `ReentrancyGuard`.
No code reused from previous hackathons; all contracts written during the build window.
