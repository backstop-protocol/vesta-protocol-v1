// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./CropJoinAdapter.sol";
import "./PriceFormula.sol";
import "./Interfaces/IPriceFeed.sol";
import "./Dependencies/IERC20.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/AggregatorV3Interface.sol";

interface StabilityPoolLike {
    function withdrawFromSP(uint256 _amount) external;
    function provideToSP(uint256 _amount) external;
    function getCompoundedVSTDeposit(address _depositor)
        external
        view
        returns (uint256);
    function getDepositorAssetGain(address _depositor)
        external
        view
        returns (uint256);
}

contract BAMM is CropJoinAdapter, PriceFormula, Ownable {
    using SafeMath for uint256;

    AggregatorV3Interface public immutable priceAggregator;
    IERC20 public immutable LUSD;
    IERC20 public immutable collateral;    
    StabilityPoolLike immutable public SP;

    address payable public immutable feePool;
    uint public constant MAX_FEE = 100; // 1%
    uint public fee = 0; // fee in bps
    uint public A = 20;
    uint public constant MIN_A = 20;
    uint public constant MAX_A = 200;    

    uint public immutable maxDiscount; // max discount in bips

    address public immutable frontEndTag;

    uint constant public PRECISION = 1e18;

    event ParamsSet(uint A, uint fee);
    event UserDeposit(address indexed user, uint lusdAmount, uint numShares);
    event UserWithdraw(address indexed user, uint lusdAmount, uint ethAmount, uint numShares);
    event RebalanceSwap(address indexed user, uint lusdAmount, uint ethAmount, uint timestamp);

    constructor(
        address _priceAggregator,
        address payable _SP,
        address _LUSD,
        address _LQTY,
        address _collateral,
        uint _maxDiscount,
        address payable _feePool,
        address _fronEndTag)
        public
        CropJoinAdapter(_LQTY)
    {
        priceAggregator = AggregatorV3Interface(_priceAggregator);
        LUSD = IERC20(_LUSD);
        collateral = IERC20(_collateral);
        SP = StabilityPoolLike(_SP);

        feePool = _feePool;
        maxDiscount = _maxDiscount;
        frontEndTag = _fronEndTag;
    }

    function setParams(uint _A, uint _fee) external onlyOwner {
        require(_fee <= MAX_FEE, "setParams: fee is too big");
        require(_A >= MIN_A, "setParams: A too small");
        require(_A <= MAX_A, "setParams: A too big");

        fee = _fee;
        A = _A;

        emit ParamsSet(_A, _fee);
    }

    function fetchPrice() public view returns(uint) {
        uint chainlinkDecimals;
        uint chainlinkLatestAnswer;
        uint chainlinkTimestamp;

        // First, try to get current decimal precision:
        try priceAggregator.decimals() returns (uint8 decimals) {
            // If call to Chainlink succeeds, record the current decimal precision
            chainlinkDecimals = decimals;
        } catch {
            // If call to Chainlink aggregator reverts, return a zero response with success = false
            return 0;
        }

        // Secondly, try to get latest price data:
        try priceAggregator.latestRoundData() returns
        (
            uint80 /* roundId */,
            int256 answer,
            uint256 /* startedAt */,
            uint256 timestamp,
            uint80 /* answeredInRound */
        )
        {
            // If call to Chainlink succeeds, return the response and success = true
            chainlinkLatestAnswer = uint(answer);
            chainlinkTimestamp = timestamp;
        } catch {
            // If call to Chainlink aggregator reverts, return a zero response with success = false
            return 0;
        }

        if(chainlinkTimestamp + 1 hours < now) return 0; // price is down

        uint chainlinkFactor = 10 ** chainlinkDecimals;
        return chainlinkLatestAnswer.mul(PRECISION) / chainlinkFactor;
    }

    function deposit(uint lusdAmount) external {        
        // update share
        uint lusdValue = SP.getCompoundedVSTDeposit(address(this));
        uint ethValue = getCollateralBalance();

        uint price = fetchPrice();
        require(ethValue == 0 || price > 0, "deposit: chainlink is down");

        uint totalValue = lusdValue.add(ethValue.mul(price) / PRECISION);

        // this is in theory not reachable. if it is, better halt deposits
        // the condition is equivalent to: (totalValue = 0) ==> (total = 0)
        require(totalValue > 0 || total == 0, "deposit: system is rekt");

        uint newShare = PRECISION;
        if(total > 0) newShare = total.mul(lusdAmount) / totalValue;

        // deposit
        require(LUSD.transferFrom(msg.sender, address(this), lusdAmount), "deposit: transferFrom failed");
        SP.provideToSP(lusdAmount);

        // update LP token
        mint(msg.sender, newShare);

        emit UserDeposit(msg.sender, lusdAmount, newShare);        
    }

    function withdraw(uint numShares) external {
        uint lusdValue = SP.getCompoundedVSTDeposit(address(this));
        uint ethValue = getCollateralBalance();

        uint lusdAmount = lusdValue.mul(numShares).div(total);
        uint ethAmount = ethValue.mul(numShares).div(total);

        // this withdraws lusd, lqty, and eth
        SP.withdrawFromSP(lusdAmount);

        // update LP token
        burn(msg.sender, numShares);

        // send lusd and eth
        if(lusdAmount > 0) LUSD.transfer(msg.sender, lusdAmount);
        if(ethAmount > 0) {
            sendCollateral(msg.sender, ethAmount);
        }

        emit UserWithdraw(msg.sender, lusdAmount, ethAmount, numShares);            
    }

    function addBps(uint n, int bps) internal pure returns(uint) {
        require(bps <= 10000, "reduceBps: bps exceeds max");
        require(bps >= -10000, "reduceBps: bps exceeds min");

        return n.mul(uint(10000 + bps)) / 10000;
    }

    function getSwapEthAmount(uint lusdQty) public view returns(uint ethAmount, uint feeLusdAmount) {
        uint lusdBalance = SP.getCompoundedVSTDeposit(address(this));
        uint ethBalance  = getCollateralBalance();

        uint eth2usdPrice = fetchPrice();
        if(eth2usdPrice == 0) return (0, 0); // chainlink is down

        uint ethUsdValue = ethBalance.mul(eth2usdPrice) / PRECISION;
        uint maxReturn = addBps(lusdQty.mul(PRECISION) / eth2usdPrice, int(maxDiscount));

        uint xQty = lusdQty;
        uint xBalance = lusdBalance;
        uint yBalance = lusdBalance.add(ethUsdValue.mul(2));
        
        uint usdReturn = getReturn(xQty, xBalance, yBalance, A);
        uint basicEthReturn = usdReturn.mul(PRECISION) / eth2usdPrice;

        if(ethBalance < basicEthReturn) basicEthReturn = ethBalance; // cannot give more than balance 
        if(maxReturn < basicEthReturn) basicEthReturn = maxReturn;

        ethAmount = basicEthReturn;
        feeLusdAmount = addBps(lusdQty, int(fee)).sub(lusdQty);
    }

    // get ETH in return to LUSD
    function swap(uint lusdAmount, uint minEthReturn, address payable dest) public returns(uint) {
        (uint ethAmount, uint feeAmount) = getSwapEthAmount(lusdAmount);

        require(ethAmount >= minEthReturn, "swap: low return");

        LUSD.transferFrom(msg.sender, address(this), lusdAmount);
        SP.provideToSP(lusdAmount.sub(feeAmount));

        if(feeAmount > 0) LUSD.transfer(feePool, feeAmount);
        sendCollateral(dest, ethAmount); // re-entry is fine here

        emit RebalanceSwap(msg.sender, lusdAmount, ethAmount, now);

        return ethAmount;
    }

    // kyber network reserve compatible function
    function trade(
        IERC20 /* srcToken */,
        uint256 srcAmount,
        IERC20 /* destToken */,
        address payable destAddress,
        uint256 /* conversionRate */,
        bool /* validate */
    ) external payable returns (bool) {
        return swap(srcAmount, 0, destAddress) > 0;
    }

    function getConversionRate(
        IERC20 /* src */,
        IERC20 /* dest */,
        uint256 srcQty,
        uint256 /* blockNumber */
    ) external view returns (uint256) {
        (uint ethQty, ) = getSwapEthAmount(srcQty);
        return ethQty.mul(PRECISION) / srcQty;
    }

    receive() external payable {}

    // multi collateral competability
    function collaterals(uint index) public view returns(address) {
        require(index == 0, "only one collateral");
        return address(collateral);
    }

    function sendCollateral(address to, uint amount) internal {
        if(collateral == IERC20(0x0)) {
            (bool success, ) = to.call{ value: amount }("");
            require(success, "sendCollateral: sending ETH failed");            
        }
        else {
            require(collateral.transfer(to, amount), "sendCollateral: swap failed");
        }
    }

    function getCollateralBalance() public view returns(uint) {
        uint spBalance = SP.getDepositorAssetGain(address(this));
        uint contractBalance;

        if(collateral == IERC20(0x0)) {
            contractBalance = address(this).balance;            
        }
        else {
            contractBalance = collateral.balanceOf(address(this));
        }

        return spBalance.add(contractBalance);
    }

    function getCollateralValue() public view returns(bool succ, uint value) {
        uint ethValue = getCollateralBalance();

        uint price = fetchPrice();

        succ = price > 0;
        value = (ethValue.mul(price) / PRECISION);
    }
}
