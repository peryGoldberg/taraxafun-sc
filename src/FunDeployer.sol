// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IFunPool} from "./interfaces/IFunPool.sol";
import {IFunStorageInterface} from "./interfaces/IFunStorageInterface.sol";
import {IFunEventTracker} from "./interfaces/IFunEventTracker.sol";

contract FunDeployer is Ownable {
// הפונקציה יוצרת טוקן חדש עם שוק נזילות ראשוני, תוך ווידוא עמידה בתנאים פיננסיים.
    event funCreated( //אירוע יצירת הטוקן
        address indexed creator,
        address indexed funContract,
        address indexed tokenAddress,
        string name,
        string symbol,
        string data,
        uint256 totalSupply,
        uint256 initialReserve,
        uint256 timestamp
    );

    event royal( //אירוע הטוקן שנוצר
        address indexed tokenAddress, 
        uint256 liquidityAmount,
        uint256 tokenAmount, 
        uint256 time, 
        uint256 totalVolume
    );

    address public feeWallet;
    address public funStorage;
    address public eventTracker;
    address public funPool;

    /// deployment fee in wei
    uint256 public deploymentFee = 10000000; 
    // base of 10000 -> 500 equals 5%
    uint256 public antiSnipePer = 500; 
    // base of 10000 -> 1000 equals 10%
    uint256 public affiliatePer = 1000; 
    // base of 10000 -> 1000 means 10%
    uint256 public devFeePer = 1000; 
    // base of 10000 -> 100 equals 1%
    uint256 public tradingFeePer = 100; 
    // listing marketcap in $USD
    uint256 public listThreshold = 10; 
    /// virtual liquidity
    uint256 public initialReserveTARA = 100 ether; 

    mapping(address => uint256) public affiliateSpecialPer;
    mapping(address => bool) public affiliateSpecial;

    constructor(
        address _funPool, 
        address _feeWallet, 
        address _funStorage, 
        address _eventTracker
    ) Ownable(msg.sender) {
        funPool = _funPool;
        feeWallet = _feeWallet;
        funStorage = _funStorage;
        eventTracker = _eventTracker;
    }

    function createFun( //פונקציה ליצירת הטוקן- מקבלת את פרטי הטוקן החדש
        string memory _name,
        string memory _symbol,
        string memory _data,
        uint256 _totalSupply,
        uint256 _liquidityETHAmount,
        uint256 _amountAntiSnipe,
        uint256 _maxBuyPerWallet
    ) public payable { 
        // הפונקציה מקבלת נתוני טוקן חדשים (שם, סמל, היצע וכו') ומוודאת שהם בתחום ההגבלות
       //בודקת:
       // שהמשתמש לא עובר את הגבלת ה-אנטי סניפ  (קנייה אוטומטית נגד בוטים).
       // שהמשתמש שילם לפחות את העמלות והנזילות הנדרשות
        require(_amountAntiSnipe <= ((initialReserveTARA * antiSnipePer) / 10000), "over antisnipe restrictions");
        require(msg.value >= (deploymentFee + _liquidityETHAmount + _amountAntiSnipe), "fee amount error");
    //אם לא מאותחל, הוא מקבל ברירת מחדל של כל ההיצע
        if (_maxBuyPerWallet == 0) { 
            _maxBuyPerWallet = _totalSupply;
        }
    //feeWallet משתמש בפונקציה  כאל כדי לשלוח עמלה לכתובת .
    //אם התשלום נכשל require יפסיק את הביצוע
        (bool feeSuccess,) = feeWallet.call{value: deploymentFee}("");
        require(feeSuccess, "creation fee failed");
    //קורא לחוזה IFunPool ליצירת טוקן חדש.
//מעביר את שם הטוקן, הסמל, הכמות הכוללת והגבלות שונות.
//מצרף נזילות ראשונית (_liquidityETHAmount) כדי להתחיל מסחר.
//מחזיר את הכתובת של חוזה הטוקן החדש (funToken
        address funToken = IFunPool(funPool).initFun{value: _liquidityETHAmount}(
            [_name, _symbol], _totalSupply, msg.sender, [listThreshold, initialReserveTARA], _maxBuyPerWallet
        );
//שומר את המידע במערכת הסטורג כדי שאפשר יהיה לחפש ולעבוד עם הטוקן בעתיד.
        IFunStorageInterface(funStorage).addFunContract(
            msg.sender, (funToken), funToken, _name, _symbol, _data, _totalSupply, _liquidityETHAmount
        );
// רושם את האירוע  כדי שיהיה ניתן לראות בלוגים של הבלוקצ'יין את יצירת הטוקן.

        IFunEventTracker(eventTracker).createFunEvent(
            msg.sender,
            (funToken),
            (funToken),
            _name,
            _symbol,
            _data,
            _totalSupply,
            initialReserveTARA + _liquidityETHAmount,
            block.timestamp
        );

        if (_amountAntiSnipe > 0) {
            IFunPool(funPool).buyTokens{value: _amountAntiSnipe}(funToken, 0, msg.sender);
            IERC20(funToken).transfer(msg.sender, IERC20(funToken).balanceOf(address(this)));
        }

        emit funCreated( //הפעלת האירוע
            msg.sender,
            (funToken), //כתובת טוקן
            (funToken), //כתובת חוזה טוקן
            _name,
            _symbol,
            _data,
            _totalSupply,
            initialReserveTARA + _liquidityETHAmount,
            block.timestamp
        );
    }

    function getTradingFeePer() public view returns (uint256) { // מחזיר את עמלת המסחר 
        return tradingFeePer;
    }

    function getAffiliatePer(address _affiliateAddrs) public view returns (uint256) { //מחזיר: אם אתה שותף, מחזיר את ערך הטוקן. אם לא, מחזיר את שיעור העמלה הכללי
        if (affiliateSpecial[_affiliateAddrs]) {
            return affiliateSpecialPer[_affiliateAddrs];
        } else {
            return affiliatePer;
        }
    }

    function getDevFeePer() public view returns (uint256) { // מחזיר את האחוז שהמפתחים אמורים לקבל  
        return devFeePer;
    }

    function getSpecialAffiliateValidity(address _affiliateAddrs) public view returns (bool) {//בודק אם הכתובת קיימת במערך
        return affiliateSpecial[_affiliateAddrs]; 
    }

    function setDeploymentFee(uint256 _newdeploymentFee) public onlyOwner { //פונקציה שמשנה את העמלה של השימוש בפלטפורמה- מנהל בלבד  
        require(_newdeploymentFee > 0, "invalid fee");
        deploymentFee = _newdeploymentFee;
    }

    function setDevFeePer(uint256 _newOwnerFee) public onlyOwner { //משנה את העמלה של המפתחים- מנהל בלבד
        require(_newOwnerFee > 0, "invalid fee");
        devFeePer = _newOwnerFee;
    }

    function setSpecialAffiliateData(address _affiliateAddrs, bool _status, uint256 _specialPer) public onlyOwner { //משנה או מוסיף נתוני משתנה 
        affiliateSpecial[_affiliateAddrs] = _status;
        affiliateSpecialPer[_affiliateAddrs] = _specialPer;
    }

    function setInitReserveTARA(uint256 _newVal) public onlyOwner {//משנה את כמות הטוקנים 
        require(_newVal > 0, "invalid reserve");
        initialReserveTARA = _newVal;
    }

    function setFunPool(address _newfunPool) public onlyOwner {// משנה את  הנזילות הוירטואלית שאמורה להיות במערכת 
        require(_newfunPool != address(0), "invalid pool");
        funPool = _newfunPool;
    }

    function setFeeWallet(address _newFeeWallet) public onlyOwner { // משנה את כתובת הארנק שלשם מגיעות העמלות
        require(_newFeeWallet != address(0), "invalid wallet");
        feeWallet = _newFeeWallet;
    }

    function setStorageContract(address _newStorageContract) public onlyOwner { //משנה את הכתובת של החוזה שמאחסן נתונים
        require(_newStorageContract != address(0), "invalid storage");
        funStorage = _newStorageContract;
    }

    function setEventContract(address _newEventContract) public onlyOwner { //funEvent משנה את כתובת החוזה 
        require(_newEventContract != address(0), "invalid event");
        eventTracker = _newEventContract;
    }

    function setListThreshold(uint256 _newListThreshold) public onlyOwner {
        require(_newListThreshold > 0, "invalid threshold");
        listThreshold = _newListThreshold;
    }

    function setAntiSnipePer(uint256 _newAntiSnipePer) public onlyOwner {
        require(_newAntiSnipePer > 0, "invalid antisnipe");
        antiSnipePer = _newAntiSnipePer;
    }

    function setAffiliatePer(uint256 _newAffPer) public onlyOwner {//משנה עמלת שותפים
        require(_newAffPer > 0, "invalid affiliate");
        affiliatePer = _newAffPer;
    }

    function emitRoyal( //royal פונקציה שמפעילה את האירוע 
        address tokenAddress,
        uint256 liquidityAmount,
        uint256 tokenAmount,
        uint256 time,
        uint256 totalVolume
    ) public {
        require(msg.sender == funPool, "invalid caller");
        emit royal(tokenAddress, liquidityAmount, tokenAmount, time, totalVolume);
    }
}
