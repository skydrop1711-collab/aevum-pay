# Aevum Pay — Frontend

Static single page (no build step, no framework) for the Aevum Pay escrow
invoice app on **Aevum testnet** (chain 44005). Uses ethers.js v6 from a CDN
and MetaMask.

## Run

```bash
cd web
python3 -m http.server 8080
# open http://localhost:8080
```

Or open `index.html` directly in a browser. MetaMask is required for
transactions; balances and invoice reads also work through the public RPC.

## Configure the contract address

All addresses are constants at the **top of `app.js`**:

```js
const ESCROW_ADDRESS = "0x0000000000000000000000000000000000000000"; // <-- fill in after deploy
const TUSD8_ADDRESS  = "0x456569838f1d43009A91ebA4263147Afd7233483";    // tUSD8, 6 decimals
const DEPLOYMENT_BLOCK = 0;  // set to the escrow deployment block after deploy
```

`ESCROW_ADDRESS` is currently the placeholder zero address because the
contract has not been deployed yet. Until it is set to the real deployed
address the page shows a banner and disables invoice/agent/name actions —
wallet connect and balances still work.

`DEPLOYMENT_BLOCK` matters: the Aevum RPC enforces a 1,000-block
`eth_getLogs` limit, so the page reads `InvoiceCreated` /
`AgentAuthorized` events in 900-block chunks (`LOG_CHUNK` in `app.js`),
starting at the deployment block instead of scanning from genesis.

## What each section does

| Section | What it does |
|---|---|
| **Connect** (header) | Connects MetaMask; auto-prompts to add/switch to Aevum testnet (chain 44005, RPC https://rpc-test.qday.info, symbol tQDAY). |
| **Wallet** | Shows address, tUSD8 balance, tQDAY balance, and current tUSD8 allowance for the escrow. **Approve tUSD8** grants a one-time unlimited allowance so the escrow can pull funds when an invoice is funded. |
| **Create invoice** | Payee as a wallet address **or** a registered name (resolved on-chain), amount in tUSD8, deadline in hours, memo. Calls `createInvoice`. The new invoice id is read back from the `InvoiceCreated` event in the receipt. |
| **Invoices** | All invoices, read from `InvoiceCreated` events (chunked log reads) + `getInvoice` per id. Status badge: Created / Funded / Released / Refunded / Expired. Buttons are gated by status **and** caller role: **Fund** (payer, Created), **Confirm delivery** (payee, Funded — releases funds), **Refund** (payer, Funded), **Claim expired** (anyone, Funded + past deadline — returns funds to the payer). |
| **Agents & spend caps** | Authorize an agent address with a total tUSD8 cap (`authorizeAgent`); lists agents you authorized with cap / spent / **remaining cap** (`agentRemaining`) and a **Revoke** button (`revokeAgent`). Also a lookup: remaining cap for any payer + agent pair. The actual "pay as agent" step runs in `../agent/agent.mjs`. |
| **Name registry** | Register a name for your address (`registerName`, first-come; only you can re-register your own name), resolve a name to an address (`resolveName`), and fill the resolved address into the payee field. |
| **Recent activity** | Every transaction this session, with tx hash + link to `https://explorer-test.qday.info/tx/<hash>`. |

## Notes

- Testnet only. No private keys anywhere in the page; all signing happens in
  MetaMask. No real funds.
- Amounts are tUSD8 with 6 decimals (`parseUnits(amount, 6)`).
- All contract calls use the interface in `SPEC.md` (`../SPEC.md`) — the ABI
  in `app.js` is hardcoded from that spec.
- If MetaMask is on the wrong chain, the page offers to switch; if Aevum
  testnet is not added yet, it offers to add it.
