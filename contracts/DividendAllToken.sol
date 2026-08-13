// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
/*

     $$$$$$\  $$\                      $$$$$$\        $$$$$$$$\                  $$\           
    $$  __$$\ $$ |                    $$  __$$\       \__$$  __|                 $$ |          
    $$ /  \__|$$ | $$$$$$\   $$$$$$\  $$ /  \__|         $$ | $$$$$$\   $$$$$$\  $$ | $$$$$$$\ 
    \$$$$$$\  $$ |$$  __$$\ $$  __$$\ $$$$\              $$ |$$  __$$\ $$  __$$\ $$ |$$  _____|
     \____$$\ $$ |$$$$$$$$ |$$ |  \__|$$  _|             $$ |$$ /  $$ |$$ /  $$ |$$ |\$$$$$$\  
    $$\   $$ |$$ |$$   ____|$$ |      $$ |               $$ |$$ |  $$ |$$ |  $$ |$$ | \____$$\ 
    \$$$$$$  |$$ |\$$$$$$$\ $$ |      $$ |               $$ |\$$$$$$  |\$$$$$$  |$$ |$$$$$$$  |
     \______/ \__| \_______|\__|      \__|               \__| \______/  \______/ \__|\_______/ 
                                                                                                                                                                                 
*/

// @author Slerf Tools
import "./DividendAllTrackers.sol";

error ZeroAddress();
error NotOwner();
error Unauthorized();
error InsufficientBalance();
error InsufficientAllowance();
error Blacklisted();
error TradingNotEnabled();
error TaxRateTooHigh();
error TaxTotalTooHigh();
error SetMinHoldingFailed();
error FundDead();
error CanOnlySetWhenTradingClosed();
error InvalidState();
error IndexOutOfBounds();
error MintNotEnabled();
error MintAmountExceedsCap();
error MinHoldingMustBePositive();
error ProtectedAddress();
error ListTooLong();
error DecimalsOverflow();
error ZeroSupply();
error InvalidDividendToken();
error RewardQuoteFailed(bytes reason);
error RewardSwapFailed(bytes reason);
error RewardDistributionFailed(bytes reason);
error RewardProcessFailed(bytes reason);

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface ISwapRouter {
    function factory() external view returns (address);
    function WETH() external view returns (address);
}

interface IRewardSwapRouter is ISwapRouter {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface ISwapFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface ISwapPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
}

abstract contract DividendAllOwnable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        _transferOwnership(msg.sender);
    }

    modifier onlyOwner() {
        if (_owner != msg.sender) revert NotOwner();
        _;
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        _transferOwnership(newOwner);
    }

    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

contract DividendAllToken is IERC20, DividendAllOwnable {
    mapping(address => uint256) public _rOwned;
    mapping(address => mapping(address => uint256)) private _allowances;

    string private _name;
    string private _symbol;
    uint8 private _decimals;
    uint256 private _tTotal;
    uint256 private _rTotal;

    address public fundAddress;
    address public receiveAddress;
    address public swapRouter;
    address public mainPair;
    address public basePoolToken;

    bool public isSameTokenDividend;
    address public dividendToken;
    DividendAllBaseTracker public dividendTracker;

    SameTokenDividendTracker private _sameTokenTracker;
    RewardTokenDividendTracker private _rewardTokenTracker;

    uint256 public buyFundFee;
    uint256 public buyLPFee;
    uint256 public buyBurnFee;
    uint256 public buyDividendFee;
    uint256 public sellFundFee;
    uint256 public sellLPFee;
    uint256 public sellBurnFee;
    uint256 public sellDividendFee;
    uint256 public transferFundFee;
    uint256 public transferLPFee;
    uint256 public transferBurnFee;
    uint256 public transferDividendFee;

    mapping(address => bool) public _swapPairList;
    mapping(address => bool) public whitelist;
    mapping(address => bool) public blacklist;
    bool public blacklistEnabled;
    bool public whitelistEnabled;
    address[] private _blacklistAddresses;
    address[] private _whitelistAddresses;
    mapping(address => uint256) private _blacklistIndex;
    mapping(address => uint256) private _whitelistIndex;

    bool public tradingEnabled;
    bool public manualTradingEnable;
    uint256 public killBlockCount;
    uint256 public tradingEnabledBlock;

    bool public mintEnabled;
    uint256 public initialSupply;
    uint256 public totalMinted;
    uint256 public minHoldingForDividend;
    uint256 public pendingDividends;
    uint256 public dividendTriggerThreshold;
    uint256 public autoProcessGasLimit;
    bool private inSwap;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant RATE_PRECISION = 10**18;
    uint256 private constant AUTO_PROCESS_GAS_BUFFER = 50000;
    uint256 private constant BPS_DENOMINATOR = 10000;
    uint256 public constant MAX_LIST_LENGTH = 100;
    uint256 public constant DEFAULT_REWARD_SWAP_SLIPPAGE_BPS = 500;
    uint256 public constant MAX_REWARD_SWAP_SLIPPAGE_BPS = 1000;
    string public constant TOKEN_TYPE = "DIVIDEND";
    bytes32 public constant TOKEN_TYPE_HASH = keccak256(bytes(TOKEN_TYPE));
    string public constant TOKEN_VERSION = "v1";
    bytes32 public constant TOKEN_VERSION_HASH = keccak256(bytes(TOKEN_VERSION));

    event DividendModeConfigured(bool indexed isSameTokenDividend, address indexed dividendToken);
    event RewardSwapAndDistribute(uint256 tokenAmount, uint256 rewardAmount);
    event RewardSwapFailedEvent(uint256 tokenAmount, bytes reason);
    event RewardProcessFailedEvent(bytes reason);
    event RewardAutoProcessDeferred(uint256 pendingAmount, address indexed caller);

    modifier onlyTracker() {
        if (msg.sender != address(dividendTracker)) revert Unauthorized();
        _;
    }

    struct CreateParams {
        string name;
        string symbol;
        uint8 decimals;
        uint256 totalSupply;
        address receiveAddress;
        address fundAddress;
        address swapRouter;
        address basePoolToken;
        uint256[4] buyRates;
        uint256[4] sellRates;
        uint256[4] transferRates;
        uint256 minHoldingForDividend;
        uint256 dividendTriggerThreshold;
        uint256 autoProcessGasLimit;
        uint256 killBlockCount;
        bool mintEnabled;
        bool manualTradingEnable;
        bool blacklistEnabled;
        bool whitelistEnabled;
        address[] initialBlacklist;
        address[] initialWhitelist;
        bool isSameTokenDividend;
        address dividendToken;
    }

    constructor(CreateParams memory params) {
        _name = params.name;
        _symbol = params.symbol;
        _decimals = params.decimals;

        if (params.decimals > 18) revert DecimalsOverflow();
        if (params.totalSupply == 0) revert ZeroSupply();
        if (params.minHoldingForDividend == 0) revert MinHoldingMustBePositive();
        if (params.dividendTriggerThreshold == 0) revert InvalidState();
        if (params.autoProcessGasLimit == 0) revert InvalidState();
        if (params.receiveAddress == address(0)) revert ZeroAddress();
        if (params.fundAddress == address(0)) revert ZeroAddress();
        if (params.fundAddress == DEAD) revert FundDead();
        if (params.swapRouter == address(0) || params.basePoolToken == address(0)) revert ZeroAddress();
        if (params.initialBlacklist.length > MAX_LIST_LENGTH || params.initialWhitelist.length > MAX_LIST_LENGTH) {
            revert ListTooLong();
        }

        _tTotal = params.totalSupply * 10**params.decimals;
        _rTotal = _tTotal * RATE_PRECISION;
        initialSupply = _tTotal;

        receiveAddress = params.receiveAddress;
        fundAddress = params.fundAddress;
        swapRouter = params.swapRouter;
        basePoolToken = params.basePoolToken;

        address factory = ISwapRouter(params.swapRouter).factory();
        mainPair = ISwapFactory(factory).getPair(address(this), basePoolToken);
        if (mainPair == address(0)) {
            mainPair = ISwapFactory(factory).createPair(address(this), basePoolToken);
        }
        _swapPairList[mainPair] = true;

        _validateAndSetTaxRates(
            params.buyRates[0], params.buyRates[1], params.buyRates[2], params.buyRates[3],
            params.sellRates[0], params.sellRates[1], params.sellRates[2], params.sellRates[3],
            params.transferRates[0], params.transferRates[1], params.transferRates[2], params.transferRates[3]
        );

        mintEnabled = params.mintEnabled;
        manualTradingEnable = params.manualTradingEnable;
        tradingEnabled = !params.manualTradingEnable;
        if (tradingEnabled) {
            tradingEnabledBlock = block.number;
        }
        blacklistEnabled = params.blacklistEnabled;
        whitelistEnabled = params.whitelistEnabled;
        killBlockCount = params.killBlockCount;
        minHoldingForDividend = params.minHoldingForDividend;
        dividendTriggerThreshold = params.dividendTriggerThreshold;
        autoProcessGasLimit = params.autoProcessGasLimit;

        isSameTokenDividend = params.isSameTokenDividend;
        if (params.isSameTokenDividend) {
            if (params.dividendToken != address(0) && params.dividendToken != address(this)) {
                revert InvalidDividendToken();
            }
            dividendToken = address(this);
            SameTokenDividendTracker tracker = new SameTokenDividendTracker(
                address(this),
                params.receiveAddress,
                mainPair,
                params.receiveAddress,
                params.swapRouter,
                params.minHoldingForDividend
            );
            _sameTokenTracker = tracker;
            dividendTracker = tracker;
        } else {
            if (params.dividendToken == address(0) || params.dividendToken == address(this)) {
                revert InvalidDividendToken();
            }
            dividendToken = params.dividendToken;
            RewardTokenDividendTracker tracker = new RewardTokenDividendTracker(
                address(this),
                params.receiveAddress,
                params.dividendToken,
                mainPair,
                params.receiveAddress,
                params.swapRouter,
                params.minHoldingForDividend
            );
            _rewardTokenTracker = tracker;
            dividendTracker = tracker;
        }

        _rOwned[params.receiveAddress] = _rTotal;
        emit Transfer(address(0), params.receiveAddress, _tTotal);
        dividendTracker.setBalance(params.receiveAddress, balanceOf(params.receiveAddress));

        _transferOwnership(params.receiveAddress);

        _addToWhitelist(params.receiveAddress);
        _addToWhitelist(params.fundAddress);
        _addToWhitelist(address(this));
        _addToWhitelist(mainPair);
        _addToWhitelist(params.swapRouter);

        for (uint256 i = 0; i < params.initialBlacklist.length; i++) {
            if (params.blacklistEnabled && params.initialBlacklist[i] != params.receiveAddress) {
                _addToBlacklist(params.initialBlacklist[i]);
            }
        }
        for (uint256 i = 0; i < params.initialWhitelist.length; i++) {
            if (params.whitelistEnabled) {
                _addToWhitelist(params.initialWhitelist[i]);
            }
        }

        emit DividendModeConfigured(params.isSameTokenDividend, dividendToken);
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        _transferOwnership(newOwner);
        dividendTracker.setTokenOwner(newOwner);
    }

    function renounceOwnership() public override onlyOwner {
        if (manualTradingEnable && !tradingEnabled) {
            tradingEnabled = true;
            tradingEnabledBlock = block.number;
        }
        if (autoProcessGasLimit == 0) revert InvalidState();
        _transferOwnership(address(0));
        dividendTracker.setTokenOwner(address(0));
    }

    function name() public view returns (string memory) { return _name; }

    function symbol() public view returns (string memory) { return _symbol; }

    function decimals() public view returns (uint8) { return _decimals; }

    function totalSupply() public view override returns (uint256) { return _tTotal; }

    function tokenType() external pure returns (string memory) { return TOKEN_TYPE; }

    function tokenTypeHash() external pure returns (bytes32) { return TOKEN_TYPE_HASH; }

    function tokenVersion() external pure returns (string memory) { return TOKEN_VERSION; }

    function tokenVersionHash() external pure returns (bytes32) { return TOKEN_VERSION_HASH; }

    function balanceOf(address account) public view override returns (uint256) {
        return _rOwned[account] / _getRate();
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner_, address spender) public view override returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        if (currentAllowance < amount) revert InsufficientAllowance();
        unchecked {
            _approve(from, msg.sender, currentAllowance - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    function setTaxRates(
        uint256[4] calldata buyRates,
        uint256[4] calldata sellRates,
        uint256[4] calldata transferRates
    ) external onlyOwner {
        _validateAndSetTaxRates(
            buyRates[0], buyRates[1], buyRates[2], buyRates[3],
            sellRates[0], sellRates[1], sellRates[2], sellRates[3],
            transferRates[0], transferRates[1], transferRates[2], transferRates[3]
        );
    }

    function mint(address to, uint256 amount) external onlyOwner {
        if (!mintEnabled) revert MintNotEnabled();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) return;

        uint256 rate = _getRate();
        uint256 rAmount = amount * rate;
        _tTotal += amount;
        _rTotal += rAmount;
        _rOwned[to] += rAmount;
        totalMinted += amount;

        emit Transfer(address(0), to, amount);

        dividendTracker.setBalance(to, balanceOf(to));
    }

    function disableMintForever() external onlyOwner {
        if (!mintEnabled) revert InvalidState();
        mintEnabled = false;
    }

    function setFundAddress(address addr) external onlyOwner {
        if (addr == address(0)) revert ZeroAddress();
        if (addr == DEAD) revert FundDead();
        address oldFund = fundAddress;
        fundAddress = addr;
        if (oldFund != addr) {
            if (oldFund != receiveAddress) _removeFromWhitelist(oldFund);
            _addToWhitelist(addr);
        }
    }

    function setMinHoldingForDividend(uint256 amount) external onlyOwner {
        if (amount == 0) revert MinHoldingMustBePositive();
        try dividendTracker.setMinHoldingForDividend(amount) {} catch { revert SetMinHoldingFailed(); }
        minHoldingForDividend = amount;
    }

    function setDividendTriggerThreshold(uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidState();
        dividendTriggerThreshold = amount;
    }

    function setAutoProcessGasLimit(uint256 gasLimit) external onlyOwner {
        if (gasLimit == 0) revert InvalidState();
        autoProcessGasLimit = gasLimit;
    }

    function setBlacklistEnabled(bool enabled) external onlyOwner {
        if (enabled) revert InvalidState();
        blacklistEnabled = false;
    }

    function setWhitelistEnabled(bool enabled) external onlyOwner {
        if (enabled) revert InvalidState();
        whitelistEnabled = false;
    }

    function batchSetList(bool isWhitelistList, address[] calldata accounts, bool add) external onlyOwner {
        if (accounts.length > MAX_LIST_LENGTH) revert ListTooLong();

        if (add) {
            if (isWhitelistList && !whitelistEnabled) revert InvalidState();
            if (!isWhitelistList && !blacklistEnabled) revert InvalidState();
        }

        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            if (account == address(0)) revert ZeroAddress();

            if (isWhitelistList) {
                if (add) {
                    _addToWhitelist(account);
                } else {
                    _removeFromWhitelist(account);
                }
            } else {
                if (add) {
                    _addToBlacklist(account);
                } else {
                    _removeFromBlacklist(account);
                }
            }
        }
    }

    function clearList(bool isWhitelistList) external onlyOwner {
        if (isWhitelistList) {
            for (uint256 i = _whitelistAddresses.length; i > 0; i--) {
                address account = _whitelistAddresses[i - 1];
                if (_isProtectedAddress(account)) continue;
                _removeFromWhitelist(account);
            }
        } else {
            while (_blacklistAddresses.length > 0) {
                _removeFromBlacklist(_blacklistAddresses[_blacklistAddresses.length - 1]);
            }
        }
    }

    function setKillBlockCount(uint256 count) external onlyOwner {
        if (!manualTradingEnable || tradingEnabled) revert CanOnlySetWhenTradingClosed();
        killBlockCount = count;
    }

    function enableTrading() external onlyOwner {
        if (!manualTradingEnable || tradingEnabled) revert InvalidState();
        tradingEnabled = true;
        tradingEnabledBlock = block.number;
    }

    function processDividend(uint256 gasLimit) external onlyOwner {
        uint256 processGas = gasLimit == 0 ? autoProcessGasLimit : gasLimit;
        if (processGas == 0) revert InvalidState();
        _processPendingDividends(true, processGas);
        _processDividendTracker(processGas, true);
    }

    function transferDividend(address to, uint256 amount) external onlyTracker {
        uint256 rate = _getRate();
        uint256 rAmount = amount * rate;
        if (_rOwned[address(this)] < rAmount) revert InsufficientBalance();
        _rOwned[address(this)] -= rAmount;
        _rOwned[to] += rAmount;
        emit Transfer(address(this), to, amount);
    }

    function getWithdrawableDividend(address account) external view returns (uint256) {
        return dividendTracker.withdrawableDividendOf(account);
    }

    function getTotalDividendsDistributed() external view returns (uint256) {
        return dividendTracker.totalDividendsDistributed();
    }

    function getListLength(bool isWhitelistList) external view returns (uint256) {
        return isWhitelistList ? _whitelistAddresses.length : _blacklistAddresses.length;
    }

    function getListAt(bool isWhitelistList, uint256 index) external view returns (address) {
        address[] storage target = isWhitelistList ? _whitelistAddresses : _blacklistAddresses;
        if (index >= target.length) revert IndexOutOfBounds();
        return target[index];
    }

    function getDefaultExcludedAddresses() external view returns (address, address, address, address, address) {
        return (DEAD, address(this), mainPair, swapRouter, address(dividendTracker));
    }

    function getProtectedListAddresses() external view returns (address, address, address, address, address, address) {
        return (receiveAddress, fundAddress, address(this), mainPair, swapRouter, DEAD);
    }

    function _approve(address owner_, address spender, uint256 amount) internal {
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function _getRate() internal view returns (uint256) {
        return _rTotal / _tTotal;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (balanceOf(from) < amount) revert InsufficientBalance();

        if (inSwap) {
            _basicTransfer(from, to, amount);
            return;
        }

        if (blacklistEnabled && (blacklist[from] || blacklist[to])) revert Blacklisted();

        bool takeFee = true;
        if (whitelistEnabled && (whitelist[from] || whitelist[to])) {
            takeFee = false;
        }

        bool isSell = false;
        bool isAddLP = false;
        bool isRemoveLP = false;

        if (_swapPairList[from] || _swapPairList[to]) {
            (isAddLP, isRemoveLP) = _addOrRemove(from, to, amount);
            if (isAddLP || isRemoveLP) takeFee = false;
            if (_swapPairList[to]) isSell = true;

            if (!isAddLP && !isRemoveLP && !tradingEnabled) revert TradingNotEnabled();

            if (killBlockCount > 0 && block.number < tradingEnabledBlock + killBlockCount) {
                if (!_swapPairList[from] && from != swapRouter && from != address(this) && !whitelist[from]) {
                    _addToBlacklist(from);
                }
                if (!_swapPairList[to] && to != swapRouter && to != address(this) && !whitelist[to]) {
                    _addToBlacklist(to);
                }
            }
        }

        (uint256 divAmt, uint256 fundAmt) = _tokenTransfer(from, to, amount, takeFee, isSell);

        dividendTracker.setBalance(from, balanceOf(from));
        dividendTracker.setBalance(to, balanceOf(to));
        if (fundAmt > 0) {
            dividendTracker.setBalance(fundAddress, balanceOf(fundAddress));
        }

        if (divAmt > 0) pendingDividends += divAmt;

        if (isSell) {
            if (isSameTokenDividend || msg.sender != swapRouter) {
                _tryAutoDividend();
            } else if (pendingDividends >= dividendTriggerThreshold) {
                emit RewardAutoProcessDeferred(pendingDividends, msg.sender);
            }
        } else if (!isSameTokenDividend && msg.sender != swapRouter) {
            _tryAutoDividend();
        }
    }

    function _basicTransfer(address from, address to, uint256 amount) internal {
        uint256 rate = _getRate();
        uint256 rAmount = amount * rate;
        _rOwned[from] -= rAmount;
        _rOwned[to] += rAmount;
        emit Transfer(from, to, amount);
    }

    function _tryAutoDividend() internal {
        if (pendingDividends == 0) return;
        if (pendingDividends < dividendTriggerThreshold) return;
        if (dividendTracker.totalSupply() == 0) return;

        _processPendingDividends(false, autoProcessGasLimit);

        uint256 processGas = _resolveProcessGasLimit();
        if (processGas == 0) return;
        _processDividendTracker(processGas, false);
    }

    function _resolveProcessGasLimit() internal view returns (uint256) {
        uint256 gasCap = autoProcessGasLimit;
        if (gasCap == 0) return 0;

        uint256 left = gasleft();
        if (left <= AUTO_PROCESS_GAS_BUFFER) return 0;

        uint256 dynamicCap = left - AUTO_PROCESS_GAS_BUFFER;
        return gasCap < dynamicCap ? gasCap : dynamicCap;
    }

    function _processPendingDividends(bool forceProcess, uint256 processGas) internal {
        if (pendingDividends == 0) return;
        if (!forceProcess && pendingDividends < dividendTriggerThreshold) return;
        if (dividendTracker.totalSupply() == 0) return;

        if (isSameTokenDividend) {
            uint256 distributeAmount = pendingDividends;
            try dividendTracker.distributeDividends(distributeAmount) {
                pendingDividends = 0;
            } catch (bytes memory reason) {
                if (forceProcess) revert RewardDistributionFailed(reason);
                emit RewardProcessFailedEvent(reason);
                return;
            }
            emit RewardSwapAndDistribute(distributeAmount, distributeAmount);
            return;
        }

        _swapCollectedDividends(forceProcess);
        processGas;
    }

    function _addOrRemove(address from, address to, uint256 amount) internal view returns (bool isAddLP, bool isRemoveLP) {
        if (_swapPairList[to] && msg.sender == swapRouter) {
            uint256 addLP = _isAddLiquidity(to, amount);
            if (addLP > 0) isAddLP = true;
        }
        if (_swapPairList[from]) {
            uint256 removeLP = _isRemoveLiquidity(from, amount);
            if (removeLP > 0) isRemoveLP = true;
        }
    }

    function _isAddLiquidity(address pair, uint256 amount) internal view returns (uint256) {
        if (ISwapPair(pair).totalSupply() == 0) return amount > 0 ? 1 : 0;

        (uint256 r0, uint256 r1,) = ISwapPair(pair).getReserves();
        address tokenOther = ISwapPair(pair).token0() == address(this) ? ISwapPair(pair).token1() : ISwapPair(pair).token0();
        uint256 rOther = tokenOther < address(this) ? r0 : r1;
        uint256 rThis = tokenOther < address(this) ? r1 : r0;
        uint256 balanceOther = IERC20(tokenOther).balanceOf(pair);
        if (rOther == 0 || rThis == 0) return 0;
        uint256 amountOther = amount * rOther / rThis;
        if (balanceOther < rOther + amountOther) return 0;
        return 1;
    }

    function _isRemoveLiquidity(address pair, uint256 /* amount */) internal view returns (uint256) {
        (uint256 r0, uint256 r1,) = ISwapPair(pair).getReserves();
        address tokenOther = ISwapPair(pair).token0() == address(this) ? ISwapPair(pair).token1() : ISwapPair(pair).token0();
        uint256 rOther = tokenOther < address(this) ? r0 : r1;
        uint256 balanceOther = IERC20(tokenOther).balanceOf(pair);
        if (balanceOther > rOther) return 0;
        return 1;
    }

    function _tokenTransfer(address from, address to, uint256 amount, bool takeFee, bool isSell) private returns (uint256 divAmt, uint256 fundAmt) {
        uint256 rate = _getRate();
        uint256 rAmount = amount * rate;
        _rOwned[from] -= rAmount;

        uint256 swapFee = 0;
        if (takeFee) {
            uint256 burnAmt;
            uint256 lpAmt;
            if (isSell) {
                swapFee = sellFundFee + sellLPFee + sellBurnFee + sellDividendFee;
                burnAmt = amount * sellBurnFee / 10000;
                fundAmt = amount * sellFundFee / 10000;
                lpAmt = amount * sellLPFee / 10000;
                divAmt = amount * sellDividendFee / 10000;
            } else if (_swapPairList[from]) {
                swapFee = buyFundFee + buyLPFee + buyBurnFee + buyDividendFee;
                burnAmt = amount * buyBurnFee / 10000;
                fundAmt = amount * buyFundFee / 10000;
                lpAmt = amount * buyLPFee / 10000;
                divAmt = amount * buyDividendFee / 10000;
            } else {
                swapFee = transferFundFee + transferLPFee + transferBurnFee + transferDividendFee;
                burnAmt = amount * transferBurnFee / 10000;
                fundAmt = amount * transferFundFee / 10000;
                lpAmt = amount * transferLPFee / 10000;
                divAmt = amount * transferDividendFee / 10000;
            }

            if (burnAmt > 0) _takeTransfer(from, DEAD, burnAmt, rate);
            if (fundAmt > 0) _takeTransfer(from, fundAddress, fundAmt, rate);
            if (lpAmt > 0) _takeTransfer(from, mainPair, lpAmt, rate);
            if (divAmt > 0) _takeTransfer(from, address(this), divAmt, rate);
        }

        uint256 recipientRate = 10000 - swapFee;
        uint256 recipientAmount = amount * recipientRate / 10000;
        _rOwned[to] += recipientAmount * rate;
        emit Transfer(from, to, recipientAmount);
    }

    function _takeTransfer(address from, address to, uint256 amount, uint256 rate) private {
        uint256 rAmount = amount * rate;
        _rOwned[to] += rAmount;
        emit Transfer(from, to, amount);
    }

    function _swapCollectedDividends(bool forceSwap) internal {
        uint256 amountToSwap = pendingDividends;
        if (amountToSwap == 0) return;
        if (!forceSwap && amountToSwap < dividendTriggerThreshold) return;
        if (dividendTracker.totalSupply() == 0) return;

        uint256 contractBalance = balanceOf(address(this));
        if (contractBalance == 0) return;
        if (amountToSwap > contractBalance) amountToSwap = contractBalance;
        if (amountToSwap == 0) return;

        if (_allowances[address(this)][swapRouter] < amountToSwap) {
            _approve(address(this), swapRouter, type(uint256).max);
        }

        uint256 rewardBefore = IERC20(dividendToken).balanceOf(address(dividendTracker));
        address[] memory path = _buildRewardPath();
        uint256 amountOutMin = _resolveMinRewardOut(amountToSwap, path, forceSwap);
        if (amountOutMin == 0) return;

        inSwap = true;
        try IRewardSwapRouter(swapRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountToSwap,
            amountOutMin,
            path,
            address(dividendTracker),
            block.timestamp
        ) {
            inSwap = false;
        } catch (bytes memory reason) {
            inSwap = false;
            _handleRewardSwapFailure(amountToSwap, reason, forceSwap);
            return;
        }

        pendingDividends -= amountToSwap;

        uint256 rewardAfter = IERC20(dividendToken).balanceOf(address(dividendTracker));
        uint256 rewardReceived = rewardAfter > rewardBefore ? rewardAfter - rewardBefore : 0;
        if (rewardReceived == 0) return;

        try dividendTracker.distributeDividends(rewardReceived) {
        } catch (bytes memory reason) {
            _handleRewardDistributionFailure(reason, forceSwap);
            return;
        }
        emit RewardSwapAndDistribute(amountToSwap, rewardReceived);
    }

    function _buildRewardPath() internal view returns (address[] memory path) {
        address directPair = ISwapFactory(ISwapRouter(swapRouter).factory()).getPair(address(this), dividendToken);
        if (dividendToken == basePoolToken) {
            path = new address[](2);
            path[0] = address(this);
            path[1] = basePoolToken;
            return path;
        }
        if (directPair != address(0)) {
            path = new address[](2);
            path[0] = address(this);
            path[1] = dividendToken;
            return path;
        }

        path = new address[](3);
        path[0] = address(this);
        path[1] = basePoolToken;
        path[2] = dividendToken;
    }

    function _resolveMinRewardOut(uint256 amountIn, address[] memory path, bool forceSwap) internal returns (uint256) {
        uint256 quote;
        try IRewardSwapRouter(swapRouter).getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            if (amounts.length == 0) return 0;
            quote = amounts[amounts.length - 1];
        } catch (bytes memory reason) {
            if (forceSwap) revert RewardQuoteFailed(reason);
            emit RewardSwapFailedEvent(amountIn, reason);
            return 0;
        }

        if (quote == 0) return 0;
        return quote * (BPS_DENOMINATOR - DEFAULT_REWARD_SWAP_SLIPPAGE_BPS) / BPS_DENOMINATOR;
    }

    function _handleRewardSwapFailure(uint256 amountToSwap, bytes memory reason, bool forceSwap) internal {
        if (forceSwap) revert RewardSwapFailed(reason);
        emit RewardSwapFailedEvent(amountToSwap, reason);
    }

    function _handleRewardDistributionFailure(bytes memory reason, bool forceSwap) internal {
        if (forceSwap) revert RewardDistributionFailed(reason);
        emit RewardProcessFailedEvent(reason);
    }

    function _processDividendTracker(uint256 gasLimit, bool forceProcess) internal {
        if (gasLimit == 0) return;
        try dividendTracker.process(gasLimit) returns (uint256) {
        } catch (bytes memory reason) {
            if (forceProcess) revert RewardProcessFailed(reason);
            emit RewardProcessFailedEvent(reason);
        }
    }

    function _validateTaxRates(uint256 a, uint256 b, uint256 c, uint256 d) internal pure {
        if (a > 2500 || b > 2500 || c > 2500 || d > 2500) revert TaxRateTooHigh();
        if (a + b + c + d > 5000) revert TaxTotalTooHigh();
    }

    function _setTaxRates(
        uint256 buyFund,
        uint256 buyLP,
        uint256 buyBurn,
        uint256 buyDiv,
        uint256 sellFund,
        uint256 sellLP,
        uint256 sellBurn,
        uint256 sellDiv,
        uint256 transferFund,
        uint256 transferLP,
        uint256 transferBurn,
        uint256 transferDiv
    ) internal {
        buyFundFee = buyFund;
        buyLPFee = buyLP;
        buyBurnFee = buyBurn;
        buyDividendFee = buyDiv;

        sellFundFee = sellFund;
        sellLPFee = sellLP;
        sellBurnFee = sellBurn;
        sellDividendFee = sellDiv;

        transferFundFee = transferFund;
        transferLPFee = transferLP;
        transferBurnFee = transferBurn;
        transferDividendFee = transferDiv;
    }

    function _validateAndSetTaxRates(
        uint256 buyFund,
        uint256 buyLP,
        uint256 buyBurn,
        uint256 buyDiv,
        uint256 sellFund,
        uint256 sellLP,
        uint256 sellBurn,
        uint256 sellDiv,
        uint256 transferFund,
        uint256 transferLP,
        uint256 transferBurn,
        uint256 transferDiv
    ) internal {
        _validateTaxRates(buyFund, buyLP, buyBurn, buyDiv);
        _validateTaxRates(sellFund, sellLP, sellBurn, sellDiv);
        _validateTaxRates(transferFund, transferLP, transferBurn, transferDiv);
        _setTaxRates(
            buyFund, buyLP, buyBurn, buyDiv,
            sellFund, sellLP, sellBurn, sellDiv,
            transferFund, transferLP, transferBurn, transferDiv
        );
    }

    function _addToBlacklist(address account) internal {
        if (_isProtectedAddress(account)) revert ProtectedAddress();
        _addToIndexedSet(blacklist, _blacklistAddresses, _blacklistIndex, account);
    }

    function _removeFromBlacklist(address account) internal {
        _removeFromIndexedSet(blacklist, _blacklistAddresses, _blacklistIndex, account);
    }

    function _addToWhitelist(address account) internal {
        _addToIndexedSet(whitelist, _whitelistAddresses, _whitelistIndex, account);
    }

    function _removeFromWhitelist(address account) internal {
        if (_isProtectedAddress(account)) revert ProtectedAddress();
        _removeFromIndexedSet(whitelist, _whitelistAddresses, _whitelistIndex, account);
    }

    function _isProtectedAddress(address account) internal view returns (bool) {
        return account == receiveAddress
            || account == fundAddress
            || account == address(this)
            || account == mainPair
            || account == swapRouter
            || account == DEAD;
    }

    function _addToIndexedSet(
        mapping(address => bool) storage setMap,
        address[] storage setArray,
        mapping(address => uint256) storage setIndex,
        address account
    ) internal {
        if (account == address(0)) return;
        if (setMap[account]) return;

        setMap[account] = true;
        setArray.push(account);
        setIndex[account] = setArray.length;
    }

    function _removeFromIndexedSet(
        mapping(address => bool) storage setMap,
        address[] storage setArray,
        mapping(address => uint256) storage setIndex,
        address account
    ) internal {
        if (!setMap[account]) return;

        setMap[account] = false;
        uint256 index = setIndex[account];
        if (index > 0 && index <= setArray.length) {
            address last = setArray[setArray.length - 1];
            setArray[index - 1] = last;
            setIndex[last] = index;
            setArray.pop();
            setIndex[account] = 0;
        }
    }
}
