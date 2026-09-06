# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Foundry project (solc 0.8.26, optimizer on, 200 runs). Submodules must be initialized: `forge install` / `git submodule update --init --recursive`.

```bash
forge build --sizes          # build (CI uses --sizes)
forge fmt                    # format; CI runs `forge fmt --check`
forge test -vvv              # full suite (unit + fuzz + invariant)
forge test --match-test test_takeOffer_settlesTradeAndFee -vvv   # single test
forge test --match-contract PeerlyEscrowInvariantTest -vvv       # invariant suite only
forge test --match-path test/PeerlyEscrow.t.sol
```

Deploy reads `OWNER`, `FEE_RECIPIENT`, `FEE_BPS` from env (see `.env.example`):

```bash
source .env && forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast
```

## Architecture

One contract: [src/PeerlyEscrow.sol](src/PeerlyEscrow.sol). P2P swap escrow — an offerer locks `tokenSell`, names a `tokenBuy` price; a taker pays the price and receives the escrowed tokens. `Ownable2Step + Pausable + ReentrancyGuard + SafeERC20`.

The design decisions that constrain any change:

- **Not upgradeable.** No proxy, no logic swap. Trade logic is frozen once deployed; a V2 is a new deployment. The owner's only powers are a fee capped at `MAX_FEE_BPS` (500), the global pause, and `depositsPaused`.
- **Two independent pause flags.** The global `Pausable` blocks `createOffer` and `takeOffer`. `depositsPaused` blocks only `createOffer`, leaving existing offers takeable so escrow drains on its own (the V2 wind-down path). `unpause()` does **not** clear `depositsPaused`.
- **`cancelOffer` is never gated by either pause.** This is the guarantee that the owner can never trap escrowed funds — do not add `whenNotPaused` to it.
- **`createOffer` records the balance delta**, not the requested `amountSell`, so a fee-on-transfer `tokenSell` cannot under-collateralize an offer and eat another offer's balance of the same token.
- **The contract never custodies `tokenBuy`.** `takeOffer` moves payment taker→offerer and taker→feeRecipient directly; the fee is deducted from the offerer's proceeds, not added on top for the taker.

## Tests

- [test/PeerlyEscrow.t.sol](test/PeerlyEscrow.t.sol) — unit + fuzz, including the pause/depositsPaused interaction matrix.
- [test/PeerlyEscrow.invariant.t.sol](test/PeerlyEscrow.invariant.t.sol) — the solvency invariant: the contract always holds enough of each token to cover every active offer. [test/handlers/EscrowHandler.sol](test/handlers/EscrowHandler.sol) drives random sequences and tracks `ghost_escrowedByToken`.
- [test/mocks/MockERC20.sol](test/mocks/MockERC20.sol) also defines `FeeOnTransferERC20` for the deflationary-token cases.

Any change touching escrow accounting or the pause flags needs its handler counterpart updated, or the invariant silently stops covering it.
