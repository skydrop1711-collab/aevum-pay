/* ============================================================================
 * Aevum Pay — frontend (ethers.js v6, MetaMask, Aevum testnet)
 * Static page, no build step. Testnet only — no real funds, no private keys.
 * ========================================================================== */

// --- Configurable constants (edit these when the contract is deployed) ---
// ESCROW_ADDRESS: fill in once AevumPayEscrow is deployed on Aevum testnet.
// Until then it is the zero address and the page runs in "not deployed" mode
// (wallet connect + balances still work; contract actions are disabled).
const ESCROW_ADDRESS = "0x79c322BA58fdF1FDFE347d52D8f58D5F7708aD54";
const TUSD8_ADDRESS  = "0x456569838f1d43009A91ebA4263147Afd7233483"; // tUSD8, 6 decimals
const RPC_URL        = "https://rpc-test.qday.info";
const CHAIN_ID       = 44005;
const CHAIN_ID_HEX   = "0xabe5"; // 44005
const EXPLORER_URL   = "https://explorer-test.qday.info";
// First block to scan for InvoiceCreated events. Set to the escrow deployment
// block once deployed so the page does not scan from genesis.
const DEPLOYMENT_BLOCK = 3765006;
// Aevum testnet RPC enforces a 1,000-block eth_getLogs limit — never query a
// wider range in a single call. Keep chunks safely below the limit.
const LOG_CHUNK = 900;
const TUSD8_DECIMALS = 6;

// --- ABIs (from SPEC.md — the contract interface is the single source of truth) ---
const ESCROW_ABI = [
  "function createInvoice(address payee, uint256 amount, uint256 deadline, string memo) returns (uint256 id)",
  "function fundInvoice(uint256 id)",
  "function fundInvoiceFor(address payer, uint256 id)",
  "function confirmDelivery(uint256 id)",
  "function refundInvoice(uint256 id)",
  "function claimExpired(uint256 id)",
  "function authorizeAgent(address agent, uint256 cap)",
  "function revokeAgent(address agent)",
  "function registerName(string name)",
  "function resolveName(string name) view returns (address)",
  "function getInvoice(uint256 id) view returns (tuple(address payer, address payee, uint256 amount, uint256 deadline, uint8 status, string memo))",
  "function agentRemaining(address payer, address agent) view returns (uint256)",
  "function agentAuths(address payer, address agent) view returns (tuple(uint256 cap, uint256 spent, bool active))",
  "function invoices(uint256 id) view returns (tuple(address payer, address payee, uint256 amount, uint256 deadline, uint8 status, string memo))",
  "function nameRegistry(string name) view returns (address)",
  "function nextInvoiceId() view returns (uint256)",
  "function token() view returns (address)",
  "event InvoiceCreated(uint256 indexed id, address indexed payer, address indexed payee, uint256 amount, uint256 deadline)",
  "event InvoiceFunded(uint256 indexed id, address indexed funder, uint256 amount)",
  "event InvoiceReleased(uint256 indexed id, address indexed payee, uint256 amount)",
  "event InvoiceRefunded(uint256 indexed id, address indexed payer, uint256 amount)",
  "event InvoiceExpired(uint256 indexed id, address indexed payer, uint256 amount)",
  "event AgentAuthorized(address indexed payer, address indexed agent, uint256 cap)",
  "event AgentRevoked(address indexed payer, address indexed agent)",
  "event AgentSpent(address indexed payer, address indexed agent, uint256 indexed invoiceId, uint256 amount)",
  "event NameRegistered(string name, address indexed addr)",
];

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
];

// --- State ---
const ESCROW_DEPLOYED = ESCROW_ADDRESS !== "0x0000000000000000000000000000000000000000";
let provider = null;      // ethers.BrowserProvider (MetaMask)
let readProvider = null;  // ethers.JsonRpcProvider (public RPC, for log scans)
let signer = null;
let account = null;
let escrow = null;        // write contract (signer)
let escrowRead = null;    // read contract (public RPC)
let token = null;         // tUSD8 (signer)
let tokenRead = null;     // tUSD8 (public RPC)

const STATUS_LABELS = ["Created", "Funded", "Released", "Refunded", "Expired"];

// --- DOM helpers ---
const $ = (id) => document.getElementById(id);
const short = (addr) => (addr ? addr.slice(0, 6) + "…" + addr.slice(-4) : "—");
const explorerTx = (hash) => `${EXPLORER_URL}/tx/${hash}`;
const fmtTusd8 = (v) => ethers.formatUnits(v, TUSD8_DECIMALS);
const fmtDate = (ts) => new Date(Number(ts) * 1000).toLocaleString();

function setStatus(msg) { $("status").textContent = msg; }

function logActivity(label, hash) {
  const list = $("activity");
  if (list.querySelector("li") && list.textContent.includes("No transactions yet.")) list.innerHTML = "";
  const li = document.createElement("li");
  const a = document.createElement("a");
  a.href = explorerTx(hash); a.target = "_blank"; a.rel = "noopener";
  a.textContent = short(hash); a.className = "mono";
  li.textContent = `${new Date().toLocaleTimeString()} — ${label}: `;
  li.appendChild(a);
  list.prepend(li);
}

function showBanner(msg) {
  const b = $("banner");
  b.style.display = "block";
  b.textContent = msg;
}

async function sendTx(label, txPromise) {
  setStatus(`${label} — waiting for signature…`);
  const tx = await txPromise;
  logActivity(label, tx.hash);
  setStatus(`${label} — sent, waiting for confirmation… (${short(tx.hash)})`);
  const receipt = await tx.wait();
  if (receipt.status !== 1n && receipt.status !== 1) throw new Error("Transaction reverted on-chain.");
  setStatus(`${label} — confirmed.`);
  return receipt;
}

// --- Chunked log reads (RPC limit: 1,000 blocks per eth_getLogs call) ---
async function queryFilterChunked(contract, filter, fromBlock, toBlock) {
  const out = [];
  for (let from = fromBlock; from <= toBlock; from += LOG_CHUNK) {
    const to = Math.min(from + LOG_CHUNK - 1, toBlock);
    const chunk = await contract.queryFilter(filter, from, to);
    out.push(...chunk);
  }
  return out;
}

// --- Wallet connect + network ---
async function connect() {
  if (typeof window.ethereum === "undefined") {
    alert("MetaMask is not installed. Install it from https://metamask.io and reload this page.");
    return;
  }
  if (typeof ethers === "undefined") {
    alert("ethers.js failed to load from the CDN. Check your connection and reload.");
    return;
  }
  provider = new ethers.BrowserProvider(window.ethereum);
  readProvider = new ethers.JsonRpcProvider(RPC_URL);

  // Make sure we are on Aevum testnet; offer to add/switch if not.
  let network = await provider.getNetwork();
  if (Number(network.chainId) !== CHAIN_ID) {
    try {
      await window.ethereum.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: CHAIN_ID_HEX }],
      });
    } catch (switchErr) {
      if (switchErr && switchErr.code === 4902) {
        await window.ethereum.request({
          method: "wallet_addEthereumChain",
          params: [{
            chainId: CHAIN_ID_HEX,
            chainName: "Aevum Testnet",
            nativeCurrency: { name: "tQDAY", symbol: "tQDAY", decimals: 18 },
            rpcUrls: [RPC_URL],
            blockExplorerUrls: [EXPLORER_URL],
          }],
        });
      } else {
        throw switchErr;
      }
    }
    network = await provider.getNetwork();
    if (Number(network.chainId) !== CHAIN_ID) throw new Error("Please switch MetaMask to Aevum testnet (chain 44005).");
  }

  const accounts = await provider.send("eth_requestAccounts", []);
  account = accounts[0];
  signer = await provider.getSigner();
  token = new ethers.Contract(TUSD8_ADDRESS, ERC20_ABI, signer);
  tokenRead = new ethers.Contract(TUSD8_ADDRESS, ERC20_ABI, readProvider);
  if (ESCROW_DEPLOYED) {
    escrow = new ethers.Contract(ESCROW_ADDRESS, ESCROW_ABI, signer);
    escrowRead = new ethers.Contract(ESCROW_ADDRESS, ESCROW_ABI, readProvider);
  }

  $("walletAddress").textContent = account;
  $("connectBtn").textContent = `Connected: ${short(account)}`;
  setStatus(`Connected on Aevum testnet (chain ${CHAIN_ID}).`);
  for (const id of ["approveBtn", "refreshBtn", "createBtn", "reloadInvoicesBtn",
                    "authorizeBtn", "lookupBtn", "registerNameBtn", "resolveBtn", "useAsPayeeBtn"]) {
    $(id).disabled = false;
  }
  if (!ESCROW_DEPLOYED) {
    for (const id of ["createBtn", "reloadInvoicesBtn", "authorizeBtn", "lookupBtn",
                      "registerNameBtn", "resolveBtn"]) $(id).disabled = true;
  }

  await refreshBalances();
  await loadInvoices();
  await loadAgents();
}

async function refreshBalances() {
  if (!account) return;
  try {
    const [tusd8, tqday, allowance] = await Promise.all([
      tokenRead.balanceOf(account),
      provider.getBalance(account),
      ESCROW_DEPLOYED ? tokenRead.allowance(account, ESCROW_ADDRESS) : Promise.resolve(0n),
    ]);
    $("tusd8Balance").textContent = `${fmtTusd8(tusd8)} tUSD8`;
    $("tqdayBalance").textContent = `${ethers.formatEther(tqday)} tQDAY`;
    $("allowance").textContent = ESCROW_DEPLOYED
      ? (allowance >= ethers.MaxUint256 / 2n ? "unlimited" : `${fmtTusd8(allowance)} tUSD8`)
      : "— (contract not deployed)";
  } catch (err) {
    setStatus(`Could not read balances: ${err.message}`);
  }
}

// --- Invoices ---
async function loadInvoices() {
  const list = $("invoiceList");
  if (!ESCROW_DEPLOYED) {
    list.innerHTML = "<p style='color:var(--muted)'>Escrow contract not deployed yet — invoices will appear here once ESCROW_ADDRESS is set in app.js.</p>";
    return;
  }
  list.innerHTML = "<p style='color:var(--muted)'>Loading invoices from on-chain events…</p>";
  try {
    const latest = await readProvider.getBlockNumber();
    const events = await queryFilterChunked(
      escrowRead, escrowRead.filters.InvoiceCreated(), DEPLOYMENT_BLOCK, latest);
    const ids = [...new Set(events.map((e) => Number(e.args.id)))].sort((a, b) => b - a);
    if (ids.length === 0) {
      list.innerHTML = "<p style='color:var(--muted)'>No invoices yet. Create the first one above.</p>";
      return;
    }
    const now = Math.floor(Date.now() / 1000);
    list.innerHTML = "";
    for (const id of ids) {
      const inv = await escrowRead.getInvoice(id);
      list.appendChild(renderInvoice(id, inv, now));
    }
  } catch (err) {
    list.innerHTML = `<p style='color:var(--red)'>Failed to load invoices: ${err.message}</p>`;
  }
}

function renderInvoice(id, inv, now) {
  const status = Number(inv.status);
  const statusLabel = STATUS_LABELS[status];
  const isExpired = status === 1 && now >= Number(inv.deadline);
  const isPayer = account && inv.payer.toLowerCase() === account.toLowerCase();
  const isPayee = account && inv.payee.toLowerCase() === account.toLowerCase();

  const div = document.createElement("div");
  div.className = "invoice";
  const badge = isExpired
    ? `<span class="badge Expired">Funded — expired, claimable</span>`
    : `<span class="badge ${statusLabel}">${statusLabel}</span>`;
  div.innerHTML = `
    <div class="top"><strong>Invoice #${id}</strong> ${badge}</div>
    <div class="grid">
      <div><b>Payer</b><br><span class="addr">${inv.payer}</span>${isPayer ? " (you)" : ""}</div>
      <div><b>Payee</b><br><span class="addr">${inv.payee}</span>${isPayee ? " (you)" : ""}</div>
      <div><b>Amount</b><br>${fmtTusd8(inv.amount)} tUSD8</div>
      <div><b>Deadline</b><br>${fmtDate(inv.deadline)}${isExpired ? " — passed" : ""}</div>
      <div><b>Memo</b><br>${escapeHtml(inv.memo) || "—"}</div>
    </div>
    <div class="actions"></div>`;
  const actions = div.querySelector(".actions");

  const addBtn = (label, cls, fn) => {
    const b = document.createElement("button");
    b.textContent = label; b.className = cls || "secondary";
    b.addEventListener("click", async () => {
      b.disabled = true;
      try { await fn(); await refreshBalances(); await loadInvoices(); await loadAgents(); }
      catch (err) { setStatus(`${label} failed: ${err.reason || err.message}`); }
      finally { b.disabled = false; }
    });
    actions.appendChild(b);
  };

  if (status === 0 && isPayer) addBtn("Fund invoice", "green", () => sendTx(`Fund invoice #${id}`, escrow.fundInvoice(id)));
  if (status === 1 && isPayee) addBtn("Confirm delivery (release funds)", "green", () => sendTx(`Confirm delivery #${id}`, escrow.confirmDelivery(id)));
  if (status === 1 && isPayer) addBtn("Refund (return funds to me)", "danger", () => sendTx(`Refund invoice #${id}`, escrow.refundInvoice(id)));
  if (isExpired) addBtn("Claim expired (return funds to payer)", "", () => sendTx(`Claim expired #${id}`, escrow.claimExpired(id)));
  return div;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

// --- Create invoice / approve ---
async function resolvePayee(raw) {
  const input = raw.trim();
  if (!input) throw new Error("Enter a payee address or a registered name.");
  if (ethers.isAddress(input)) return input;
  if (!ESCROW_DEPLOYED) throw new Error("Payee names need the deployed contract — enter a wallet address instead.");
  const addr = await escrowRead.resolveName(input);
  if (addr === ethers.ZeroAddress) throw new Error(`Name "${input}" is not registered.`);
  return addr;
}

async function createInvoice() {
  const payeeRaw = $("payeeInput").value;
  const amountStr = $("amountInput").value;
  const hours = Number($("deadlineInput").value);
  const memo = $("memoInput").value.trim();
  if (!amountStr || Number(amountStr) <= 0) throw new Error("Enter an amount greater than 0.");
  if (!hours || hours <= 0) throw new Error("Enter a deadline in hours greater than 0.");
  const payee = await resolvePayee(payeeRaw);
  const amount = ethers.parseUnits(amountStr, TUSD8_DECIMALS);
  const deadline = Math.floor(Date.now() / 1000) + Math.floor(hours * 3600);
  const receipt = await sendTx("Create invoice",
    escrow.createInvoice(payee, amount, deadline, memo));
  // The new id comes from the InvoiceCreated event in the receipt.
  const created = receipt.logs
    .map((l) => { try { return escrow.interface.parseLog(l); } catch { return null; } })
    .find((p) => p && p.name === "InvoiceCreated");
  if (created) setStatus(`Invoice #${Number(created.args.id)} created. Fund it (or let an authorized agent fund it) before the deadline.`);
  $("payeeInput").value = ""; $("amountInput").value = "";
  $("deadlineInput").value = ""; $("memoInput").value = "";
  await refreshBalances(); await loadInvoices();
}

async function approveToken() {
  await sendTx("Approve tUSD8 for escrow", token.approve(ESCROW_ADDRESS, ethers.MaxUint256));
  await refreshBalances();
}

// --- Agents ---
async function authorizeAgent() {
  const agentAddr = $("agentAddrInput").value.trim();
  const capStr = $("agentCapInput").value;
  if (!ethers.isAddress(agentAddr)) throw new Error("Enter a valid agent address.");
  if (!capStr || Number(capStr) < 0) throw new Error("Enter a cap of 0 or more.");
  const cap = ethers.parseUnits(capStr, TUSD8_DECIMALS);
  await sendTx(`Authorize agent ${short(agentAddr)} (cap ${capStr} tUSD8)`,
    escrow.authorizeAgent(agentAddr, cap));
  $("agentAddrInput").value = ""; $("agentCapInput").value = "";
  await loadAgents();
}

async function loadAgents() {
  const list = $("agentList");
  if (!ESCROW_DEPLOYED || !account) { list.innerHTML = "<p style='color:var(--muted)'>—</p>"; return; }
  list.innerHTML = "<p style='color:var(--muted)'>Loading…</p>";
  try {
    const latest = await readProvider.getBlockNumber();
    const events = await queryFilterChunked(
      escrowRead, escrowRead.filters.AgentAuthorized(account), DEPLOYMENT_BLOCK, latest);
    const agents = [...new Set(events.map((e) => e.args.agent))];
    if (agents.length === 0) {
      list.innerHTML = "<p style='color:var(--muted)'>No agents authorized yet.</p>";
      return;
    }
    list.innerHTML = "";
    for (const agentAddr of agents) {
      const auth = await escrowRead.agentAuths(account, agentAddr);
      const remaining = await escrowRead.agentRemaining(account, agentAddr);
      const row = document.createElement("div");
      row.className = "agent-row";
      row.innerHTML = `
        <div>
          <span class="addr">${agentAddr}</span><br>
          <span style="color:var(--muted); font-size:13px;">
            ${auth.active ? "active" : "revoked"} · cap ${fmtTusd8(auth.cap)} tUSD8 ·
            spent ${fmtTusd8(auth.spent)} tUSD8 · remaining <strong style="color:var(--text)">${fmtTusd8(remaining)} tUSD8</strong>
          </span>
        </div>`;
      if (auth.active) {
        const b = document.createElement("button");
        b.textContent = "Revoke"; b.className = "danger";
        b.addEventListener("click", async () => {
          b.disabled = true;
          try {
            await sendTx(`Revoke agent ${short(agentAddr)}`, escrow.revokeAgent(agentAddr));
            await loadAgents();
          } catch (err) { setStatus(`Revoke failed: ${err.reason || err.message}`); }
          finally { b.disabled = false; }
        });
        row.appendChild(b);
      }
      list.appendChild(row);
    }
  } catch (err) {
    list.innerHTML = `<p style='color:var(--red)'>Failed to load agents: ${err.message}</p>`;
  }
}

async function lookupRemaining() {
  const payer = $("lookupPayerInput").value.trim();
  const agentAddr = $("lookupAgentInput").value.trim();
  if (!ethers.isAddress(payer) || !ethers.isAddress(agentAddr)) {
    throw new Error("Enter valid payer and agent addresses.");
  }
  const remaining = await escrowRead.agentRemaining(payer, agentAddr);
  const auth = await escrowRead.agentAuths(payer, agentAddr);
  $("lookupResult").innerHTML =
    `Agent <span class="addr">${agentAddr}</span> for payer <span class="addr">${payer}</span>: ` +
    `${auth.active ? "active" : "not active"} — remaining cap <strong>${fmtTusd8(remaining)} tUSD8</strong> ` +
    `(cap ${fmtTusd8(auth.cap)}, spent ${fmtTusd8(auth.spent)}).`;
}

// --- Name registry ---
let lastResolved = null;

async function registerName() {
  const name = $("nameInput").value.trim();
  if (!name) throw new Error("Enter a name to register.");
  await sendTx(`Register name "${name}"`, escrow.registerName(name));
  $("nameInput").value = "";
}

async function resolveName() {
  const name = $("resolveInput").value.trim();
  if (!name) throw new Error("Enter a name to resolve.");
  const addr = await escrowRead.resolveName(name);
  lastResolved = addr === ethers.ZeroAddress ? null : addr;
  $("resolveResult").innerHTML = lastResolved
    ? `Name "<strong>${escapeHtml(name)}</strong>" → <span class="addr">${addr}</span>`
    : `Name "<strong>${escapeHtml(name)}</strong>" is not registered.`;
}

// --- Wire up ---
$("escrowAddrFooter").textContent = ESCROW_ADDRESS;

if (!ESCROW_DEPLOYED) {
  showBanner("Escrow contract not deployed yet — ESCROW_ADDRESS in app.js is still the placeholder. " +
    "Wallet connect and balances work; invoice, agent and name actions unlock once the deployed address is set.");
}

$("connectBtn").addEventListener("click", async () => {
  $("connectBtn").disabled = true;
  try { await connect(); }
  catch (err) { setStatus(`Connect failed: ${err.reason || err.message}`); }
  finally { $("connectBtn").disabled = false; }
});

$("refreshBtn").addEventListener("click", async () => { await refreshBalances(); });
$("approveBtn").addEventListener("click", async () => {
  $("approveBtn").disabled = true;
  try { await approveToken(); } catch (err) { setStatus(`Approve failed: ${err.reason || err.message}`); }
  finally { $("approveBtn").disabled = false; }
});
$("createBtn").addEventListener("click", async () => {
  $("createBtn").disabled = true;
  try { await createInvoice(); } catch (err) { setStatus(`Create invoice failed: ${err.reason || err.message}`); }
  finally { $("createBtn").disabled = false; }
});
$("reloadInvoicesBtn").addEventListener("click", async () => { await loadInvoices(); });
$("authorizeBtn").addEventListener("click", async () => {
  $("authorizeBtn").disabled = true;
  try { await authorizeAgent(); } catch (err) { setStatus(`Authorize failed: ${err.reason || err.message}`); }
  finally { $("authorizeBtn").disabled = false; }
});
$("lookupBtn").addEventListener("click", async () => {
  try { await lookupRemaining(); } catch (err) { setStatus(`Lookup failed: ${err.reason || err.message}`); }
});
$("registerNameBtn").addEventListener("click", async () => {
  $("registerNameBtn").disabled = true;
  try { await registerName(); } catch (err) { setStatus(`Register name failed: ${err.reason || err.message}`); }
  finally { $("registerNameBtn").disabled = false; }
});
$("resolveBtn").addEventListener("click", async () => {
  try { await resolveName(); } catch (err) { setStatus(`Resolve failed: ${err.reason || err.message}`); }
});
$("useAsPayeeBtn").addEventListener("click", () => {
  if (lastResolved) { $("payeeInput").value = lastResolved; setStatus(`Payee set to ${lastResolved}.`); }
  else setStatus("Resolve a name first.");
});

if (window.ethereum) {
  window.ethereum.on("accountsChanged", () => window.location.reload());
  window.ethereum.on("chainChanged", () => window.location.reload());
}
