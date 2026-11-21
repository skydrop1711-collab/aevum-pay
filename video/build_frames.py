#!/usr/bin/env python3
"""Render Aevum Pay demo-video frames (1280x720). Slides + terminal frames.
Reuses the Cortensor render_frames.py helpers."""
import sys
sys.path.insert(0, "/home/hatch/workspace/aevum/video")
from render_frames import (slide_title, slide_bullets, slide_code,
                           term_frame, save, TEXT, MUTED, ACCENT, GREEN,
                           TERM_FG, TERM_GREEN, TERM_CYAN, TERM_YELLOW, RED)

# 01 title
save(slide_title("Aevum Pay",
                 "Escrow invoice payments\nwith agent spend caps",
                 "Aevum Builder Challenge #1  ·  Aevum testnet (chain 44005)"),
     "slide_title.png")

# 02 problem
save(slide_bullets("The problem",
    ["Paying in stablecoin today is trust-on-a-prayer: send first, hope the work arrives.",
     "Or hand funds to an AI agent — and hope it does not overspend.",
     "Aevum Pay locks tUSD8 in escrow until delivery is confirmed.",
     "An agent can pay only up to a cap the payer set — the agent never holds the payer's funds."],
    footer="tUSD8  ·  Aevum testnet, chain 44005"),
     "slide_problem.png")

# 03 contract
save(slide_code("The contract — AevumPayEscrow",
    [("Solidity ^0.8.24  ·  Foundry  ·  EVM Shanghai  ·  legacy txs", TERM_CYAN),
     ("tUSD8  0x456569838f1d43009A91ebA4263147Afd7233483  (6 decimals)", TERM_FG),
     ("", TERM_FG),
     ("createInvoice  fundInvoice  confirmDelivery", TERM_GREEN),
     ("refundInvoice  claimExpired", TERM_GREEN),
     ("authorizeAgent  revokeAgent  fundInvoiceFor", TERM_GREEN),
     ("registerName  resolveName  agentRemaining", TERM_GREEN),
     ("", TERM_FG),
     ("Fork deploy (chain 440050):", TERM_YELLOW),
     ("  escrow  0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9", TERM_FG),
     ("  tx  0x99dcdb47d16a91ad081a5ad7909cd4af6abc2dddb9", TERM_FG),
     ("      689c7346b42ec8a597ee8e", TERM_FG)],
    footer="nonReentrant + SafeERC20  ·  caps are cumulative, revocation is instant",
    font_size=22, line_h=34),
     "slide_contract.png")

# 04 tests
save(slide_bullets("Tested, not just written",
    ["Unit tests:  41 passed / 0 failed  (mock tUSD8)",
     "Fork tests:  6 passed / 0 failed  (real tUSD8, anvil fork)",
     "Fork end-to-end, verified on chain:",
     "#0 Released   ·   #1 Released (agent-funded)",
     "#2 Refunded   ·   #3 Expired",
     "Escrow balance 0 after all flows — every path works."],
    footer="forge test  ·  anvil fork of Aevum, chain 440050, --hardfork shanghai"),
     "slide_tests.png")

# 05 agent terminal (verbatim real output)
save(term_frame([
    ("$ node agent.mjs 4 --payer 0x70997970C51812dc3A010C7d01b50e0d17dc79C8", TERM_CYAN),
    ("", TERM_FG),
    ("Agent:   0x637d5EE87111b106D04a79A99D4A4728Fb2B5ca0", TERM_FG),
    ("Invoice: #4 -- 10.0 tUSD8, status Created, memo \"agent demo invoice\"", TERM_FG),
    ("Cap: 50.0 tUSD8, spent: 0.0, remaining: 50.0", TERM_FG),
    ("", TERM_FG),
    ("Tx sent: 0x5e0dfeeeb78ce3f609d0ae52d6801189d56b9887de9081386962c58580919c5e", TERM_YELLOW),
    ("", TERM_FG),
    ("Invoice #4 FUNDED -- 10.0 tUSD8 now held in escrow.", TERM_GREEN),
]), "term_agent.png")

# 06 agent after (on-chain check)
save(term_frame([
    ("$ cast call $ESCROW \"getInvoice(uint256)\" 4  # on-chain after", TERM_CYAN),
    ("", TERM_FG),
    ("Invoice #4 status: Funded", TERM_GREEN),
    ("Escrow balance:  10 tUSD8", TERM_FG),
    ("Agent remaining cap:  40.0 tUSD8  (was 50.0)", TERM_FG),
    ("", TERM_FG),
    ("Funds moved payer -> escrow.", TERM_FG),
    ("Never through the agent's wallet.", TERM_GREEN),
]), "term_after.png")

# 07 frontend
save(slide_bullets("The frontend — static page, no build step",
    ["ethers.js v6 + MetaMask on Aevum testnet (chain 44005)",
     "Create / fund / confirm / refund / claim-expired",
     "Agents & spend caps: authorize, revoke, remaining cap",
     "Name registry: pay \"alice\" instead of pasting 0x...",
     "No private keys in the page — all signing in MetaMask"],
    footer="web/  ·  index.html + app.js  ·  described, not screenshotted"),
     "slide_frontend.png")

# 08 blocker — honest
save(slide_bullets("Honest blocker: the faucet",
    ["Deployer 0xFD79641A2016a66689ca68406be7be98918A74f3",
     "holds 0 tQDAY — the web faucet needs a browser wallet,",
     "a bot check, AND a mainnet balance the fresh wallet",
     "does not have (~0.0001 ETH / 1 USDT / 1 USDC).",
     "Everything else is done and tested on the fork.",
     "The testnet deploy is one funded wallet away."],
    footer="faucet.qday.info  ·  alt: Discord /faucet (Verified role)"),
     "slide_blocker.png")

# 09 wrap
save(slide_title("Aevum Pay",
                 "Escrow invoices. Capped agents.\nTested end to end.",
                 "Code and docs ready to push  ·  Deadline 11 Dec 2026, 15:00 WIB"),
     "slide_wrap.png")

print("frames rendered")
