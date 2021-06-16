pragma solidity ^0.8.0;

interface IClaimManager {
    function getFundingRoundBlockDiff() external view returns (uint256);

    function getLastFundedBlock() external view returns (uint256);

    function claimPending(address _sp) external view returns (bool);

    function initiateRound() external;
}
