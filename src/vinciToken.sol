// SPDX-License-Identifier: MIT
pragma solidity >=0.8.9 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Vinci is ERC20, Ownable {
    // @dev Struct to hold how many tokens are due to an address at the specified time

    struct TimeLock {
        uint256 amount;
        uint128 releaseTime;
        bool claimed;
    }

    struct VestingSchedule {
        TimeLock[] timelocks;
    }

    uint256 public freeSupply;

    mapping(address => uint256) public totalClaimed;
    mapping(address => TimeLock[]) public timeLocks;

    constructor() ERC20("Vinci", "VINCI") {
        _mint(address(this), 200 * 500 * 10 ** 6 * 10 ** 18);
        freeSupply = totalSupply();
    }

    event TokensLocked(address indexed beneficiary, uint256 amount, uint256 releaseTime);

    event TokensClaimed(address indexed beneficiary, uint256 amount, uint256 releaseTime);

    /**
     * @dev Withdraw tokens from contract
     *
     * Withdraw unlocked tokens from contract.
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     */
    function withdraw(address recipient, uint256 amount) public onlyOwner {
        require(amount <= freeSupply, "amount exceeds free supply");
        _transfer(address(this), recipient, amount);
        freeSupply -= amount;
    }

    // Deprecated in favor of setVestingSchedule
    // Locks the given amounts of tokens for the given users, to be released at the given times (by claiming)
    function batchLockTo(address[] calldata users, uint256[][] calldata amounts, uint256[][] calldata releaseTimes)
        external
        onlyOwner
    {
        require(users.length == amounts.length, "users and amounts must be the same length");
        require(users.length == releaseTimes.length, "users and releaseTimes must be the same length");

        uint256 totalAmount;

        for (uint256 i = 0; i < users.length; i++) {
            require(
                amounts[i].length == releaseTimes[i].length,
                "amounts and releaseTimes must be the same length for each user"
            );
            for (uint256 j = 0; j < amounts[i].length; j++) {
                timeLocks[users[i]].push(TimeLock(amounts[i][j], uint128(releaseTimes[i][j]), false));
                emit TokensLocked(users[i], amounts[i][j], releaseTimes[i][j]);
                totalAmount += amounts[i][j];
            }
        }
        freeSupply -= totalAmount;
    }

    // Claims all unlocked tokens for the given user
    function claim() external {
        address user = msg.sender;
        TimeLock[] storage userTimeLocks = timeLocks[user];
        uint256 total = 0;

        // this saves gas
        uint256 length = userTimeLocks.length;

        for (uint256 i = 0; i < length; i++) {
            TimeLock storage timeLock = userTimeLocks[i];

            if (timeLock.releaseTime <= block.timestamp && timeLock.amount > 0) {
                uint256 amount = timeLock.amount;
                total += amount;
                timeLock.claimed = true;
                emit TokensClaimed(user, amount, timeLock.releaseTime);
            }
        }

        totalClaimed[user] += total;
        _transfer(address(this), user, total);
    }

    // set vestings of individual users
    function setVestingSchedule(address user, TimeLock[] calldata vestings) external onlyOwner {
        uint256 total;
        uint256 numberOfVestings = vestings.length;
        for (uint256 i = 0; i < numberOfVestings; i++) {
            timeLocks[user].push(vestings[i]);
            emit TokensLocked(user, vestings[i].amount, vestings[i].releaseTime);
            total += vestings[i].amount;
        }
        // only change storage variable once
        freeSupply -= total;
    }

    function batchVestingSchedule(address[] calldata investors, VestingSchedule[] calldata vestings)
        external
        onlyOwner
    {
        // in this function, the list of investors shares the same vestings
        require(investors.length == vestings.length, "lengths must match");
        // save it here to not modify constantly the storage variable and save gas
        uint256 totalBatchVested;

        for (uint256 a = 0; a < investors.length; a++) {
            TimeLock[] memory investorTimelocks = vestings[a].timelocks;
            for (uint256 i = 0; i < investorTimelocks.length; i++) {
                timeLocks[investors[a]].push(investorTimelocks[i]);
                emit TokensLocked(investors[a], investorTimelocks[i].amount, investorTimelocks[i].releaseTime);
                totalBatchVested += investorTimelocks[i].amount;
            }
        }
        // only modify storage variable once
        freeSupply -= totalBatchVested;
    }

    // view functions

    function getNumberOfTimelocks(address user) public view returns (uint256) {
        return timeLocks[user].length;
    }

    function readTimelock(address user, uint256 index) public view returns (TimeLock memory) {
        return timeLocks[user][index];
    }

    // returns the sum of all expired timeLocks
    function getTotalVestedTokens(address user) public view returns (uint256) {
        uint256 total = 0;
        uint256 length = timeLocks[user].length;
        for (uint256 i = 0; i < length; i++) {
            if ((timeLocks[user][i].releaseTime <= block.timestamp)) {
                total += timeLocks[user][i].amount;
            }
        }
        return total;
    }

    // gets the sum of all non-expired timeLocks
    function getTotalUnVestedTokens(address user) public view returns (uint256) {
        uint256 total = 0;
        uint256 length = timeLocks[user].length;
        for (uint256 i = 0; i < length; i++) {
            if (timeLocks[user][i].releaseTime > block.timestamp) {
                total += timeLocks[user][i].amount;
            }
        }
        return total;
    }
}
