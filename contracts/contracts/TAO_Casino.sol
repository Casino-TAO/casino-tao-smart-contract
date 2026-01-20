// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TAOCasino
 * @notice P2P betting game on Bittensor EVM with dual-position betting, referrals, and rapid mode
 * @dev Features:
 *   - Dual-position betting (bet on BOTH Red AND Blue simultaneously)
 *   - Referral system (referrers earn 10% of referee's platform fees)
 *   - Rapid mode (10-minute games) alongside regular games
 *   - Underdog bonus (reduced fee when betting on smaller side)
 *   - Leaderboard tracking for top winners
 *   - Native TAO betting
 */
contract TAOCasino is ReentrancyGuard, Ownable {

    // ==================== ENUMS ====================
    
    enum GameType {
        Classic,    // More money wins (majority)
        Underdog    // Less money wins (minority)
    }
    
    enum GameSpeed {
        Regular,    // 105 minutes betting
        Rapid       // 10 minutes betting
    }
    
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
        GameType gameType;
        GameSpeed gameSpeed;
        GamePhase phase;
        uint256 redPool;
        uint256 bluePool;
        uint256 redBettors;
        uint256 blueBettors;
        uint256 startTime;
        uint256 endTime;
        uint256 resolvedTime;
        Side winningSide;
        uint256 totalLiquidity;
        bool hasWinner;
    }
    
    // Bet on a specific side (user can have one per side)
    struct SideBet {
        uint256 amount;
        bool claimed;
        address referrer;
    }
    
    // Combined user bets for a game (both sides)
    struct UserBets {
        SideBet redBet;
        SideBet blueBet;
    }
    
    struct UserStats {
        uint256 totalBets;
        uint256 totalWins;
        uint256 totalWinnings;
        uint256 totalLosses;
        uint256 referralEarnings;
    }
    
    struct ReferralInfo {
        address referrer;
        uint256 totalReferred;
        uint256 totalEarnings;
        bool isActive;
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
    error InvalidGameDuration();
    error NotEnoughParticipation();
    error InvalidReferralCode();
    error CannotReferSelf();

    // ==================== STATE VARIABLES ====================
    
    uint256 public nextGameId = 1;
    uint256 public platformFee = 150;           // 1.5% normal fee
    uint256 public referralShareBps = 1000;     // 10% of fees go to referrer
    uint256 public underdogBonusBps = 500;      // 5% bonus when betting on underdog
    uint256 public underdogThreshold = 7000;    // Underdog bonus activates when side < 30%
    
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant TOKEN_DECIMALS = 18; // TAO uses 18 decimals
    
    // Accumulated fees in native TAO
    uint256 public accumulatedFees;
    
    // Game timing parameters (in seconds)
    uint256 public regularBettingDuration = 105 minutes;
    uint256 public rapidBettingDuration = 10 minutes;
    uint256 public finalCallDuration = 15 minutes;
    uint256 public rapidFinalCallDuration = 3 minutes;
    uint256 public breakDuration = 15 minutes;
    uint256 public rapidBreakDuration = 5 minutes;
    
    // Minimum participation
    uint256 public minTotalBets = 2;
    uint256 public minPoolSize = 1 ether;        // 1 TAO minimum for regular
    uint256 public rapidMinPoolSize = 0.5 ether; // 0.5 TAO minimum for rapid
    
    // Current active games (one Classic, one Underdog can run simultaneously)
    uint256 public currentClassicGameId = 0;
    uint256 public currentUnderdogGameId = 0;
    
    // Mappings
    mapping(uint256 => Game) public games;
    // gameId => user => side => SideBet
    mapping(uint256 => mapping(address => mapping(Side => SideBet))) public sideBets;
    mapping(uint256 => address[]) public gameBettors;
    mapping(uint256 => uint256) public gameBalance;
    
    // Track if user has any bet in game (for bettor list)
    mapping(uint256 => mapping(address => bool)) public hasAnyBet;
    
    // Referral mappings
    mapping(address => ReferralInfo) public referrals;
    mapping(bytes32 => address) public referralCodes;
    mapping(address => bytes32) public userReferralCode;
    mapping(address => uint256) public pendingReferralRewards;
    
    // User stats for leaderboard
    mapping(address => UserStats) public userStats;
    
    // Leaderboard tracking (top 100 by winnings)
    address[] public leaderboard;
    uint256 public constant MAX_LEADERBOARD_SIZE = 100;

    // ==================== EVENTS ====================
    
    event GameCreated(
        uint256 indexed gameId,
        GameType gameType,
        GameSpeed gameSpeed,
        uint256 startTime,
        uint256 endTime
    );
    
    event BetPlaced(
        uint256 indexed gameId,
        address indexed bettor,
        Side side,
        uint256 amount,
        uint256 newPoolTotal,
        address referrer
    );
    
    event GameResolved(
        uint256 indexed gameId,
        GameType gameType,
        GameSpeed gameSpeed,
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
    
    event ReferralCodeCreated(
        address indexed user,
        bytes32 codeHash
    );
    
    event ReferralRewardEarned(
        address indexed referrer,
        address indexed referee,
        uint256 amount
    );
    
    event ReferralRewardsClaimed(
        address indexed referrer,
        uint256 amount
    );
    
    event GameCancelled(uint256 indexed gameId, string reason);
    event RefundClaimed(uint256 indexed gameId, address indexed bettor, Side side, uint256 amount);

    // ==================== CONSTRUCTOR ====================
    
    constructor() {}

    // ==================== REFERRAL FUNCTIONS ====================
    
    function createReferralCode(string calldata _code) external {
        bytes32 codeHash = keccak256(abi.encodePacked(_code));
        require(referralCodes[codeHash] == address(0), "Code already taken");
        require(userReferralCode[msg.sender] == bytes32(0), "Already have a code");
        
        referralCodes[codeHash] = msg.sender;
        userReferralCode[msg.sender] = codeHash;
        
        referrals[msg.sender] = ReferralInfo({
            referrer: address(0),
            totalReferred: 0,
            totalEarnings: 0,
            isActive: true
        });
        
        emit ReferralCodeCreated(msg.sender, codeHash);
    }
    
    function validateReferralCode(string calldata _code) public view returns (address) {
        bytes32 codeHash = keccak256(abi.encodePacked(_code));
        return referralCodes[codeHash];
    }
    
    function claimReferralRewards() external nonReentrant {
        uint256 reward = pendingReferralRewards[msg.sender];
        require(reward > 0, "No rewards to claim");
        
        pendingReferralRewards[msg.sender] = 0;
        
        (bool success, ) = payable(msg.sender).call{value: reward}("");
        if (!success) revert TransferFailed();
        
        emit ReferralRewardsClaimed(msg.sender, reward);
    }

    // ==================== MAIN FUNCTIONS ====================
    
    function startNewGame(GameType _gameType, GameSpeed _gameSpeed) external {
        // Check by game type - Classic and Underdog are separate slots
        uint256 currentId = _gameType == GameType.Classic ? currentClassicGameId : currentUnderdogGameId;
        
        if (currentId > 0) {
            Game storage prevGame = games[currentId];
            if (prevGame.phase == GamePhase.Betting) revert GameStillActive();
            if (prevGame.phase == GamePhase.Calculating) revert GameStillActive();
        }
        
        uint256 gameId = nextGameId++;
        uint256 startTime = block.timestamp;
        uint256 duration = _gameSpeed == GameSpeed.Regular ? regularBettingDuration : rapidBettingDuration;
        uint256 endTime = startTime + duration;
        
        games[gameId] = Game({
            id: gameId,
            gameType: _gameType,
            gameSpeed: _gameSpeed,
            phase: GamePhase.Betting,
            redPool: 0,
            bluePool: 0,
            redBettors: 0,
            blueBettors: 0,
            startTime: startTime,
            endTime: endTime,
            resolvedTime: 0,
            winningSide: Side.Red,
            totalLiquidity: 0,
            hasWinner: false
        });
        
        // Track by game type - each type has its own slot
        if (_gameType == GameType.Classic) {
            currentClassicGameId = gameId;
        } else {
            currentUnderdogGameId = gameId;
        }
        
        emit GameCreated(gameId, _gameType, _gameSpeed, startTime, endTime);
    }
    
    /**
     * @notice Place a bet on a specific side (users can bet on BOTH sides)
     * @param _gameId Game to bet on
     * @param _side Red or Blue
     * @param _referralCode Optional referral code (empty string if none)
     */
    function placeBet(
        uint256 _gameId, 
        Side _side,
        string calldata _referralCode
    ) external payable nonReentrant {
        if (_gameId == 0 || _gameId >= nextGameId) revert GameNotFound();
        if (msg.value == 0) revert InvalidBetAmount();
        
        Game storage game = games[_gameId];
        
        if (game.phase != GamePhase.Betting) revert GameNotInBettingPhase();
        if (block.timestamp >= game.endTime) revert BettingPeriodEnded();
        
        SideBet storage existingBet = sideBets[_gameId][msg.sender][_side];
        
        uint256 _amount = msg.value;
        
        // Calculate fee rate (with underdog bonus if applicable)
        uint256 feeRate = platformFee;
        
        if (game.redPool + game.bluePool > 0) {
            uint256 sidePool = _side == Side.Red ? game.redPool : game.bluePool;
            uint256 totalPool = game.redPool + game.bluePool;
            uint256 sidePercentage = (sidePool * FEE_DENOMINATOR) / totalPool;
            
            // If betting on the underdog (< 30%), reduce fee
            if (sidePercentage < (FEE_DENOMINATOR - underdogThreshold)) {
                feeRate = feeRate > underdogBonusBps ? feeRate - underdogBonusBps : 0;
            }
        }
        
        uint256 feeAmount = (_amount * feeRate) / FEE_DENOMINATOR;
        uint256 netAmount = _amount - feeAmount;
        
        // Handle referral
        address referrer = existingBet.referrer;
        if (bytes(_referralCode).length > 0 && referrer == address(0)) {
            referrer = validateReferralCode(_referralCode);
            if (referrer != address(0) && referrer != msg.sender) {
                uint256 referralReward = (feeAmount * referralShareBps) / FEE_DENOMINATOR;
                feeAmount -= referralReward;
                
                pendingReferralRewards[referrer] += referralReward;
                referrals[referrer].totalReferred++;
                referrals[referrer].totalEarnings += referralReward;
                
                emit ReferralRewardEarned(referrer, msg.sender, referralReward);
            }
        } else if (referrer != address(0)) {
            // Existing referrer on this bet
            uint256 referralReward = (feeAmount * referralShareBps) / FEE_DENOMINATOR;
            feeAmount -= referralReward;
            
            pendingReferralRewards[referrer] += referralReward;
            referrals[referrer].totalEarnings += referralReward;
            
            emit ReferralRewardEarned(referrer, msg.sender, referralReward);
        }
        
        // Track fees
        accumulatedFees += feeAmount;
        gameBalance[_gameId] += netAmount;
        
        // Check if this is a new bettor on this side
        bool isNewBettorOnSide = existingBet.amount == 0;
        
        // Update user's side bet
        existingBet.amount += _amount;
        existingBet.claimed = false;
        if (referrer != address(0)) {
            existingBet.referrer = referrer;
        }
        
        // Update game pools
        if (_side == Side.Red) {
            game.redPool += _amount;
            if (isNewBettorOnSide) {
                game.redBettors++;
            }
        } else {
            game.bluePool += _amount;
            if (isNewBettorOnSide) {
                game.blueBettors++;
            }
        }
        
        game.totalLiquidity += netAmount;
        
        // Track bettor (only add to list once)
        if (!hasAnyBet[_gameId][msg.sender]) {
            hasAnyBet[_gameId][msg.sender] = true;
            gameBettors[_gameId].push(msg.sender);
        }
        
        // Update user stats
        userStats[msg.sender].totalBets++;
        
        uint256 newPoolTotal = _side == Side.Red ? game.redPool : game.bluePool;
        emit BetPlaced(_gameId, msg.sender, _side, _amount, newPoolTotal, referrer);
    }
    
    function resolveGame(uint256 _gameId) external {
        if (_gameId == 0 || _gameId >= nextGameId) revert GameNotFound();
        
        Game storage game = games[_gameId];
        
        if (game.phase != GamePhase.Betting) revert GameAlreadyResolved();
        if (block.timestamp < game.endTime) revert BettingPeriodNotEnded();
        
        uint256 totalBettors = game.redBettors + game.blueBettors;
        uint256 totalPool = game.redPool + game.bluePool;
        uint256 minPool = game.gameSpeed == GameSpeed.Rapid ? rapidMinPoolSize : minPoolSize;
        
        if (totalBettors < minTotalBets || totalPool < minPool) {
            _cancelGame(_gameId, "Insufficient participation");
            return;
        }
        
        Side winner;
        
        if (game.gameType == GameType.Classic) {
            // Classic: More money wins
            winner = game.redPool >= game.bluePool ? Side.Red : Side.Blue;
        } else {
            // Underdog: Less money wins
            winner = game.redPool <= game.bluePool ? Side.Red : Side.Blue;
        }
        
        game.winningSide = winner;
        game.hasWinner = true;
        game.phase = GamePhase.Resolved;
        game.resolvedTime = block.timestamp;
        
        emit GameResolved(
            _gameId,
            game.gameType,
            game.gameSpeed,
            winner,
            game.redPool,
            game.bluePool,
            game.redBettors,
            game.blueBettors
        );
    }
    
    /**
     * @notice Claim winnings from a resolved game (only winning side bet pays out)
     * @param _gameId Game ID to claim from
     * @param _side Side to claim from (must be winning side)
     */
    function claimWinnings(uint256 _gameId, Side _side) external nonReentrant {
        if (_gameId == 0 || _gameId >= nextGameId) revert GameNotFound();
        
        Game storage game = games[_gameId];
        SideBet storage bet = sideBets[_gameId][msg.sender][_side];
        
        if (bet.amount == 0) revert NoBetToClaim();
        if (bet.claimed) revert AlreadyClaimed();
        
        uint256 payout = 0;
        
        // Handle cancelled games - refund both sides
        if (!game.hasWinner && game.phase == GamePhase.Finalized) {
            payout = bet.amount;
            bet.claimed = true;
            
            (bool success, ) = payable(msg.sender).call{value: payout}("");
            if (!success) revert TransferFailed();
            
            emit RefundClaimed(_gameId, msg.sender, _side, payout);
            return;
        }
        
        if (game.phase != GamePhase.Resolved && game.phase != GamePhase.Finalized) {
            revert GameNotResolved();
        }
        
        // If this side lost, mark as claimed but no payout
        if (_side != game.winningSide) {
            bet.claimed = true;
            userStats[msg.sender].totalLosses++;
            return;
        }
        
        // Calculate winnings for winning side
        uint256 winningPool = game.winningSide == Side.Red ? game.redPool : game.bluePool;
        uint256 userShare = (bet.amount * 1e18) / winningPool;
        
        payout = (gameBalance[_gameId] * userShare) / 1e18;
        
        bet.claimed = true;
        
        if (payout > 0) {
            (bool success, ) = payable(msg.sender).call{value: payout}("");
            if (!success) revert TransferFailed();
        }
        
        // Update stats
        userStats[msg.sender].totalWins++;
        userStats[msg.sender].totalWinnings += payout;
        
        // Update leaderboard
        _updateLeaderboard(msg.sender);
        
        emit WinningsClaimed(_gameId, msg.sender, _side, bet.amount, payout);
    }
    
    /**
     * @notice Convenience function to claim both sides at once
     */
    function claimAllWinnings(uint256 _gameId) external {
        SideBet storage redBet = sideBets[_gameId][msg.sender][Side.Red];
        SideBet storage blueBet = sideBets[_gameId][msg.sender][Side.Blue];
        
        if (redBet.amount > 0 && !redBet.claimed) {
            this.claimWinnings(_gameId, Side.Red);
        }
        if (blueBet.amount > 0 && !blueBet.claimed) {
            this.claimWinnings(_gameId, Side.Blue);
        }
    }
    
    // ==================== INTERNAL FUNCTIONS ====================
    
    function _cancelGame(uint256 _gameId, string memory _reason) internal {
        Game storage game = games[_gameId];
        
        // Return fees to game balance for refunds
        uint256 fees = (gameBalance[_gameId] * platformFee) / (FEE_DENOMINATOR - platformFee);
        gameBalance[_gameId] += fees;
        
        if (accumulatedFees >= fees) accumulatedFees -= fees;
        
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
    
    function getCurrentClassicGame() external view returns (Game memory) {
        if (currentClassicGameId == 0) revert NoActiveGame();
        return games[currentClassicGameId];
    }
    
    function getCurrentUnderdogGame() external view returns (Game memory) {
        if (currentUnderdogGameId == 0) revert NoActiveGame();
        return games[currentUnderdogGameId];
    }
    
    /**
     * @notice Get user's bet on a specific side
     */
    function getUserSideBet(uint256 _gameId, address _user, Side _side) external view returns (SideBet memory) {
        return sideBets[_gameId][_user][_side];
    }
    
    /**
     * @notice Get user's bets on both sides
     */
    function getUserBets(uint256 _gameId, address _user) external view returns (UserBets memory) {
        return UserBets({
            redBet: sideBets[_gameId][_user][Side.Red],
            blueBet: sideBets[_gameId][_user][Side.Blue]
        });
    }
    
    function getUserStats(address _user) external view returns (UserStats memory) {
        return userStats[_user];
    }
    
    function getReferralInfo(address _user) external view returns (ReferralInfo memory) {
        return referrals[_user];
    }
    
    function getPendingReferralRewards(address _user) external view returns (uint256) {
        return pendingReferralRewards[_user];
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
        
        // Get user's existing bet on this side
        uint256 existingBet = sideBets[_gameId][_user][_side].amount;
        uint256 totalUserBet = existingBet + _amount;
        
        // Calculate fee for new amount only (existing bet already had fee deducted)
        uint256 feeAmount = (_amount * platformFee) / FEE_DENOMINATOR;
        uint256 netNewAmount = _amount - feeAmount;
        
        // New pools after this bet
        uint256 sidePool = _side == Side.Red ? game.redPool : game.bluePool;
        uint256 newSidePool = sidePool + _amount;
        uint256 newTotalLiquidity = game.totalLiquidity + netNewAmount;
        
        // Calculate payout based on user's TOTAL position
        return (totalUserBet * newTotalLiquidity) / newSidePool;
    }
    
    function getCurrentMultiplier(uint256 _gameId, Side _side) external view returns (uint256) {
        if (_gameId == 0 || _gameId >= nextGameId) return 10000;
        
        Game storage game = games[_gameId];
        
        uint256 sidePool = _side == Side.Red ? game.redPool : game.bluePool;
        if (sidePool == 0) return 0;
        
        return (game.totalLiquidity * 10000) / sidePool;
    }
    
    function getTimeRemaining(uint256 _gameId) external view returns (uint256) {
        if (_gameId == 0 || _gameId >= nextGameId) return 0;
        
        Game storage game = games[_gameId];
        
        if (game.phase != GamePhase.Betting) return 0;
        if (block.timestamp >= game.endTime) return 0;
        
        return game.endTime - block.timestamp;
    }
    
    function isInFinalCall(uint256 _gameId) external view returns (bool) {
        if (_gameId == 0 || _gameId >= nextGameId) return false;
        
        Game storage game = games[_gameId];
        
        if (game.phase != GamePhase.Betting) return false;
        
        uint256 finalCall = game.gameSpeed == GameSpeed.Rapid ? rapidFinalCallDuration : finalCallDuration;
        uint256 finalCallStart = game.endTime - finalCall;
        return block.timestamp >= finalCallStart && block.timestamp < game.endTime;
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
    
    function isUnderdogSide(uint256 _gameId, Side _side) external view returns (bool) {
        Game storage game = games[_gameId];
        uint256 totalPool = game.redPool + game.bluePool;
        if (totalPool == 0) return false;
        
        uint256 sidePool = _side == Side.Red ? game.redPool : game.bluePool;
        uint256 sidePercentage = (sidePool * FEE_DENOMINATOR) / totalPool;
        
        return sidePercentage < (FEE_DENOMINATOR - underdogThreshold);
    }

    // ==================== ADMIN FUNCTIONS ====================
    
    function setPlatformFee(uint256 _fee) external onlyOwner {
        require(_fee <= 1000, "Fee cannot exceed 10%");
        platformFee = _fee;
    }
    
    function setReferralShareBps(uint256 _share) external onlyOwner {
        require(_share <= 5000, "Referral share cannot exceed 50%");
        referralShareBps = _share;
    }
    
    function setUnderdogBonus(uint256 _bonus, uint256 _threshold) external onlyOwner {
        require(_bonus <= 1000, "Bonus cannot exceed 10%");
        require(_threshold <= 9000, "Threshold too high");
        underdogBonusBps = _bonus;
        underdogThreshold = _threshold;
    }
    
    function setRegularBettingDuration(uint256 _duration) external onlyOwner {
        if (_duration < 30 minutes || _duration > 24 hours) revert InvalidGameDuration();
        regularBettingDuration = _duration;
    }
    
    function setRapidBettingDuration(uint256 _duration) external onlyOwner {
        if (_duration < 5 minutes || _duration > 1 hours) revert InvalidGameDuration();
        rapidBettingDuration = _duration;
    }
    
    function setMinParticipation(uint256 _minBets, uint256 _minPool, uint256 _rapidMinPool) external onlyOwner {
        minTotalBets = _minBets;
        minPoolSize = _minPool;
        rapidMinPoolSize = _rapidMinPool;
    }
    
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
    
    function emergencyCancelGame(uint256 _gameId) external onlyOwner {
        if (_gameId == 0 || _gameId >= nextGameId) revert GameNotFound();
        
        Game storage game = games[_gameId];
        if (game.phase == GamePhase.Finalized) revert GameAlreadyResolved();
        
        _cancelGame(_gameId, "Emergency cancellation by owner");
    }
    
    // Allow contract to receive TAO
    receive() external payable {}
}
