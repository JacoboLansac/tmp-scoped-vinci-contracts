// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.16;

contract Checkpoints {
    /// user timestam when next checkpoint can be crossed
    mapping(address => uint256) public checkpoint;
    /// checkpoints are postponed in multiples of 30 days. The checkpointReduction is how many blocks of 30 days the current checkpoint has been reduced from the baseCheckpointMultplier.
    mapping(address => uint256) public checkpointMultiplierReduction; // Initialized at 0, increasing up to 5
    /// staker initialization timestamp to track the time since staking streak started.
    // TODO: talk with frontend to try to get rid of this variable. They could read events instead
    mapping(address => uint256) public stakingStrikeStartTimestamp;

    /// the checkpoint multiplier is reduced by 1 block every time a user crosses a checkpoint. The starting multiplier is this
    uint256 internal constant BASE_CHECKPOINT_MULTIPLIER = 6;
    uint256 internal constant BASE_CHECKPOINT_DURATION = 30 days;

    event CheckpointSet(address indexed user, uint256 newCheckpoint);

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // Internal functions (inheritable by VinciStaking)

    function _checkpointMultiplier(address user) internal view returns (uint256) {
        return BASE_CHECKPOINT_MULTIPLIER - checkpointMultiplierReduction[user];
    }

    /// @dev    This function will update as many checkpoints as crossed
    function _postponeCheckpoint(address user, bool decreaseMultiplier) internal {
        if (checkpoint[user] == 0) {
            checkpoint[user] = block.timestamp + _checkpointMultiplier(user) * BASE_CHECKPOINT_DURATION;
        } else {
            // store these in memory for gas savings
            uint256 nextCheckpoint = checkpoint[user];
            uint256 reduction = checkpointMultiplierReduction[user];

            while (nextCheckpoint < block.timestamp) {
                if (decreaseMultiplier && (reduction < BASE_CHECKPOINT_MULTIPLIER - 1)) {
                    reduction += 1;
                }
                // addition to the current checkpoint to ignore the delay from the time when it is possible and the moment when crossing is actually executed
                nextCheckpoint += (BASE_CHECKPOINT_MULTIPLIER - reduction) * BASE_CHECKPOINT_DURATION;
            }

            checkpoint[user] = nextCheckpoint;
            checkpointMultiplierReduction[user] = reduction;
        }
        emit CheckpointSet(user, checkpoint[user]);
    }

    function _postponeCheckpointWithoutDurationReduction(address user) internal {
        checkpoint[user] +=
            (BASE_CHECKPOINT_MULTIPLIER - checkpointMultiplierReduction[user]) * BASE_CHECKPOINT_DURATION;
        emit CheckpointSet(user, checkpoint[user]);
    }

    function _initCheckpoint(address user) internal {
        uint256 userCheckpoint = block.timestamp + _checkpointMultiplier(user) * BASE_CHECKPOINT_DURATION;
        checkpoint[user] = userCheckpoint;
        stakingStrikeStartTimestamp[user] = block.timestamp;
        emit CheckpointSet(user, userCheckpoint);
    }

    function _resetCheckpointInfo(address _user) internal {
        // either of the following variables can be used to identified a 'finished' stakeholder
        delete checkpoint[_user];
        delete stakingStrikeStartTimestamp[_user];
        // deleting the checkpointMultiplierReduction will also remove the superstaker status
        delete checkpointMultiplierReduction[_user];
    }

    /// @dev    The condition for being a super staker is to have crossed at least one checkpoint
    function _isSuperstaker(address user) internal view returns (bool) {
        return checkpointMultiplierReduction[user] > 0;
    }

    function _canCrossCheckpoint(address user) internal view returns (bool) {
        // only allows existing users
        return (checkpoint[user] != 0) && (block.timestamp > checkpoint[user]);
    }

    function _streakDaysStaked(address user) internal view returns (uint256) {
        if (stakingStrikeStartTimestamp[user] > 0) {
            return uint256((block.timestamp - stakingStrikeStartTimestamp[user]) / (1 days));
        } else {
            return 0;
        }
    }
}
