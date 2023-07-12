// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.9;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "./IPresale.sol";

contract Presale is IPresale, Ownable2Step, ReentrancyGuard, Pausable {
    address public immutable USDC;

    address public immutable DAI;

    AggregatorV3Interface public immutable ORACLE;

    uint256 private immutable PRECISION = 1e18;
    uint256 private immutable ETH_TO_WEI_PRECISION = 1e10;
    uint256 private immutable USDC_TO_WEI_PRECISION = 1e12;

    uint256 private $currentRoundIndex;
    uint256 private $totalRaisedUSD;

    PresaleConfig private $config;

    address payable public $withdrawTo;

    mapping(uint256 => uint256) private $raisedUSD;
    mapping(address => uint256) private $tokensAllocated;

    constructor(address oracle, address usdc, address dai, PresaleConfig memory config_) {
        ORACLE = AggregatorV3Interface(oracle);
        USDC = usdc;
        DAI = dai;

        $config = config_;
    }

    function currentRoundIndex() external view override returns (uint256) {
        return $currentRoundIndex;
    }

    function round(uint256 roundIndex) external view override returns (RoundConfig memory) {
        return $config.rounds[roundIndex];
    }

    function config() external view returns (PresaleConfig memory) {
        return $config;
    }

    function totalRounds() external view override returns (uint256) {
        return $config.rounds.length;
    }

    function raisedUSD(uint256 roundIndex) external view returns (uint256) {
        return $raisedUSD[roundIndex];
    }

    function totalRaisedUSD() external view override returns (uint256) {
        return $totalRaisedUSD;
    }

    function tokensAllocated(address account) external view override returns (uint256) {
        return $tokensAllocated[account];
    }

    function ethPrice() public view returns (uint256) {
        (, int256 price,,,) = ORACLE.latestRoundData();
        return uint256(uint256(price) * ETH_TO_WEI_PRECISION);
    }

    function ethToUsd(uint256 amount) public view returns (uint256) {
        uint256 _ethPrice = ethPrice();
        uint256 _ethAmountInUsd = (_ethPrice * amount) / PRECISION;
        return _ethAmountInUsd;
    }

    function usdToTokens(uint256 roundIndex, uint256 amount) public view returns (uint256) {
        RoundConfig memory _round = $config.rounds[roundIndex];
        return amount * _round.tokenPrice;
    }

    function setConfig(PresaleConfig calldata newConfig) external onlyOwner {
        emit ConfigUpdated($config, newConfig, _msgSender());

        $config = newConfig;
    }

    function purchase() public payable override whenNotPaused {
        uint256 amountUSD = ethToUsd(msg.value);
        _sync($currentRoundIndex, address(0), amountUSD, _msgSender());
    }

    function purchase(address account) public payable override whenNotPaused {
        uint256 amountUSD = ethToUsd(msg.value);
        _sync($currentRoundIndex, address(0), amountUSD, account);
    }

    function purchaseUSDC(uint256 amount) external override whenNotPaused {
        address sender = _msgSender();

        IERC20(USDC).transferFrom(sender, address(this), amount);

        uint256 amountScaled = amount * USDC_TO_WEI_PRECISION;
        _sync($currentRoundIndex, USDC, amountScaled, sender);
    }

    function purchaseDAI(uint256 amount) external override whenNotPaused {
        address sender = _msgSender();

        IERC20(DAI).transferFrom(sender, address(this), amount);
        _sync($currentRoundIndex, DAI, amount, sender);
    }

    receive() external payable {
        purchase();
    }

    function _sync(uint256 roundIndex, address asset, uint256 amountUSD, address account) private {
        PresaleConfig memory _config = $config;

        RoundConfig memory _round = _config.rounds[roundIndex];
        uint256 _availableAllocation = amountUSD * _round.tokenPrice;
        uint256 _roundsLength = _config.rounds.length;

        uint256 _depositAmount = amountUSD;
        uint256 _currentRoundIndex = roundIndex;

        while (_availableAllocation > 0) {
            if (_depositAmount >= _availableAllocation) {
                _deposit(_currentRoundIndex, asset, _availableAllocation, account);

                if (_currentRoundIndex == _roundsLength - 1) {
                    uint256 _leftOver = _depositAmount - _availableAllocation;
                    if (_leftOver > 0) {
                        _refund(asset, _leftOver, account);
                    }
                } else {
                    $currentRoundIndex += 1;
                    _currentRoundIndex = $currentRoundIndex;
                }

                _depositAmount -= _availableAllocation;

                _round = _config.rounds[_currentRoundIndex];
                //                _availableAllocation = _round.allocationUSD - _round.totalRaisedUSD;
            } else {
                _deposit(_currentRoundIndex, asset, _depositAmount, account);
                break;
            }
        }
    }

    function _deposit(uint256 roundIndex, address asset, uint256 amountUSD, address account) private {
        PresaleConfig memory _config = $config;
        uint256 _minDepositAmount = _config.minDepositAmount;
        uint256 tokenAllocation = usdToTokens(roundIndex, amountUSD);

        require(block.timestamp >= _config.startDate, "RAISE_NOT_STARTED");
        require(block.timestamp <= _config.endDate, "RAISE_ENDED");
        require(amountUSD >= _minDepositAmount || _minDepositAmount == 0, "MIN_DEPOSIT_AMOUNT");
        require(tokenAllocation + $tokensAllocated[account] <= _config.maxUserAllocation, "MAX_USER_ALLOCATION");

        $raisedUSD[$currentRoundIndex] += amountUSD;

        $tokensAllocated[account] += tokenAllocation;

        $totalRaisedUSD += amountUSD;

        emit Deposit(roundIndex, asset, amountUSD, account);
    }

    function _refund(address asset, uint256 amountUSD, address account) private {
        if (asset == address(0)) {
            uint256 amountInWei = amountUSD * PRECISION / ethPrice();
            payable(account).transfer(amountInWei);
        } else if (asset == USDC) {
            IERC20(USDC).transfer(account, amountUSD / USDC_TO_WEI_PRECISION);
        } else {
            IERC20(DAI).transfer(account, amountUSD);
        }

        emit Refund(asset, amountUSD, account);
    }
}
