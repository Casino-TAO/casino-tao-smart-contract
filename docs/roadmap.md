## The Problem: Why Bittensor Needs This

### 1. TAO Utility Gap

Currently, TAO's primary utility is:
- Staking on validators
- Subnet registration fees, neuron reg fees
- Transfer/holding
- dTao alpha trading

**Missing:** Active, engaging use cases that drive daily transactions and user engagement.

```
Compare to other blockchain:
- Ethereum: DeFi, NFTs, Gaming = millions of daily transactions
- Solana: Same + high-frequency trading games
- ...

TAO needs MORE reasons for people to use it daily.
```

### 2. EVM Underutilization

Bittensor EVM is powerful but underutilized. The community invested in EVM compatibility - where are the applications?

### 3. User Acquisition Funnel

Most people discover crypto through:
1. Speculation/trading
2. Games/entertainment
3. DeFi yields

Bittensor has none of these consumer-facing entry points. Strategic games create an **on-ramp** for new users.

---

## Why Strategic Games (Not "Casino")

### Philosophical Alignment with Bittensor

| Bittensor Value | Strategic Games Alignment |
|-----------------|---------------------------|
| **Decentralized Intelligence** | Games test collective decision-making and emergent behavior |
| **Incentive Design** | Games ARE mechanism design - same field as subnet incentives |
| **Permissionless** | Anyone can play, no KYC, no gatekeeping |
| **Trustless** | Smart contract enforced, no house edge manipulation |
| **AI-Native** | Natural playground for AI agents (see roadmap) |

### It's Research, Not Gambling

These games are studied in:
- **Economics departments** (mechanism design, auction theory)
- **AI research** (multi-agent systems, game-playing AI)
- **Behavioral science** (decision-making under uncertainty)

The Underdog game specifically demonstrates **minority game dynamics** - a serious research topic in complex systems theory.

---

## Unique Bittensor Advantages

### 1. Native drand Integration

Bittensor has **on-chain verifiable randomness** via drand - most chains don't have this natively.

```
Our current contract already uses this:
- Commit to future drand round
- Use randomness for anti-sniping
- Provably fair, manipulation-resistant

This is a UNIQUE Bittensor capability that makes fair games possible.
```

### 2. Subnet Economics

Unlike standalone dApps, this can be a **subnet** with:
- Dedicated validators incentivized to maintain the games
- Emission rewards for miners propotional to their volume 

### 3. AI Agent Playground

Bittensor IS an AI network. Strategic games are the perfect testing ground for:
- AI decision-making agents
- Multi-agent competition
- Emergent strategies

This creates a **natural synergy**

---

## Roadmap

### Phase 1: Foundation (Current)
**"Prove the Concept"**

> See [Game Details: Underdog](./games.md#underdog-minority-wins) for full mechanics.

- [x] Core Underdog game contract
- [x] drand randomness integration
- [x] Anti-sniping mechanism
- [x] Leaderboard system
- [x] Frontend MVP deployment
- [x] Mainnet launch
- [ ] Validators

**Goal:** Demonstrate that trustless, sybil-resistant strategic games work on Bittensor EVM.

---

### Phase 2: Game Expansion
**"Build the Arena"**

Add more games that share the same sybil-resistant properties.

> See [Game Details](./games.md) for full mechanics of each game.

| Game | Description | Strategic Depth |
|------|-------------|-----------------|
| **1v1 Matched RPS Tournament** | Tournament brackets, random matching | Psychology, patterns |
| **Threshold Catastrophe** | Hidden bets, last before threshold wins all, exceed = pool rolls over | Risk calibration, crowd prediction |
| **Last Stander** | Hidden bids, highest AND lowest lose, middle survives | Distribution prediction, avoid extremes |
| **Anti-Coordination Slots** | Pick unique time slots | Spatial strategy |

**Technical Goals:**
- Modular game architecture (easy to add new games)
- Shared leaderboard across games
- Cross-game reputation system

---

### Phase 3: AI Integration
**"The Bittensor Native Feature"**

> See [Game Details: Werewolf AI Protocol](./games.md#phase-3-ai-integration---werewolf-protocol) for full mechanics.

This is where it gets **uniquely Bittensor**:

**Goal:**
Launch the **Werewolf AI Game** - a social deduction game where AI reasoning models play as Villagers and Werewolves, while humans bet on the outcomes.

**How Werewolf Works:**
- 8 AI agents (reasoning models from Bittensor subnets) are assigned secret roles: 2 Werewolves, 6 Villagers
- **Night Phase:** Werewolves secretly eliminate a villager
- **Morning Phase:** All surviving AI agents post their analysis/reasoning on-chain (who they suspect and why)
- **Betting Phase:** Humans read AI analyses and bet on "Who is the Werewolf?" using underdog mechanics
- **Voting Phase:** AI agents vote to eliminate a suspect; role is revealed
- **Repeat** until Werewolves are found or Werewolves equal Villagers

**Why Werewolf is Perfect for Bittensor:**
- Tests AI capabilities: deception (as werewolf), detection (as villager), persuasion (in voting)
- Creates real demand for reasoning model subnets
- Humans observe and bet on AI reasoning - unique entertainment value
- Sybil-resistant through underdog betting mechanics
- Generates engaging AI debate content

---

### Phase 4: Governance & Community
**"Decentralize Everything"**

- Community-proposed new games (governance vote to add)
- Configurable parameters (betting periods, fees) via governance
- Tournament organization by community
- Prize pools funded by accumulated fees

---

### Phase 5: Research Output
**"Academic Value"**

Publish findings on:
- Crowd behavior in minority games
- AI vs human strategic performance
- Mechanism design effectiveness
- Sybil resistance in practice

**Partner with:**
- Academic institutions studying game theory
- AI safety researchers (decision-making alignment)
- Behavioral economics researchers

---

## Metrics That Matter

### For Bittensor Ecosystem

| Metric | Why It Matters |
|--------|----------------|
| **Daily Active Players** | User engagement with TAO |
| **TAO Volume Through Games** | Economic activity |
| **New Wallet Addresses** | User acquisition |
| **Cross-Subnet AI Participation** | Ecosystem integration |

### For Subnet Health

| Metric | Target |
|--------|--------|
| Games per day | 50+ |
| Unique players per week | 500+ |
| Average game participation | 20+ players |
| Fee revenue (sustainability) | Self-sustaining operations |

---

## Economic Model

### Revenue Flow (No External Liquidity Needed)

```
Player Stakes
     ↓
   Game Pool
     ↓
  ┌─────────────────┐
  │ 98.5% to Winners │ ← Pure P2P redistribution
  │  1.5% Platform   │ ← Sustainability fee
  └─────────────────┘
           ↓
    Platform Fee Uses:
    - Subnet operation costs
    - Development
    - Community prizes
```

### Sustainability

- **No VC funding needed** - self-sustaining from fees
- **No token launch needed** - uses native TAO
- **No liquidity providers needed** - pure P2P

This is **economically sustainable from day 1** if there are players.

---

## Risk Mitigation

### "Isn't this just gambling?"

**Response:**
1. **No house edge** - pure P2P, contract doesn't profit from player losses
2. **Skill-based** - game theory knowledge provides edge
3. **Academic legitimacy** - these are studied in universities
4. **Transparent odds** - all pool sizes visible on-chain
5. **Self-limiting** - sybil resistance prevents whale manipulation

### "Will anyone actually use this?"

**Response:**
1. Strategic games have proven demand (poker, prediction markets)
2. Low barrier to entry (just need TAO)
3. Quick rounds (~20 minutes) fit casual play
4. Leaderboards create competitive motivation
5. AI integration creates unique Bittensor appeal

### "What about regulatory concerns?"

**Response:**
1. Skill-based games have different legal status than pure chance
2. Decentralized, permissionless - no central operator
3. No fiat on/off ramps in the protocol itself
4. Users responsible for their own jurisdiction compliance

---

## The Big Picture Vision

```
Year 1: Establish strategic games as TAO utility
         ↓
Year 2: AI agents become significant players
         ↓
Year 3: Research publications, academic recognition
         ↓
Year 4: "Bittensor: Where humans and AI compete in strategic games"
         ↓
Endgame: Premier platform for human-AI strategic interaction
```
