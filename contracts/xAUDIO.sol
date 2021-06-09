pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "./interfaces/IDelegateManager.sol";

contract xAUDIO is Initializable, ERC20Upgradeable, OwnableUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /* ========================================================================================= */
    /*                                        States                                             */
    /* ========================================================================================= */

    uint256 private constant MAX_UINT = type(uint256).max;

    uint256 private constant AUDIO_BUFFER_TARGET = 20; // 5% target

    uint256 private constant INITIAL_SUPPLY_MULTIPLIER = 100;

    uint256 public constant LIQUIDATION_TIME_PERIOD = 4 weeks;

    // addresses are locked from transfer after minting or burning
    uint256 private constant BLOCK_LOCK_COUNT = 6;

    uint256 public adminActiveTimestamp;

    IERC20 private audio;

    address private targetSP;

    IDelegateManager private delegateManager;

    bool public cooldownActivated;

    // last block for which this address is timelocked
    mapping(address => uint256) public lastLockedBlock;

    function initialize(
        IERC20 _audio,
        address _targetSP,
        IDelegateManager _delegateManger,
        string memory _symbol
    ) public initializer {
        __Ownable_init();
        __ERC20_init("xAUDIO", _symbol);

        audio = _audio;
        targetSP = _targetSP;
        delegateManager = _delegateManger;

        audio.safeApprove(address(delegateManager), MAX_UINT);

        _updateAdminActiveTimestamp();
    }

    /* ========================================================================================= */
    /*                                        Modifiers                                          */
    /* ========================================================================================= */

    /**
     *  BlockLock logic: Implements locking of mint, burn, transfer and
     *  transferFrom functions via a notLocked modifier.
     *  Functions are locked per address.
     */
    modifier notLocked(address lockedAddress) {
        require(lastLockedBlock[lockedAddress] <= block.number, "Function is temporarily locked for this address");
        _;
    }

    /**
     * @notice If admin doesn't certify within LIQUIDATION_TIME_PERIOD,
     * admin functions unlock to public
     */
    modifier liquidationTimeElapsed {
        require(block.timestamp > adminActiveTimestamp + LIQUIDATION_TIME_PERIOD, "Liquidation time hasn't elapsed");
        _;
    }

    /** ========================================================================================= */
    /**                                        Admin functions                                    */
    /** ========================================================================================= */

    /**
     * @notice Admin-callable function in case of persistent depletion of buffer
     * reserve or emergency shutdown
     * @notice Incremental AUDIO will only be allocated to buffer reserve
     * @param amount: AUDIO to unstake
     */
    function cooldown(uint256 amount) external onlyOwner {
        _updateAdminActiveTimestamp();
        _cooldown(amount);
    }

    /**
     * @notice Admin-callable function disabling cooldown and returning fund to
     * normal course of management
     */
    function disableCooldown() external onlyOwner {
        _updateAdminActiveTimestamp();
        _disableCooldown();
    }

    /**
     * @notice Admin-callable function available once cooldown has been
     * activated and requisite time elapsed
     * @notice Called when buffer reserve is persistently insufficient to
     * satisfy redemption requirements
     */
    function unstake() external onlyOwner {
        _updateAdminActiveTimestamp();
        _unstake();
    }

    /**
     * @notice Admin-callable function claiming staking rewards
     * @notice Called regularly on behalf of pool in normal course of management
     */
    function claimRewards() external onlyOwner {
        _updateAdminActiveTimestamp();
        _claimRewards();
    }

    function pauseContract() external onlyOwner returns (bool) {
        _pause();
        return true;
    }

    function unpauseContract() external onlyOwner returns (bool) {
        _unpause();
        return true;
    }

    /**
     * @notice Callable by admin to ensure LIQUIDATION_TIME_PERIOD won't elapse
     */
    function certifyAdmin() external onlyOwner {
        _updateAdminActiveTimestamp();
    }

    /* ========================================================================================= */
    /*                                        Investor-Facing                                    */
    /* ========================================================================================= */

    /**
     * @dev Mint xAUDIO using AUDIO
     * @notice Must run ERC20 approval first
     * @param audioAmount: AUDIO to contribute
     */
    function mintWithToken(uint256 audioAmount) external whenNotPaused notLocked(msg.sender) {
        require(audioAmount > 0, "Must send AUDIO");
        _lock(msg.sender);

        (uint256 stakedBalance, uint256 bufferBalance) = getFundBalances();

        audio.safeTransferFrom(msg.sender, address(this), audioAmount);

        return _mintInternal(bufferBalance, stakedBalance, audioAmount);
    }

    /**
     * @dev Burn xAUDIO tokens
     * @notice Will fail if redemption value exceeds available liquidity
     * @param tokenAmount: xAUDIO to redeem
     */
    function burn(uint256 tokenAmount) external notLocked(msg.sender) {
        require(tokenAmount > 0, "Must send xAUDIO");
        _lock(msg.sender);

        (uint256 stakedBalance, uint256 bufferBalance) = getFundBalances();
        uint256 audioHoldings = bufferBalance + stakedBalance;
        uint256 proRataAudio = (audioHoldings * tokenAmount) / totalSupply();

        require(proRataAudio <= bufferBalance, "Insufficient exit liquidity");
        super._burn(msg.sender, tokenAmount);

        audio.safeTransfer(msg.sender, proRataAudio);
    }

    function transfer(address recipient, uint256 amount) public override notLocked(msg.sender) returns (bool) {
        return super.transfer(recipient, amount);
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override notLocked(sender) returns (bool) {
        return super.transferFrom(sender, recipient, amount);
    }

    /* ========================================================================================= */
    /*                                  Public Getters                                           */
    /* ========================================================================================= */

    function getFundHoldings() public view returns (uint256) {
        return getStakedBalance() + getBufferBalance();
    }

    function getStakedBalance() public view returns (uint256) {
        return delegateManager.getDelegatorStakeForServiceProvider(address(this), targetSP);
    }

    function getBufferBalance() public view returns (uint256) {
        return audio.balanceOf(address(this));
    }

    function getFundBalances() public view returns (uint256, uint256) {
        return (getStakedBalance(), getBufferBalance());
    }

    /* ========================================================================================= */
    /*                                   Fund Management - Public                                */
    /* ========================================================================================= */

    /**
     * @notice First step in xAUDIO unwind in event of admin failure/incapacitation
     
     */
    function emergencyCooldown(uint256 amount) external liquidationTimeElapsed {
        _cooldown(amount);
    }

    /**
     * @notice Second step in xAUDIO unwind in event of admin
     * failure/incapacitation
     * @notice Called after cooldown period, during unwind period
     */
    function emergencyUnstake() external liquidationTimeElapsed {
        _unstake();
    }

    /**
     * @notice Public callable function for claiming staking rewards
     */
    function claimExternal() external {
        _claimRewards();
    }

    /* ========================================================================================= */
    /*                                         Internals                                         */
    /* ========================================================================================= */

    /**
     * @dev Helper function for mint, mintWithToken
     * @param incrementalAudio: AUDIO contributed
     * @param audioHoldingsBefore: xAUDIO buffer reserve + staked balance
     * @param totalSupply: xAUDIO.totalSupply()
     */
    function _calculateMintAmount(
        uint256 incrementalAudio,
        uint256 audioHoldingsBefore,
        uint256 totalSupply
    ) internal pure returns (uint256 mintAmount) {
        if (totalSupply == 0) return incrementalAudio * INITIAL_SUPPLY_MULTIPLIER;

        mintAmount = (incrementalAudio * totalSupply) / audioHoldingsBefore;
    }

    /**
     * @dev Helper function for mint, mintWithToken
     * @param _bufferBalanceBefore: xAUDIO AUDIO buffer balance pre-mint
     * @param _incrementalAudio: AUDIO contributed
     * @param _stakedBalance: xAUDIO delegateManager balance pre-mint
     * @param _totalSupply: xAUDIO.totalSupply()
     */
    function _calculateAllocationToStake(
        uint256 _bufferBalanceBefore,
        uint256 _incrementalAudio,
        uint256 _stakedBalance,
        uint256 _totalSupply
    ) internal pure returns (uint256) {
        if (_totalSupply == 0) return _incrementalAudio - (_incrementalAudio / AUDIO_BUFFER_TARGET);

        uint256 bufferBalanceAfter = _bufferBalanceBefore + _incrementalAudio;
        uint256 audioHoldings = bufferBalanceAfter + _stakedBalance;

        uint256 targetBufferBalance = audioHoldings / AUDIO_BUFFER_TARGET;

        // allocate full incremental audio to buffer balance
        if (bufferBalanceAfter < targetBufferBalance) return 0;

        return bufferBalanceAfter - targetBufferBalance;
    }

    function _mintInternal(
        uint256 _bufferBalance,
        uint256 _stakedBalance,
        uint256 _incrementalAudio
    ) internal {
        uint256 totalSupply = totalSupply();
        uint256 allocationToStake =
            _calculateAllocationToStake(_bufferBalance, _incrementalAudio, _stakedBalance, totalSupply);
        _stake(allocationToStake);

        uint256 audioHoldings = _bufferBalance + (_stakedBalance);
        uint256 mintAmount = _calculateMintAmount(_incrementalAudio, audioHoldings, totalSupply);
        return super._mint(msg.sender, mintAmount);
    }

    /**
     * @dev Lock mint, burn, transfer and transferFrom functions for _address
     * for BLOCK_LOCK_COUNT blocks
     */
    function _lock(address _address) internal {
        lastLockedBlock[_address] = block.number + BLOCK_LOCK_COUNT;
    }

    /**
     * @notice xAUDIO only stakes when cooldown is not active
     * @param _amount: allocation to staked balance
     */
    function _stake(uint256 _amount) internal {
        if (_amount > 0 && !cooldownActivated) {
            delegateManager.delegateStake(targetSP, _amount);
        }
    }

    function _cooldown(uint256 _amount) internal {
        cooldownActivated = true;
        delegateManager.requestUndelegateStake(targetSP, _amount);
    }

    function _disableCooldown() internal {
        cooldownActivated = false;
        delegateManager.cancelUndelegateStakeRequest();
    }

    function _unstake() internal {
        delegateManager.undelegateStake();
    }

    function _claimRewards() internal {
        delegateManager.claimRewards(targetSP);
    }

    /**
     * @notice Records admin activity
     * @notice Because Audio staking "locks" capital in contract and only admin
     * has power to cooldown and redeem in normal course, this function
     * certifies that admin is still active and capital is accessible
     * @notice If not certified for a period exceeding LIQUIDATION_TIME_PERIOD,
     * emergencyCooldown and emergencyRedeem become available to non-admin
     * caller
     */
    function _updateAdminActiveTimestamp() internal {
        adminActiveTimestamp = block.timestamp;
    }

    /* ========================================================================================= */
    /*                                         Fallbacks                                         */
    /* ========================================================================================= */

    receive() external payable {
        require(msg.sender != tx.origin, "Errant ETH deposit");
    }
}
