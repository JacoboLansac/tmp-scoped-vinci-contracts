// SPDX-License-Identifier: MIT
pragma solidity >=0.8.14 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./inheritables/tiers.sol";
import "./inheritables/checkpoints.sol";
import "./inheritables/penaltyPot.sol";

//                          &&&&&%%%%%%%%%%#########*
//                      &&&&&&&&%%%%%%%%%%##########(((((
//                   @&&&&&&&&&%%%%%%%%%##########((((((((((
//                @@&&&&&&&&&&%%%%%%%%%#########(((((((((((((((
//              @@@&&&&&&&&%%%%%%%%%%##########((((((((((((((///(
//            %@@&&&&&&               ######(                /////.
//           @@&&&&&&&&&           #######(((((((       ,///////////
//          @@&&&&&&&&%%%           ####((((((((((*   .//////////////
//         @@&&&&&&&%%%%%%          ##((((((((((((/  ////////////////*
//         &&&&&&&%%%%%%%%%          *(((((((((//// //////////////////
//         &&&&%%%%%%%%%####          .((((((/////,////////////////***
//        %%%%%%%%%%%########.          ((/////////////////***********
//         %%%%%##########((((/          /////////////****************
//         ##########((((((((((/          ///////*********************
//         #####((((((((((((/////          /*************************,
//          #(((((((((////////////          *************************
//           (((((//////////////***          ***********************
//            ,//////////***********        *************,*,,*,,**
//              ///******************      *,,,,,,,,,,,,,,,,,,,,,
//                ******************,,    ,,,,,,,,,,,,,,,,,,,,,
//                   ****,,*,,,,,,,,,,,  ,,,,,,,,,,,,,,,,,,,
//                      ,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,
//                          .,,,,,,,,,,,,,,,,,,,,,,,

/// @title Version 1 of Vinci staking pool
/// @notice A smart contract to handle staking of Vinci ERC20 token and grant Picasso club tiers and superstaker status
/// @dev VINCI
contract VinciStakingV1 is AccessControl, TierManager, Checkpoints, PenaltyPot {
    bytes32 public constant CONTRACT_OPERATOR_ROLE = keccak256("CONTRACT_OPERATOR_ROLE");

    using SafeERC20 for IERC20;

    /// ERC20 vinci token
    IERC20 vinciToken;

    // balances
    uint256 public vinciStakingRewardsFunds;
    // Tokens that are staked and actively earning rewards
    mapping(address => uint256) public activeStaking;
    // Tokens that have been unstaked, but are not claimable yet (2 weeks delay)
    mapping(address => uint256) public currentlyUnstakingBalance;
    // Timestamp when the currentlyUnstakingBalance is available for claim
    mapping(address => uint256) public unstakingReleaseTime;
    // Total vinci rewards at the end of the current staking period of each user
    mapping(address => uint256) public baseAprBalanceNextCP;
    // Airdropped tokens of each user. They are unclaimable until crossing the next period
    mapping(address => uint256) public airdroppedBalance;
    // Tokens that have been unlocked in previous checkpoints and are now claimable
    mapping(address => uint256) public claimableBalance;

    uint256 public constant UNSTAKING_LOCK_TIME = 15 days;

    // constants
    uint256 public constant BASE_APR = 550; // 5.5%
    uint256 public constant BASIS_POINTS = 10000;

    event Staked(address indexed user, uint256 amount);
    event StakedTo(address indexed user, uint256 amount);
    event UnstakingInitiated(address indexed user, uint256 amount);
    event UnstakingCompleted(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event AirdroppedBatch(address[] users, uint256[] amounts);
    event StakingRewardsFunded(address indexed funder, uint256 amount);
    event MissedPayout(address indexed user, uint256 entitledPayout, uint256 actualPayout);
    event StakingRewardsAllocated(address indexed user, uint256 amount);
    event StakeholderFinished(address indexed user);
    event Relocked(address indexed user);
    event CheckpointCrossed(address indexed user);

    error NothingToClaim();
    error InvalidAmount();
    error CannotCrossCheckpointYet();
    error NonExistingStaker();

    // the following mappings are a waste of gas as they are only used for front-end views
    // but they were requested by upper management, and the low gas in polygon make them affordable
    // Aggregation of all VINCI staked in the contract by all stakers
    uint256 public totalVinciStaked;

    constructor(ERC20 _vinciTokenAddress, uint256[] memory _tiersThresholdsInVinci)
        TierManager(_tiersThresholdsInVinci)
    {
        vinciToken = IERC20(_vinciTokenAddress);

        /// todo: review potential collision roles in TierManager and this contract
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        // TODO: review where the CONTRACT_OPERATOR_ROLE is more suitable than the DEFAULT_ADMIN_ROLE
        _setupRole(CONTRACT_OPERATOR_ROLE, msg.sender);
    }

    /// ================== User functions =============================

    // TODO: review IVinciStaking docstrings
    /// @dev    See IVinciStaking for specifications
    function stake(uint256 amount) external {
        _stake(msg.sender, amount);
    }

    /// @dev    See IVinciStaking for specifications
    function batchStakeTo(address[] calldata users, uint256[] calldata amounts)
        external
        onlyRole(CONTRACT_OPERATOR_ROLE)
    {
        require(users.length == amounts.length, "Input lengths must match");
        // This is gas inefficient, as the ERC20 transaction takes place for every stake, instead of grouping the
        // total amount and making a single transfer. However, this function is meant to be used only once at the
        // beginning and the saved gas  doesn't compensate the added contract complexity
        for (uint256 i = 0; i < amounts.length; i++) {
            _stake(users[i], amounts[i]);
        }
    }

    function unstake(uint256 amount) external {
        // unstaking has a high cost in this echosystem:
        // - loosing already earned staking rewards,
        // - being downgrading in tier
        // - a lockup of 2 weeks before the unstaked can be completed
        // - potentially losing your staking streak if too much is unstaked
        address sender = msg.sender;
        // when unstaking, a percentage of the rewards, proportional to the current stake will be withdrawn as a penalty
        // from all the difference rewards sources: baseAPR, airdrops, penaltyPot.
        // This penalty is distributed to the penalty pot

        bool isFullUnstake = (amount == activeStaking[sender]);

        uint256 stakedBefore = activeStaking[sender];

        uint256 penaltyToAirddrops = amount * airdroppedBalance[sender] / stakedBefore;
        uint256 penaltyToBaseApr = amount * baseAprBalanceNextCP[sender] / stakedBefore;

        airdroppedBalance[sender] -= penaltyToAirddrops;
        baseAprBalanceNextCP[sender] -= penaltyToBaseApr;

        uint256 totalPenalization = penaltyToAirddrops + penaltyToBaseApr;
        // Important to do this check before potentially finishing stakeholder
        if (_isSuperstaker(sender)) {
            // sender only has share of the penalty pot if is superstaker. This function buffers first
            uint256 penaltyToPenaltyPot = _penalizeSuperStaker(sender, amount, stakedBefore);
            totalPenalization += penaltyToPenaltyPot;
            // we only reduce the amount elegible for penaltyPotRewards if already a superstaker
            // no need to _bufferPenaltyPot here, as it is already done by _penalizeStaker
            _removeFromElegibleSupplyForPenaltyPot(amount);
        }

        _depositToPenaltyPot(totalPenalization);

        // modify these ones only after the modifications to penalty pot
        totalVinciStaked -= amount;
        activeStaking[sender] -= amount;
        currentlyUnstakingBalance[sender] += amount;
        unstakingReleaseTime[sender] = block.timestamp + UNSTAKING_LOCK_TIME;

        if (isFullUnstake) {
            // finished stakeholders can still claim pending claims or pending unstaking tokens
            _finishStakeholder(sender);
        } else {
            // if they unstake, the tier is reevaluated only if new tier would be lower, but checkpoint is not postponed
            uint256 _potentialTier = calculateTier(stakingBalance(sender));
            if (_potentialTier < userTier[sender]) {
                _setTier(sender, _potentialTier);
                // TODO: if tier2 is lost, _addToElegibleSupplyForPenaltyPot also must be reduced
            }
        }
        emit UnstakingInitiated(sender, amount);
    }

    /// @dev    See IVinciStaking for specifications
    function claim() external {
        address sender = msg.sender;
        uint256 amount;

        if (claimableBalance[sender] > 0) {
            uint256 pureCalimable = claimableBalance[sender];
            amount += pureCalimable;
            delete claimableBalance[sender];
            // this is an unnecessary gas expense but the team wants to have it for frontend display purposes
            emit Claimed(sender, amount);
        }

        // finished stakeholders should also be able to claim their tokens also after being finished as stakeholders
        if (currentlyUnstakingBalance[sender] > 0) {
            // TODO: consider having a separate function for this ?? discuss with frontend
            uint256 unstakeAmount = currentlyUnstakingBalance[sender];
            amount += unstakeAmount;
            delete currentlyUnstakingBalance[sender];
            emit UnstakingCompleted(sender, unstakeAmount);
        }

        if (amount == 0) revert NothingToClaim();
        _sendVinci(sender, amount);
    }

    /// @dev    See IVinciStaking for specifications
    function relock() external {
        address sender = msg.sender;
        require(_existingUser(sender), "VINCI: Not authorized to run this function with zero stake");

        uint256 previousNextCheckpoint = checkpoint[sender];

        _setTier(sender, calculateTier(stakingBalance(sender)));
        _postponeCheckpointWithoutDurationReduction(sender);

        // extend the baseAprBalanceNextCP with the length from current next checkpoint until new next checkpoint
        baseAprBalanceNextCP[sender] +=
            _estimatePeriodRewards(activeStaking[sender], previousNextCheckpoint, checkpoint[sender]);

        emit Relocked(sender);
    }

    function crossCheckpoint() external {
        _crossCheckpoint(msg.sender);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    /// Contract Management Functions

    function crossCheckpointTo(address to) external onlyRole(CONTRACT_OPERATOR_ROLE) {
        _crossCheckpoint(to);
    }

    function batchAirdrop(address[] calldata users, uint256[] calldata amount)
        external
        onlyRole(CONTRACT_OPERATOR_ROLE)
    {
        // Note that non-initialized users will be initialized here, starting a checkpoint counter, even though they have 0 staking. That is weird
        // TODO: consider if we should impose the rule that a user must be an already registered staker in order to receive airdrops

        if (users.length != amount.length) revert("Lengths must match");
        uint256 n = users.length;

        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            if (!_existingUser(users[i])) {
                _initializeStakeholder(users[i]);
            }

            airdroppedBalance[users[i]] += amount[i];
            total += amount[i];
        }

        emit AirdroppedBatch(users, amount);
        _receiveVinci(total);
    }

    // anyone is allowed to fund the contract with VINCI tokens
    function fundContractWithVinciForRewards(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        vinciStakingRewardsFunds += amount;
        emit StakingRewardsFunded(msg.sender, amount);
        _receiveVinci(amount);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    /// View functions

    // todo review visibility of all view functions (external or public?)

    /// @notice Balance of staked VINCI tokens, (that are earning rewards for `user`)
    function stakingBalance(address user) public view returns (uint256) {
        return activeStaking[user];
    }

    /// @notice All unvested rewards that are not claimable yet. They can come from 3 different sources:
    ///         - airdoprs,
    ///         - corresponding share of the penaltyPot
    ///         - basic staking rewards (5.5% APR on the user's staking balance)
    function getTotalUnclaimableBalance(address user) public view returns (uint256) {
        return airdroppedBalance[user] + _getPenaltyPotShare(user, activeStaking[user])
            + _getCurrentUnclaimableRewardsFromBaseAPR(user);
    }

    /// @notice Part of the unvested rewards that come from airdrops
    function getUnclaimableFromAirdrops(address user) public view returns (uint256) {
        return airdroppedBalance[user];
    }

    /// @notice Part of the unvested rewards that are the user's share of the current penalty pot
    function getUnclaimableFromPenaltyPot(address user) public view returns (uint256) {
        return _getPenaltyPotShare(user, activeStaking[user]);
    }

    /// @notice Part of the unvested rewards that come from the basic staking rewards (5.5% on the staking balance)
    function getUnclaimableFromBaseApr(address user) public view returns (uint256) {
        return _getCurrentUnclaimableRewardsFromBaseAPR(user);
    }

    /// @notice When a user unstakes, those tokens are locked for 15 days, not earning rewards. Once the lockup period
    ///         ends, these toknes are available for withdraw. This function returns the amount of tokens available
    ///         for withdraw.
    function getUnstakeAmountAvailableForWithdrawal(address user) public view returns (uint256) {
        return (unstakingReleaseTime[user] > block.timestamp) ? 0 : currentlyUnstakingBalance[user];
    }

    /// @notice When a user unstakes, a penalization is imposed on the three different sources of unvested rewards.
    ///         This function returns what would be the potential loss (aggregation of the three sources)
    ///         This will help being transparent with the user and let them know how much they will lose if they
    ///         actually unstake
    function estimateRewardsLossIfUnstaking(address user, uint256 unstakeAmount) public view returns (uint256) {
        uint256 staked = activeStaking[user];
        uint256 penaltyToAirddrops = unstakeAmount * airdroppedBalance[user] / staked;
        uint256 penaltyToBaseApr = unstakeAmount * baseAprBalanceNextCP[user] / staked;
        uint256 penaltyToPenaltyPot = unstakeAmount * _getPenaltyPotShare(user, staked) / staked;
        return penaltyToAirddrops + penaltyToBaseApr + penaltyToPenaltyPot;
    }

    /// @notice Total VINCI collected in the penalty pot from penalizations to unstakers
    function penaltyPot() public view returns (uint256) {
        return _getTotalPenaltyPot();
    }

    /// @notice By default it will return 550, (5.5% in BASIS_POINTS)
    ///         But we might want to change this value in the future
    function getUserBaseAPRInBasisPoints(address user) external view virtual returns (uint256) {
        // TODO: implement this if nichlaes wants it in the end
        return BASE_APR;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    /// @notice Timestamp of the next checkpoint for the user
    function nextCheckpointTimestamp(address user) external view returns (uint256) {
        return checkpoint[user];
    }

    /// @notice Duration in months of the current checkpoint period (it reduces every time a checkpoint is crossed)
    function currentCheckpointDurationInMonths(address user) external view returns (uint256) {
        return _checkpointMultiplier(user);
    }

    /// @notice Returns if the checkpoint information of `user` is up-to-date
    ///         If the user does not exist, it also returns true, as there is no info to be updated
    function canCrossCheckpoint(address user) external view returns (bool) {
        return _canCrossCheckpoint(user);
    }

    /// @notice Duration in days since the staking streak was started (first stake)
    ///         When a user fully unstakes everything, the streak is reset
    function getDaysStaked(address user) public view returns (uint256) {
        return _streakDaysStaked(user);
    }

    /// @notice Returns True if the user has earned the status of SuperStaker. This is gained once the user has
    ///         crossed at least one checkpoint with non-zero staking. The SuperStaker status is lost when all the
    ///          balance is unstaked
    function isSuperstaker(address user) public view returns (bool) {
        return _isSuperstaker(user);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    /// INTERNAL FUNCTIONS

    function _stake(address user, uint256 amount) internal {
        if (amount == 0) revert InvalidAmount();

        if (checkpoint[user] == 0) {
            _initializeStakeholder(user);
        }

        if (_isSuperstaker(user)) {
            // no need to track the supplyElegibleForPenaltyPot specific of a user, because that is exactly the activeStaking
            // We only need to buffer any penalty pot earned so far, before changing the activeStaking
            _bufferPenaltyPot(user, activeStaking[user]);
            // This addition is not specific for the user, but for the entire penalty pot supply
            _addToElegibleSupplyForPenaltyPot(amount);
        }

        activeStaking[user] += amount;
        totalVinciStaked += amount;

        // we save the rewards for the entire period since now until next checkpoint here because the will only be
        // unlocked in the enxt checkpoint anyways
        uint256 rewards = _estimatePeriodRewards(amount, block.timestamp, checkpoint[user]);

        // TODO: think if we should revert or allow to stake without rewards. Consult management

        if (rewards > vinciStakingRewardsFunds) {
            emit MissedPayout(user, rewards, vinciStakingRewardsFunds);
            rewards = vinciStakingRewardsFunds;
        }

        if (rewards > 0) {
            baseAprBalanceNextCP[user] += rewards;
            vinciStakingRewardsFunds -= rewards;
            emit StakingRewardsAllocated(user, rewards);
        }

        emit Staked(user, amount);
        _receiveVinci(amount);
    }

    function _crossCheckpoint(address user) internal {
        if (!_canCrossCheckpoint(user)) revert CannotCrossCheckpointYet();

        uint256 activeStake = activeStaking[user];
        uint256 penaltyPotShare = _redeemPenaltyPot(user, activeStake);
        uint256 previousNextCheckpoint = checkpoint[user];

        // TODO: if several checkpoints have been missed, only the rewards of the first period are accrued. Acceptable
        claimableBalance[user] += baseAprBalanceNextCP[user] + airdroppedBalance[user] + penaltyPotShare;

        delete airdroppedBalance[user];

        // here user is not superstaker yet, the first time crossing the checkpoint
        if (!_isSuperstaker(user)) {
            _addToElegibleSupplyForPenaltyPot(activeStake);
        }

        // automatically becomes superStaker when crossing checkpoint and multiplier is reduced
        // TODO: CAREFUL! When several checkpoints are missed, the APR rewards are not properly saved. Only the one in the first period.
        // TODO: APR rewards are only reset when crossing the checkpoint. APR rewards should be calculated not from "now", but from "last checkpoint"

        _postponeCheckpoint(user, true);

        // set the rewards that will be accrued during the next period. Do this only after postponing checkpoint
        baseAprBalanceNextCP[user] = _estimatePeriodRewards(activeStake, previousNextCheckpoint, checkpoint[user]);

        // Evaluate new tier every time the checkpoint is crossed
        _setTier(user, calculateTier(activeStaking[user]));
        emit CheckpointCrossed(user);
    }

    function _receiveVinci(uint256 amount) internal {
        vinciToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function _sendVinci(address to, uint256 amount) internal {
        vinciToken.safeTransfer(to, amount);
    }

    function _initializeStakeholder(address user) internal {
        _initCheckpoint(user);
        _setTier(user, calculateTier(stakingBalance(user)));
    }

    /// @dev    This function is triggered when a user does not have any active stake.
    ///         Tier is removed, chekpointMultiplier is reset and user is removed from list of stakeholders
    function _finishStakeholder(address _user) internal {
        if (!_existingUser(_user)) revert NonExistingStaker();

        _setTier(_user, 0);
        // deleting the checkpointMultiplierReduction will also remove the superstaker status
        _resetCheckpointInfo(_user);

        emit StakeholderFinished(_user);
    }

    //////////////////////////////////////////////////////////////////////////////////////////////
    /// Internal view/pure functions

    function _estimatePeriodRewards(uint256 amount, uint256 startTime, uint256 endTime)
        internal
        pure
        returns (uint256)
    {
        // This should never ever happen, but we put this to avoid underflows
        if (endTime < startTime) return 0;

        return amount * BASE_APR * (endTime - startTime) / (BASIS_POINTS * 365 days);
    }

    /// A user checkpoint=0 until the user is registered and it is set back to zero when is _finalized
    function _existingUser(address _user) internal view returns (bool) {
        return checkpoint[_user] > 0;
    }

    function _getCurrentUnclaimableRewardsFromBaseAPR(address user) internal view returns (uint256) {
        // This is tricky as the rewards schedule can change with stakes and unstakes from users. However:
        // we know the final rewards because that is the `baseAprBalance` and we know how much time until the next checkpoint
        // Therefore, the rewards earned so far are the total minus the ones not earned yet, that will be earned from
        // now until the next checkpoint
        if (!_existingUser(user)) return 0;
        // if checkpoint can be crossed already, the total APR is the one accumulated in the full period
        if (_canCrossCheckpoint(user)) return baseAprBalanceNextCP[user];
        // block.timestamp is always < checkpoint[user] because otherwise it could cross checkpoint
        uint256 futureRewards = _estimatePeriodRewards(activeStaking[user], block.timestamp, checkpoint[user]);
        return baseAprBalanceNextCP[user] - futureRewards;
    }
}
