// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Dependencies/AggregatorV3Interface.sol";

contract OracleAdapter {
    AggregatorV3Interface immutable oracle;
    uint immutable tokenDecimals;

    constructor(AggregatorV3Interface _oracle, uint _tokenDecimals) public {
        oracle = _oracle;
        tokenDecimals = _tokenDecimals;

        require(_tokenDecimals <= 18, "unstupported decimals");
    }

    function decimals() public view returns (uint8) {
        return oracle.decimals();
    }

    function latestRoundData() public view
        returns
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 timestamp,
            uint80 answeredInRound
        )
    {
        (roundId, answer, startedAt, timestamp, answeredInRound) = oracle.latestRoundData();
        int decimalsFactor = int(10 ** (18 - tokenDecimals));
        int adjustAnswer = answer * decimalsFactor;
        require(adjustAnswer / decimalsFactor == answer, "latestRoundData: overflow");
        answer = adjustAnswer;
        timestamp = now; // override timestamp, as on arbitrum they are updated every 24 hours
    }
}

contract GOHMOracleAdapter {
    AggregatorV3Interface immutable ohmIndex;
    AggregatorV3Interface immutable ohmV2;

    constructor(AggregatorV3Interface _ohmIndex, AggregatorV3Interface _ohmV2) public {
        ohmIndex = _ohmIndex;
        ohmV2 = _ohmV2;
    }

    function decimals() public view returns (uint8) {
        return ohmIndex.decimals() + ohmV2.decimals();
    }

    function latestRoundData() public view
        returns
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 timestamp,
            uint80 answeredInRound
        )
    {
        int answer1; int answer2;
        (roundId, answer1, startedAt, , answeredInRound) = ohmIndex.latestRoundData();
        (, answer2, , , ) = ohmV2.latestRoundData();
        answer = answer1 * answer2;
        require(answer / answer2 == answer1, "latestRoundData: overflow");
        timestamp = now; // override timestamp, as on arbitrum they are updated every 24 hours
    }
}
