// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {INonfungiblePositionManager} from "@v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IFunStorageInterface} from "./interfaces/IFunStorageInterface.sol";

// החוזה מאפשר לנהל את הפוזיציות של ה-LP, לאסוף עמלות (fees) מהן ולחלק את העמלות בין המפתחים ובעל החוזה, תוך שמירה על ניהול מותאם לפוזיציות מסוג ERC721 (NFTs). 
//בנוסף, החוזה מספק את האפשרות לשנות את שיעור העמלה וכולל גם אפשרות למשיכה חירומית של NFTs.
contract FunLPManager is Ownable, IERC721Receiver {

    struct LPPosition {
        address dev;
        uint256 token0Collected;
        uint256 token1Collected;
    }

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public feePer;

    address public positionManager = 0x1C5A295E9860d127D8A3E7af138Bb945c4377ae7;

    address public funPool;

    mapping(uint256 => LPPosition) public tokenIdToLPPosition;
    mapping(address => uint256[])  public devToTokenIds;

    event PositionDeposited(
        uint256 tokenId, 
        address dev, 
        uint256 timestamp
    );

    event FeesCollected(
        uint256 tokenId, 
        address dev,
        address token,
        uint256 amount,
        uint256 timestamp
    );

    constructor(
        address _funPool,
        uint256 _feePer
    ) Ownable(msg.sender) {
        funPool = _funPool;
        feePer = _feePer;
    }

    // מאפשר להפקיד פוזיציה חדשה של NFT.
    // רק ה-funPool מורשה לקרוא לפונקציה זו
    function depositNFTPosition(uint256 _tokenId, address _dev) external {
        require(msg.sender == funPool, "LPManager: Only FunPool can call this function");

        IERC721(positionManager).transferFrom(funPool, address(this), _tokenId);

        LPPosition memory lpPosition = LPPosition({
            dev: _dev,
            token0Collected: 0,
            token1Collected: 0
        });

        tokenIdToLPPosition[_tokenId] = lpPosition;
        devToTokenIds[_dev].push(_tokenId);

        emit PositionDeposited(_tokenId, _dev, block.timestamp);
    }

    // איסוף עמלות
    // מאשרת שרק המפתח (dev) או בעל החוזה (owner) יכולים לאסוף את העמלות.
    // משיכה של העמלות נעשית עבור שני סוגי המטבעות (אם יש) והשארת אחוז העמלה עבור בעל החוזה.
    function collectFees(uint256 _tokenId) external {

        LPPosition storage lpPosition = tokenIdToLPPosition[_tokenId];

        require(IERC721(positionManager).ownerOf(_tokenId) == address(this), "LPManager: LP Token not owned by LPManager"); // בודק האם שייך למנהל של החוזה הנוכחי
        require((msg.sender == lpPosition.dev) || (msg.sender == owner()), "LPManager: Only Dev or Owner can collect fees"); // בודקת אם מי שמבצע את הפעולה מפתח או בעל החוזה

    //איסוף העמלות
    // המשתנים amount0 ו-amount1 מייצגים את הכמויות של שני סוגי הטוקנים שמתקבלים בעת איסוף העמלות מתוך הפוזיציה הבלתי ניתנת להחלפה (LP Position).
    // amount0: מייצג את כמות הטוקן הראשון שנאסף. זה יכול להיות, למשל, ERC-20 טוקן כמו USDC, ETH, או כל טוקן אחר שמוזן לפוזיציה.
    //amount1: מייצג את כמות הטוקן השני שנאסף, שיכול להיות טוקן אחר (למשל, DAI, WBTC או כל טוקן אחר במערכת).

        (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(positionManager).collect(INonfungiblePositionManager.CollectParams({
            tokenId: _tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        }));

        (,,address token0, address token1,,,,,,,,) = INonfungiblePositionManager(positionManager).positions(_tokenId);

        if (amount0 > 0) {
            uint256 feeAmount0 = (amount0 * feePer) / BASIS_POINTS;
            IERC20(token0).transfer(owner(), feeAmount0);
            IERC20(token0).transfer(lpPosition.dev, amount0 - feeAmount0);

            emit FeesCollected(_tokenId, lpPosition.dev, token0, amount0, block.timestamp);
        }

        if (amount1 > 0) {
            uint256 feeAmount1 = (amount1 * feePer) / BASIS_POINTS;
            IERC20(token1).transfer(owner(), feeAmount1);
            IERC20(token1).transfer(lpPosition.dev, amount1 - feeAmount1);

            emit FeesCollected(_tokenId, lpPosition.dev, token1, amount1, block.timestamp);
        }
    }

    // פונקציה לקבלת NFT (onERC721Received)
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    //  הגדרת שיעור העמלה
    function setFeePer(uint256 _feePer) external onlyOwner {
        require(_feePer > 0, "LPManager: Fee Per must be greater than 0");
        feePer = _feePer;
    }

    // משיכת NFT במצב חירום
    function emergencyWithdrawERC721(address _token, uint256 _tokenId) external onlyOwner {
        IERC721(_token).transferFrom(address(this), owner(), _tokenId);
    }
}