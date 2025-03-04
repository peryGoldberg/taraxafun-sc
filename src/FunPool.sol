// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Clones} from "./libraries/Clones.sol";
import {IFunDeployer} from "./interfaces/IFunDeployer.sol";
import {IFunEventTracker} from "./interfaces/IFunEventTracker.sol";
import {IFunLPManager} from "./interfaces/IFunLPManager.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IFunToken} from "./interfaces/IFunToken.sol";
import {IChainlinkAggregator} from "./interfaces/IChainlinkAggregator.sol";

// import {INonfungiblePositionManager} from "@v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
// import {IUniswapV3Factory} from "@v3-core/contracts/interfaces/IUniswapV3Factory.sol";
// import {IUniswapV3Pool} from "@v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {IRouter} from "@velodrome/interfaces/IRouter.sol";
import {IPoolFactory} from "@velodrome/interfaces/factories/IPoolFactory.sol";
import {console} from "forge-std/console.sol";

contract FunPool is Ownable, ReentrancyGuard {
    //ERC20 חוזה לניהול בריכות מסחר לטוקנים המבוססים על  
      // Uniswap V3  עם אינטגרציה ל
 
    using FixedPointMathLib for uint256; // לחישוב פעולות מתמטיות

    struct FunTokenPoolData { //data
        uint256 reserveTokens; //כמות הטוקנים שבבריכה
        uint256 reserveTARA; //ERC20 טוקן מסוג 
        uint256 volume; //  נפח המסחר שנעשה  
        uint256 listThreshold; // הסף המינימלי שצריך לשים בבריכה כדי להיכלל ברשימה
        uint256 initialReserveTARA; // כמות התחלתית שיש בבריכה
        uint256 maxBuyPerWallet; // כמות הטוקנים המקסימלית שארנק יכול לקנות
        bool tradeActive; //בודק אם המסחר אפשרי
        bool royalemitted; //בודק אם אפשר לשחרר תגמול תגמולים 
    }

    struct FunTokenPool { //הפרטים על הטוקן
        address creator;
        address token;
        address baseToken;
        address router;
        address lockerAddress;
        address storedLPAddress;
        address deployer;
        FunTokenPoolData pool;
    }

    uint256 public constant BASIS_POINTS = 10000;
    uint24  public uniswapPoolFee = 10000;

    address public wtara           = 0x5d0Fa4C5668E5809c83c95A7CeF3a9dd7C68d4fE;
    address public stable          = 0x69D411CbF6dBaD54Bfe36f81d0a39922625bC78c;
    address public factory         = 0x5EFAc029721023DD6859AFc8300d536a2d6d4c82;
    address public router          = 0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858; //velodrome
    address public positionManager = 0x1C5A295E9860d127D8A3E7af138Bb945c4377ae7; //כתובת של מצב מנהל
    address public oracle          = 0xe03e2C41c8c044192b3CE2d7AFe49370551c7f80;

    address public implementation;
    address public feeContract;
    address public LPManager;
    address public eventTracker;
 

    // deployer allowed to create fun tokens
    //משתמשים מורשים להפעלת הבריכה 
    mapping(address => bool) public allowedDeployers;
    // user => array of fun tokens
    //שומר עבור כל משתמש את רשימת הטוקנים שלו
    mapping(address => address[]) public userFunTokens;
    // fun token => fun token details
    // עבור כל טוקן, שומר את פרטיו
    mapping(address => FunTokenPool) public tokenPools;
    /// represents the tick spacing for each fee tier
    //אין שימוש בחוזה
    mapping(uint24 => int256) public tickSpacing;
 // אירוע של הוספת נזילות
    event LiquidityAdded(address indexed provider, uint256 tokenAmount, uint256 taraAmount);
// אירוע של הוספת טוקן
    event listed(
        address indexed tokenAddress,
        address indexed router,
        address indexed pair, //הצמדה
        uint256 liquidityAmount,
        uint256 tokenAmount,
        uint256 time,
        uint256 totalVolume
    );
//אירוע של מכירת וקנית  טוקנים
    event tradeCall(
        address indexed caller,
        address indexed funContract,
        uint256 inAmount,
        uint256 outAmount,
        uint256 reserveTARA,
        uint256 reserveTokens,
        uint256 timestamp,
        string tradeType
    );

    constructor(
        address _implementation,
        address _feeContract,
        address _eventTracker
    ) Ownable(msg.sender) {

        implementation = _implementation;
        feeContract    = _feeContract;
        eventTracker   = _eventTracker;
    }
//הפונקציה  אחראית על יצירת טוקן חדש והגדרת בריכת המסחר הראשונית עבורו
    function initFun( 
        string[2] memory _name_symbol,
        uint256 _totalSupply,
        address _creator,
        uint256[2] memory listThreshold_initReserveTARA,
        uint256 _maxBuyPerWallet
    ) public payable returns (address) {
        require(allowedDeployers[msg.sender], "not deployer");

        address funToken = Clones.clone(implementation);
        IFunToken(funToken).initialize(_totalSupply, _name_symbol[0], _name_symbol[1], address(this), msg.sender);

        // add tokens to the tokens user list
        userFunTokens[_creator].push(funToken);

        // create the pool data
        FunTokenPool memory pool;
        // מכניס את כל הנתונים והפרטים
        pool.creator = _creator;
        pool.token = funToken;
        pool.baseToken = wtara;
        pool.router = router;
        pool.deployer = msg.sender;

        pool.pool.tradeActive = true;
        pool.pool.reserveTokens += _totalSupply;
        pool.pool.reserveTARA += (listThreshold_initReserveTARA[1] + msg.value);
        pool.pool.listThreshold = listThreshold_initReserveTARA[0];
        pool.pool.initialReserveTARA = listThreshold_initReserveTARA[1];
        pool.pool.maxBuyPerWallet = _maxBuyPerWallet;

        // add the fun data for the fun token
        tokenPools[funToken] = pool;

        emit LiquidityAdded(address(this), _totalSupply, msg.value);

        return address(funToken); 
    }

    //TARA מחזיר לו את החשבון כמה טוקנים הוא אמור לקבל בעד ה  
    // Calculate amount of output tokens based on input TARA
    //num- 10tara * 50token =500
    //den- 20tara + 10tara=30
    // 500/30 = 16.3
    //יקבל 16.3
    function getAmountOutTokens(address _funToken, uint256 _amountIn) public view returns (uint256 amountOut) {
        require(_amountIn > 0, "Invalid input amount");
        FunTokenPool storage token = tokenPools[_funToken];
        require(token.pool.reserveTokens > 0 && token.pool.reserveTARA > 0, "Invalid reserves");

        uint256 numerator = _amountIn * token.pool.reserveTokens;
        uint256 denominator = (token.pool.reserveTARA) + _amountIn;
        amountOut = numerator / denominator;
    }
// מחזיר לו את החשבון כמה טרה הוא אמור לקבל בעד הטוקנים  
    // Calculate amount of output TARA based on input tokens
    function getAmountOutTARA(address _funToken, uint256 _amountIn) public view returns (uint256 amountOut) {
        require(_amountIn > 0, "Invalid input amount");
        FunTokenPool storage token = tokenPools[_funToken];
        require(token.pool.reserveTokens > 0 && token.pool.reserveTARA > 0, "Invalid reserves");

        uint256 numerator = _amountIn * token.pool.reserveTARA;
        uint256 denominator = (token.pool.reserveTokens) + _amountIn;
        amountOut = numerator / denominator;
    }

//base token מקבל כתובת ומחזיר עבור כתובת הטוקן את 
    function getBaseToken(address _funToken) public view returns (address) {
        FunTokenPool storage token = tokenPools[_funToken];
        return address(token.baseToken);
    }

    //TARAמחשב את  שווי השוק של הטוקן ביחס ל 
    function getCurrentCap(address _funToken) public view returns (uint256) {
        FunTokenPool storage token = tokenPools[_funToken];

        // latestPrice() is in 1e8 format
        uint256 latestPrice = uint(IChainlinkAggregator(oracle).latestAnswer() / 1e2);

        uint256 amountMinToken = FixedPointMathLib.mulWadDown(token.pool.reserveTARA, latestPrice);

        return (amountMinToken * IERC20(_funToken).totalSupply()) / token.pool.reserveTokens;
    }

//מקבל כתובת ומחזיר את הפרטים של הטוקן
    function getFuntokenPool(address _funToken) public view returns (FunTokenPool memory) {
        return tokenPools[_funToken];
    }

//הפונקציה מחזירה מערך של פרטי טוקנים עבור רשימת טוקנים נתונה.
    function getFuntokenPools(address[] memory _funTokens) public view returns (FunTokenPool[] memory) {
        uint256 length = _funTokens.length;
        FunTokenPool[] memory pools = new FunTokenPool[](length);
        for (uint256 i = 0; i < length;) {
            pools[i] = tokenPools[_funTokens[i]];
            unchecked { //overflow בודק 
                i++;
            }
        }
        return pools;
    }

// מקבל כתובת משתמש ומחזיר מערך של כל הטוקנים שלו
    function getUserFuntokens(address _user) public view returns (address[] memory) {
        return userFunTokens[_user];
    }

// הפונקציה  בודקת אם המשתמש יכול לקנות כמות מסוימת של טוקנים מבלי לעבור את המגבלה המוגדרת עבור טוקן מסוים 
    function checkMaxBuyPerWallet(address _funToken, uint256 _amount) public view returns (bool) {
        FunTokenPool memory token = tokenPools[_funToken];
        uint256 userBalance = IERC20(_funToken).balanceOf(msg.sender);
        return userBalance + _amount <= token.pool.maxBuyPerWallet;
    }

//הפונקציה  מאפשרת למשתמש למכור טוקנים ולהמיר אותם לכסף 
// תוך שמירה על מגבלות שונות. הפונקציה גם מטפלת בעמלות שותפים
// עמלות פיתוח ועמלות אחרות 
    function sellTokens(address _funToken, uint256 _tokenAmount, uint256 _minEth, address _affiliate)
        public
        nonReentrant // שלא יקרה יותר מפעם אחת
    {
        FunTokenPool storage token = tokenPools[_funToken];
        require(token.pool.tradeActive, "Trading not active");

        uint256 tokenToSell = _tokenAmount;
        //מחשב כמה טרה מקבלים על הטוקנים שרוצים למכור
        uint256 taraAmount = getAmountOutTARA(_funToken, tokenToSell);
        //חישוב העמלה הכללית של העסקה
        uint256 taraAmountFee = (taraAmount * IFunDeployer(token.deployer).getTradingFeePer()) / BASIS_POINTS;
       //חישוב העמלה שתינתן למפתחי המערכת
        uint256 taraAmountOwnerFee = (taraAmountFee * IFunDeployer(token.deployer).getDevFeePer()) / BASIS_POINTS;
       //ישוב העמלה שתינתן לשותף
        uint256 affiliateFee =
            (taraAmountFee * (IFunDeployer(token.deployer).getAffiliatePer(_affiliate))) / BASIS_POINTS;
        // בודקת שהכמות המתקבלת  לא אפס ושהיא לא פחותה מהכמות המינימלית שהוגדרה על ידי המשתמש 
        // אם תנאי זה לא מתקיים, הפונקציה תפסול את העסקה
        require(taraAmount > 0 && taraAmount >= _minEth, "Slippage too high");
//משנה את הנתונים; מעלה את הטוקנים ןמוריד את הטרה
        token.pool.reserveTokens += _tokenAmount;
        token.pool.reserveTARA -= taraAmount;
        token.pool.volume += taraAmount;
// :העברות כספים
//לכתובת העמלות לשותף אם יש כזה.למפתחי המערכת.לשולח עצמו (המשתמש שמוכר את הטוקנים).
//כל העברה מתבצעת באמצעות קריאה לפונקציה  עם הערך  המתאים.
//require כל קריאה חייבת להצליח או שהיא תפסול את העסקה בדיקה באמצעות  .
        IERC20(_funToken).transferFrom(msg.sender, address(this), tokenToSell);
        (bool success,) = feeContract.call{value: taraAmountFee - taraAmountOwnerFee - affiliateFee}("");
        require(success, "fee TARA transfer failed");

        (success,) = _affiliate.call{value: affiliateFee}(""); 
        require(success, "aff TARA transfer failed");

        (success,) = payable(owner()).call{value: taraAmountOwnerFee}(""); 
        require(success, "ownr TARA transfer failed");

        (success,) = msg.sender.call{value: taraAmount - taraAmountFee}("");
        require(success, "seller TARA transfer failed");

//trade call קורא לאירוע של מכירה טוקנים
        emit tradeCall(
            msg.sender,
            _funToken,
            tokenToSell,
            taraAmount,
            token.pool.reserveTARA,
            token.pool.reserveTokens,
            block.timestamp,
            "sell"
        );
//Event tracker מעביר את המידע לחוזה 
        IFunEventTracker(eventTracker).sellEvent(msg.sender, _funToken, tokenToSell, taraAmount);
    }

//הפונקציה  מאפשרת למשתמש לקנות טוקנים   
// תוך שמירה על מגבלות שונות. הפונקציה גם מטפלת בעמלות שותפים
// עמלות פיתוח ועמלות אחרות 
    function buyTokens(address _funToken, uint256 _minTokens, address _affiliate) public payable nonReentrant {
        require(msg.value > 0, "Invalid buy value");
        FunTokenPool storage token = tokenPools[_funToken];
        require(token.pool.tradeActive, "Trading not active");

        uint256 taraAmount = msg.value;
        uint256 taraAmountFee = (taraAmount * IFunDeployer(token.deployer).getTradingFeePer()) / BASIS_POINTS;
        uint256 taraAmountOwnerFee = (taraAmountFee * (IFunDeployer(token.deployer).getDevFeePer())) / BASIS_POINTS;
        uint256 affiliateFee = (taraAmountFee * (IFunDeployer(token.deployer).getAffiliatePer(_affiliate))) / BASIS_POINTS;

        uint256 tokenAmount = getAmountOutTokens(_funToken, taraAmount - taraAmountFee);
        require(tokenAmount >= _minTokens, "Slippage too high");
        require(checkMaxBuyPerWallet(_funToken, tokenAmount), "Max buy per wallet exceeded");

        token.pool.reserveTARA += (taraAmount - taraAmountFee);
        token.pool.reserveTokens -= tokenAmount;
        token.pool.volume += taraAmount;

        (bool success,) = feeContract.call{value: taraAmountFee - taraAmountOwnerFee - affiliateFee}("");
        require(success, "fee TARA transfer failed");

        (success,) = _affiliate.call{value: affiliateFee}("");
        require(success, "fee TARA transfer failed");

        (success,) = payable(owner()).call{value: taraAmountOwnerFee}(""); 
        require(success, "fee TARA transfer failed");

        IERC20(_funToken).transfer(msg.sender, tokenAmount);

        emit tradeCall(
            msg.sender,
            _funToken,
            taraAmount,
            tokenAmount,
            token.pool.reserveTARA,
            token.pool.reserveTokens,
            block.timestamp,
            "buy"
        );
        
        IFunEventTracker(eventTracker).buyEvent(
            msg.sender, 
            _funToken, 
            msg.value, 
            tokenAmount
        );

//לאחר שהשווי שוק של הטוקן עבר סף מסוים,
//מתבצע תהליך של הוספת נזילות ל- דקס ורישום הטוקן בבורסה
        uint256 currentMarketCap = getCurrentCap(_funToken);

        uint256 listThresholdCap = token.pool.listThreshold * (10 ** IERC20Metadata(stable).decimals());

        /// royal emit when marketcap is half of listThresholdCap
        //אם שווי השוק הגיע לחצי, מפעיל את האירוע רויאל
        if (currentMarketCap >= (listThresholdCap / 2) && !token.pool.royalemitted) {
            IFunDeployer(token.deployer).emitRoyal(
                _funToken, token.pool.reserveTARA, token.pool.reserveTokens, block.timestamp, token.pool.volume
            );
            token.pool.royalemitted = true;
        }
        // using marketcap value of token to check when to add liquidity to DEX
        //Threshold הוספת נזילות לבורסה כאשר המרקט קאפ חצה את ה 
        if (currentMarketCap >= listThresholdCap) {
            token.pool.tradeActive = false;
            IFunToken(_funToken).initiateDex();
            token.pool.reserveTARA -= token.pool.initialReserveTARA;

             _addLiquidityVelodrome(_funToken, IERC20(_funToken).balanceOf(address(this)), token.pool.reserveTARA);
            uint256 reserveTARA = token.pool.reserveTARA;
            token.pool.reserveTARA = 0;

//מופעל כדי לרשום את הטוקן בבורסה, עם כל הנתונים הרלוונטיים (הכמות שנותרה של טוקנים וכו)
            emit listed(
                token.token,
                token.router,
                token.storedLPAddress,
                reserveTARA,
                token.pool.reserveTokens,
                block.timestamp,
                token.pool.volume
            );
        }
    }
   // מבצעת הוספת נזילות (liquidity) לפלטפורמת  Velodrome עבור טוקן מסוג _funToken ו-WETH
    function _addLiquidityVelodrome(address _funToken, uint256 _amountTokenDesired, uint256 _nativeForDex) internal {
        
       address tokenA = _funToken;
        address tokenB = wtara;

         uint256 amountADesired = (tokenA == _funToken ? _amountTokenDesired : _nativeForDex);
         uint256 amountBDesired = (tokenA == _funToken ? _nativeForDex : _amountTokenDesired);
        //כמה יחס צריך לקחת???
         uint256 amountAMin = (amountADesired * 98) / 100;
         uint256 amountBMin = (amountBDesired * 98) / 100;

        // IWETH(wtara).deposit{value: _nativeForDex}();
        IERC20(wtara).approve(positionManager, _nativeForDex);
        IERC20(_funToken).approve(positionManager, _amountTokenDesired);

               
        IRouter(positionManager).addLiquidity(tokenA,tokenB,true,amountADesired,amountBDesired,
        amountAMin,amountBMin,address(this),block.timestamp + 1);
    
    }

    // המטרה היא לחשב ולהחזיר את שורש המחיר ברמה של דיוק גבוהה
    // חישוב של שורש ריבועי של המחיר
    function encodePriceSqrtX96(uint256 price_numerator, uint256 price_denominator) internal pure returns (uint160) {
        require(price_denominator > 0, "Invalid price denominator");
    // חילוק מונה במכנה
        uint256 sqrtPrice = sqrt(price_numerator.divWadDown(price_denominator));
    //הדפסת התוצאה
        console.log("sqrtPrice: %s", sqrtPrice);
        
        // Q64.96 fixed-point number divided by 1e9 for underflow prevention
        return uint160((sqrtPrice * 2**96) / 1e9);
    }


    // חישוב שורש ריבועי של מספר
    // פונקציה עזר לחישוב השורש הריבועי של מספר y
    // Helper function to calculate square root
    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
     // פונקציה זו מוסיפה כתובת (_deployer) לרשימה של "deployer" שמורשים לפעול על החוזה. 
    function addDeployer(address _deployer) public onlyOwner {
        allowedDeployers[_deployer] = true;
    }

    // פונקציה זו מסירה כתובת (_deployer) מהרשימה של "deployer" המורשים.
    function removeDeployer(address _deployer) public onlyOwner {
        allowedDeployers[_deployer] = false;
    }

    // קובעת את כתובת החוזה של היישום החדש
    function setImplementation(address _implementation) public onlyOwner {
        require(_implementation != address(0), "Invalid implementation");
        implementation = _implementation;
    }
     // קובעת את כתובת החוזה של חוזה העמלות
    function setFeeContract(address _newFeeContract) public onlyOwner {
        require(_newFeeContract != address(0), "Invalid fee contract");
        feeContract = _newFeeContract;
    }
     // קובעת את כתובת מנהל ה LP
    function setLPManager(address _newLPManager) public onlyOwner {
        require(_newLPManager != address(0), "Invalid LP lock deployer");
        LPManager = _newLPManager;
    }

    // קובעת את כתובת המעקב אחרי אירועים
    function setEventTracker(address _newEventTracker) public onlyOwner {
        require(_newEventTracker != address(0), "Invalid event tracker");
        eventTracker = _newEventTracker;
    }

    // קובעת את כתובת המטבע היציב
    function setStableAddress(address _newStableAddress) public onlyOwner {
        require(_newStableAddress != address(0), "Invalid stable address");
        stable = _newStableAddress;
    }

    function setWTARA(address _newwtara) public onlyOwner {
        require(_newwtara != address(0), "Invalid wtara");
        wtara = _newwtara;
    }

    function setFactory(address _newFactory) public onlyOwner {
        require(_newFactory != address(0), "Invalid factory");
        factory = _newFactory;
    }

    function setRouter(address _newRouter) public onlyOwner {
        require(_newRouter != address(0), "Invalid router");
        router = _newRouter;
    }

    function setPositionManager(address _newPositionManager) public onlyOwner {
        require(_newPositionManager != address(0), "Invalid position manager");
        positionManager = _newPositionManager;
    }

//לשנות!!!
    // קובעת את כתובת מנהל המיקומים 
    function setUniswapPoolFee(uint24 _newuniswapPoolFee) public onlyOwner {
        require(_newuniswapPoolFee > 0, "Invalid pool fee");
        uniswapPoolFee = _newuniswapPoolFee;
    }

    // מאפשרת לבעלים של החוזה למשוך טוקנים (ERC-20) מתוך החוזה במקרה חירום. 
    // זה לא משיחת שטיח?
    function emergencyWithdrawToken(address _token, uint256 _amount) public onlyOwner {
        IERC20(_token).transfer(owner(), _amount);
    }

    // מאפשרת לבעלים של החוזה למשוך Ether או TARA  מתוך החוזה במקרה חירום.
    // הפונקציה משתמשת בפקודת call .
    //כדי לשלוח את האיטריום לבעלים של החוזה ותוך כדי מבצעת בדיקת הצלחה על מנת לוודא שההעברה בוצעה כראוי.
    function emergencyWithdrawTARA(uint256 _amount) public onlyOwner {
        (bool success,) = payable(owner()).call{value: _amount}("");
        require(success, "TARA transfer failed");
    }

    // מאפשרת לקבל איטריום 
    receive() external payable { }
}
