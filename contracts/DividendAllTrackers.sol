// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

error DividendAllTrackerUnauthorized();
error DividendAllTrackerAlreadyExcluded();
error DividendAllTrackerNotExcluded();
error DividendAllTrackerNoSupply();
error DividendAllTrackerIndexOutOfBounds();
error DividendAllTrackerMinHoldingMustBePositive();
error DividendAllTrackerZeroAddress();
error DividendAllTrackerInvalidRewardToken();
error DividendAllTrackerInsufficientRewards();
error DividendAllTrackerUnsupportedRewardToken();

interface IERC20DividendReward {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

abstract contract DividendAllBaseTracker {
    enum PayoutStatus {
        SKIP,
        PAID,
        BREAK
    }

    address public immutable token;
    address public tokenOwner;

    uint256 internal constant magnitude = 2**96;

    mapping(address => int256) internal magnifiedDividendCorrections;
    mapping(address => uint256) internal withdrawnDividends;

    uint256 public totalDividendsDistributed;
    uint256 public magnifiedDividendPerShare;
    uint256 public minHoldingForDividend;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    mapping(address => bool) public excludedFromDividends;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) private holderIndex;
    address[] private holders;
    uint256 public lastProcessedIndex;

    uint256 public totalSupply;

    event DividendsDistributed(address indexed from, uint256 amount);
    event DividendWithdrawn(address indexed to, uint256 amount);
    event MinHoldingUpdated(uint256 oldValue, uint256 newValue);
    event ExcludedFromDividends(address indexed account, bool excluded);

    modifier onlyToken() {
        if (msg.sender != token) revert DividendAllTrackerUnauthorized();
        _;
    }

    modifier onlyTokenOwner() {
        if (msg.sender != tokenOwner && msg.sender != token) revert DividendAllTrackerUnauthorized();
        _;
    }

    constructor(
        address _token,
        address _tokenOwner,
        address _mainPair,
        address _receiveAddress,
        address _swapRouter,
        uint256 _minHoldingForDividend
    ) {
        if (
            _token == address(0)
            || _tokenOwner == address(0)
            || _mainPair == address(0)
            || _receiveAddress == address(0)
            || _swapRouter == address(0)
        ) revert DividendAllTrackerZeroAddress();
        if (_minHoldingForDividend == 0) revert DividendAllTrackerMinHoldingMustBePositive();

        token = _token;
        tokenOwner = _tokenOwner;
        minHoldingForDividend = _minHoldingForDividend;

        excludedFromDividends[DEAD] = true;
        excludedFromDividends[_token] = true;
        excludedFromDividends[_mainPair] = true;
        excludedFromDividends[_swapRouter] = true;
        excludedFromDividends[address(this)] = true;
    }

    function setMinHoldingForDividend(uint256 newMinHolding) external onlyToken {
        if (newMinHolding == 0) revert DividendAllTrackerMinHoldingMustBePositive();
        uint256 oldValue = minHoldingForDividend;
        minHoldingForDividend = newMinHolding;
        emit MinHoldingUpdated(oldValue, newMinHolding);
    }

    function excludeFromDividends(address account) external onlyTokenOwner {
        if (excludedFromDividends[account]) revert DividendAllTrackerAlreadyExcluded();
        excludedFromDividends[account] = true;

        if (balanceOf[account] > 0) {
            _setBalance(account, 0);
        }
        emit ExcludedFromDividends(account, true);
    }

    function includeInDividends(address account) external onlyTokenOwner {
        if (!excludedFromDividends[account]) revert DividendAllTrackerNotExcluded();
        excludedFromDividends[account] = false;
        emit ExcludedFromDividends(account, false);
    }

    function distributeDividends(uint256 amount) external onlyToken {
        if (amount == 0) return;
        if (totalSupply == 0) revert DividendAllTrackerNoSupply();

        _beforeDistribute(amount);

        magnifiedDividendPerShare += (amount * magnitude) / totalSupply;
        totalDividendsDistributed += amount;

        emit DividendsDistributed(msg.sender, amount);
    }

    function setBalance(address account, uint256 newBalance) external onlyToken {
        if (excludedFromDividends[account]) return;
        if (newBalance < minHoldingForDividend) newBalance = 0;

        uint256 oldBalance = balanceOf[account];
        if (oldBalance == newBalance) return;

        _setBalance(account, newBalance);
    }

    function withdrawableDividendOf(address account) public view returns (uint256) {
        return _accumulativeDividendOf(account) - withdrawnDividends[account];
    }

    function withdrawnDividendOf(address account) external view returns (uint256) {
        return withdrawnDividends[account];
    }

    function getAccount(address account) external view returns (uint256 withdrawable, uint256 withdrawn) {
        withdrawable = withdrawableDividendOf(account);
        withdrawn = withdrawnDividends[account];
    }

    function process(uint256 gasLimit) external onlyToken returns (uint256 processed) {
        uint256 effectiveGas = gasLimit == 0 ? 100000 : gasLimit;
        uint256 len = holders.length;
        if (len == 0) return 0;

        uint256 gasUsed;
        uint256 gasLeft = gasleft();
        uint256 iterations;
        uint256 index = lastProcessedIndex;

        while (gasUsed < effectiveGas && iterations < len) {
            unchecked {
                index++;
                if (index >= len) index = 0;
            }

            address account = holders[index];
            uint256 withdrawable = withdrawableDividendOf(account);

            if (withdrawable > 0) {
                PayoutStatus status = _processAccountDividend(account, withdrawable);
                if (status == PayoutStatus.BREAK) break;
                if (status == PayoutStatus.PAID) {
                    withdrawnDividends[account] += withdrawable;
                    _afterSuccessfulPayout(account);
                    processed++;
                    emit DividendWithdrawn(account, withdrawable);
                }
            }

            iterations++;
            uint256 newGasLeft = gasleft();
            if (gasLeft > newGasLeft) {
                unchecked {
                    gasUsed += gasLeft - newGasLeft;
                }
            }
            gasLeft = newGasLeft;
        }

        lastProcessedIndex = index;
    }

    function setTokenOwner(address newTokenOwner) external onlyToken {
        tokenOwner = newTokenOwner;
    }

    function getHolderAt(uint256 index) external view returns (address) {
        if (index >= holders.length) revert DividendAllTrackerIndexOutOfBounds();
        return holders[index];
    }

    function getHoldersCount() external view returns (uint256) {
        return holders.length;
    }

    function _accumulativeDividendOf(address account) internal view returns (uint256) {
        if (excludedFromDividends[account]) return 0;
        if (balanceOf[account] < minHoldingForDividend) return withdrawnDividends[account];

        int256 accumulative = int256(balanceOf[account] * magnifiedDividendPerShare)
            - magnifiedDividendCorrections[account];

        if (accumulative < 0) return withdrawnDividends[account];
        return uint256(accumulative) / magnitude;
    }

    function _setBalance(address account, uint256 newBalance) internal {
        uint256 oldBalance = balanceOf[account];
        balanceOf[account] = newBalance;

        if (oldBalance > 0) {
            magnifiedDividendCorrections[account] -= int256(oldBalance * magnifiedDividendPerShare);
            _removeHolder(account);
        }
        if (newBalance > 0) {
            magnifiedDividendCorrections[account] += int256(newBalance * magnifiedDividendPerShare);
            _addHolder(account);
        }

        totalSupply = totalSupply - oldBalance + newBalance;
    }

    function _addHolder(address account) internal {
        if (holderIndex[account] == 0) {
            holders.push(account);
            holderIndex[account] = holders.length;
        }
    }

    function _removeHolder(address account) internal {
        uint256 index = holderIndex[account];
        if (index == 0) return;

        uint256 lastIndex = holders.length;
        if (index != lastIndex) {
            address lastHolder = holders[lastIndex - 1];
            holders[index - 1] = lastHolder;
            holderIndex[lastHolder] = index;
        }
        holders.pop();
        holderIndex[account] = 0;
    }

    function _beforeDistribute(uint256 amount) internal view virtual {}

    function _afterSuccessfulPayout(address account) internal virtual {}

    function _processAccountDividend(address account, uint256 amount)
        internal
        virtual
        returns (PayoutStatus);
}

contract SameTokenDividendTracker is DividendAllBaseTracker {
    constructor(
        address _token,
        address _tokenOwner,
        address _mainPair,
        address _receiveAddress,
        address _swapRouter,
        uint256 _minHoldingForDividend
    )
        DividendAllBaseTracker(
            _token,
            _tokenOwner,
            _mainPair,
            _receiveAddress,
            _swapRouter,
            _minHoldingForDividend
        )
    {}

    function _processAccountDividend(address account, uint256 amount)
        internal
        override
        returns (PayoutStatus)
    {
        (bool success,) = token.call(
            abi.encodeWithSignature("transferDividend(address,uint256)", account, amount)
        );
        return success ? PayoutStatus.PAID : PayoutStatus.SKIP;
    }

    function _afterSuccessfulPayout(address account) internal override {
        uint256 oldTrackedBalance = balanceOf[account];
        if (oldTrackedBalance == 0) return;

        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("balanceOf(address)", account)
        );
        if (!success || data.length < 32) return;

        uint256 newTrackedBalance = abi.decode(data, (uint256));
        if (newTrackedBalance <= oldTrackedBalance) return;

        uint256 delta = newTrackedBalance - oldTrackedBalance;
        balanceOf[account] = newTrackedBalance;
        magnifiedDividendCorrections[account] += int256(delta * magnifiedDividendPerShare);
        totalSupply += delta;
    }
}

contract RewardTokenDividendTracker is DividendAllBaseTracker {
    address public immutable rewardToken;

    constructor(
        address _token,
        address _tokenOwner,
        address _rewardToken,
        address _mainPair,
        address _receiveAddress,
        address _swapRouter,
        uint256 _minHoldingForDividend
    )
        DividendAllBaseTracker(
            _token,
            _tokenOwner,
            _mainPair,
            _receiveAddress,
            _swapRouter,
            _minHoldingForDividend
        )
    {
        if (_rewardToken == address(0)) revert DividendAllTrackerZeroAddress();
        if (_rewardToken == _token) revert DividendAllTrackerInvalidRewardToken();
        rewardToken = _rewardToken;
    }

    function rewardBalance() external view returns (uint256) {
        return _rewardBalance();
    }

    function _beforeDistribute(uint256 amount) internal view override {
        if (_rewardBalance() < amount) revert DividendAllTrackerInsufficientRewards();
    }

    function _processAccountDividend(address account, uint256 amount)
        internal
        override
        returns (PayoutStatus)
    {
        if (_rewardBalance() < amount) return PayoutStatus.BREAK;
        if (_safeRewardTransfer(account, amount)) return PayoutStatus.PAID;
        return PayoutStatus.SKIP;
    }

    function _rewardBalance() internal view returns (uint256) {
        return IERC20DividendReward(rewardToken).balanceOf(address(this));
    }

    function _safeRewardTransfer(address to, uint256 amount) internal returns (bool) {
        uint256 trackerBefore = _rewardBalance();
        uint256 recipientBefore = IERC20DividendReward(rewardToken).balanceOf(to);

        (bool success, bytes memory data) = rewardToken.call(
            abi.encodeWithSelector(IERC20DividendReward.transfer.selector, to, amount)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            return false;
        }

        uint256 trackerAfter = _rewardBalance();
        uint256 recipientAfter = IERC20DividendReward(rewardToken).balanceOf(to);

        if (trackerBefore < trackerAfter || trackerBefore - trackerAfter != amount) {
            revert DividendAllTrackerUnsupportedRewardToken();
        }
        if (recipientAfter < recipientBefore || recipientAfter - recipientBefore != amount) {
            revert DividendAllTrackerUnsupportedRewardToken();
        }

        return true;
    }
}
