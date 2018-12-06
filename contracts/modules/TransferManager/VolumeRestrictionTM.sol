pragma solidity ^0.4.24;

import "./ITransferManager.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "../../libraries/BokkyPooBahsDateTimeLibrary.sol";

contract VolumeRestrictionTM is ITransferManager {
    
    using SafeMath for uint256;

    // permission definition
    bytes32 public constant ADMIN = "ADMIN";

    enum RestrictionType { Fixed, Percentage }

    struct VolumeRestriction {
        // If typeOfRestriction is `Percentage` then allowedTokens will be in
        // the % (w.r.t to totalSupply) with a multiplier of 10**16 . else it 
        // will be fixed amount of tokens
        uint256 allowedTokens;
        uint256 startTime;
        uint256 rollingPeriodInDays;
        uint256 endTime;
        RestrictionType typeOfRestriction;
    }

    struct BucketDetails {
        uint256 lastTradedDayTime;
        uint256 sumOfLastPeriod;   // It is the sum of transacted amount within the last rollingPeriodDays 
        uint256 daysCovered;    // No of days covered till (from the startTime of VolumeRestriction)
        uint256 dailyLastTradedDayTime;
    }

    // Global restriction that applies to all token holders
    VolumeRestriction public defaultRestriction;
    // Daily global restriction that applies to all token holders (Total ST traded daily is restricted)
    VolumeRestriction public defaultDailyRestriction;
    // Restriction stored corresponds to a particular token holder
    mapping(address => VolumeRestriction) public individualRestriction;
    // Daily restriction stored corresponds to a particular token holder
    mapping(address => VolumeRestriction) public individualDailyRestriction;
    // Storing _from => day's timestamp => total amount transact in a day --individual
    mapping(address => mapping(uint256 => uint256)) internal bucket;
    // Storing the information that used to validate the transaction
    mapping(address => BucketDetails) internal bucketToUser;
    // Storing the information related to default restriction
    mapping(address => BucketDetails) internal defaultBucketToUser;
    // List of wallets that are exempted from all the restrictions applied by the this contract
    mapping(address => bool) public exemptList;

    // Emit when the token holder is added/removed from the exemption list
    event ChangedExemptWalletList(address indexed _wallet, bool _change);
    // Emit when the new individual restriction is added corresponds to new token holders
    event AddNewIndividualRestriction(
        address indexed _holder,
        uint256 _allowedTokens,
        uint256 _startTime,
        uint256 _rollingPeriodInDays,
        uint256 _endTime,
        uint256 _typeOfRestriction
    );
    // Emit when the individual restriction is modified for a given address
    event ModifyIndividualRestriction(
        address indexed _holder,
        uint256 _allowedTokens,
        uint256 _startTime,
        uint256 _rollingPeriodInDays,
        uint256 _endTime,
        uint256 _typeOfRestriction
    );
    // Emit when the new global restriction is added
    event AddDefaultRestriction(
        uint256 _allowedTokens,
        uint256 _startTime,
        uint256 _rollingPeriodInDays,
        uint256 _endTime,
        uint256 _typeOfRestriction
    );
    // Emit when the new daily (Default) restriction is added
    event AddDefaultDailyRestriction(
        uint256 _allowedTokens,
        uint256 _startTime,
        uint256 _rollingPeriodInDays,
        uint256 _endTime,
        uint256 _typeOfRestriction
    );
    // Emit when default restriction get modified
    event ModifyDefaultRestriction(
        uint256 _allowedTokens,
        uint256 _startTime,
        uint256 _rollingPeriodInDays,
        uint256 _endTime,
        uint256 _typeOfRestriction
    );
    // Emit when daily default restriction get modified
    event ModifyDefaultDailyRestriction(
        uint256 _allowedTokens,
        uint256 _startTime,
        uint256 _rollingPeriodInDays,
        uint256 _endTime,
        uint256 _typeOfRestriction
    );
    // Emit when the individual restriction gets removed
    event IndividualRestrictionRemoved(address _user);
    // Emit when the default restriction gets removed
    event DefaultRestrictionRemoved();
    // Emit when the daily default restriction gets removed
    event DefaultDailyRestrictionRemoved();

    /**
     * @notice Constructor
     * @param _securityToken Address of the security token
     * @param _polyAddress Address of the polytoken
     */
    constructor (address _securityToken, address _polyAddress)
    public
    Module(_securityToken, _polyAddress)
    {

    }

    /**
     * @notice Used to verify the transfer/transferFrom transaction and prevent tranaction
     * whose volume of tokens will voilate the maximum volume transfer restriction
     * @param _from Address of the sender
     * @param _amount The amount of tokens to transfer
     * @param _isTransfer Whether or not this is an actual transfer or just a test to see if the tokens would be transferrable
     */
    function verifyTransfer(address _from, address /*_to */, uint256 _amount, bytes /*_data*/, bool _isTransfer) public returns (Result) {
        // If `_from` is present in the exemptionList or it is `0x0` address then it will not follow the vol restriction
        if (!paused && _from != address(0) && !exemptList[_from]) {
            // Function must only be called by the associated security token if _isTransfer == true
            require(msg.sender == securityToken || !_isTransfer);
            // Checking the individual restriction if the `_from` comes in the individual category 
            if (individualRestriction[_from].endTime >= now && individualRestriction[_from].startTime <= now 
                || individualDailyRestriction[_from].endTime >= now && individualDailyRestriction[_from].startTime <= now) {

                return _individualRestrictionCheck(_from, _amount, _isTransfer);
                // If the `_from` doesn't fall under the individual category. It will processed with in the global category automatically
            } else if (defaultRestriction.endTime >= now && defaultRestriction.startTime <= now
                || defaultDailyRestriction.endTime >= now && defaultDailyRestriction.startTime <= now) {
                
                return _defaultRestrictionCheck(_from, _amount, _isTransfer);
            }
        } 
        return Result.NA;
    }

    /**
     * @notice Add/Remove wallet address from the exempt list
     * @param _wallet Ethereum wallet/contract address that need to be exempted
     * @param _change Boolean value used to add (i.e true) or remove (i.e false) from the list 
     */
    function changeExemptWalletList(address _wallet, bool _change) public withPerm(ADMIN) {
        require(_wallet != address(0), "Invalid address");
        exemptList[_wallet] = _change;
        emit ChangedExemptWalletList(_wallet, _change);
    }

    /**
     * @notice Use to add the new individual restriction for a given token holder
     * @param _holder Address of the token holder, whom restriction will be implied
     * @param _allowedTokens Amount of tokens allowed to be trade for a given address.
     * @param _startTime Unix timestamp at which restriction get into effect
     * @param _rollingPeriodInDays Rolling period in days (Minimum value should be 1 day)
     * @param _endTime Unix timestamp at which restriction effects will gets end.
     * @param _restrictionType It will be 0 or 1 (i.e 0 for fixed while 1 for Percentage)
     */
    function addIndividualRestriction(
        address _holder,
        uint256 _allowedTokens,
        uint256 _startTime,
        uint256 _rollingPeriodInDays,
        uint256 _endTime,
        uint256 _restrictionType 
    )
        external
        withPerm(ADMIN)
    {
        _addIndividualRestriction(
            _holder,
            _allowedTokens,
            _startTime,
            _rollingPeriodInDays,
            _endTime,
            _restrictionType
        );
    }

    /**
     * @notice Use to add the new individual restriction for multiple token holders
     * @param _holders Array of address of the token holders, whom restriction will be implied
     * @param _allowedTokens Array of amount of tokens allowed to be trade for a given address.
     * @param _startTimes Array of unix timestamps at which restrictions get into effect
     * @param _rollingPeriodInDays Array of rolling period in days (Minimum value should be 1 day)
     * @param _endTimes Array of unix timestamps at which restriction effects will gets end.
     * @param _restrictionTypes Array of restriction types value will be 0 or 1 (i.e 0 for fixed while 1 for Percentage)
     */
    function addIndividualRestrictionMulti(
        address[] _holders,
        uint256[] _allowedTokens,
        uint256[] _startTimes,
        uint256[] _rollingPeriodInDays,
        uint256[] _endTimes,
        uint256[] _restrictionTypes 
    )
        public
        withPerm(ADMIN)
    {
        _checkLengthOfArray(_allowedTokens, _startTimes, _rollingPeriodInDays, _endTimes, _restrictionTypes);
        require(_holders.length == _allowedTokens.length, "Length mismatch");
        for (uint256 i = 0; i < _holders.length; i++) {
            _addIndividualRestriction(
                _holders[i],
                _allowedTokens[i],
                _startTimes[i],
                _rollingPeriodInDays[i],
                _endTimes[i],
                _restrictionTypes[i] 
            );
        }
    }

    /**
     * @notice Use to add the new default restriction for all token holder
     * @param _allowedTokens Amount of tokens allowed to be traded for all token holder.
     * @param _startTime Unix timestamp at which restriction get into effect
     * @param _rollingPeriodInDays Rolling period in days (Minimum value should be 1 day)
     * @param _endTime Unix timestamp at which restriction effects will gets end.
     * @param _restrictionType It will be 0 or 1 (i.e 0 for fixed while 1 for Percentage)
     */
    function addDefaultRestriction(
        uint256 _allowedTokens,
        uint256 _startTime,
        uint256 _rollingPeriodInDays,
        uint256 _endTime,
        uint256 _restrictionType 
    )
        external
        withPerm(ADMIN)
    {   
        require(
            defaultRestriction.endTime < now,
            "Not allowed"
        );
        _checkInputParams(_allowedTokens, _startTime, _rollingPeriodInDays, _endTime, _restrictionType);
        defaultRestriction = VolumeRestriction(
            _allowedTokens,
            _startTime,
            _rollingPeriodInDays,
            _endTime,
            RestrictionType(_restrictionType)
        );
        emit AddDefaultRestriction(
            _allowedTokens,
            _startTime,
            _rollingPeriodInDays,
            _endTime,
            _restrictionType
        );
    }

    /**
     * @notice Use to add the new default daily restriction for all token holder
     * @param _allowedTokens Amount of tokens allowed to be traded for all token holder.
     * @param _startTime Unix timestamp at which restriction get into effect
     * @param _endTime Unix timestamp at which restriction effects will gets end.
     * @param _restrictionType It will be 0 or 1 (i.e 0 for fixed while 1 for Percentage)
     */
    function addDefaultDailyRestriction(
        uint256 _allowedTokens,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _restrictionType 
    )
        external
        withPerm(ADMIN)
    {   
        require(
            defaultDailyRestriction.endTime < now,
            "Not Allowed"
        );
        _checkInputParams(_allowedTokens, _startTime, 1, _endTime, _restrictionType);
        defaultDailyRestriction = VolumeRestriction(
            _allowedTokens,
            _startTime,
            1,
            _endTime,
            RestrictionType(_restrictionType)
        );
        emit AddDefaultDailyRestriction(
            _allowedTokens,
            _startTime,
            1,
            _endTime,
            _restrictionType
        );
    }

    /**
     * @notice use to remove the individual restriction for a given address
     * @param _user Address of the user 
     */
    function removeIndividualRestriction(address _user) external withPerm(ADMIN) {
        _removeIndividualRestriction(_user);
    }

    /**
     * @notice use to remove the individual restriction for a given address
     * @param _users Array of address of the user 
     */
    function removeIndividualRestrictionMulti(address[] _users) external withPerm(ADMIN) {
        for (uint256 i = 0; i < _users.length; i++) {
            _removeIndividualRestriction(_users[i]);
        }
    }

    /**
     * @notice Use to remove the default restriction
     */
    function removeDefaultRestriction() public withPerm(ADMIN) {
        require(defaultRestriction.endTime != 0);
        defaultRestriction = VolumeRestriction(0, 0, 0, 0, RestrictionType(0));
        emit DefaultRestrictionRemoved();
    }

    /**
     * @notice Use to remove the daily default restriction
     */
    function removeDefaultDailyRestriction() external withPerm(ADMIN) {
        require(defaultDailyRestriction.endTime != 0);
        defaultDailyRestriction = VolumeRestriction(0, 0, 0, 0, RestrictionType(0));
        emit DefaultDailyRestrictionRemoved();
    } 

    /**
     * @notice Use to modify the existing individual restriction for a given token holder
     * @param _holder Address of the token holder, whom restriction will be implied
     * @param _allowedTokens Amount of tokens allowed to be trade for a given address.
     * @param _startTime Unix timestamp at which restriction get into effect
     * @param _rollingPeriodInDays Rolling period in days (Minimum value should be 1 day)
     * @param _endTime Unix timestamp at which restriction effects will gets end.
     * @param _restrictionType It will be 0 or 1 (i.e 0 for fixed while 1 for Percentage)
     */
    function modifyIndividualRestriction(
        address _holder,
        uint256 _allowedTokens,
        uint256 _startTime,
        uint256 _rollingPeriodInDays,
        uint256 _endTime,
        uint256 _restrictionType 
    )
        external
        withPerm(ADMIN)
    {
        _modifyIndividualRestriction(
            _holder,
            _allowedTokens,
            _startTime,
            _rollingPeriodInDays,
            _endTime,
            _restrictionType
        );
    }

    /**
     * @notice Use to modify the existing individual restriction for multiple token holders
     * @param _holders Array of address of the token holders, whom restriction will be implied
     * @param _allowedTokens Array of amount of tokens allowed to be trade for a given address.
     * @param _startTimes Array of unix timestamps at which restrictions get into effect
     * @param _rollingPeriodInDays Array of rolling period in days (Minimum value should be 1 day)
     * @param _endTimes Array of unix timestamps at which restriction effects will gets end.
     * @param _restrictionTypes Array of restriction types value will be 0 or 1 (i.e 0 for fixed while 1 for Percentage)
     */
    function modifyIndividualRestrictionMulti(
        address[] _holders,
        uint256[] _allowedTokens,
        uint256[] _startTimes,
        uint256[] _rollingPeriodInDays,
        uint256[] _endTimes,
        uint256[] _restrictionTypes  
    )
        public
        withPerm(ADMIN)
    {
        _checkLengthOfArray(_allowedTokens, _startTimes, _rollingPeriodInDays, _endTimes, _restrictionTypes);
        require(_holders.length == _allowedTokens.length, "Length mismatch");
        for (uint256 i = 0; i < _holders.length; i++) {
            _modifyIndividualRestriction(
                _holders[i],
                _allowedTokens[i],
                _startTimes[i],
                _rollingPeriodInDays[i],
                _endTimes[i],
                _restrictionTypes[i] 
            );
        }
    } 

    /**
     * @notice Use to modify the global restriction for all token holder
     * @param _allowedTokens Amount of tokens allowed to be traded for all token holder.
     * @param _startTime Unix timestamp at which restriction get into effect
     * @param _rollingPeriodInDays Rolling period in days (Minimum value should be 1 day)
     * @param _endTime Unix timestamp at which restriction effects will gets end.
     * @param _restrictionType It will be 0 or 1 (i.e 0 for fixed while 1 for Percentage)
     */
    function modifyDefaultRestriction(
        uint256 _allowedTokens,
        uint256 _startTime,
        uint256 _rollingPeriodInDays,
        uint256 _endTime,
        uint256 _restrictionType
    )
        external
        withPerm(ADMIN)
    {   
        require(defaultRestriction.startTime > now, "Not allowed");    
        _checkInputParams(_allowedTokens, _startTime, _rollingPeriodInDays, _endTime, _restrictionType);
        defaultRestriction = VolumeRestriction(
            _allowedTokens,
            _startTime,
            _rollingPeriodInDays,
            _endTime,
            RestrictionType(_restrictionType)
        );
        emit ModifyDefaultRestriction(
            _allowedTokens,
            _startTime,
            _rollingPeriodInDays,
            _endTime,
            _restrictionType
        );
    }

    /**
     * @notice Use to modify the daily default restriction for all token holder
     * @param _allowedTokens Amount of tokens allowed to be traded for all token holder.
     * @param _startTime Unix timestamp at which restriction get into effect
     * @param _endTime Unix timestamp at which restriction effects will gets end.
     * @param _restrictionType It will be 0 or 1 (i.e 0 for fixed while 1 for Percentage)
     */
    function modifyDefaultDailyRestriction(
        uint256 _allowedTokens,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _restrictionType
    )
        external
        withPerm(ADMIN)
    {   
        require(defaultDailyRestriction.startTime > now, "Not allowed");    
        _checkInputParams(_allowedTokens, _startTime, 1, _endTime, _restrictionType);
        defaultDailyRestriction = VolumeRestriction(
            _allowedTokens,
            _startTime,
            1,
            _endTime,
            RestrictionType(_restrictionType)
        );
        emit ModifyDefaultDailyRestriction(
            _allowedTokens,
            _startTime,
            1,
            _endTime,
            _restrictionType
        );
    }

    /**
    * @notice Internal function used to validate the transaction for a given address
    * If it validates then it also update the storage corressponds to the default restriction
    */
    function _defaultRestrictionCheck(address _from, uint256 _amount, bool _isTransfer) internal returns (Result) {   
        // using the variable to avoid stack too deep error
        uint256 daysCovered = defaultRestriction.rollingPeriodInDays;
        uint256 fromTimestamp = 0;
        uint256 sumOfLastPeriod = 0;
        uint256 dailyTime = 0;
        bool allowedDefault = true;
        bool allowedDaily;
        if (defaultRestriction.endTime >= now && defaultRestriction.startTime <= now) {
            if (defaultBucketToUser[_from].lastTradedDayTime < defaultRestriction.startTime) {
                // It will execute when the txn is performed first time after the addition of individual restriction
                fromTimestamp = defaultRestriction.startTime;
            } else {
                // Picking up the last timestamp
                fromTimestamp = defaultBucketToUser[_from].lastTradedDayTime;
            }
        
            // Check with the bucket and parse all the new timestamps to calculate the sumOfLastPeriod
            // re-using the local variables to avoid the stack too deep error.
            (sumOfLastPeriod, fromTimestamp, daysCovered) = _bucketCheck(
                fromTimestamp,
                BokkyPooBahsDateTimeLibrary.diffDays(fromTimestamp, now),
                _from,
                daysCovered,
                defaultBucketToUser[_from]
            );
            // validation of the transaction amount
            if (!_checkValidAmountToTransact(sumOfLastPeriod, _amount, defaultRestriction)) {
                allowedDefault == false;
            }
        }
        (allowedDaily, dailyTime) = _dailyTxCheck(_from, _amount, fromTimestamp, defaultBucketToUser[_from].dailyLastTradedDayTime, defaultDailyRestriction);
        
        if (_isTransfer) {
            _updateStorage(
                _from,
                _amount,
                fromTimestamp,
                sumOfLastPeriod,
                daysCovered,
                dailyTime,
                defaultBucketToUser[_from]
            );
        }
        return ((allowedDaily && allowedDefault) == true ? Result.NA : Result.INVALID);
    }

    /**
     * @notice Internal function used to validate the transaction for a given address
     * If it validates then it also update the storage corressponds to the individual restriction
     */
    function _individualRestrictionCheck(address _from, uint256 _amount, bool _isTransfer) internal returns (Result) {   
        // using the variable to avoid stack too deep error
        uint256 daysCovered = individualRestriction[_from].rollingPeriodInDays;
        uint256 fromTimestamp = 0;
        uint256 sumOfLastPeriod = 0;
        uint256 dailyTime = 0;
        bool allowedIndividual = true;
        bool allowedDaily;
        if (individualRestriction[_from].endTime >= now && individualRestriction[_from].startTime <= now) {
            if (bucketToUser[_from].lastTradedDayTime < individualRestriction[_from].startTime) {
                // It will execute when the txn is performed first time after the addition of individual restriction
                fromTimestamp = individualRestriction[_from].startTime;
            } else {
                // Picking up the last timestamp
                fromTimestamp = bucketToUser[_from].lastTradedDayTime;
            }
        
            // Check with the bucket and parse all the new timestamps to calculate the sumOfLastPeriod
            // re-using the local variables to avoid the stack too deep error.
            (sumOfLastPeriod, fromTimestamp, daysCovered) = _bucketCheck(
                fromTimestamp,
                BokkyPooBahsDateTimeLibrary.diffDays(fromTimestamp, now),
                _from,
                daysCovered,
                bucketToUser[_from]
            );
            // validation of the transaction amount
            if (!_checkValidAmountToTransact(sumOfLastPeriod, _amount, individualRestriction[_from])) {
                allowedIndividual == false;
            }
        }
        (allowedDaily, dailyTime) = _dailyTxCheck(_from, _amount, fromTimestamp, bucketToUser[_from].dailyLastTradedDayTime, individualDailyRestriction[_from]);
        
        if (_isTransfer) {
            _updateStorage(
                _from,
                _amount,
                fromTimestamp,
                sumOfLastPeriod,
                daysCovered,
                dailyTime,
                bucketToUser[_from]
            );
        }

        return ((allowedDaily && allowedIndividual) == true ? Result.NA : Result.INVALID);
    }

    function _dailyTxCheck(
        address from,
        uint256 amount,
        uint256 fromTimestamp,
        uint256 dailyLastTradedDayTime,
        VolumeRestriction restriction
    ) 
        internal
        view
        returns(bool, uint256)
    {
        // Checking whether the daily restriction is added or not if yes then calculate
        // the total amount get traded on a particular day (~ _fromTime)
        if ( now <= restriction.endTime && now >= restriction.startTime) {   
            uint256 txSumOfDay = 0;
            if (now.sub(dailyLastTradedDayTime) < 1 days || dailyLastTradedDayTime == 0) {
                txSumOfDay = bucket[from][dailyLastTradedDayTime] >= bucket[from][fromTimestamp] ? bucket[from][dailyLastTradedDayTime] : bucket[from][fromTimestamp];
            } else {
                txSumOfDay = 0;
                dailyLastTradedDayTime = now;
            }
            return (_checkValidAmountToTransact(txSumOfDay, amount, restriction), dailyLastTradedDayTime);
        }
        return (true, dailyLastTradedDayTime);
    }

    /// Internal function for the bucket check
    function _bucketCheck(
        uint256 _fromTime,
        uint256 _diffDays,
        address _from,
        uint256 _rollingPeriodInDays,
        BucketDetails memory _bucketDetails
    )
        internal
        view
        returns (uint256, uint256, uint256)
    {
        uint256 counter = _bucketDetails.daysCovered;
        uint256 sumOfLastPeriod = _bucketDetails.sumOfLastPeriod;
        uint256 i = 0;
        if (_diffDays >= _rollingPeriodInDays) {
            // If the difference of days is greater than the rollingPeriod then sumOfLastPeriod will always be zero
            sumOfLastPeriod = 0;
        } else {
            for (i = 0; i < _diffDays; i++) {
            // This condition is to check whether the first rolling period is covered or not
            // if not then it continues and adding 0 value into sumOfLastPeriod without subtracting
            // the earlier value at that index
            if (counter >= _rollingPeriodInDays) {
                // Subtracting the former value(Sum of all the txn amount of that day) from the sumOfLastPeriod
                sumOfLastPeriod = sumOfLastPeriod.
                sub(bucket[_from][_bucketDetails.lastTradedDayTime.sub((counter.sub(_rollingPeriodInDays)).mul(1 days))]);
            }
            // Adding the last amount that is transacted on the `_fromTime` not actually doing it but left written to understand
            // the alogrithm
            //_bucketDetails.sumOfLastPeriod = _bucketDetails.sumOfLastPeriod.add(uint256(0));
            // Storing all those timestamps whose total transacted value is 0
            counter++;
            }
        }
        // calculating the timestamp that will used as an index of the next bucket
        // i.e buckets period will be look like this T1 to T2-1, T2 to T3-1 .... 
        // where T1,T2,T3 are timestamps having 24 hrs difference
        _fromTime = _fromTime.add(_diffDays.mul(1 days));
        return (sumOfLastPeriod, _fromTime, counter);
    }

    function _checkValidAmountToTransact(
        uint256 _sumOfLastPeriod,
        uint256 _amountToTransact,
        VolumeRestriction _restriction
    ) 
        internal
        view
        returns (bool)
    {    
        uint256 _allowedAmount = 0;
        if (_restriction.typeOfRestriction == RestrictionType.Percentage) {
            _allowedAmount = (_restriction.allowedTokens.mul(ISecurityToken(securityToken).totalSupply())) / uint256(10) ** 18;
        } else {
            _allowedAmount = _restriction.allowedTokens;
        }
        // Validation on the amount to transact
        return (_allowedAmount >= _sumOfLastPeriod.add(_amountToTransact));
    }

    function _updateStorage(
        address _from,
        uint256 _amount,
        uint256 _lastTradedDayTime,
        uint256 _sumOfLastPeriod,
        uint256 _daysCovered, 
        uint256 _dailyLastTradedDayTime,
        BucketDetails storage _details
    )
        internal 
    {   
        // Cheap storage technique
        if (_details.lastTradedDayTime != _lastTradedDayTime) {
            // Assigning the latest transaction timestamp of the day
            _details.lastTradedDayTime = _lastTradedDayTime;
        }
        if (_lastTradedDayTime != 0 && _lastTradedDayTime != _dailyLastTradedDayTime) {
            // Assigning the latest transaction timestamp of the day
            _details.dailyLastTradedDayTime = _lastTradedDayTime;
        } else if (_details.dailyLastTradedDayTime != _dailyLastTradedDayTime) {
            // Assigning the latest transaction timestamp of the day
            _details.dailyLastTradedDayTime = _dailyLastTradedDayTime;
        }
        if (_details.daysCovered != _daysCovered) {
                _details.daysCovered = _daysCovered;
        }
        if (_amount != 0) {
            _details.sumOfLastPeriod = _sumOfLastPeriod.add(_amount);
            _dailyLastTradedDayTime = _details.dailyLastTradedDayTime;
            // Increasing the total amount of the day by `_amount`
            bucket[_from][_dailyLastTradedDayTime] = bucket[_from][_dailyLastTradedDayTime].add(_amount);
        }  
    }

    function _removeIndividualRestriction(address _user) internal {
        require(_user != address(0), "Invalid address");
        require(individualRestriction[_user].endTime != 0, "Not present");
        individualRestriction[_user] = VolumeRestriction(0, 0, 0, 0, RestrictionType(0));
        bucketToUser[_user].lastTradedDayTime = 0;
        bucketToUser[_user].sumOfLastPeriod = 0;
        bucketToUser[_user].daysCovered = 0;
        emit IndividualRestrictionRemoved(_user);
    }

    function _modifyIndividualRestriction(
        address _holder,
        uint256 _allowedTokens,
        uint256 _startTime,
        uint256 _rollingPeriodInDays,
        uint256 _endTime,
        uint256 _restrictionType 
    )
        internal
    {   
        _checkInputParams(_allowedTokens, _startTime, _rollingPeriodInDays, _endTime, _restrictionType);
        require(individualRestriction[_holder].startTime > now, "Not allowed");
        
        individualRestriction[_holder] = VolumeRestriction(
            _allowedTokens,
            _startTime,
            _rollingPeriodInDays,
            _endTime,
            RestrictionType(_restrictionType)
        );
        emit ModifyIndividualRestriction(
            _holder,
            _allowedTokens,
            _startTime,
            _rollingPeriodInDays,
            _endTime,
            _restrictionType
        );
    }

    function _addIndividualRestriction(
        address _holder,
        uint256 _allowedTokens,
        uint256 _startTime,
        uint256 _rollingPeriodInDays,
        uint256 _endTime,
        uint256 _restrictionType 
    )
        internal
    {   
        require(
            individualRestriction[_holder].endTime < now,
            "Already present"
        );
        require(_holder != address(0) && !exemptList[_holder], "Invalid address");
        _checkInputParams(_allowedTokens, _startTime, _rollingPeriodInDays, _endTime, _restrictionType);
        
        if (individualRestriction[_holder].endTime != 0) {
            _removeIndividualRestriction(_holder);
        }
        individualRestriction[_holder] = VolumeRestriction(
            _allowedTokens,
            _startTime,
            _rollingPeriodInDays,
            _endTime,
            RestrictionType(_restrictionType)
        );
        emit AddNewIndividualRestriction(
            _holder,
            _allowedTokens,
            _startTime,
            _rollingPeriodInDays,
            _endTime,
            _restrictionType
        );
    }

    function _checkInputParams(
        uint256 _allowedTokens,
        uint256 _startTime, 
        uint256 _rollingPeriodDays, 
        uint256 _endTime,
        uint256 _restrictionType 
    ) 
        internal
        view
    {
        require(_restrictionType == 0 || _restrictionType == 1, "Invalid type");
        if (_restrictionType == uint256(RestrictionType.Fixed)) {
            require(_allowedTokens > 0, "Invalid value");
        } else {
            require(
                _allowedTokens > 0 && _allowedTokens <= 100 * 10 ** 16,
                "Percentage is not within (0,100]"
            );
        }
        require(_startTime >= now && _endTime > _startTime);
        // Maximum limit for the rollingPeriod is 365 days
        require(_rollingPeriodDays >= 1 && _rollingPeriodDays <= 365);
        require(BokkyPooBahsDateTimeLibrary.diffDays(_startTime, _endTime) >= _rollingPeriodDays);
    }   

    function _checkLengthOfArray(
        uint256[] _allowedTokens,
        uint256[] _startTimes,
        uint256[] _rollingPeriodInDays,
        uint256[] _endTimes,
        uint256[] _restrictionTypes
    )
        internal
        pure 
    {
        require(
            _allowedTokens.length == _startTimes.length &&
            _startTimes.length == _rollingPeriodInDays.length &&
            _rollingPeriodInDays.length == _endTimes.length &&
            _endTimes.length == _restrictionTypes.length,
            "Array length mismatch"
        );
    }

    /**
     * @notice Use to get the bucket details for a given address
     * @param _user Address of the token holder for whom the bucket details has queried
     * @return uint256 lastTradedDayTime
     * @return uint256 sumOfLastPeriod
     * @return uint256 days covered
     */
    function getBucketDetailsToUser(address _user) external view returns(uint256, uint256, uint256) {
        return(
            bucketToUser[_user].lastTradedDayTime,
            bucketToUser[_user].sumOfLastPeriod,
            bucketToUser[_user].daysCovered
        );
    }

    /**
     * @notice Use to get the volume of token that being traded at a particular day (`_at` + 24 hours) for a given user
     * @param _user Address of the token holder
     * @param _at Timestamp 
     */
    function getTotalTradeByuser(address _user, uint256 _at) external view returns(uint256) {
        return bucket[_user][_at];
    }

    /**
     * @notice This function returns the signature of configure function
     */
    function getInitFunction() public view returns(bytes4) {
        return bytes4(0);
    }

    /**
     * @notice Returns the permissions flag that are associated with Percentage transfer Manager
     */
    function getPermissions() public view returns(bytes32[]) {
        bytes32[] memory allPermissions = new bytes32[](1);
        allPermissions[0] = ADMIN;
        return allPermissions;
    }

}