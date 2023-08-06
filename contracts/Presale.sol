// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.9;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./IPresale.sol";

contract Presale is IPresale, Ownable2Step, ReentrancyGuard, Pausable {
    using Math for uint256;
    using SafeERC20 for IERC20;

    address public immutable USDC;
    address public immutable DAI;
    AggregatorV3Interface public immutable ORACLE;

    uint256 private immutable PRECISION = 1e8;
    uint256 private immutable USD_PRECISION = 1e18;
    uint256 private immutable USDC_SCALE = 1e12;

    uint256 private $currentRoundIndex;
    uint256 private $totalRaisedUSD;
    uint256 private $totalPurchases;

    PresaleConfig private $config;
    RoundConfig[] private $rounds;

    mapping(uint256 => uint256) private $roundTokensAllocated;
    mapping(address => uint256) private $userTokensAllocated;
    mapping(address => uint256) private $userUSDAllocated;

    constructor(
        address oracle,
        address usdc,
        address dai,
        PresaleConfig memory newConfig,
        RoundConfig[] memory newRounds
    ) {
        ORACLE = AggregatorV3Interface(oracle);
        USDC = usdc;
        DAI = dai;

        _setConfig(newConfig);
        _setRounds(newRounds);
    }

    function currentRoundIndex() external view returns (uint256) {
        return $currentRoundIndex;
    }

    function config() external view returns (PresaleConfig memory) {
        return $config;
    }

    function round(uint256 roundIndex) external view override returns (RoundConfig memory) {
        return $rounds[roundIndex];
    }

    function rounds() external view override returns (RoundConfig[] memory) {
        return $rounds;
    }

    function totalPurchases() external view override returns (uint256) {
        return $totalPurchases;
    }

    function totalRounds() external view override returns (uint256) {
        return $rounds.length;
    }

    function totalRaisedUSD() external view override returns (uint256) {
        return $totalRaisedUSD;
    }

    function roundTokensAllocated(uint256 roundIndex) external view returns (uint256) {
        return $roundTokensAllocated[roundIndex];
    }

    function userTokensAllocated(address account) external view override returns (uint256) {
        return $userTokensAllocated[account];
    }

    function userUSDAllocated(address account) external view override returns (uint256) {
        return $userUSDAllocated[account];
    }

    function ethPrice() public view override returns (uint256) {
        (, int256 price,,,) = ORACLE.latestRoundData();
        return uint256(price);
    }

    function ethToUsd(uint256 amount) public view override returns (uint256 _usdAmount) {
        _usdAmount = (amount * ethPrice()) / PRECISION;
    }

    function ethToTokens(uint256 amount, uint256 price) public view override returns (uint256 _tokenAmount) {
        _tokenAmount = usdToTokens(ethToUsd(amount), price);
    }

    function usdToTokens(uint256 amount, uint256 price) public pure override returns (uint256) {
        return (amount * PRECISION) / price;
    }

    function tokensToUSD(uint256 amount, uint256 price) public pure override returns (uint256) {
        return (amount * price).ceilDiv(PRECISION);
    }

    function pause() external override onlyOwner {
        _pause();
    }

    function unpause() external override onlyOwner {
        _unpause();
    }

    function setConfig(PresaleConfig calldata newConfig) external override onlyOwner {
        _setConfig(newConfig);
    }

    function setRounds(RoundConfig[] calldata newRounds) external override onlyOwner {
        _setRounds(newRounds);
    }

    function purchase(address account, bytes memory data) public payable override whenNotPaused returns (Receipt memory) {
        return _purchase(PurchaseConfig({
            asset: address(0),
            amountAsset: msg.value,
            amountUSD: ethToUsd(msg.value),
            account: account,
            data: data
        }));
    }

    function purchaseUSDC(address account, uint256 amount, bytes calldata data) external override whenNotPaused returns (Receipt memory) {
        return _purchase(PurchaseConfig({
            asset: USDC,
            amountAsset: amount,
            amountUSD: amount * USDC_SCALE,
            account: account,
            data: data
        }));
    }

    function purchaseDAI(address account, uint256 amount, bytes calldata data) external override whenNotPaused returns (Receipt memory) {
        return _purchase(PurchaseConfig({
            asset: DAI,
            amountAsset: amount,
            amountUSD: amount,
            account: account,
            data: data
        }));
    }

    function allocate(address account, uint256 amountUSD, bytes calldata data) external override onlyOwner returns (Receipt memory) {
        return _purchase(PurchaseConfig({
            asset: address(0),
            amountAsset: 0,
            amountUSD: amountUSD,
            account: account,
            data: data
        }));
    }

    receive() external payable {
        purchase(_msgSender(), "");
    }

    struct SyncCache {
        uint256 totalTokenAllocation;
        uint256 totalUSDAllocation;
        uint256 totalRounds;
        uint256 remainingUSD;
        uint256 userAllocationRemaining;
        uint256 currentIndex;
        uint256 roundAllocationRemaining;
        uint256 userAllocation;
    }

    function _purchase(PurchaseConfig memory purchaseConfig) private returns (Receipt memory receipt) {
        PresaleConfig memory _config = $config;
        receipt.id = ++$totalPurchases;

        require(block.timestamp >= _config.startDate, "RAISE_NOT_STARTED");
        require(block.timestamp <= _config.endDate, "RAISE_ENDED");
        require(
            purchaseConfig.amountUSD >= _config.minDepositAmount || _config.minDepositAmount == 0, "MIN_DEPOSIT_AMOUNT"
        );

        SyncCache memory _c;

        _c.totalRounds = $rounds.length;
        _c.currentIndex = $currentRoundIndex;
        _c.remainingUSD = purchaseConfig.amountUSD;
        _c.userAllocationRemaining = _config.maxUserAllocation - $userTokensAllocated[purchaseConfig.account];

        while (_c.currentIndex < _c.totalRounds && _c.remainingUSD > 0 && _c.userAllocationRemaining > 0) {
            RoundConfig memory _round = $rounds[_c.currentIndex];

            _c.roundAllocationRemaining = _remainingRoundAllocation(_c.currentIndex, _round);
            _c.userAllocation = _calculateUserAllocation(_c.remainingUSD, _round);

            if (_c.userAllocation > _c.roundAllocationRemaining) {
                _c.userAllocation = _c.roundAllocationRemaining;
            }
            if (_c.userAllocation > _c.userAllocationRemaining) {
                _c.userAllocation = _c.userAllocationRemaining;
            }

            if (_c.userAllocation > 0) {
                uint256 _tokensCostUSD = tokensToUSD(_c.userAllocation, _round.tokenPrice);

                _c.remainingUSD = _subZero(_c.remainingUSD, _tokensCostUSD);
                _c.userAllocationRemaining = _subZero(_c.userAllocationRemaining, _c.userAllocation);
                _c.totalTokenAllocation += _c.userAllocation;

                $roundTokensAllocated[_c.currentIndex] += _c.userAllocation;

                if (_round.roundType == RoundType.Liquidity) {
                    _c.totalUSDAllocation += _tokensCostUSD;
                    _c.remainingUSD = _subZero(_c.remainingUSD, _tokensCostUSD);
                }

                emit Purchase(receipt.id, _c.currentIndex, _tokensCostUSD, _c.userAllocation);
            }

            // if we have used everything then lets increment current index. and only increment if we are not on the last round.
            if (_c.userAllocation == _c.roundAllocationRemaining && _c.currentIndex < _c.totalRounds - 1) {
                _c.currentIndex++;
            } else {
                break;
            }
        }

        unchecked {
            $totalRaisedUSD += purchaseConfig.amountUSD - _c.remainingUSD;
            $currentRoundIndex = _c.currentIndex;
            $userTokensAllocated[purchaseConfig.account] = _config.maxUserAllocation - _c.userAllocationRemaining;

            if (_c.totalUSDAllocation > 0) {
                $userUSDAllocated[purchaseConfig.account] += _c.totalUSDAllocation;
            }
        }

        receipt.remainingUSD = _c.remainingUSD;
        receipt.refundedAssets = (purchaseConfig.amountAsset * _c.remainingUSD) / purchaseConfig.amountUSD;
        receipt.tokensAllocated = _c.totalTokenAllocation;
        receipt.usdAllocated = _c.totalUSDAllocation;
        receipt.costAssets = purchaseConfig.amountAsset - receipt.refundedAssets;
        receipt.costUSD = purchaseConfig.amountUSD - _c.remainingUSD;

        // edge case to prevent the user from getting free tokens
        require(
            receipt.refundedAssets == 0 ||
            receipt.tokensAllocated == 0 ||
            receipt.refundedAssets != purchaseConfig.amountAsset,
            'INVALID_PURCHASE'
        );

        if (receipt.refundedAssets > 0) {
            _send(purchaseConfig.asset, receipt.refundedAssets, purchaseConfig.account);
        }

        if (receipt.costAssets > 0) {
            _send(purchaseConfig.asset, receipt.costAssets, _config.withdrawTo);
        }

        require(receipt.tokensAllocated > 0, 'NO_TOKENS_ALLOCATED');

        emit PurchaseReceipt(receipt.id, purchaseConfig, receipt, _msgSender());
    }

    function _send(address asset, uint256 amountAsset, address account) private {
        address _sender = _msgSender();
        if (asset == address(0)) {
            payable(account).transfer(amountAsset);
        } else if (_sender != account) {
            IERC20(asset).safeTransferFrom(_sender, account, amountAsset);
        }
    }

    function _setRounds(RoundConfig[] memory newRounds) private {
        uint256 _totalRounds = $rounds.length;
        for (uint256 i; i < newRounds.length; ++i) {
            if (i >= _totalRounds || $roundTokensAllocated[i] < newRounds[i].tokenAllocation || i == newRounds.length - 1) {
                emit RoundsUpdated($rounds, newRounds, $currentRoundIndex, i, _msgSender());
                $currentRoundIndex = i;
                break;
            }
        }

        for (uint256 i; i < _totalRounds; i++) {
            $rounds.pop();
        }

        for (uint256 i; i < newRounds.length; ++i) {
            $rounds.push(newRounds[i]);
        }

    }

    function _setConfig(PresaleConfig memory newConfig) private {
        require(newConfig.startDate < newConfig.endDate, "INVALID_DATES");
        require(newConfig.withdrawTo != address(0), "INVALID_WITHDRAW_TO");

        emit ConfigUpdated($config, newConfig, _msgSender());

        $config = newConfig;
    }

    function _remainingRoundAllocation(uint256 roundIndex, RoundConfig memory round_) private view returns (uint256) {
        uint256 _roundTotalAllocated = $roundTokensAllocated[roundIndex];
        return _subZero(round_.tokenAllocation, _roundTotalAllocated);
    }

    function _calculateUserAllocation(uint256 amountUSD, RoundConfig memory round_) private pure returns (uint256) {
        return usdToTokens(
            round_.roundType == RoundType.Liquidity ? amountUSD / 2 : amountUSD,
            round_.tokenPrice
        );
    }

    function _subZero(uint256 a, uint256 b) private pure returns (uint256) {
        unchecked {
            return a > b ? a - b : 0;
        }
    }
}
