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
        // Anti-sniping: random end block within final call window
        uint256 randomnessBlock;    // Block whose hash determines actualEndBlock
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
    uint256 public constant RANDOMNESS_DELAY_BLOCKS = 5;     // Wait 5 blocks for unpredictable hash
    uint256 public constant MAX_BETTORS_PER_GAME = 500;      // Prevent gas DoS in _calculateValidPools
    uint256 public constant MAX_LEADERBOARD_SIZE = 100;

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
    event RandomnessCommitted(uint256 indexed gameId, uint256 randomnessBlock);
    event ActualEndBlockSet(uint256 indexed gameId, uint256 actualEndBlock, uint256 validRedPool, uint256 validBluePool);
    event LateBetRefunded(uint256 indexed gameId, address indexed bettor, Side side, uint256 amount);

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
            randomnessBlock: 0,
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
     * @dev Phase 1: Commit to future block for randomness
     *      Phase 2: Use blockhash to determine actual end, filter late bets
     * @param _gameId Game to resolve
     */
    function resolveGame(uint256 _gameId) external {
        if (_gameId == 0 || _gameId >= nextGameId) revert GameNotFound();
        
        Game storage game = games[_gameId];
        
        // PHASE 1: Commit to randomness block
        if (game.phase == GamePhase.Betting) {
            if (block.number < game.endBlock) revert BettingPeriodNotEnded();
            
            // Commit to a future block for unpredictable randomness
            game.randomnessBlock = block.number + RANDOMNESS_DELAY_BLOCKS;
            game.phase = GamePhase.Calculating;
            
            emit RandomnessCommitted(_gameId, game.randomnessBlock);
            return;
        }
        
        // PHASE 2: Finalize with random end block
        if (game.phase == GamePhase.Calculating) {
            if (block.number <= game.randomnessBlock) revert WaitingForRandomness();
            
            // Combined blockhash: use multiple block hashes for stronger randomness
            // This makes validator manipulation much harder (would need to control 3 consecutive blocks)
            bytes32 hash1 = blockhash(game.randomnessBlock);
            bytes32 hash2 = blockhash(game.randomnessBlock > 0 ? game.randomnessBlock - 1 : 0);
            bytes32 hash3 = blockhash(game.randomnessBlock > 1 ? game.randomnessBlock - 2 : 0);
            
            // Combine hashes for entropy
            bytes32 entropy = keccak256(abi.encodePacked(hash1, hash2, hash3));
            
            uint256 finalCallStart = game.endBlock - FINAL_CALL_BLOCKS;
            
            // If primary hash is 0 (too old, >256 blocks), use endBlock as fallback
            // Game must still complete even without randomness benefit
            if (hash1 == bytes32(0)) {
                game.actualEndBlock = game.endBlock;
            } else {
                // Random offset within final call window
                uint256 randomOffset = uint256(entropy) % FINAL_CALL_BLOCKS;
                game.actualEndBlock = finalCallStart + randomOffset;
            }
            
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
     * @notice Get anti-sniping resolution status
     * @return phase Current game phase
     * @return randomnessBlock Block whose hash will determine actual end
     * @return actualEndBlock The randomly selected end block (0 if not yet determined)
     * @return canFinalize True if phase 2 can be called
     */
    function getResolutionStatus(uint256 _gameId) external view returns (
        GamePhase phase,
        uint256 randomnessBlock,
        uint256 actualEndBlock,
        bool canFinalize
    ) {
        Game storage game = games[_gameId];
        phase = game.phase;
        randomnessBlock = game.randomnessBlock;
        actualEndBlock = game.actualEndBlock;
        canFinalize = (game.phase == GamePhase.Calculating && block.number > game.randomnessBlock);
    }
    
    /**
     * @notice Check if a specific bet was marked as late (for anti-sniping)
     */
    function isBetLate(uint256 _gameId, address _user, Side _side) external view returns (bool) {
        return sideBets[_gameId][_user][_side].isLateBet;
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
