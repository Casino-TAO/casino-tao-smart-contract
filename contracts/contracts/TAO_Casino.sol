// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TAOCasino
 * @notice P2P Underdog betting game on Bittensor EVM - the minority side wins!
 * @dev Simplified trustless design:
 *   - All parameters are IMMUTABLE constants
 *   - Owner can ONLY: withdraw earned fees, pause new games
 *   - No admin function can affect active games or user funds
 *   - Dual-position betting (bet on BOTH Red AND Blue)
 *   - Leaderboard tracking for top winners
 *   - Native TAO betting
 *   - All games are 100 blocks (~20 minutes)
 */
contract TAOCasino is ReentrancyGuard, Ownable {

    // ==================== ENUMS ====================
    
    enum Side {
        Red,
        Blue
    }
    
    enum GamePhase {
        NotStarted,
        Betting,
        Calculating,
        Resolved,
        Finalized
    }

    // ==================== STRUCTS ====================
    
    struct Game {
        uint256 id;
        GamePhase phase;
        uint256 redPool;
        uint256 bluePool;
        uint256 redBettors;
        uint256 blueBettors;
        uint256 startBlock;
        uint256 endBlock;
        uint256 resolvedBlock;
        Side winningSide;
        uint256 totalLiquidity;
        bool hasWinner;
        // Anti-sniping: random end block within final call window (drand-based)
        uint64 targetDrandRound;    // Drand round committed to for randomness
        uint256 commitBlock;        // Block when we committed to drand round (for timeout)
        uint256 actualEndBlock;     // Randomly selected end (only valid bets before this count)
        uint256 validRedPool;       // Pool from valid bets only
        uint256 validBluePool;      // Pool from valid bets only
        uint256 validLiquidity;     // Liquidity from valid bets only
    }
    
    struct SideBet {
        uint256 amount;
        uint256 placedAtBlock;  // Track when bet was placed for anti-sniping
        bool claimed;
        bool isLateBet;         // True if placed after actualEndBlock (refund only)
    }
    
    struct UserBets {
        SideBet redBet;
        SideBet blueBet;
    }
    
    struct UserStats {
        uint256 totalBets;
        uint256 totalWins;
        uint256 totalWinnings;
        uint256 totalLosses;
    }

    // ==================== CUSTOM ERRORS ====================
    
    error GameNotFound();
    error GameNotInBettingPhase();
    error GameAlreadyResolved();
    error GameNotResolved();
    error BettingPeriodEnded();
    error BettingPeriodNotEnded();
    error InvalidBetAmount();
    error NoBetToClaim();
    error AlreadyClaimed();
    error TransferFailed();
    error NoActiveGame();
    error GameStillActive();
    error BetTooSmall();
    error ContractPaused();
    error WaitingForRandomness();
    error LateBetRefundOnly();
    error TooManyBettors();
    error DrandPulseNotAvailable();
    error DrandPrecompileCallFailed();

    // ==================== IMMUTABLE CONSTANTS ====================
    
    uint256 public constant PLATFORM_FEE = 150;              // 1.5% fee
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant MIN_BET_AMOUNT = 0.001 ether;    // 0.001 TAO minimum
    uint256 public constant MIN_TOTAL_BETS = 2;              // 2 bettors minimum
    uint256 public constant MIN_POOL_SIZE = 0.5 ether;       // 0.5 TAO minimum
    
    // Block-based durations (~12s/block on Bittensor EVM)
    // Using blocks instead of timestamps handles chain halting gracefully
    uint256 public constant BETTING_BLOCKS = 100;            // ~20 minutes
    uint256 public constant FINAL_CALL_BLOCKS = 25;          // ~5 minutes (last 25 blocks)
    uint256 public constant MAX_BETTORS_PER_GAME = 500;      // Prevent gas DoS in _calculateValidPools
    uint256 public constant MAX_LEADERBOARD_SIZE = 100;
    
    // ==================== DRAND RANDOMNESS CONSTANTS ====================
    
    // Substrate storage precompile for reading runtime storage
    address public constant STORAGE_PRECOMPILE = 0x0000000000000000000000000000000000000807;
    
    // Drand pallet storage key prefixes (from substrate metadata)
    // drand.pulses prefix (StorageMap with Blake2_128Concat hasher)
    bytes public constant DRAND_PULSES_PREFIX = hex"a285cdb66e8b8524ea70b1693c7b1e050d8e70fd32bfb1639703f9a23d15b15e";
    // drand.lastStoredRound key (StorageValue)
    bytes32 public constant DRAND_LAST_ROUND_KEY = 0xa285cdb66e8b8524ea70b1693c7b1e05087f3dd6e0ceded0e388dd34f810a73d;
    
    // Drand configuration
    uint256 public constant DRAND_ROUND_BUFFER = 3;          // Commit to lastStoredRound + 3 for unpredictability
    uint256 public constant DRAND_TIMEOUT_BLOCKS = 7200;     // ~24 hours timeout if pulse unavailable

    // ==================== STATE VARIABLES ====================
    
    uint256 public nextGameId = 1;
    uint256 public currentGameId = 0;
    uint256 public accumulatedFees;
    bool public paused = false;
    
    // Mappings
    mapping(uint256 => Game) public games;
    mapping(uint256 => mapping(address => mapping(Side => SideBet))) public sideBets;
    mapping(uint256 => address[]) public gameBettors;
    mapping(uint256 => uint256) public gameBalance;
    mapping(uint256 => uint256) public gameFees;
    mapping(uint256 => mapping(address => bool)) public hasAnyBet;
    mapping(address => UserStats) public userStats;
    
    // Leaderboard
    address[] public leaderboard;

    // ==================== EVENTS ====================
    
    event GameCreated(
        uint256 indexed gameId,
        uint256 startBlock,
        uint256 endBlock
    );
    
    event BetPlaced(
        uint256 indexed gameId,
        address indexed bettor,
        Side side,
        uint256 amount,
        uint256 newPoolTotal
    );
    
    event GameResolved(
        uint256 indexed gameId,
        Side winningSide,
        uint256 redPool,
        uint256 bluePool,
        uint256 redBettors,
        uint256 blueBettors
    );
    
    event WinningsClaimed(
        uint256 indexed gameId,
        address indexed bettor,
        Side side,
        uint256 betAmount,
        uint256 winnings
    );
    
    event GameCancelled(uint256 indexed gameId, string reason);
    event RefundClaimed(uint256 indexed gameId, address indexed bettor, Side side, uint256 amount);
    event FeesReleased(uint256 indexed gameId, uint256 platformFees);
    event GameTied(uint256 indexed gameId, uint256 redPool, uint256 bluePool);
    event ContractPausedEvent(bool isPaused);
    event DrandRoundCommitted(uint256 indexed gameId, uint64 targetDrandRound, uint256 commitBlock);
    event ActualEndBlockSet(uint256 indexed gameId, uint256 actualEndBlock, uint256 validRedPool, uint256 validBluePool);
    event LateBetRefunded(uint256 indexed gameId, address indexed bettor, Side side, uint256 amount);
    event DrandTimeoutCancelled(uint256 indexed gameId, uint64 targetDrandRound, uint256 blocksWaited);

    // ==================== CONSTRUCTOR ====================
    
    constructor() {}

    // ==================== MAIN FUNCTIONS ====================
    
    /**
     * @notice Start a new game (anyone can call)
     * @dev All games are 100 blocks (~20 minutes)
     */
    function startNewGame() external {
        if (paused) revert ContractPaused();
        
        if (currentGameId > 0) {
            Game storage prevGame = games[currentGameId];
            if (prevGame.phase == GamePhase.Betting) revert GameStillActive();
            if (prevGame.phase == GamePhase.Calculating) revert GameStillActive();
        }
        
        uint256 gameId = nextGameId++;
        uint256 startBlock = block.number;
        uint256 endBlock = startBlock + BETTING_BLOCKS;
        
        games[gameId] = Game({
            id: gameId,
            phase: GamePhase.Betting,
            redPool: 0,
            bluePool: 0,
            redBettors: 0,
            blueBettors: 0,
            startBlock: startBlock,
            endBlock: endBlock,
            resolvedBlock: 0,
            winningSide: Side.Red,
            totalLiquidity: 0,
            hasWinner: false,
            targetDrandRound: 0,
            commitBlock: 0,
            actualEndBlock: 0,
            validRedPool: 0,
            validBluePool: 0,
            validLiquidity: 0
        });
        
        currentGameId = gameId;
        
        emit GameCreated(gameId, startBlock, endBlock);
    }
    
    /**
     * @notice Place a bet on a side (can bet on BOTH sides)
     * @param _gameId Game to bet on
     * @param _side Red or Blue
     */
    function placeBet(uint256 _gameId, Side _side) external payable nonReentrant {
        if (_gameId == 0 || _gameId >= nextGameId) revert GameNotFound();
        if (msg.value == 0) revert InvalidBetAmount();
        if (msg.value < MIN_BET_AMOUNT) revert BetTooSmall();
        
        Game storage game = games[_gameId];
        
        if (game.phase != GamePhase.Betting) revert GameNotInBettingPhase();
        if (block.number >= game.endBlock) revert BettingPeriodEnded();
        
        SideBet storage existingBet = sideBets[_gameId][msg.sender][_side];
        
        // Calculate flat 1.5% fee
        uint256 feeAmount = (msg.value * PLATFORM_FEE) / FEE_DENOMINATOR;
        uint256 netAmount = msg.value - feeAmount;
        
        // Track fees per game (released only on resolution)
        gameFees[_gameId] += feeAmount;
        gameBalance[_gameId] += netAmount;
        
        // Check if new bettor on this side
        bool isNewBettorOnSide = existingBet.amount == 0;
        
        // Update bet
        existingBet.amount += msg.value;
        existingBet.placedAtBlock = block.number;  // Track when bet was placed
        existingBet.claimed = false;
        existingBet.isLateBet = false;  // Will be determined at resolution
        
        // Update pools
        if (_side == Side.Red) {
            game.redPool += msg.value;
            if (isNewBettorOnSide) game.redBettors++;
        } else {
            game.bluePool += msg.value;
            if (isNewBettorOnSide) game.blueBettors++;
        }
        
        game.totalLiquidity += netAmount;
        
        // Track bettor (only add once)
        if (!hasAnyBet[_gameId][msg.sender]) {
            // Prevent gas DoS - limit bettors per game
            if (gameBettors[_gameId].length >= MAX_BETTORS_PER_GAME) revert TooManyBettors();
            
            hasAnyBet[_gameId][msg.sender] = true;
            gameBettors[_gameId].push(msg.sender);
        }
        
        userStats[msg.sender].totalBets++;
        
        uint256 newPoolTotal = _side == Side.Red ? game.redPool : game.bluePool;
        emit BetPlaced(_gameId, msg.sender, _side, msg.value, newPoolTotal);
    }
    
    /**
     * @notice Resolve a game after betting ends (two-phase for anti-sniping)
     * @dev Phase 1: Commit to future drand round for randomness
     *      Phase 2: Use drand pulse to determine actual end, filter late bets
     *      Timeout: Cancel if drand pulse not available after DRAND_TIMEOUT_BLOCKS
     * @param _gameId Game to resolve
     */
    function resolveGame(uint256 _gameId) external {
        if (_gameId == 0 || _gameId >= nextGameId) revert GameNotFound();
        
        Game storage game = games[_gameId];
        
        // PHASE 1: Commit to drand round
        if (game.phase == GamePhase.Betting) {
            if (block.number < game.endBlock) revert BettingPeriodNotEnded();
            
            // Get current last stored drand round and commit to a future round
            uint64 lastRound = _getLastStoredRound();
            if (lastRound == 0) {
                // Drand not available at all - use fallback or revert
                // For safety, we'll cancel the game
                _cancelGame(_gameId, "Drand not available");
                return;
            }
            
            // Commit to lastStoredRound + buffer for unpredictable randomness
            game.targetDrandRound = lastRound + uint64(DRAND_ROUND_BUFFER);
            game.commitBlock = block.number;
            game.phase = GamePhase.Calculating;
            
            emit DrandRoundCommitted(_gameId, game.targetDrandRound, game.commitBlock);
            return;
        }
        
        // PHASE 2: Finalize with drand randomness
        if (game.phase == GamePhase.Calculating) {
            // Check for timeout first
            if (block.number > game.commitBlock + DRAND_TIMEOUT_BLOCKS) {
                emit DrandTimeoutCancelled(_gameId, game.targetDrandRound, block.number - game.commitBlock);
                _cancelGame(_gameId, "Drand pulse timeout - randomness not available");
                return;
            }
            
            // Try to get randomness from committed drand round
            bytes32 randomness = _getDrandRandomness(game.targetDrandRound);
            
            // If randomness not yet available, caller must wait and try again
            if (randomness == bytes32(0)) {
                revert WaitingForRandomness();
            }
            
            uint256 finalCallStart = game.endBlock - FINAL_CALL_BLOCKS;
            
            // Use drand randomness to pick actual end block within final call window
            uint256 randomOffset = uint256(randomness) % FINAL_CALL_BLOCKS;
            game.actualEndBlock = finalCallStart + randomOffset;
            
            // Calculate valid pools (excluding late bets)
            _calculateValidPools(_gameId);
            
            emit ActualEndBlockSet(_gameId, game.actualEndBlock, game.validRedPool, game.validBluePool);
            
            // Check minimum participation with VALID pools
            uint256 totalValidPool = game.validRedPool + game.validBluePool;
            
            if (totalValidPool < MIN_POOL_SIZE || game.validRedPool == 0 || game.validBluePool == 0) {
                _cancelGame(_gameId, "Insufficient valid participation after anti-snipe filter");
                return;
            }
            
            // Check for exact tie in valid pools
            if (game.validRedPool == game.validBluePool) {
                emit GameTied(_gameId, game.validRedPool, game.validBluePool);
                _cancelGame(_gameId, "Exact tie - refunding all bets");
                return;
            }
            
            // Underdog wins (minority side based on VALID pools)
            Side winner = game.validRedPool < game.validBluePool ? Side.Red : Side.Blue;
            
            game.winningSide = winner;
            game.hasWinner = true;
            game.phase = GamePhase.Resolved;
            game.resolvedBlock = block.number;
            
            // Release fees (only from valid bets) to accumulatedFees
            // Late bets get full refund including fees
            uint256 releasedFees = gameFees[_gameId];
            accumulatedFees += releasedFees;
            gameFees[_gameId] = 0;
            
            emit FeesReleased(_gameId, releasedFees);
            
            emit GameResolved(
                _gameId,
                winner,
                game.validRedPool,
                game.validBluePool,
                game.redBettors,
                game.blueBettors
            );
            return;
        }
        
        revert GameAlreadyResolved();
    }
    
    /**
     * @notice Calculate valid pools by filtering out late bets
     * @dev Iterates through all bettors to sum valid bets and mark late bets
     */
    function _calculateValidPools(uint256 _gameId) internal {
        Game storage game = games[_gameId];
        address[] storage bettors = gameBettors[_gameId];
        
        uint256 validRedPool = 0;
        uint256 validBluePool = 0;
        uint256 validLiquidity = 0;
        uint256 lateFees = 0;
        
        for (uint256 i = 0; i < bettors.length; i++) {
            address bettor = bettors[i];
            
            // Check Red bet
            SideBet storage redBet = sideBets[_gameId][bettor][Side.Red];
            if (redBet.amount > 0) {
                if (redBet.placedAtBlock < game.actualEndBlock) {
                    // Valid bet - count towards pool
                    validRedPool += redBet.amount;
                    uint256 fee = (redBet.amount * PLATFORM_FEE) / FEE_DENOMINATOR;
                    validLiquidity += redBet.amount - fee;
                } else {
                    // Late bet - mark for refund
                    redBet.isLateBet = true;
                    uint256 fee = (redBet.amount * PLATFORM_FEE) / FEE_DENOMINATOR;
                    lateFees += fee;
                }
            }
            
            // Check Blue bet
            SideBet storage blueBet = sideBets[_gameId][bettor][Side.Blue];
            if (blueBet.amount > 0) {
                if (blueBet.placedAtBlock < game.actualEndBlock) {
                    // Valid bet - count towards pool
                    validBluePool += blueBet.amount;
                    uint256 fee = (blueBet.amount * PLATFORM_FEE) / FEE_DENOMINATOR;
                    validLiquidity += blueBet.amount - fee;
                } else {
                    // Late bet - mark for refund
                    blueBet.isLateBet = true;
                    uint256 fee = (blueBet.amount * PLATFORM_FEE) / FEE_DENOMINATOR;
                    lateFees += fee;
                }
            }
        }
        
        game.validRedPool = validRedPool;
        game.validBluePool = validBluePool;
        game.validLiquidity = validLiquidity;
        
        // Return late fees to gameBalance for refunds
        if (lateFees > 0) {
            gameFees[_gameId] -= lateFees;
            gameBalance[_gameId] += lateFees;
        }
    }
    
    /**
     * @notice Claim winnings from a resolved game
     * @param _gameId Game ID
     * @param _side Side to claim from
     */
    function claimWinnings(uint256 _gameId, Side _side) external nonReentrant {
        _claimWinnings(_gameId, _side);
    }
    
    /**
     * @notice Claim both sides at once
     */
    function claimAllWinnings(uint256 _gameId) external nonReentrant {
        SideBet storage redBet = sideBets[_gameId][msg.sender][Side.Red];
        SideBet storage blueBet = sideBets[_gameId][msg.sender][Side.Blue];
        
        if (redBet.amount > 0 && !redBet.claimed) {
            _claimWinnings(_gameId, Side.Red);
        }
        if (blueBet.amount > 0 && !blueBet.claimed) {
            _claimWinnings(_gameId, Side.Blue);
        }
    }
    
    // ==================== INTERNAL FUNCTIONS ====================
    
    function _claimWinnings(uint256 _gameId, Side _side) internal {
        if (_gameId == 0 || _gameId >= nextGameId) revert GameNotFound();
        
        Game storage game = games[_gameId];
        SideBet storage bet = sideBets[_gameId][msg.sender][_side];
        
        if (bet.amount == 0) revert NoBetToClaim();
        if (bet.claimed) revert AlreadyClaimed();
        
        uint256 payout = 0;
        
        // Handle cancelled games - full refund (all bets)
        if (!game.hasWinner && game.phase == GamePhase.Finalized) {
            payout = bet.amount;
            bet.claimed = true;
            
            gameBalance[_gameId] -= payout;
            
            (bool success, ) = payable(msg.sender).call{value: payout}("");
            if (!success) revert TransferFailed();
            
            emit RefundClaimed(_gameId, msg.sender, _side, payout);
            return;
        }
        
        if (game.phase != GamePhase.Resolved && game.phase != GamePhase.Finalized) {
            revert GameNotResolved();
        }
        
        // Handle LATE BETS - full refund (anti-sniping protection)
        if (bet.isLateBet) {
            payout = bet.amount;  // Full refund including fee portion
            bet.claimed = true;
            
            gameBalance[_gameId] -= payout;
            
            (bool success, ) = payable(msg.sender).call{value: payout}("");
            if (!success) revert TransferFailed();
            
            emit LateBetRefunded(_gameId, msg.sender, _side, payout);
            return;
        }
        
        // Valid bet on losing side gets nothing
        if (_side != game.winningSide) {
            bet.claimed = true;
            userStats[msg.sender].totalLosses++;
            return;
        }
        
        // Calculate winnings using VALID pools only
        uint256 winningPool = game.winningSide == Side.Red ? game.validRedPool : game.validBluePool;
        uint256 userShare = (bet.amount * 1e18) / winningPool;
        payout = (game.validLiquidity * userShare) / 1e18;
        
        bet.claimed = true;
        
        if (payout > 0) {
            gameBalance[_gameId] -= payout;
            
            (bool success, ) = payable(msg.sender).call{value: payout}("");
            if (!success) revert TransferFailed();
        }
        
        userStats[msg.sender].totalWins++;
        userStats[msg.sender].totalWinnings += payout;
        
        _updateLeaderboard(msg.sender);
        
        emit WinningsClaimed(_gameId, msg.sender, _side, bet.amount, payout);
    }
    
    function _cancelGame(uint256 _gameId, string memory _reason) internal {
        Game storage game = games[_gameId];
        
        // Return fees to game balance for full refunds
        uint256 feesToReturn = gameFees[_gameId];
        gameBalance[_gameId] += feesToReturn;
        gameFees[_gameId] = 0;
        
        uint256 totalPool = game.redPool + game.bluePool;
        game.totalLiquidity = totalPool;
        game.phase = GamePhase.Finalized;
        game.hasWinner = false;
        
        emit GameCancelled(_gameId, _reason);
    }
    
    // ==================== DRAND HELPER FUNCTIONS ====================
    
    /**
     * @notice Blake2f precompile address (EIP-152)
     */
    address private constant BLAKE2F_PRECOMPILE = address(0x09);
    
    /**
     * @notice Compute blake2b-128 hash using the blake2f precompile (EIP-152)
     * @dev Uses assembly to avoid stack depth issues
     * @param data Input data (up to 128 bytes)
     * @return hash 16-byte blake2b-128 hash
     */
    function _blake2b128(bytes memory data) internal view returns (bytes16) {
        // Blake2f input: rounds (4) + h (64) + m (128) + t (8) + f (1) = 213 bytes
        bytes memory input = new bytes(213);
        uint256 dataLen = data.length;
        
        assembly ("memory-safe") {
            let inp := add(input, 32)
            
            // Rounds = 12 (0x0000000c big-endian)
            mstore8(inp, 0)
            mstore8(add(inp, 1), 0)
            mstore8(add(inp, 2), 0)
            mstore8(add(inp, 3), 0x0c)
            
            // h state (64 bytes) - blake2b-128 IV with parameter block XOR
            // h[0] = IV[0] XOR 0x01010010 (16 byte output)
            // IV[0] = 0x6a09e667f3bcc908, XOR 0x01010010 = 0x6a09e667f3bcf918
            // All IVs stored in little-endian format
            
            // h[0] = 0x6a09e667f3bcc908 XOR 0x01010010 = 0x6a09e667f3bcf918 (LE)
            mstore8(add(inp, 4), 0x18)
            mstore8(add(inp, 5), 0xf9)
            mstore8(add(inp, 6), 0xbc)
            mstore8(add(inp, 7), 0xf3)
            mstore8(add(inp, 8), 0x67)
            mstore8(add(inp, 9), 0xe6)
            mstore8(add(inp, 10), 0x09)
            mstore8(add(inp, 11), 0x6a)
            
            // h[1] = 0xbb67ae8584caa73b (LE)
            mstore8(add(inp, 12), 0x3b)
            mstore8(add(inp, 13), 0xa7)
            mstore8(add(inp, 14), 0xca)
            mstore8(add(inp, 15), 0x84)
            mstore8(add(inp, 16), 0x85)
            mstore8(add(inp, 17), 0xae)
            mstore8(add(inp, 18), 0x67)
            mstore8(add(inp, 19), 0xbb)
            
            // h[2] = 0x3c6ef372fe94f82b (LE)
            mstore8(add(inp, 20), 0x2b)
            mstore8(add(inp, 21), 0xf8)
            mstore8(add(inp, 22), 0x94)
            mstore8(add(inp, 23), 0xfe)
            mstore8(add(inp, 24), 0x72)
            mstore8(add(inp, 25), 0xf3)
            mstore8(add(inp, 26), 0x6e)
            mstore8(add(inp, 27), 0x3c)
            
            // h[3] = 0xa54ff53a5f1d36f1 (LE)
            mstore8(add(inp, 28), 0xf1)
            mstore8(add(inp, 29), 0x36)
            mstore8(add(inp, 30), 0x1d)
            mstore8(add(inp, 31), 0x5f)
            mstore8(add(inp, 32), 0x3a)
            mstore8(add(inp, 33), 0xf5)
            mstore8(add(inp, 34), 0x4f)
            mstore8(add(inp, 35), 0xa5)
            
            // h[4] = 0x510e527fade682d1 (LE)
            mstore8(add(inp, 36), 0xd1)
            mstore8(add(inp, 37), 0x82)
            mstore8(add(inp, 38), 0xe6)
            mstore8(add(inp, 39), 0xad)
            mstore8(add(inp, 40), 0x7f)
            mstore8(add(inp, 41), 0x52)
            mstore8(add(inp, 42), 0x0e)
            mstore8(add(inp, 43), 0x51)
            
            // h[5] = 0x9b05688c2b3e6c1f (LE)
            mstore8(add(inp, 44), 0x1f)
            mstore8(add(inp, 45), 0x6c)
            mstore8(add(inp, 46), 0x3e)
            mstore8(add(inp, 47), 0x2b)
            mstore8(add(inp, 48), 0x8c)
            mstore8(add(inp, 49), 0x68)
            mstore8(add(inp, 50), 0x05)
            mstore8(add(inp, 51), 0x9b)
            
            // h[6] = 0x1f83d9abfb41bd6b (LE)
            mstore8(add(inp, 52), 0x6b)
            mstore8(add(inp, 53), 0xbd)
            mstore8(add(inp, 54), 0x41)
            mstore8(add(inp, 55), 0xfb)
            mstore8(add(inp, 56), 0xab)
            mstore8(add(inp, 57), 0xd9)
            mstore8(add(inp, 58), 0x83)
            mstore8(add(inp, 59), 0x1f)
            
            // h[7] = 0x5be0cd19137e2179 (LE)
            mstore8(add(inp, 60), 0x79)
            mstore8(add(inp, 61), 0x21)
            mstore8(add(inp, 62), 0x7e)
            mstore8(add(inp, 63), 0x13)
            mstore8(add(inp, 64), 0x19)
            mstore8(add(inp, 65), 0xcd)
            mstore8(add(inp, 66), 0xe0)
            mstore8(add(inp, 67), 0x5b)
            
            // m message (128 bytes at offset 68) - copy input data, rest is zero-padded
            let dataPtr := add(data, 32)
            let mPtr := add(inp, 68)
            for { let i := 0 } lt(i, dataLen) { i := add(i, 1) } {
                if lt(i, 128) {
                    mstore8(add(mPtr, i), byte(0, mload(add(dataPtr, i))))
                }
            }
            // Bytes 68+dataLen to 195 are already zero
            
            // t offset (16 bytes at offset 196) - t[0] = dataLen (LE), t[1] = 0
            mstore8(add(inp, 196), and(dataLen, 0xff))
            mstore8(add(inp, 197), and(shr(8, dataLen), 0xff))
            // Rest of t is already zero
            
            // f = 1 (final block) at offset 212
            mstore8(add(inp, 212), 1)
        }
        
        // Call blake2f precompile
        (bool success, bytes memory result) = BLAKE2F_PRECOMPILE.staticcall(input);
        require(success && result.length == 64, "blake2f failed");
        
        // Extract first 16 bytes as blake2b-128 output
        bytes16 hash;
        assembly ("memory-safe") {
            hash := mload(add(result, 32))
        }
        return hash;
    }
    
    /**
     * @notice Build storage key for drand.pulses(round) using Blake2_128Concat
     * @param round The drand round number
     * @return key The full storage key
     */
    function _buildDrandPulseKey(uint64 round) internal view returns (bytes memory) {
        // Encode round as u64 little-endian
        bytes memory roundLE = new bytes(8);
        uint64 r = round;
        for (uint256 i = 0; i < 8; i++) {
            roundLE[i] = bytes1(uint8(r));
            r = r >> 8;
        }
        
        // Blake2_128Concat = blake2_128(encoded_key) ++ encoded_key
        bytes16 hash = _blake2b128(roundLE);
        
        // Full key = prefix (32 bytes) + hash (16 bytes) + round (8 bytes) = 56 bytes
        bytes memory key = new bytes(56);
        
        // Copy prefix
        bytes memory prefix = DRAND_PULSES_PREFIX;
        for (uint256 i = 0; i < 32; i++) {
            key[i] = prefix[i];
        }
        
        // Copy blake2 hash
        for (uint256 i = 0; i < 16; i++) {
            key[32 + i] = hash[i];
        }
        
        // Copy round (little-endian)
        for (uint256 i = 0; i < 8; i++) {
            key[48 + i] = roundLE[i];
        }
        
        return key;
    }
    
    /**
     * @notice Read a value from Substrate storage using the precompile
     * @param key The storage key
     * @return data The stored value (empty if not found)
     */
    function _readSubstrateStorage(bytes memory key) internal view returns (bytes memory) {
        (bool success, bytes memory result) = STORAGE_PRECOMPILE.staticcall(key);
        if (!success) {
            return new bytes(0);
        }
        return result;
    }
    
    /**
     * @notice Get the last stored drand round from storage
     * @return round The last stored round (0 if not available)
     */
    function _getLastStoredRound() internal view returns (uint64) {
        bytes memory key = new bytes(32);
        bytes32 k = DRAND_LAST_ROUND_KEY;
        assembly ("memory-safe") {
            mstore(add(key, 32), k)
        }
        
        bytes memory data = _readSubstrateStorage(key);
        if (data.length < 8) {
            return 0;
        }
        
        // Decode u64 little-endian
        uint64 round = 0;
        for (uint256 i = 0; i < 8; i++) {
            round |= uint64(uint8(data[i])) << uint64(i * 8);
        }
        return round;
    }
    
    /**
     * @notice Read a drand pulse and extract the randomness
     * @param round The drand round to read
     * @return randomness The 32-byte randomness (empty if pulse not available)
     */
    function _getDrandRandomness(uint64 round) internal view returns (bytes32) {
        bytes memory key = _buildDrandPulseKey(round);
        bytes memory data = _readSubstrateStorage(key);
        
        if (data.length == 0) {
            return bytes32(0);
        }
        
        // Decode SCALE-encoded Pulse:
        // - round: u64 (8 bytes LE)
        // - randomness: BoundedVec<u8, 32> (compact length + up to 32 bytes)
        // - signature: BoundedVec<u8, 144> (compact length + up to 144 bytes)
        
        // We need at least: 8 (round) + 1 (compact len) + 32 (randomness) = 41 bytes
        if (data.length < 41) {
            return bytes32(0);
        }
        
        // Skip round (bytes 0-7)
        // Read compact length at byte 8
        uint8 compactLen = uint8(data[8]);
        
        // For lengths 0-63, compact encoding is just the length byte
        // For 32 bytes, compact = 0x80 (32 << 2 = 128 = 0x80) - wait, let me recalculate
        // SCALE compact: if value < 64, encode as (value << 2) | 0b00
        // For 32: 32 << 2 = 128 = 0x80... that doesn't fit in "single byte mode"
        // Actually: for 0-63, mode 0: byte = value << 2
        // For 32: 32 << 2 = 128, which has high bit set, so it's mode 1 (two bytes)
        // Wait no - let me check SCALE compact again:
        // Mode 0 (single byte): bits [7:2] = value, bits [1:0] = 00. Range: 0-63
        // Mode 1 (two bytes): bits [15:2] = value, bits [1:0] = 01. Range: 64-16383
        // For 32: fits in mode 0, so byte = 32 << 2 | 0 = 128 = 0x80
        // Hmm, but 0x80 has the pattern XX where low 2 bits are 00, so:
        // 0x80 = 0b10000000, low 2 bits = 00, so value = 0x80 >> 2 = 32. Correct!
        
        // Decode compact length
        uint256 randomnessLen;
        uint256 randomnessStart;
        
        if ((compactLen & 0x03) == 0) {
            // Single byte mode
            randomnessLen = compactLen >> 2;
            randomnessStart = 9;
        } else if ((compactLen & 0x03) == 1) {
            // Two byte mode
            if (data.length < 10) return bytes32(0);
            uint16 val = uint16(compactLen) | (uint16(uint8(data[9])) << 8);
            randomnessLen = val >> 2;
            randomnessStart = 10;
        } else {
            // Four byte or big integer mode - randomness shouldn't need this
            return bytes32(0);
        }
        
        // Validate length
        if (randomnessLen != 32) {
            return bytes32(0);
        }
        
        if (data.length < randomnessStart + 32) {
            return bytes32(0);
        }
        
        // Extract 32-byte randomness
        bytes32 randomness;
        assembly ("memory-safe") {
            randomness := mload(add(add(data, 32), randomnessStart))
        }
        
        return randomness;
    }
    
    function _updateLeaderboard(address _user) internal {
        uint256 userWinnings = userStats[_user].totalWinnings;
        
        bool found = false;
        uint256 userIndex = 0;
        
        for (uint256 i = 0; i < leaderboard.length; i++) {
            if (leaderboard[i] == _user) {
                found = true;
                userIndex = i;
                break;
            }
        }
        
        if (!found) {
            if (leaderboard.length < MAX_LEADERBOARD_SIZE) {
                leaderboard.push(_user);
                userIndex = leaderboard.length - 1;
            } else {
                uint256 lowestWinnings = userStats[leaderboard[leaderboard.length - 1]].totalWinnings;
                if (userWinnings > lowestWinnings) {
                    leaderboard[leaderboard.length - 1] = _user;
                    userIndex = leaderboard.length - 1;
                } else {
                    return;
                }
            }
        }
        
        while (userIndex > 0 && userStats[leaderboard[userIndex]].totalWinnings > userStats[leaderboard[userIndex - 1]].totalWinnings) {
            address temp = leaderboard[userIndex - 1];
            leaderboard[userIndex - 1] = leaderboard[userIndex];
            leaderboard[userIndex] = temp;
            userIndex--;
        }
    }

    // ==================== VIEW FUNCTIONS ====================
    
    function getGame(uint256 _gameId) external view returns (Game memory) {
        if (_gameId == 0 || _gameId >= nextGameId) revert GameNotFound();
        return games[_gameId];
    }
    
    function getCurrentGame() external view returns (Game memory) {
        if (currentGameId == 0) revert NoActiveGame();
        return games[currentGameId];
    }
    
    function getUserSideBet(uint256 _gameId, address _user, Side _side) external view returns (SideBet memory) {
        return sideBets[_gameId][_user][_side];
    }
    
    function getUserBets(uint256 _gameId, address _user) external view returns (UserBets memory) {
        return UserBets({
            redBet: sideBets[_gameId][_user][Side.Red],
            blueBet: sideBets[_gameId][_user][Side.Blue]
        });
    }
    
    function getUserStats(address _user) external view returns (UserStats memory) {
        return userStats[_user];
    }
    
    function getLeaderboard() external view returns (address[] memory) {
        return leaderboard;
    }
    
    function getLeaderboardWithStats(uint256 _limit) external view returns (
        address[] memory addresses,
        uint256[] memory winnings,
        uint256[] memory wins
    ) {
        uint256 count = _limit < leaderboard.length ? _limit : leaderboard.length;
        addresses = new address[](count);
        winnings = new uint256[](count);
        wins = new uint256[](count);
        
        for (uint256 i = 0; i < count; i++) {
            addresses[i] = leaderboard[i];
            winnings[i] = userStats[leaderboard[i]].totalWinnings;
            wins[i] = userStats[leaderboard[i]].totalWins;
        }
    }
    
    function calculatePotentialPayout(
        uint256 _gameId,
        address _user,
        Side _side, 
        uint256 _amount
    ) external view returns (uint256) {
        if (_gameId == 0 || _gameId >= nextGameId) return 0;
        
        Game storage game = games[_gameId];
        
        uint256 existingBet = sideBets[_gameId][_user][_side].amount;
        uint256 totalUserBet = existingBet + _amount;
        
        uint256 feeAmount = (_amount * PLATFORM_FEE) / FEE_DENOMINATOR;
        uint256 netNewAmount = _amount - feeAmount;
        
        uint256 sidePool = _side == Side.Red ? game.redPool : game.bluePool;
        uint256 newSidePool = sidePool + _amount;
        uint256 newTotalLiquidity = game.totalLiquidity + netNewAmount;
        
        return (totalUserBet * newTotalLiquidity) / newSidePool;
    }
    
    function getCurrentMultiplier(uint256 _gameId, Side _side) external view returns (uint256) {
        if (_gameId == 0 || _gameId >= nextGameId) return 10000;
        
        Game storage game = games[_gameId];
        
        uint256 sidePool = _side == Side.Red ? game.redPool : game.bluePool;
        if (sidePool == 0) return 0;
        
        return (game.totalLiquidity * 10000) / sidePool;
    }
    
    function getBlocksRemaining(uint256 _gameId) external view returns (uint256) {
        if (_gameId == 0 || _gameId >= nextGameId) return 0;
        
        Game storage game = games[_gameId];
        
        if (game.phase != GamePhase.Betting) return 0;
        if (block.number >= game.endBlock) return 0;
        
        return game.endBlock - block.number;
    }
    
    function isInFinalCall(uint256 _gameId) external view returns (bool) {
        if (_gameId == 0 || _gameId >= nextGameId) return false;
        
        Game storage game = games[_gameId];
        
        if (game.phase != GamePhase.Betting) return false;
        
        uint256 finalCallStartBlock = game.endBlock - FINAL_CALL_BLOCKS;
        return block.number >= finalCallStartBlock && block.number < game.endBlock;
    }
    
    function getGameCount() external view returns (uint256) {
        return nextGameId - 1;
    }
    
    function getGameBettors(uint256 _gameId) external view returns (address[] memory) {
        return gameBettors[_gameId];
    }
    
    function getGameBalance(uint256 _gameId) external view returns (uint256) {
        return gameBalance[_gameId];
    }
    
    function getGameFees(uint256 _gameId) external view returns (uint256) {
        return gameFees[_gameId];
    }
    
    /**
     * @notice Get anti-sniping resolution status (drand-based)
     * @return phase Current game phase
     * @return targetDrandRound Drand round committed to for randomness
     * @return actualEndBlock The randomly selected end block (0 if not yet determined)
     * @return canFinalize True if phase 2 can be called (drand pulse available)
     */
    function getResolutionStatus(uint256 _gameId) external view returns (
        GamePhase phase,
        uint64 targetDrandRound,
        uint256 actualEndBlock,
        bool canFinalize
    ) {
        Game storage game = games[_gameId];
        phase = game.phase;
        targetDrandRound = game.targetDrandRound;
        actualEndBlock = game.actualEndBlock;
        canFinalize = false;
        
        if (game.phase == GamePhase.Calculating && game.targetDrandRound > 0) {
            bytes32 randomness = _getDrandRandomness(game.targetDrandRound);
            canFinalize = (randomness != bytes32(0));
        }
    }
    
    /**
     * @notice Check if a game's drand resolution has timed out
     */
    function isResolutionTimedOut(uint256 _gameId) external view returns (bool) {
        Game storage game = games[_gameId];
        if (game.phase != GamePhase.Calculating) return false;
        return block.number > game.commitBlock + DRAND_TIMEOUT_BLOCKS;
    }
    
    /**
     * @notice Check if a specific bet was marked as late (for anti-sniping)
     */
    function isBetLate(uint256 _gameId, address _user, Side _side) external view returns (bool) {
        return sideBets[_gameId][_user][_side].isLateBet;
    }
    
    // ==================== DRAND VIEW FUNCTIONS ====================
    
    /**
     * @notice Get the last stored drand round from the chain
     * @return round The last available drand round (0 if drand not available)
     */
    function getLastDrandRound() external view returns (uint64) {
        return _getLastStoredRound();
    }
    
    /**
     * @notice Check if a specific drand round's pulse is available
     * @param round The drand round to check
     * @return available True if the pulse is stored and readable
     */
    function isDrandRoundAvailable(uint64 round) external view returns (bool) {
        bytes32 randomness = _getDrandRandomness(round);
        return randomness != bytes32(0);
    }
    
    /**
     * @notice Get randomness from a specific drand round (for debugging)
     * @param round The drand round
     * @return randomness The 32-byte randomness (zero if not available)
     */
    function getDrandRandomness(uint64 round) external view returns (bytes32) {
        return _getDrandRandomness(round);
    }
    
    /**
     * @notice Check drand health - returns info about drand availability
     * @return lastRound The last stored drand round
     * @return isAvailable True if drand storage is accessible
     */
    function getDrandStatus() external view returns (uint64 lastRound, bool isAvailable) {
        lastRound = _getLastStoredRound();
        isAvailable = lastRound > 0;
    }

    // ==================== ADMIN FUNCTIONS ====================
    
    /**
     * @notice Withdraw accumulated platform fees (only from resolved games)
     * @dev Safe: only touches accumulatedFees, never user principal
     */
    function withdrawFees() external onlyOwner {
        if (accumulatedFees > 0) {
            uint256 fees = accumulatedFees;
            accumulatedFees = 0;
            
            (bool success, ) = payable(owner()).call{value: fees}("");
            if (!success) revert TransferFailed();
        }
    }
    
    function getAccumulatedFees() external view returns (uint256) {
        return accumulatedFees;
    }
    
    /**
     * @notice Circuit breaker - pause/unpause new game creation
     * @dev Active games can still complete, only new games are blocked
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit ContractPausedEvent(_paused);
    }
}
