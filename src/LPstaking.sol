// SPDX-License-Identifier: MIT
pragma solidity >=0.8.14 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

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

/**
 * @title  Simple staking pool for PancakeSwap LP tokens
 * @author VINCI
 * @notice This contract is meant to be used to incentive
 *         liquidity provision by distributing Vinci.
 */
contract VinciLPStaking is AccessControl {
    bytes32 public constant PRICE_FEEDER_ROLE = keccak256("PRICE_FEEDER_ROLE");

    /// vinci contract
    ERC20 private vinciToken;

    /// LP contract (given after liquidity pool is created)
    ERC20 private lpToken;

    struct Stake {
        // uint128 is enough and allows for packing
        uint128 releaseTime;
        uint64 monthsLocked;
        bool withdrawn;
        uint256 amount;
        uint256 weeklyVinciRewardsPerLPclaimed;
        uint256 finalVinciRewardsPerLPclaimed;
    }

    /// Vinci per LP token. How many Vinci do I get for one (complete) LP token
    // vinci comes with all decimals, while LP not
    uint256 public LPpriceInVinci;

    // stakings of each user are stored as a list of Stake[] structs
    mapping(address => Stake[]) public stakes;

    /// Remaining VINCI tokens used exclusively for staking rewards
    uint256 public fundsForStakingRewards;
    uint256 public fundsForInstantPayouts;

    /// total staked LP contracts in the contract. This is used everytime the distributeAPR() is called (weekly)
    uint256 public totalStakedLPTokens;
    // number of APR distributions. We keep track of this in case we miss a week, that rewards are not lost
    uint256 internal numberOfDistributionsCompleted;
    // If the division of the totalStakedLPTokens and the weekly rewards is not exact, we buffer the decimals
    uint256 public bufferedDecimals;

    // This is how many VINCI tokens corresponds to one LP token in terms of rewards.
    // This will be constantly updated every time the APR is distributed
    // Deppending on the number of months locked, the rewards will be split differently between weekly and final payouts
    uint256 vinciRewardsPerLP;
    // the constructor will set these values. But for each number of months, the sum of weekly and final should be 100%
    mapping(uint256 => uint256) public weeklyMultiplier;
    mapping(uint256 => uint256) public finalMultiplier;
    // Depending on the number of months, the instant payout at stake will be different
    mapping(uint256 => uint256) public instantPayoutMultiplier;
    // Used for all calculations that need percentages and shares (payouts)
    uint256 internal constant BASIS_POINTS = 10000;

    // TODO: update the weelky rewards with real numbers
    uint256 public constant WEEKLY_VINCI_REWARDS = 3_000_000 ether;
    // We use a reference time to track the number of weeks since inception
    // We hardcode the launch date as the reference time is: 31 May 2023 02:00:00 GMT+02:00.
    // TODO: review this reference time if the launch date is postponed
    uint256 public rewardsReferenceStartingTime = 1685491200;

    event Staked(address indexed staker, uint256 _amount, uint64 _monthsLocked);
    event Unstaked(address indexed staker, uint256 _amount);
    event APRDistributed(uint256 _distributionCounter, uint256 vinciDistributed);
    event NonClaimedRewardsReceived(address indexed staker, uint256 _missingClaims);
    event InstantPayoutInVinci(address indexed staker, uint256 _amount);
    event FundedInstantPayoutsBalance(address indexed staker, uint256 _amount);
    event FundedStakingRewardsBalance(address indexed staker, uint256 _amount);
    event InsufficientVinciForInstantPayout(address indexed staker, uint256 correspondingPayout, uint256 missedPayout);
    event NotEnoughVinciFundsForRewards(address indexed staker, uint256 correspondingPayout, uint256 missedPayout);
    event RewardsClaimReceived(address indexed staker, uint256 _amount);
    event NotVinciFundsToDistributeAPR();

    error APRDistributionTooSoon();
    error UnsupportedNumberOfMonths();
    error InvalidAmount();
    error NonExistingIndex();
    error StakeNotReleased();
    error AlreadyWithdrawnIndex();
    error NoLpTokensStaked();
    error NoRewardsToClaim();
    error InsufficientVinciInLPStakingContract();

    /**
     * @dev   Create a new SimpleLPPool
     * @param vinciContract The address of the Vinci Contract on this chain
     * @param lpContract    The address of a ERC20 compatible contract used as
     *                      a staking token. This can be a LP token.
     */
    constructor(ERC20 vinciContract, ERC20 lpContract) {
        vinciToken = vinciContract;
        lpToken = lpContract;

        // initially the deployer has both roles
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(PRICE_FEEDER_ROLE, _msgSender());

        // nmonths=4 --> all APR given at the end
        weeklyMultiplier[4] = 0;
        finalMultiplier[4] = 10000;
        // nmonths=12 --> 50% APR given on a weekly basis, 50% at the end
        weeklyMultiplier[8] = 5000;
        finalMultiplier[8] = 5000;
        // nmonths=12 --> all APR given on a weekly basis
        weeklyMultiplier[12] = 10000;
        finalMultiplier[12] = 0;

        instantPayoutMultiplier[4] = 50; // == 0.5%
        instantPayoutMultiplier[8] = 150; // == 1.5%
        instantPayoutMultiplier[12] = 500; // == 5%
    }

    /**
     * @notice Create a new stake.
     * @param  amount       Amount to stake
     * @param  monthsLocked Number of months this is supposed to be locked.
     */
    function newStake(uint256 amount, uint64 monthsLocked) external {
        if ((monthsLocked != 4) && (monthsLocked != 8) && (monthsLocked != 12)) revert UnsupportedNumberOfMonths();
        if (amount == 0) revert InvalidAmount();
        address sender = _msgSender();

        // monthsLocked is already capped by uint64 so should be safe of overloads
        uint128 releaseTime = uint128(block.timestamp) + (30 days * monthsLocked);
        // here, the weekly and final are tracked as the same value. It is the responsibility of _getCurrentClaimable()
        // to make the distinction between weekly and final for the different months locked, to make sure amounts are
        // not double counted
        stakes[sender].push(Stake(releaseTime, monthsLocked, false, amount, vinciRewardsPerLP, vinciRewardsPerLP));

        // these are useful to calculate APR rewards
        totalStakedLPTokens += amount;

        // For low amount of LP tokens this Division will return 0 due to lack of decimals in solidity. No payout
        uint256 vinciInstantPayout = (amount * LPpriceInVinci * instantPayoutMultiplier[monthsLocked])
            / (10 ** vinciToken.decimals() * BASIS_POINTS);

        if (vinciInstantPayout > fundsForInstantPayouts) {
            uint256 missedPayout = vinciInstantPayout - fundsForInstantPayouts;
            emit InsufficientVinciForInstantPayout(sender, vinciInstantPayout, missedPayout);
            vinciInstantPayout = fundsForInstantPayouts;
        }

        emit Staked(sender, amount, monthsLocked);
        require(lpToken.transferFrom(sender, address(this), amount), "LP transfer failed");

        // instant payout is available FCFS. But after that, staking is still possible
        emit InstantPayoutInVinci(sender, vinciInstantPayout);
        if (vinciInstantPayout > 0) {
            fundsForInstantPayouts -= vinciInstantPayout;
            require(vinciToken.transfer(sender, vinciInstantPayout), "VINCI payout transfer failed");
        }
    }

    /// @notice Claim staking rewards from a stake. Each stake has to be claimed individually
    function claimRewards(uint256 stakeIndex) external {
        address sender = msg.sender;
        if (stakeIndex > stakes[sender].length - 1) revert NonExistingIndex();
        if (stakes[sender][stakeIndex].withdrawn) revert AlreadyWithdrawnIndex();

        uint256 claimableNow = _getCurrentClaimable(sender, stakeIndex);
        if (claimableNow == 0) revert NoRewardsToClaim();

        // resets the rewawrds trackers to the current vinci RewardsPerLP
        stakes[sender][stakeIndex].weeklyVinciRewardsPerLPclaimed = vinciRewardsPerLP;
        // The final is only reset if the claim happens with a released stake.
        if (stakes[sender][stakeIndex].releaseTime < block.timestamp) {
            stakes[sender][stakeIndex].finalVinciRewardsPerLPclaimed = vinciRewardsPerLP;
        }

        _sendStakingRewards(sender, claimableNow);
        emit RewardsClaimReceived(sender, claimableNow);
    }

    /// @notice Withdraw a staked amount after the lock time has expired
    function withdrawStake(uint256 stakeIndex) external {
        address sender = _msgSender();

        if (stakeIndex > stakes[sender].length - 1) revert NonExistingIndex();
        if (stakes[sender][stakeIndex].withdrawn) revert AlreadyWithdrawnIndex();
        if (stakes[sender][stakeIndex].releaseTime > block.timestamp) revert StakeNotReleased();

        uint256 stakedLPAmount = stakes[sender][stakeIndex].amount;
        uint256 missingClaims = _getCurrentClaimable(sender, stakeIndex);

        // Here we avoid future reward claims and double withdrawns
        stakes[sender][stakeIndex].weeklyVinciRewardsPerLPclaimed = vinciRewardsPerLP;
        stakes[sender][stakeIndex].finalVinciRewardsPerLPclaimed = vinciRewardsPerLP;
        stakes[sender][stakeIndex].withdrawn = true;

        totalStakedLPTokens -= stakedLPAmount;

        emit Unstaked(sender, stakedLPAmount);
        require(lpToken.transfer(sender, stakedLPAmount), "LP tokens transfer failed");

        // The event needs to come after _sendVinci because the later corrects for missing funds and missed payouts
        _sendStakingRewards(sender, missingClaims);
        emit NonClaimedRewardsReceived(sender, missingClaims);
    }

    ////////////////////////////////////////////////////////////////////////////////////
    // Management functions

    /**
     * @notice Set the amount of vinci equivalent to an LP token.
     *         Decimals need to be the decimals of the Vinci Token.
     *         I.e. If the price of an LP is 0.2 VINCI,
     *         the amount to input should be 0.2 * (10 ** <decimals of Vinci>).
     * @param _newPrice The amount of Vinci per LP token.
     */
    function setLPPriceInVinci(uint256 _newPrice) external onlyRole(PRICE_FEEDER_ROLE) {
        LPpriceInVinci = _newPrice;
    }

    /// @notice Enables Vinci deposits to the contract, to be used exclusively for instant payouts
    function addVinciForInstantPayouts(uint256 amount) external {
        fundsForInstantPayouts += amount;
        emit FundedInstantPayoutsBalance(msg.sender, amount);
        require(vinciToken.transferFrom(msg.sender, address(this), amount), "VINCI Transfer failed");
    }

    /// @notice Enables Vinci deposits to the contract, to be used exclusively for staking rewards
    function addVinciForStakingRewards(uint256 amount) external {
        fundsForStakingRewards += amount;
        emit FundedStakingRewardsBalance(msg.sender, amount);
        require(vinciToken.transferFrom(msg.sender, address(this), amount), "VINCI Transfer failed");
    }

    /// @dev    even though VINCI will take care of calling this function, any wallet could do it
    function distributeWeeklyAPR() external {
        // ignore decimals for this check. Only distribute if the current fundsForStakingRewards is > weekly
        if (fundsForStakingRewards < WEEKLY_VINCI_REWARDS) revert InsufficientVinciInLPStakingContract();

        // Save totalStaked to save gas
        uint256 totalStaked = totalStakedLPTokens;
        if (totalStaked == 0) revert NoLpTokensStaked();

        // we track the number of weeks since the reference date
        // this way of tracking APR distributions allows for two in a row if we miss one
        uint256 targetDistributions = (block.timestamp - rewardsReferenceStartingTime) / (1 weeks);
        if (numberOfDistributionsCompleted >= targetDistributions) revert APRDistributionTooSoon();

        // This controls how much vinci per LP token
        uint256 weeklyVinciDistribution = WEEKLY_VINCI_REWARDS + bufferedDecimals;
        uint256 rewardsPerLPToken = weeklyVinciDistribution / totalStaked;
        bufferedDecimals = weeklyVinciDistribution % totalStaked;
        numberOfDistributionsCompleted += 1;

        if (rewardsPerLPToken == 0) {
            emit NotVinciFundsToDistributeAPR();
            return;
        }

        // here we add it to both
        vinciRewardsPerLP += rewardsPerLPToken;
        // keep track of spent funds in rewards
        fundsForStakingRewards -= rewardsPerLPToken * totalStaked;

        emit APRDistributed(numberOfDistributionsCompleted, rewardsPerLPToken * totalStaked);
    }

    /// ==================================================================
    ///                         READ FUNCTIONS
    /// ==================================================================
    function getUserTotalStaked(address staker) external view returns (uint256) {
        uint256 totalStaked;
        uint256 nStakes = stakes[staker].length;
        for (uint256 index = 0; index < nStakes; index++) {
            totalStaked += stakes[staker][index].amount;
        }
        return totalStaked;
    }

    function readCurrentClaimable(address staker, uint256 stakeIndex) external view returns (uint256) {
        return _getCurrentClaimable(staker, stakeIndex);
    }

    function readTotalCurrentClaimable(address staker) external view returns (uint256) {
        uint256 total;
        uint256 nStakes = stakes[staker].length;
        for (uint256 index = 0; index < nStakes; index++) {
            total += _getCurrentClaimable(staker, index);
        }
        return total;
    }

    /// @notice returns the amount of vinci that can be claimed from a stake once it is released
    /// @dev    If the stake has been already withdrawn, it returns 0
    function readFinalPayout(address staker, uint256 stakeIndex) external view returns (uint256) {
        if (stakes[staker][stakeIndex].withdrawn) return 0;
        return finalMultiplier[stakes[staker][stakeIndex].monthsLocked] * stakes[staker][stakeIndex].amount
            * (vinciRewardsPerLP - stakes[staker][stakeIndex].finalVinciRewardsPerLPclaimed) / BASIS_POINTS;
    }

    function getNumberOfStakes(address owner) public view returns (uint256) {
        return stakes[owner].length;
    }

    function getStakeAmount(address owner, uint256 stakeIndex) public view returns (uint256) {
        return stakes[owner][stakeIndex].amount;
    }

    function getStakeReleaseTime(address owner, uint256 stakeIndex) public view returns (uint128) {
        return stakes[owner][stakeIndex].releaseTime;
    }

    function getStakeMonthsLocked(address owner, uint256 stakeIndex) public view returns (uint64) {
        return stakes[owner][stakeIndex].monthsLocked;
    }

    /// @dev    This allows to read the entire Stake struct instead of individual fields
    function readStake(address staker, uint256 stakeIndex) external view returns (Stake memory) {
        return stakes[staker][stakeIndex];
    }

    ///////////////////////////////////////////////////////////////////////////////////////////
    // internal functions

    function _getCurrentClaimable(address staker, uint256 stakeIndex) internal view returns (uint256) {
        if (stakes[staker][stakeIndex].withdrawn) {
            return 0;
        }

        // save stake in memory to save gas
        Stake memory stake = stakes[staker][stakeIndex];

        uint256 claimable;

        if (weeklyMultiplier[stake.monthsLocked] > 0) {
            claimable += stake.amount * (vinciRewardsPerLP - stake.weeklyVinciRewardsPerLPclaimed)
                * weeklyMultiplier[stake.monthsLocked] / BASIS_POINTS;
        }
        // if the stake is unlocked, the final payout is also claimable
        if ((finalMultiplier[stake.monthsLocked] > 0) && (stake.releaseTime < block.timestamp)) {
            claimable += stake.amount * (vinciRewardsPerLP - stake.finalVinciRewardsPerLPclaimed)
                * finalMultiplier[stake.monthsLocked] / BASIS_POINTS;
        }
        return claimable;
    }

    function _sendStakingRewards(address to, uint256 amount) internal {
        // There should always be enough funds to pay the rewards, because the distributeAPR function only distributes
        // if there are funds available
        fundsForStakingRewards -= amount;
        require(vinciToken.transfer(to, amount));
    }
}
