// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../Interfaces/IStabilityPoolManager.sol";
import "../Interfaces/ICommunityIssuance.sol";
import "../Dependencies/BaseMath.sol";
import "../Dependencies/LiquityMath.sol";
import "../Dependencies/CheckContract.sol";

contract CommunityIssuance is ICommunityIssuance, OwnableUpgradeable, CheckContract, BaseMath {
	using SafeMathUpgradeable for uint256;
	using SafeERC20Upgradeable for IERC20Upgradeable;

	string public constant NAME = "CommunityIssuance";
	uint256 public constant SECONDS_IN_ONE_MINUTE = 60;

	/* The issuance factor F determines the curvature of the issuance curve.
	 *
	 * Minutes in one year: 60*24*365 = 525600
	 *
	 * For 50% of remaining tokens issued each year, with minutes as time units, we have:
	 *
	 * F ** 525600 = 0.5
	 *
	 * Re-arranging:
	 *
	 * 525600 * ln(F) = ln(0.5)
	 * F = 0.5 ** (1/525600)
	 * F = 0.999998681227695000
	 */
	uint256 public constant ISSUANCE_FACTOR = 999998681227695000;

	IERC20Upgradeable public vstaToken;
	IStabilityPoolManager public stabilityPoolManager;

	mapping(address => uint256) public totalVSTAIssued;
	mapping(address => uint256) public deploymentTime;
	mapping(address => uint256) public VSTASupplyCaps;

	address public adminContract;

	bool public isInitialized;

	modifier activeStabilityPoolOnly(address _pool) {
		require(deploymentTime[_pool] != 0, "CommunityIssuance: Pool needs to be added first.");
		_;
	}

	modifier isController() {
		require(msg.sender == owner() || msg.sender == adminContract, "Invalid Permission");
		_;
	}

	// --- Functions ---
	function setAddresses(
		address _vstaTokenAddress,
		address _stabilityPoolManagerAddress,
		address _adminContract
	) external override initializer {
		require(!isInitialized, "Already initialized");
		checkContract(_vstaTokenAddress);
		checkContract(_stabilityPoolManagerAddress);
		checkContract(_adminContract);
		isInitialized = true;
		__Ownable_init();

		adminContract = _adminContract;

		vstaToken = IERC20Upgradeable(_vstaTokenAddress);
		stabilityPoolManager = IStabilityPoolManager(_stabilityPoolManagerAddress);

		emit VSTATokenAddressSet(_vstaTokenAddress);
		emit StabilityPoolAddressSet(_stabilityPoolManagerAddress);
	}

	function addFundToStabilityPool(address _pool, uint256 _assignedSupply)
		external
		override
		isController
	{
		_addFundToStabilityPoolFrom(_pool, _assignedSupply, msg.sender);
	}

	function addFundToStabilityPoolFrom(
		address _pool,
		uint256 _assignedSupply,
		address _spender
	) external override isController {
		_addFundToStabilityPoolFrom(_pool, _assignedSupply, _spender);
	}

	function _addFundToStabilityPoolFrom(
		address _pool,
		uint256 _assignedSupply,
		address _spender
	) internal {
		require(
			stabilityPoolManager.isStabilityPool(_pool),
			"CommunityIssuance: Invalid Stability Pool"
		);

		if (deploymentTime[_pool] == 0) {
			deploymentTime[_pool] = block.timestamp;
		}

		VSTASupplyCaps[_pool] += _assignedSupply;
		vstaToken.safeTransferFrom(_spender, address(this), _assignedSupply);
	}

	function transferFundToAnotherStabilityPool(
		address _target,
		address _receiver,
		uint256 _quantity
	)
		external
		override
		onlyOwner
		activeStabilityPoolOnly(_target)
		activeStabilityPoolOnly(_receiver)
	{
		uint256 newCap = VSTASupplyCaps[_target].sub(_quantity);
		require(
			totalVSTAIssued[_target] <= newCap,
			"CommunityIssuance: Stability Pool doesn't have enough supply."
		);

		VSTASupplyCaps[_target] -= _quantity;
		VSTASupplyCaps[_receiver] += _quantity;

		if (totalVSTAIssued[_target] == VSTASupplyCaps[_target]) {
			disableStabilityPool(_target);
		}
	}

	function disableStabilityPool(address _pool) internal {
		deploymentTime[_pool] = 0;
		VSTASupplyCaps[_pool] = 0;
		totalVSTAIssued[_pool] = 0;
	}

	function issueVSTA() external override returns (uint256) {
		_requireCallerIsStabilityPool();

		uint256 latestTotalVSTAIssued = VSTASupplyCaps[msg.sender]
			.mul(_getCumulativeIssuanceFraction(msg.sender))
			.div(DECIMAL_PRECISION);
		uint256 issuance = latestTotalVSTAIssued.sub(totalVSTAIssued[msg.sender]);

		totalVSTAIssued[msg.sender] = latestTotalVSTAIssued;
		emit TotalVSTAIssuedUpdated(msg.sender, latestTotalVSTAIssued);

		return issuance;
	}

	/* Gets 1-f^t    where: f < 1

    f: issuance factor that determines the shape of the curve
    t:  time passed since last VSTA issuance event  */
	///Require StabilityPool for testing.
	function _getCumulativeIssuanceFraction(address stabilityPool)
		internal
		view
		returns (uint256)
	{
		require(deploymentTime[stabilityPool] != 0, "Stability pool hasn't been assigned");
		// Get the time passed since deployment
		uint256 timePassedInMinutes = block.timestamp.sub(deploymentTime[stabilityPool]).div(
			SECONDS_IN_ONE_MINUTE
		);

		// f^t
		uint256 power = LiquityMath._decPow(ISSUANCE_FACTOR, timePassedInMinutes);

		//  (1 - f^t)
		uint256 cumulativeIssuanceFraction = (uint256(DECIMAL_PRECISION).sub(power));
		assert(cumulativeIssuanceFraction <= DECIMAL_PRECISION); // must be in range [0,1]

		return cumulativeIssuanceFraction;
	}

	function sendVSTA(address _account, uint256 _VSTAamount) external override {
		_requireCallerIsStabilityPool();

		uint256 balanceVSTA = vstaToken.balanceOf(address(this));
		uint256 safeAmount = balanceVSTA >= _VSTAamount ? _VSTAamount : balanceVSTA;

		if (safeAmount == 0) {
			return;
		}

		vstaToken.transfer(_account, safeAmount);
	}

	// --- 'require' functions ---

	function _requireCallerIsStabilityPool() internal view {
		require(
			stabilityPoolManager.isStabilityPool(msg.sender),
			"CommunityIssuance: caller is not SP"
		);
	}
}
