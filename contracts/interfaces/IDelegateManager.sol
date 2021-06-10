pragma solidity ^0.8.0;

interface IDelegateManager {
    function delegateStake(address _targetSP, uint256 _amount) external returns (uint256);

    function requestUndelegateStake(address _target, uint256 _amount) external returns (uint256);

    function cancelUndelegateStakeRequest() external;

    function undelegateStake() external returns (uint256);

    function claimRewards(address _serviceProvider) external;

    function getDelegatorStakeForServiceProvider(address _delegator, address _serviceProvider)
        external
        view
        returns (uint256);

    function getStakingAddress() external view returns (address);

    function getMinDelegationAmount() external view returns (uint256);

    function getClaimsManagerAddress() external view returns (address);

    function getUndelegateLockupDuration() external view returns (uint256);
}
