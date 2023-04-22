// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.16;

import "@openzeppelin/contracts/access/AccessControl.sol";

contract TierManager is AccessControl {
    bytes32 public constant TIER_MANAGER_ROLE = keccak256("TIER_MANAGER_ROLE");

    /// User tier which is granted according to the tier thresholds in vinci.
    /// Tiers are re-evaluated in certain occasions (unstake, relock, crossing a checkpoint)
    mapping(address => uint256) public userTier;

    /// An array of thresholds which defines the minimum vinci to be staked by a user in order to have certain tiers
    uint256[] internal tiersThresholdsInVinci;

    // todo missing testing the events firing
    event TiersThresholdsUpdated(uint256[] vinciThresholds);
    event TierSet(address indexed user, uint256 newTier);

    constructor(uint256[] memory _tiersThresholdsInVinci) {
        tiersThresholdsInVinci = _tiersThresholdsInVinci;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(TIER_MANAGER_ROLE, msg.sender);
    }

    /// @notice Returns the minimum amount of VINCI to enter in `tier`
    function tierThreshold(uint256 tier) external view returns (uint256) {
        require(tier <= tiersThresholdsInVinci.length, "Non existing tier");
        return (tier > 0) ? tiersThresholdsInVinci[tier - 1] : 0;
    }

    /// @notice Returns the number of current tiers
    function numberOfTiers() public view returns (uint256) {
        return tiersThresholdsInVinci.length;
    }

    /// @notice Returns the potential tier for a given `balance` of VINCI tokens if evaluated now
    function calculateTier(uint256 vinciBalance) public view returns (uint256) {
        uint256 newTier = 0;
        if (vinciBalance < tiersThresholdsInVinci[0]) {
            return newTier;
        } else {
            for (uint256 _tier = 1; _tier <= tiersThresholdsInVinci.length; _tier++) {
                if (vinciBalance >= tiersThresholdsInVinci[_tier - 1]) {
                    newTier = _tier;
                }
            }
            return newTier;
        }
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    // Management functions

    /// @notice Allows a specific role to update the tier threholds in VINCI
    /// @dev    The contract owner will execute this periodically to follow the vinci price in usd
    ///         emits {TiersThresholdsUpdated} event
    ///         only owner can execute
    function updateTierThresholds(uint256[] memory thresholds) external onlyRole(TIER_MANAGER_ROLE) {
        require(thresholds.length > 0, "input at least one threshold");
        delete tiersThresholdsInVinci;
        for (uint256 t = 1; t < thresholds.length; t++) {
            require(thresholds[t] > thresholds[t - 1], "thresholds should be sorted ascending");
        }
        tiersThresholdsInVinci = thresholds;
        emit TiersThresholdsUpdated(thresholds);
    }

    ///////////////////////////////////////////////////////////////////////////////
    // Internal functions
    // todo this function has not been tested in onlytiers.t.sol because it
    function _setTier(address _user, uint256 _newTier) internal {
        if (_newTier != userTier[_user]) {
            userTier[_user] = _newTier;
            emit TierSet(_user, _newTier);
        }
    }
}
