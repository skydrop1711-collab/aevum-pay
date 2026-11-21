# Aevum Pay — Smart Contracts

Escrow invoice payments in tUSD8 with agent spend caps and a name registry, for the
**Aevum Builder Challenge #1** (DoraHacks, $1,500 USDT, deadline 11 Dec 2026 15:00 WIB).

- Contract: `src/AevumPayEscrow.sol` (Solidity ^0.8.24, MIT)
- Token: tUSD8 `0x456569838f1d43009A91ebA4263147Afd7233483` (6 decimals)
- Network: Aevum testnet, chain ID **44005**, RPC https://rpc-test.qday.info,
  explorer https://explorer-test.qday.info
- EVM version: **Shanghai** (mandatory — `evm_version = "shanghai"` in `foundry.toml`).
  Plain anvil runs Cancun and hides bad bytecode; always use `--hardfork shanghai`.
- Transactions: **legacy only** (`--legacy` in forge script, `type: "legacy"` in viem/ethers).
- Explorer contract verification does NOT work — share addresses + exact commit instead.

## Architecture

```
                  +------------------+
                  |   Payer (human)  |
                  +--------+---------+
                           | 1. createInvoice(payee, amount, deadline, memo)
                           | 2. approve(tUSD8) + fundInvoice(id)
                           | 3. authorizeAgent(agent, cap) / revokeAgent(agent)
                           v
              +---------------------------+
              |     AevumPayEscrow        |      tUSD8 (ERC20, 6 decimals)
              |  +----------------------+ |      +------------------+
              |  | Invoice (per id)     | |      | transferFrom     |
              |  | payer, payee, amount | +----->| transfer         |
              |  | deadline, status     | |      +------------------+
              |  | Created->Funded->    | |
              |  | Released|Refunded|   | |
              |  | Expired              | |
              |  +----------------------+ |
              |  AgentAuth (payer=>agent)| |
              |  cap, spent, active     | |
              |  nameRegistry (name=>   | |
              |  address, first-come)   | |
              +---------------------------+
                 |                 |              ^
                 | 4. confirmDelivery (payee only, Funded -> Released, pays payee)
                 | 5. refundInvoice (payer only, Funded -> Refunded)
                 | 6. claimExpired (anyone, Funded + past deadline -> Expired, pays payer)
                 v                 v
        +--------------+   +------------------+
        | Payee        |   | Agent (no custody)|
        | receives     |   | fundInvoiceFor(payer, id):
        | tUSD8 on     |   | pulls from PAYER via transferFrom,
        | release      |   | bounded by cap - spent, revocable
        +--------------+   +------------------+
```

### Safety model

- The agent **never holds payer funds**: `fundInvoiceFor` pulls tUSD8 from the
  payer (who approved the escrow) straight into escrow, bounded by `cap - spent`.
- Caps are cumulative per payer/agent; re-authorizing keeps `spent` (no reset).
- Revocation is instant (`revokeAgent` sets `active = false`, remaining becomes 0).
- All token-moving functions are `nonReentrant` (OpenZeppelin `ReentrancyGuard`,
  non-transient — Shanghai has no transient storage) and use `SafeERC20`.
- Name registry is first-come: a name can only be re-registered by its owner.

## Contract interface

See `src/AevumPayEscrow.sol` (single source of truth is `~/workspace/aevum/SPEC.md`).
Key functions: `createInvoice`, `fundInvoice`, `fundInvoiceFor`,
`confirmDelivery`, `refundInvoice`, `claimExpired`, `authorizeAgent`,
`revokeAgent`, `registerName`, `resolveName`, `getInvoice`, `agentRemaining`.
Events are emitted for every state change (`InvoiceCreated/Funded/Released/
Refunded/Expired`, `AgentAuthorized/Revoked/Spent`, `NameRegistered`).
ABI: `out/AevumPayEscrow.abi.json`.

## Deployed addresses

| Environment | Chain | Escrow | Deploy tx |
|---|---|---|---|
| Local fork | 440050 | `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9` | `0x99dcdb47d16a91ad081a5ad7909cd4af6abc2dddb9689c7346b42ec8a597ee8e` |
| Aevum testnet | 44005 | *pending — deployer has no tQDAY yet (see below)* | — |

Fork deployment file: `deployments/fork.json`.
Testnet deployment file (when funded): `deployments/testnet.json`.

## Environment variables

| Variable | Purpose |
|---|---|
| `PATH` includes `~/.foundry/bin` | `forge` / `cast` / `anvil` 1.10.0 |
| Foundry keystore account `aevum-deployer` | Testnet deployer (fresh, testnet-only). Keystore at `~/.foundry/keystores/aevum-deployer`. Use with `forge script ... --account aevum-deployer`. Password is held by the operator (see handoff notes) — never commit it. |
| `DEPLOYER_ADDRESS` | `0xFD79641A2016a66689ca68406be7be98918A74f3` (fresh testnet-only deployer) |

No private keys in the repo. No `.env` with secrets is committed.

## Tests

```bash
export PATH="$PATH:$HOME/.foundry/bin"
cd ~/workspace/aevum/contracts

# Unit tests (mock tUSD8, no network): 41 passed
forge test

# Fork tests (real tUSD8, needs a fork on 127.0.0.1:8555): 6 passed
anvil --fork-url https://rpc-test.qday.info --chain-id 440050 \
      --hardfork shanghai --port 8555 --host 127.0.0.1
forge test --match-path test/fork/AevumFork.t.sol --fork-url http://127.0.0.1:8555
```

Fork-test note: the fork test suite auto-skips when run without a fork
(`vm.skip` if the tUSD8 bytecode is absent), so plain `forge test` stays green.

## Deploy

```bash
export PATH="$PATH:$HOME/.foundry/bin"
cd ~/workspace/aevum/contracts

# Local fork (anvil account 0 is the deployer there; fund it first if needed):
#   cast rpc anvil_setBalance 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 0x8AC7230489E80000 --rpc-url http://127.0.0.1:8555
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8555 \
  --broadcast --legacy --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Aevum testnet (needs tQDAY in the deployer — see Faucet below):
forge script script/Deploy.s.sol --rpc-url https://rpc-test.qday.info \
  --account aevum-deployer --broadcast --legacy
```

## Faucet (testnet tQDAY) — BLOCKER, needs a human

Web faucet: https://faucet.qday.info — 5 tQDAY per claim, once per 24h per address.

1. Open the faucet in a browser, connect a wallet (no signature required),
   pass the bot check.
2. **Mainnet balance check (hard blocker for a fresh address):** the recipient
   must hold ~0.0001 ETH, or 1 USDT, or 1 USDC on **Ethereum mainnet**.
   The fresh deployer `0xFD79641A2016a66689ca68406be7be98918A74f3` holds nothing
   on mainnet, so it cannot claim directly.
3. Workaround: claim 5 tQDAY to your own established wallet (one that passes
   the mainnet check), then send ~0.1 tQDAY to the deployer address above.
   Then run the testnet deploy.
4. Alternative faucet: Discord `/faucet` in the Aevum/QDay Discord
   (1 tQDAY + 5 tUSD8, requires the Verified role).

Do NOT invent a faucet claim — testnet deploy happens only after real tQDAY
arrives in the deployer (verifiable with
`cast balance 0xFD79641A2016a66689ca68406be7be98918A74f3 --rpc-url https://rpc-test.qday.info`).

## Fork E2E run (verified 2026-11-21, chain 440050)

Escrow `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9`.
Payer `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` (anvil acct 1, holds real
fork tUSD8), payee `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` (acct 2),
agent `0x90F79bf6EB2c4f870365E785982E1f101E93b906` (acct 3).

| Step | Tx hash | Result |
|---|---|---|
| approve tUSD8 | `0x1a625fd22836489dd5953b68dbdcfb45a3691ddbb3c77ee4da549eda3cd589cf` | ok |
| create invoice #0 (100 tUSD8) | `0x31cf2096bc446cc5471a98c5ece9cf5a7e40425693c90cfdcc134a35f0edf7e4` | id 0 |
| fund invoice #0 | `0xb77fde12099004d457a553c217ab9148e128b804f76beeb8f5a41ebbbc5f0a38` | Funded |
| confirmDelivery #0 | `0x88c1f59f72049b522047f5672bec6d80f17136051ce2392368f8388e573ea61d` | Released, payee +100 tUSD8 |
| authorizeAgent (cap 250 tUSD8) | `0xdc001aec46fa4de76fbc066d2570a88353a204aeea6816a9aaacab768c5377cd` | ok |
| create invoice #1 | `0x4cd0d9b661bc08198522c9ba0926ee45f3340a4c0e3c2c2dd8c82ef58e668652` | id 1 |
| agent fundInvoiceFor #1 | `0xce6971ba0e3ff4620192142d21063f4c8a914e16037f0625b1374ad6695e45a0` | Funded, remaining cap 150 tUSD8 |
| confirmDelivery #1 | `0xad55a8a53ea4bf602b8424afb4750dadd1e23e255709f6d4bc471224572bd0bf` | Released |
| create invoice #2 | `0xd3f0dd3865c997a7382e3bd7dad541ab47796126919c62f1a7cc7caad8581f74` | id 2 |
| fund invoice #2 | `0xe3d11e4140bf5e31511b9992e97a2128cca5364ef99695708d300171cdaf19d1` | Funded |
| refundInvoice #2 | `0x23044d35b77f7b258dd174de719287b622dcdb6cc8a6a1f26e89447f6f34dcb5` | Refunded, payer +100 tUSD8 |
| create invoice #3 (120s deadline) | `0x26218f5749f2c9245f89a9bc8843281c849ca1d01d9ce0edaea787b52015ef1a` | id 3 |
| fund invoice #3 | `0x9ad3436c24f267268800919a8e120c2aef6df250da806cdb8805df4ecfd28834` | Funded |
| claimExpired #3 (after +300s warp) | `0x096bb6b83bbb36648943414676314c4efe668b94014c2401dd00d1eab325f880` | Expired, payer +100 tUSD8 |
| registerName("alice") | `0x04a9eb68c1c69d2401b8cf926d2eda8eaa97bd537bb1782dcb4be1a487585dd1` | resolves to payer |

Final on-chain statuses: #0 Released (2), #1 Released (2), #2 Refunded (3),
#3 Expired (4). Escrow tUSD8 balance 0 after all flows.
