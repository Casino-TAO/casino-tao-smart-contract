# Summary of reported issues: 

---

## Solvency issue (Richie Rich): https://discord.com/channels/799672011265015819/1460274530764456078/1463159577339101315 ##

**Here's how the new contract (v2) fixes this:**

### Old (Vulnerable):
```solidity
// Fees went to global pool immediately
accumulatedFees += feeAmount;  // Could be withdrawn anytime
```

### New (Fixed):
```solidity
// Fees are now locked per-game until resolution
gameFees[_gameId] += feeAmount;  // Can't be withdrawn until game ends

// Only moved to withdrawable pool AFTER game resolves with a winner
accumulatedFees += gameFees[_gameId];  // Line 489
```

### On cancellation:
```solidity
// ALL fees returned to game balance for full refunds
gameBalance[_gameId] += gameFees[_gameId] + gameReferralRewards[_gameId];
```

**The owner literally cannot withdraw fees from active games anymore.** Fees are locked per-game and only become withdrawable after the game resolves successfully.

**Verified contract:** https://evm.taostats.io/address/0x8cfb178af3ADfd120747FA04F978F18133DAcDb5#code

Check lines 412-414 (fee tracking), 486-489 (fee release on resolution), and 597-604 (full refund on cancel).

---

## `withdrawFees` opportunity to rug liquidity (distributed_tensor): https://discord.com/channels/799672011265015819/1460274530764456078/1463174029127979120 ##

This is the same concern of the below one, explained there

---

## `accumulatedFees` tracking manipulation (distributed_tensor), and other issues: https://discord.com/channels/799672011265015819/1460274530764456078/1463174572974014475 ##

Here's a comprehensive response to this full audit report:

---


### 1. "Owner Can Drain All Funds via withdrawFees()"
**Status: ❌ CLAIM WAS INCORRECT + ✅ FURTHER HARDENED**

The original claim was wrong - owner could only withdraw `accumulatedFees`, not "all funds." However, we've further hardened it:

```solidity
// NEW: Fees only accumulate from RESOLVED games
gameFees[_gameId] += feeAmount;  // Locked per-game
accumulatedFees += releasedFees;  // Only on resolution (line 489)
```

Owner cannot withdraw fees from active games.

---

### 2. "receive() Inflates accumulatedFees"
**Status: ❌ INCORRECT**

`receive()` does NOT touch `accumulatedFees`. The auditor misread the code. `accumulatedFees` is only modified in `placeBet()` and `resolveGame()`.

---

### 3. "Anyone Can Call startNewGame() - DoS"
**Status: ⚠️ BY DESIGN (with safeguards)**

- Only ONE game can be active at a time
- Previous game must complete first
- This is decentralized design, not a bug
- Added circuit breaker: `if (paused) revert ContractPaused();`

---

### 4. "Anyone Can Call resolveGame() - Race Condition"
**Status: ❌ ATTACK NOT POSSIBLE**

The "bet and resolve in same block" attack is impossible:
```solidity
// Betting: if (block.timestamp >= game.endTime) revert BettingPeriodEnded();
// Resolution: if (block.timestamp < game.endTime) revert BettingPeriodNotEnded();
```
**Mutually exclusive time checks.**


### 5. "claimAllWinnings() Reentrancy"
**Status: ✅ FIXED**
```solidity
function claimAllWinnings(uint256 _gameId) external nonReentrant {
    _claimWinnings(_gameId, Side.Red);   // Internal call
    _claimWinnings(_gameId, Side.Blue);  // Internal call
}
```

---

### 6. "Precision Loss in Payout"
**Status: ✅ MITIGATED**
```solidity
uint256 public minBetAmount = 0.001 ether;  // Minimum bet added
if (msg.value < minBetAmount) revert BetTooSmall();
```

---

### 7. "No Timelock on Admin Functions"
**Status: ⚠️ PARTIALLY ADDRESSED**

- Emergency cancel now requires 0 bets
- Parameters bounded (can't set impossible values)
- Fee withdrawal only from resolved games
- Timelock not implemented (would add complexity)

---

### 8. "emergencyCancelGame Doesn't Refund Referrals"
**Status: ✅ FIXED**
```solidity
// Referrals now locked per-game
gamePendingReferralRewards[_gameId][referrer] += referralReward;

// On cancel: not transferred to claimable pool
// Referrers earn nothing from cancelled games
```

---

### 9. "Unbounded Loop in _updateLeaderboard()"
**Status: ✅ ACCEPTABLE**

- Capped at 100 iterations (MAX_LEADERBOARD_SIZE)
- ~500k gas worst case, within limits
- Not a blocking issue

---

### 10. "Front-Running in Classic Mode"
**Status: ✅ N/A - CLASSIC MODE REMOVED**

Contract is now **Underdog-only**. Front-running is self-defeating in Underdog mode.

---

### 11. "Tie Handling Favors Red"
**Status: ✅ FIXED**
```solidity
if (game.redPool == game.bluePool) {
    emit GameTied(_gameId, game.redPool, game.bluePool);
    _cancelGame(_gameId, "Exact tie - refunding all bets");
    return;
}
```

---

### 12. "Referral Code Brute-Force"
**Status: ⚠️ LOW PRIORITY**

Code squatting is annoying but not a security issue. Referrers who squat common codes just earn rewards if people use them.

---

### 13. "Missing Zero-Address Checks"
**Status: ⚠️ MINOR**

OpenZeppelin's Ownable handles owner checks. Bettor can't be address(0) (who sends the tx?).

---

### 14. "totalLiquidity Accounting Bug"
**Status: ❌ NOT A BUG**

`totalLiquidity` = net amounts (for payout calculation)
`redPool/bluePool` = gross amounts (for winner determination)

This is intentional, not an error.

---

### 15-19: Minor Issues
| Issue | Status |
|-------|--------|
| Double-counting referrals | ⚠️ Cosmetic only |
| No max bet limit | ⚠️ Underdog mode self-limits |
| gameBettors array bloat | ⚠️ Minor storage cost |
| Missing param change events | ⚠️ Could add |
| TOKEN_DECIMALS unused | ⚠️ Cosmetic |

---

### 20. "Owner Can Create Asymmetric Conditions"
**Status: ✅ BOUNDED**
```solidity
require(_minPool <= 100 ether, "Min pool cannot exceed 100 TAO");
require(_minBets <= 100, "Min bets cannot exceed 100");
```

### 21. "No Minimum Bet"
**Status: ✅ FIXED**
```solidity
uint256 public minBetAmount = 0.001 ether;
```

### 22. "_cancelGame Math Leaves Funds Stuck"
**Status: ✅ FIXED**
```solidity
// Exact tracking, no reverse-engineering
gameBalance[_gameId] += gameFees[_gameId] + gameReferralRewards[_gameId];
```

---

## Repo issues (formalized tensor) - README for subnet repo should be more clear.  EVM side of subnet is a separate repo (https://discord.com/channels/799672011265015819/1460274530764456078/1463182763350822983); recommend cross-linking the repos in their READMEs and ensuring both repos are pinned. ##

This is not a bug

---

## UX/MEV opportunity/refund issues (yubo): https://discord.com/channels/799672011265015819/1460274530764456078/1463201567821008937 ##

Explained at the bottom

---

## code is almost identical to code already published by scam group (vune): https://discord.com/channels/799672011265015819/1460274530764456078/1463216623195263067 and https://discord.com/channels/799672011265015819/1460274530764456078/1463216728350789838 ##

This is not what I can control. Our subnet is operating without liquidity thing, so the smart contract can't be the same as Tenex's. Also I used some subnet repos as references when I write our subnet repo.

---

## You Wish Analysis: https://discord.com/channels/799672011265015819/1460274530764456078/1463226610114363604 and https://discord.com/channels/799672011265015819/1460274530764456078/1463227126407893228 ##

Explained here: https://github.com/Casino-TAO/casino-tao-smart-contract/blob/main/community%20concerns.md

---

## Yubo's vulnerability list: https://discord.com/channels/799672011265015819/1460274530764456078/1463236453185224921 ##

Explained here: https://github.com/Casino-TAO/casino-tao-smart-contract/blob/main/community%20concerns.md