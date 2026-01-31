# TAO Casino - Drand Integration Design Review

## Overview

This document summarizes the design for integrating drand randomness into the TAO Casino contract for anti-sniping protection.

## Architecture Diagrams

- `game-flow-sequence.puml` - Main game flow with all interactions
- `drand-failure-scenarios.puml` - Edge cases and failure handling
- `timing-diagram.puml` - Timing relationships between drand and chain

## System Components

| Component | Description | Address/Location |
|-----------|-------------|------------------|
| TAO_Casino Contract | Main betting contract | Deployed on Bittensor EVM |
| Storage Precompile | Reads Substrate storage from EVM | `0x0000000000000000000000000000000000000807` |
| Drand Pallet | Stores drand pulses on-chain | Substrate runtime |
| Offchain Worker | Fetches pulses from drand API | Runs each block |
| Drand API | External randomness beacon | `api.drand.sh` (Quicknet) |

## Timing Parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| Drand period | 3 seconds | New round every 3s |
| Bittensor block time | ~12 seconds | 4 drand rounds per block |
| Betting period | 100 blocks | ~20 minutes |
| Final call window | 25 blocks | ~5 minutes (anti-snipe window) |
| Drand buffer | 3 rounds | Commit to lastRound + 3 |
| Timeout | 7200 blocks | ~24 hours |

## Game Flow Summary

### Phase 1: Betting (100 blocks)
1. Anyone calls `startNewGame()`
2. Users place bets on Red or Blue
3. Bets in final 25 blocks may be marked "late"

### Phase 2: Commit (1 tx)
1. After block 100, anyone calls `resolveGame()` (Phase 1)
2. Contract reads `LastStoredRound` from drand pallet
3. Commits to `targetDrandRound = lastRound + 3`
4. Records `commitBlock` for timeout tracking
5. Transitions to `Calculating` phase

### Phase 3: Finalize (1+ tx)
1. Anyone calls `resolveGame()` (Phase 2)
2. Contract reads `Pulses[targetRound]` from storage
3. If not available: revert, caller retries later
4. If timeout (7200 blocks): cancel game
5. If available: use randomness to pick `actualEndBlock`
6. Mark late bets, determine winner, transition to `Resolved`

### Phase 4: Claims
- Winners claim proportional share of pool
- Late bettors get full refund
- Losers get nothing

## Identified Issues

### Issue 1: Sentinel Value Bug (bytes32(0)) - ✅ FIXED

**Original Code:**
```solidity
function _getDrandRandomness(uint64 round) internal view returns (bytes32) {
    // ... decode pulse ...
    return randomness;  // Returns bytes32(0) if not found
}

// In resolveGame:
if (randomness == bytes32(0)) {
    revert WaitingForRandomness();  // Assumes not available!
}
```

**Problem:** If the actual drand randomness happens to be all zeros, the contract incorrectly thinks the pulse is unavailable.

**Probability:** 2^-256 (astronomically unlikely, but still a bug)

**Impact:** Game would be stuck for 24 hours then cancelled unfairly.

**Fix Applied:** Returns a tuple `(bool exists, bytes32 randomness)` instead of using a sentinel value.

```solidity
// NEW CODE
function _getDrandRandomness(uint64 round) internal view returns (bool exists, bytes32 randomness) {
    // ... decode pulse ...
    return (true, rand);  // Pulse exists, randomness can be any value
}

// In resolveGame:
(bool pulseExists, bytes32 randomness) = _getDrandRandomness(game.targetDrandRound);
if (!pulseExists) {
    revert WaitingForRandomness();
}
// randomness is now valid even if it happens to be bytes32(0)
```

**Additional:** Added `RandomnessUsed` event for transparency.

### Issue 2: Blake2b-128 Implementation

**Current Code:** Computes blake2b-128 using the blake2f precompile (EIP-152) in Solidity.

**Problems:**
- Gas expensive (~100k+ gas for the precompile call)
- Complex code (error-prone)
- No native blake2-128 precompile on Bittensor EVM
- Audit cost would be high

**Potential Fixes:**
1. Accept pre-computed storage key as parameter (trust the caller)
2. Use a lookup table for common rounds
3. Request Bittensor team add blake2-128 precompile
4. Use off-chain resolver that provides the key

### Issue 3: Offchain Worker Reliability

**Scenario:** If the offchain worker is slow or stuck, pulses may not be available when expected.

**Current Handling:** 
- Contract retries until pulse available
- 24-hour timeout then cancel

**Observation:** This is acceptable design - games will eventually resolve or cancel safely.

## Recommended Changes

### Priority 1: Fix Sentinel Value Bug

```solidity
// Before
function _getDrandRandomness(uint64 round) internal view returns (bytes32)

// After  
function _getDrandRandomness(uint64 round) internal view returns (bool exists, bytes32 randomness)
```

### Priority 2: Simplify Blake2b-128

Consider one of:
1. **Trusted resolver pattern:** Resolver provides pre-computed key, contract verifies pulse round matches
2. **Store key mapping:** Off-chain service maintains round → key mapping
3. **Request precompile:** Ask Bittensor team for native blake2-128

### Priority 3: Add Events for Monitoring

- Event when phase 1 commits to drand round
- Event when phase 2 gets randomness (include the randomness value)
- Event when timeout occurs (include blocks waited)

## Test Scenarios

1. **Happy path:** Drand available within 1-2 blocks
2. **Brief delay:** Drand available after 5+ retries
3. **Extended outage:** Timeout after 7200 blocks
4. **Drand unavailable at start:** lastRound == 0
5. **Randomness is zero:** Edge case (requires mock)
6. **Multiple games:** Ensure isolation
7. **Gas limits:** Ensure blake2b-128 fits in block gas

## Open Questions

1. Should we use `lastStoredRound + buffer` or map block number to drand round?
2. What's the acceptable timeout period? (Currently 24h)
3. Should there be a minimum bet period before final call?
4. Who pays gas for resolution calls?
