# TAO Casino v2.0 - Changelog

## 🎯 Core Simplifications

### Removed Systems
| Feature | Why Removed |
|---------|-------------|
| **Referral System** | Attack surface for fee manipulation; added complexity |
| **Underdog Bonus** | Variable fees complicated refund accounting |
| **Regular Game Speed** | Simplified to single game type |
| **All Setter Functions** | Eliminated owner manipulation vectors |
| **Timelock System** | No longer needed with immutable constants |
| **Emergency Cancel** | Removed owner's ability to cancel active games |

### New Immutable Architecture
All parameters are now **constants** - cannot be changed after deployment:

| Constant | Value | Description |
|----------|-------|-------------|
| `PLATFORM_FEE` | 150 (1.5%) | Flat fee on all bets |
| `MIN_BET_AMOUNT` | 0.001 TAO | Minimum bet size |
| `MIN_TOTAL_BETS` | 2 | Minimum bettors to resolve |
| `MIN_POOL_SIZE` | 0.5 TAO | Minimum total pool |
| `BETTING_BLOCKS` | 100 | ~20 minute games |
| `FINAL_CALL_BLOCKS` | 25 | ~5 minute anti-snipe window |
| `RANDOMNESS_DELAY_BLOCKS` | 5 | Blocks before hash reveal |
| `MAX_BETTORS_PER_GAME` | 500 | Prevents gas DoS |
| `MAX_LEADERBOARD_SIZE` | 100 | Leaderboard cap |

---

## 🛡️ Security Fixes

### Solvency Protection
- **Per-game fee tracking** (`gameFees[gameId]`) - fees only released after resolution
- **`gameBalance` properly decremented** after payouts
- **`gameFees` zeroed** after release to `accumulatedFees`
- Full refunds on cancellation (fees returned to pool)

### Anti-Sniping (Future Block Hash Randomness)
- **Two-phase resolution**:
  1. Phase 1: Commit to `randomnessBlock = block.number + 5`
  2. Phase 2: Use `blockhash(randomnessBlock)` to determine `actualEndBlock`
- **Combined blockhash entropy**: Uses 3 consecutive block hashes for stronger randomness
- **Late bets automatically refunded**: Bets placed at/after `actualEndBlock` get full refund
- Validators would need to control 3 consecutive blocks to manipulate

### Gas DoS Prevention
- `MAX_BETTORS_PER_GAME = 500` limit
- Prevents `_calculateValidPools` from exceeding block gas limit

### Block-Based Timing
- All durations use `block.number` instead of `block.timestamp`
- Handles chain halting gracefully
- Removes validator timestamp manipulation

### Minimum Participation
- Requires `validRedPool > 0 && validBluePool > 0`
- Both sides must have bets for game to resolve

### Removed Attack Vectors
- ❌ No `receive()` function (prevents untracked TAO)
- ❌ No emergency cancel (owner can't cancel active games)
- ❌ No parameter changes (all immutable)
- ❌ No referral clawback issues

---

## 📜 Owner Powers (Minimal)

The owner can **ONLY**:
1. `withdrawFees()` - Withdraw accumulated platform fees (from resolved games only)
2. `setPaused(bool)` - Pause/unpause new game creation (active games unaffected)

**Owner CANNOT**:
- Cancel active games
- Change fees or parameters
- Affect user funds in any way
- Manipulate game outcomes

---

## 🎮 Simplified Game Flow

### Starting a Game
```solidity
// Old (removed)
startNewGame(GameSpeed.Rapid);

// New (no parameters)
startNewGame();
```

### Placing Bets
```solidity
// Same as before
placeBet(gameId, Side.Red);  // Bet on Red
placeBet(gameId, Side.Blue); // Bet on Blue (can bet both sides!)
```

### Resolution (Two-Phase)
```solidity
// Phase 1: After betting ends
resolveGame(gameId);  // Commits to randomness block

// Phase 2: After 5+ blocks
resolveGame(gameId);  // Finalizes with random end block
```

---

## 📊 New View Functions

| Function | Returns |
|----------|---------|
| `getResolutionStatus(gameId)` | phase, randomnessBlock, actualEndBlock, canFinalize |
| `isBetLate(gameId, user, side)` | Whether bet was marked late (refund only) |
| `getBlocksRemaining(gameId)` | Blocks until betting ends |
| `isInFinalCall(gameId)` | Whether in final 25-block window |

---

## 🔄 Events Updated

| Event | Change |
|-------|--------|
| `GameCreated` | Removed `GameSpeed` parameter |
| `GameResolved` | Removed `GameSpeed`, uses `validRedPool`/`validBluePool` |
| `RandomnessCommitted` | **NEW** - Emitted in phase 1 |
| `ActualEndBlockSet` | **NEW** - Emitted in phase 2 with valid pools |
| `LateBetRefunded` | **NEW** - Emitted when late bet is refunded |

---

## 📍 Contract Address

**New Deployment:** `0x1e0bA1BcF31feFf1a9dc16FE3E0A203E3439DB47`

🔗 [View on Taostats](https://evm.taostats.io/address/0x1e0bA1BcF31feFf1a9dc16FE3E0A203E3439DB47#code)