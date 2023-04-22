// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.16;

// todo: review visibility of functions
contract PenaltyPot {
    // penalty pot tracker
    mapping(address => uint256) public individualPenaltyPotTracker;
    mapping(address => uint256) public penaltyPotBuffer;
    uint256 public penaltyPotPerStakedVinci;
    uint256 public supplyElegibleForPenaltyPot;
    uint256 bufferedDecimals;

    event DepositedToPenaltyPot(address user, uint256 amountDeposited, uint256 amountDistributed);

    function _bufferPenaltyPot(address user, uint256 _stakingBalance) internal {
        uint256 penaltyPotShare = _stakingBalance * (penaltyPotPerStakedVinci - individualPenaltyPotTracker[user]);
        penaltyPotBuffer[user] += penaltyPotShare;
        individualPenaltyPotTracker[user] = penaltyPotPerStakedVinci;
    }

    function _addToElegibleSupplyForPenaltyPot(uint256 amount) internal {
        supplyElegibleForPenaltyPot += amount;
    }

    function _removeFromElegibleSupplyForPenaltyPot(uint256 amount) internal {
        supplyElegibleForPenaltyPot -= amount;
    }

    function _depositToPenaltyPot(uint256 amount) internal {
        uint256 elegibleSupply = supplyElegibleForPenaltyPot;

        if (elegibleSupply == 0) {
            bufferedDecimals += amount;
            return;
        }

        uint256 totalToDistribute = amount + bufferedDecimals;
        uint256 distributePerVinci = totalToDistribute / elegibleSupply;
        uint256 lostDecimals = totalToDistribute % elegibleSupply;
        bufferedDecimals = lostDecimals;
        penaltyPotPerStakedVinci += distributePerVinci;
        emit DepositedToPenaltyPot(msg.sender, amount, distributePerVinci * elegibleSupply);
    }

    function _penalizeSuperStaker(address user, uint256 unstakeAmount, uint256 stakingBalanceBefPenalization)
        internal
        returns (uint256)
    {
        // make sure everything is buffered before calculating the penalization
        _bufferPenaltyPot(user, stakingBalanceBefPenalization);
        uint256 penalization = penaltyPotBuffer[user] * unstakeAmount / stakingBalanceBefPenalization;
        penaltyPotBuffer[user] -= penalization;
        return penalization;
    }

    function _redeemPenaltyPot(address user, uint256 _stakingBalance) internal returns (uint256) {
        uint256 amount = _getPenaltyPotShare(user, _stakingBalance);

        individualPenaltyPotTracker[user] = penaltyPotPerStakedVinci;
        // buffer is also included in _getPenaltyPotShare(), so we have to reset it
        delete penaltyPotBuffer[user];

        return amount;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    function _getPenaltyPotShare(address user, uint256 _stakingBalance) internal view returns (uint256) {
        return _stakingBalance * (penaltyPotPerStakedVinci - individualPenaltyPotTracker[user]) + penaltyPotBuffer[user];
    }

    function _getTotalPenaltyPot() internal view returns (uint256) {
        return penaltyPotPerStakedVinci * supplyElegibleForPenaltyPot + bufferedDecimals;
    }
}
