#!/usr/bin/env node
/**
 * Aevum Pay — agent script.
 *
 * An authorized agent funds a payer's invoice from the PAYER's wallet, up to
 * the cap the payer set on-chain. The agent never holds the payer's funds:
 * the escrow pulls tUSD8 from the payer via transferFrom, and the payer must
 * have approved the escrow contract first (one-time approve in the frontend).
 *
 * Usage:
 *   node agent.mjs <invoiceId> --payer <payerAddress>
 *
 * Env vars (see README.md):
 *   AGENT_PRIVATE_KEY  fresh testnet-only key for THIS agent — never the
 *                      payer's key, never a mainnet key.
 *   ESCROW_ADDRESS     deployed AevumPayEscrow address on Aevum testnet.
 *   RPC_URL            optional, defaults to https://rpc-test.qday.info
 *
 * Exit codes: 0 = funded, 1 = refused / failed (reason printed to stderr).
 */

import { ethers } from "ethers";
import "dotenv/config"; // loads agent/.env (AGENT_PRIVATE_KEY, ESCROW_ADDRESS) — never committed

const RPC_URL = process.env.RPC_URL || "https://rpc-test.qday.info";
const EXPLORER_URL = process.env.EXPLORER_URL || "https://explorer-test.qday.info";
// Safety: only run on Aevum testnet by default. For LOCAL FORK testing only,
// set ALLOW_CHAIN_IDS to include the fork chain (440050), e.g. "44005,440050".
const ALLOW_CHAIN_IDS = (process.env.ALLOW_CHAIN_IDS || "44005")
  .split(",").map((s) => Number(s.trim())).filter((n) => Number.isFinite(n));
const ESCROW_ADDRESS = process.env.ESCROW_ADDRESS || "";
const AGENT_PRIVATE_KEY = process.env.AGENT_PRIVATE_KEY || "";

// Minimal ABI: only what this script needs (matches SPEC.md exactly).
const ESCROW_ABI = [
  "function fundInvoiceFor(address payer, uint256 id)",
  "function getInvoice(uint256 id) view returns (tuple(address payer, address payee, uint256 amount, uint256 deadline, uint8 status, string memo))",
  "function agentRemaining(address payer, address agent) view returns (uint256)",
  "function agentAuths(address payer, address agent) view returns (tuple(uint256 cap, uint256 spent, bool active))",
];

const STATUS_LABELS = ["Created", "Funded", "Released", "Refunded", "Expired"];
const TUSD8_DECIMALS = 6;

function fail(message) {
  console.error(`ERROR: ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const args = argv.slice(2);
  let invoiceId = null;
  let payer = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--payer") {
      payer = args[++i];
    } else if (args[i] === "--help" || args[i] === "-h") {
      console.log("Usage: node agent.mjs <invoiceId> --payer <payerAddress>");
      console.log("Env: AGENT_PRIVATE_KEY (required), ESCROW_ADDRESS (required), RPC_URL (optional).");
      process.exit(0);
    } else if (!args[i].startsWith("-") && invoiceId === null) {
      invoiceId = args[i];
    } else {
      fail(`Unknown argument: ${args[i]}. Usage: node agent.mjs <invoiceId> --payer <payerAddress>`);
    }
  }
  if (invoiceId === null) fail("Missing <invoiceId>. Usage: node agent.mjs <invoiceId> --payer <payerAddress>");
  if (!/^\d+$/.test(invoiceId)) fail(`Invalid invoice id: "${invoiceId}" — must be a non-negative integer.`);
  if (!payer) fail("Missing --payer <payerAddress>.");
  if (!ethers.isAddress(payer)) fail(`Invalid payer address: ${payer}`);
  return { invoiceId: BigInt(invoiceId), payer: ethers.getAddress(payer) };
}

async function main() {
  const { invoiceId, payer } = parseArgs(process.argv);

  if (!ESCROW_ADDRESS || !ethers.isAddress(ESCROW_ADDRESS) || ESCROW_ADDRESS === ethers.ZeroAddress) {
    fail("ESCROW_ADDRESS is not set (or is the zero address). Set it to the deployed AevumPayEscrow address on Aevum testnet.");
  }
  if (!AGENT_PRIVATE_KEY) {
    fail("AGENT_PRIVATE_KEY is not set. Generate a FRESH testnet-only key (see README.md) — never use the payer's key.");
  }

  let wallet;
  try {
    wallet = new ethers.Wallet(AGENT_PRIVATE_KEY);
  } catch {
    fail("AGENT_PRIVATE_KEY is not a valid private key.");
  }
  const agentAddress = await wallet.getAddress();

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const network = await provider.getNetwork().catch(() => fail(`Could not reach RPC at ${RPC_URL}.`));
  if (!ALLOW_CHAIN_IDS.includes(Number(network.chainId))) {
    fail(`Wrong chain: connected to chain ${network.chainId}, expected one of ${ALLOW_CHAIN_IDS.join(", ")} (Aevum testnet is 44005). Check RPC_URL.`);
  }
  const agent = wallet.connect(provider);
  const escrow = new ethers.Contract(ESCROW_ADDRESS, ESCROW_ABI, agent);

  console.log(`Agent:  ${agentAddress}`);
  console.log(`Payer:  ${payer}`);
  console.log(`Invoice: #${invoiceId}`);
  console.log(`Escrow: ${ESCROW_ADDRESS}`);

  // 1. Read the invoice.
  const invoice = await escrow.getInvoice(invoiceId).catch((err) =>
    fail(`Could not read invoice #${invoiceId}: ${err.reason || err.message}`));
  const status = Number(invoice.status);
  console.log(`Invoice: payer=${invoice.payer} payee=${invoice.payee} ` +
    `amount=${ethers.formatUnits(invoice.amount, TUSD8_DECIMALS)} tUSD8 ` +
    `deadline=${new Date(Number(invoice.deadline) * 1000).toISOString()} ` +
    `status=${STATUS_LABELS[status]} memo="${invoice.memo}"`);

  if (invoice.payer.toLowerCase() !== payer.toLowerCase()) {
    fail(`Invoice #${invoiceId} belongs to payer ${invoice.payer}, not ${payer}. Refusing to pay.`);
  }
  if (status !== 0) {
    fail(`Invoice #${invoiceId} is not in Created status (it is ${STATUS_LABELS[status]}). Only Created invoices can be funded.`);
  }

  // 2. Check the agent's authorization + remaining cap.
  const auth = await escrow.agentAuths(payer, agentAddress);
  if (!auth.active) {
    fail(`Agent ${agentAddress} is NOT authorized by payer ${payer} (or was revoked). ` +
      `The payer must authorize this agent first via the Aevum Pay frontend.`);
  }
  const remaining = await escrow.agentRemaining(payer, agentAddress);
  console.log(`Cap: ${ethers.formatUnits(auth.cap, TUSD8_DECIMALS)} tUSD8, ` +
    `spent: ${ethers.formatUnits(auth.spent, TUSD8_DECIMALS)} tUSD8, ` +
    `remaining: ${ethers.formatUnits(remaining, TUSD8_DECIMALS)} tUSD8`);
  if (invoice.amount > remaining) {
    fail(`Cap insufficient: invoice needs ${ethers.formatUnits(invoice.amount, TUSD8_DECIMALS)} tUSD8 ` +
      `but the agent's remaining cap is ${ethers.formatUnits(remaining, TUSD8_DECIMALS)} tUSD8. ` +
      `Ask the payer to raise the cap, or fund a smaller invoice.`);
  }

  // 3. Fund it. Aevum testnet requires legacy transactions.
  console.log(`Funding invoice #${invoiceId} for ${payer}…`);
  let tx;
  try {
    tx = await escrow.fundInvoiceFor(payer, invoiceId, { type: 0 });
  } catch (err) {
    fail(`fundInvoiceFor reverted or failed to send: ${err.reason || err.shortMessage || err.message} ` +
      `(note: the payer must have approved the escrow to pull tUSD8 first).`);
  }
  console.log(`Tx sent: ${tx.hash}`);
  console.log(`Explorer: ${EXPLORER_URL}/tx/${tx.hash}`);
  const receipt = await tx.wait();
  if (receipt.status !== 1) fail(`Transaction ${tx.hash} reverted on-chain.`);
  console.log(`Invoice #${invoiceId} FUNDED — ${ethers.formatUnits(invoice.amount, TUSD8_DECIMALS)} tUSD8 now held in escrow.`);
  console.log(`Explorer: ${EXPLORER_URL}/tx/${tx.hash}`);
}

main().catch((err) => fail(err.message || String(err)));
