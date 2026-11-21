# Aevum Pay — Agent Script

The agent funds a payer's escrow invoice from the **payer's** wallet, up to the
cap the payer set on-chain. The agent never holds the payer's funds: the
escrow pulls tUSD8 from the payer via `transferFrom`, so the payer must have
approved the escrow contract first (one-time approve in the frontend).

## Setup

```bash
cd agent
npm install
```

### 1. Agent key (fresh, testnet-only)

A demo agent keypair was already generated for this project:

- **Agent address:** `0x637d5EE87111b106D04a79A99D4A4728Fb2B5ca0`
- Private key: stored in `agent/.env` (gitignored — never committed, never shared)

To generate your own instead:

```bash
node -e "console.log(require('ethers').Wallet.createRandom().privateKey)"
# put the output in agent/.env as AGENT_PRIVATE_KEY=0x...
```

⚠️ This key is **testnet-only and throwaway**. Never use the payer's key, a
mainnet key, or any key that holds real funds. The agent only needs enough
tQDAY for gas — get it from the Aevum testnet faucet
(https://faucet.qday.info).

### 2. Environment

`agent/.env`:

```
AGENT_PRIVATE_KEY=0x...   # the agent's own fresh testnet key
ESCROW_ADDRESS=0x...      # deployed AevumPayEscrow on Aevum testnet (44005)
# RPC_URL=https://rpc-test.qday.info   # optional, this is the default
```

`agent.mjs` loads `.env` via `dotenv`. You can also export the variables in
your shell instead — shell variables take precedence.

### 3. Payer authorizes the agent first (on-chain, via the frontend)

Before the agent can pay anything, the payer must, in the web frontend:

1. Connect MetaMask (Aevum testnet) and **Approve tUSD8** for the escrow.
2. In **Agents & spend caps**, authorize the agent address
   (`0x637d5EE87111b106D04a79A99D4A4728Fb2B5ca0` for the demo key) with a cap,
   e.g. `100` tUSD8.
3. Create an invoice (the payer is the invoice creator).

The payer can revoke the agent at any time in the same section — revocation
takes effect immediately on-chain.

## Usage

```bash
node agent.mjs <invoiceId> --payer <payerAddress>
```

Example:

```bash
node agent.mjs 0 --payer 0xYourPayerAddress
```

What it does, in order:

1. Reads the invoice with `getInvoice(id)` — checks the invoice belongs to
   `--payer` and is in `Created` status.
2. Reads `agentAuths(payer, agent)` and `agentRemaining(payer, agent)` —
   refuses if the agent is not authorized/revoked or the invoice amount
   exceeds the remaining cap.
3. Calls `fundInvoiceFor(payer, id)` as a **legacy** transaction
   (Aevum testnet requires `type: 0`) and waits for confirmation.
4. Prints the tx hash + explorer link:
   `https://explorer-test.qday.info/tx/<hash>`

## Failure modes (exit code 1, message on stderr)

| Situation | Message |
|---|---|
| `ESCROW_ADDRESS` unset / zero address | "ESCROW_ADDRESS is not set…" |
| `AGENT_PRIVATE_KEY` unset / invalid | "AGENT_PRIVATE_KEY is not set…" |
| Invoice belongs to another payer | "Invoice #N belongs to payer …" |
| Invoice not `Created` | "Invoice #N is not in Created status (it is …)" |
| Agent not authorized / revoked | "Agent … is NOT authorized by payer …" |
| Amount exceeds remaining cap | "Cap insufficient: invoice needs … but the agent's remaining cap is …" |
| Payer never approved the escrow | `fundInvoiceFor` reverts (allowance) |

## Files

- `agent.mjs` — the script (Node.js, ethers v6, no other runtime deps).
- `package.json` — `ethers ^6`, `dotenv`.
- `.env` — **local only, gitignored**: agent private key + escrow address.
- `.gitignore` — keeps `.env` and `node_modules/` out of the repo.
